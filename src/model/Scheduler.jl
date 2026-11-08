# src/model/Scheduler.jl

"""
    agent_step!(agent, model)
Evolution of the agent state.
- Primary logic (Aging/Death) is now handled in `demographics_step!` at the model level
- to ensure strict Stationary Population adherence (Carro et al. 2022).
- This function remains for consistency with Agents.jl API or future agent-specific non-demographic logic.
"""
function agent_step!(agent, model)
    # Placeholder: No biological aging or death here.
    return
end

# REMOVED: Legacy process_death! which was overwriting the Demographics implementation.
# The logic has been moved to Demographics.jl.

const _ND31_HEADER_WRITTEN = Ref(false)

function nd31_log_phase!(model, phase_id::AbstractString)
    Config.ND31_DIAGNOSTIC || return
    stock = model.housing_stock
    n_total = length(stock)
    n_total == 0 && return
    step = Agents.abmtime(model)
    n_vacant   = count(h -> h.resident_id === nothing, stock)
    n_unlisted = count(h -> h.resident_id === nothing && !h.is_for_sale && !h.is_for_rent, stock)
    n_for_sale = count(h -> h.resident_id === nothing && h.is_for_sale, stock)
    n_for_rent = count(h -> h.resident_id === nothing && h.is_for_rent, stock)
    path = Config.ND31_LOG_PATH
    mode = (!_ND31_HEADER_WRITTEN[] && !isfile(path)) ? "w" : "a"
    open(path, mode) do io
        if mode == "w"
            println(io, "step,phase_id,n_total,n_vacant,n_unlisted,n_for_sale,n_for_rent")
        end
        println(io, "$step,$phase_id,$n_total,$n_vacant,$n_unlisted,$n_for_sale,$n_for_rent")
    end
    _ND31_HEADER_WRITTEN[] = true
    return
end

"""
    model_step!(model)
The Global Stepping Function.
Equivalent to `Model.java` -> `modelStep()`.

Execution Order:
0. Demographics (Stationary Population Logic)
1. Regulatory Update
2. Financial Flows
3. Markets (Supply, Sales, Rental)
4. Cleanup & Stats
5. Macro-Financial Loop
"""
function model_step!(model)

    # --- Phase 0: Reset Mechanism Counters (Flow Variables) ---
    model.market_stats.n_withdrawals = 0
    model.market_stats.n_bankruptcies = 0
    model.market_stats.n_bankruptcies_ftb = 0
    model.market_stats.n_bankruptcies_hm  = 0
    model.market_stats.n_bankruptcies_btl = 0

    nd31_log_phase!(model, "P00_entry")

    # ------------------------------------------------------------------
    # 0. Demographics (Population Maintenance)
    # ------------------------------------------------------------------
    # Forces Stationary Population Structure (UK 2011)
    # Replaces biological aging/mortality.
    demographics_step!(model)
    nd31_log_phase!(model, "P01_post_demographics")

    # ------------------------------------------------------------------
    # 1. Construction (Housing Supply)
    # ------------------------------------------------------------------
    # Runs unconditionally every tick, mirroring Java's modelStep() sequence:
    #   Model.java line 186: demographics.step();
    #   Model.java line 187: construction.step();
    #
    # Each tick the module:
    #   (a) applies a 5 % price cut to stale construction-sector listings,
    #   (b) computes target stock = min(n_hh, TARGET_POP) × HOUSES_PER_HH,
    #   (c) creates new House objects and distributes them via inherit_house!
    #       whenever a positive shortfall exists.
    # No boolean flag gates this call — it is unconditional (Java parity).
    # See Construction.jl for full documentation.
    construction_step!(model)
    nd31_log_phase!(model, "P02_post_construction")

    # ------------------------------------------------------------------
    # 1c. OO LTV Rolling Window: Pre-Clearing Slot Rotation
    # ------------------------------------------------------------------
    # bank.oo_ltv_window accumulates LTV-at-origination values for new
    # Owner-Occupier mortgages across a rolling ROLLING_WINDOW-month span.
    # It uses a circular slot structure: one slot per calendar month.
    # Before market clearing fires, the active slot must be advanced and
    # emptied so that register_mortgage! (called during clearing) writes
    # this month's values into a fresh, blank slot.
    #
    # This block is structurally and architecturally separate from the
    # post-clearing LTI reporting in Phase 5b (report_and_reset_activity!).
    # The two operations share no state and have incompatible timing contracts:
    #
    #   • Slot rotation  (this block, Phase 1c) — MUST be pre-clearing:
    #     clearing fills the freshly emptied slot during the same tick.
    #
    #   • LTI reporting  (Phase 5b) — MUST be post-clearing:
    #     the flow counters (current_month_total_ftb etc.) are populated by
    #     register_mortgage! during clearing and must be committed to the
    #     rolling history only once the full clearing pass is complete.
    #
    let b = model.bank
        b.oo_ltv_index = (b.oo_ltv_index % length(b.oo_ltv_window)) + 1
        empty!(b.oo_ltv_window[b.oo_ltv_index])
        empty!(b.oo_lti_window[b.oo_ltv_index])  # LTI shares the same slot index
    end
    nd31_log_phase!(model, "P03_post_ltv_rotation")

    # --- Phase 2: Financial Flows (Strict Sequence per Section 3.1) ---
    
    # Java (Household.java:87-93): updateDesiredPurchasePrice() runs as the FIRST statement
    # of step(), BEFORE income is credited. D18=true replicates this ordering.
    # When D18=true, the Phase 2d block below is skipped (no double-update).
    if Config.D18_PRE_INCOME_BEHAVIORAL
        _ids_d18 = Config.ND37_SORTED_BEHAVIORAL_UPDATE ? sort!(collect(allids(model))) : allids(model)
        for id in _ids_d18
            update_behavioral_state!(model[id], model)
        end
    end

    # 2a. Mandatory Obligations (Income, Tax, Shelter)
    process_income_and_obligations!(model)
    nd31_log_phase!(model, "P04_post_income_obligations")

    # 2b. Discretionary Consumption
    # Java: Household.java:97-101 — consumption CAN drive bankBalance negative (overdraft).
    # This is INTENTIONAL per Carro et al. (2022) — bailout happens AFTER consumption.
    process_discretionary_consumption!(model)
    
    # 2c. Post-Consumption Insolvency Resolution (The "Magic Cash" Intervention)
    # Java Logic (Household.java:103-107): Single bankruptcy check AFTER consumption.
    # "artificially injecting as much cash as necessary".
    # Consumption can drive bankBalance negative, then bailout occurs.
    #
    # --- IMPORTANT ---
    # In contrast to Java, the Julia implementation must call resolve_insolvency! TWICE per step:
    #   1. After consumption (here), to resolve negative balances from discretionary spending.
    #   2. After market clearing (see below), to resolve negative balances from forced sales or other market actions.
    # This ensures that negative balances never persist through any phase, as required by the paper's specification:
    #   "Whenever this happens, we make sure all committed payments are always made by artificially injecting as much cash as necessary, without further action against the bankrupt household" (Appendix A.4).

    resolve_insolvency!(model)
    nd31_log_phase!(model, "P05_post_insolvency")

    # --- Phase 2d: Behavioral State Update ---
    # [PAPER-COMPLIANT — Section 3.1, Steps 2(a) and 2(b)]
    # The paper mandates a strict two-part sequence within each simulation month:
    #   Step 2(a): Households "receive income, consume and pay housing expenses".
    #              This includes receiving monthly income, collecting rent, paying taxes,
    #              paying housing expenses, AND deciding on discretionary consumption.
    #   Step 2(b): Households "make their housing decisions, according to their current status".
    #              This is where desired purchase prices, rent-or-buy evaluations, and
    #              BTL yield decisions are made.
    # Therefore, update_behavioral_state! MUST be placed here — after process_income_and_obligations!
    # (Phase 2a), process_discretionary_consumption! (Phase 2b), AND resolve_insolvency! (Phase 2c) —
    # so agents evaluate their housing decisions against their fully-finalized end-of-month wealth.
    #
    # JAVA DIVERGENCE (Household.java:84–92): Java calls updateDesiredPurchasePrice as the FIRST
    # statement of step(), before any income is credited to bankBalance. Concretely:
    #   Line 87: desiredPurchasePrice = behaviour.updateDesiredPurchasePrice(annualGrossEmploymentIncome);
    #   Line 93: bankBalance += monthlyDisposableIncome;  <-- income arrives AFTER price is set
    # This violates Section 3.1 and introduces a systematic bias in the mortgage and bidding
    # calculations that depend on the household's financial wealth w at the time of the decision:
    #

    # ── D18 guard: skip Phase 2d when behavioral update already ran pre-income ───────────
    # When D18=true, update_behavioral_state! was executed before Phase 2a (matching Java's
    # Household.java:87 ordering). Running it again here would double-update and consume
    # an extra RNG draw per agent. The !D18 guard prevents this.
    if !Config.D18_PRE_INCOME_BEHAVIORAL
        _ids_p2d = Config.ND37_SORTED_BEHAVIORAL_UPDATE ? sort!(collect(allids(model))) : allids(model)
        for id in _ids_p2d
            update_behavioral_state!(model[id], model)
        end
    end

    nd31_log_phase!(model, "P06_post_behavioral_update")

    # --- Phase 2e: Investor Updates (Behavioral) ---

    
    # --- Phase 3: Housing Decisions (The "Push" Phase) ---
    # Agents assess state and "Push" Bids or Offers to the Market queues.
    # This must happen AFTER Phase 2 so they use current wealth (Step t).
    submit_market_bids!(model)
    nd31_log_phase!(model, "P07_post_submit_bids")

    # --- Phase 3: Markets ---
    
    # 3a. Supply Side Updates (Sales)
    # Sellers cut prices on stale listings & new sellers enter
    update_for_sale_supply!(model)
    nd31_log_phase!(model, "P08_post_for_sale_supply")
    
    # 3b. Sales Market (The "Clearing")
    # Agents buy houses using the updated prices
    # We run Sales BEFORE Rental so BTL investors can rent out immediately (Carro et al. 2022)
    clear_sales_market!(model)
    nd31_log_phase!(model, "P09_post_sales_clearing")

    # 3c. Supply Side Updates (Rental)
    # Landlords cut rents on empty properties & New Inventory from Sales enters here
    update_rental_supply!(model) 
    nd31_log_phase!(model, "P10_post_rental_supply")

    # 3d. Rental Market (The "Clearing")
    # Homeless agents find shelter using the updated rents
    clear_rental_market!(model)
    nd31_log_phase!(model, "P11_post_rental_clearing")

    # --- Phase 4: Cleanup ---
    #
    # JAVA (Household.java:84–109 + Model.modelStep()): Single insolvency check per tick.
    #   Household.step() contains exactly one check, placed after consumption (lines 104–108):
    #     if (bankBalance < 0.0) { bankBalance = 1.0; isBankrupt = true; }
    #   Model.modelStep() then calls clearMarket() / houseRentalMarket.clearMarket() with
    #   NO subsequent insolvency scan.
    #
    # JULIA (JAVA_COMPAT_MODE=false, default): Two scans per tick.
    #   A second resolve_insolvency! call is placed here as a defensive safety net for any
    #   future market-clearing path that could theoretically leave bank_balance < 0.
    #
    # WHY THE SECOND CALL IS STRUCTURALLY INERT:
    #   After the first resolve_insolvency! (Phase 2c) all agents have bank_balance >= 1.0.
    #   During market clearing, there are exactly TWO bank_balance mutation sites:
    #
    #   (A) Buyer:  buyer.bank_balance -= down_payment
    #       Guarded by a fatal error (HousingMarket.jl, execute_transaction!) that fires if
    #       down_payment > bank_balance. Therefore buyer balance is always >= 0 post-clearing.
    #
    #   (B) Seller: seller.bank_balance += (price - debt_to_settle)
    #       This is a non-negative addition because every cleared transaction satisfies
    #       price >= debt_to_settle (= remaining_principal):
    #         - put_on_market! (HousingMarket.jl:1326) floors listing_price at remaining_principal.
    #         - update_market_prices! (HousingMarket.jl:~1205) WITHDRAWS the listing before any
    #           price rethink goes below remaining_principal.
    #       Therefore (price - debt_to_settle) >= 0 always. No overdraft can occur.
    #
    # NO NEGATIVE-EQUITY BTL FORCED SALES:
    #   A BTL maturity-cliff forced sale cannot produce price < debt_to_settle.
    #   The forced sale triggers put_on_market! which immediately floors the listing at principal.
    #   If market price < principal, the withdrawal mechanism prevents a transaction; the house
    #   is pulled from the market rather than sold at a loss.
    #
    # ZOMBIE DEBT MODE (JAVA_COMPAT_MODE=true):
    #   Under the zombie debt path the bank receives only amount_paid = min(B+price, principal).
    #   The seller balance delta is still (price - debt_to_settle), which is >= 0 for the same
    #   reason: the listing floor + withdrawal guard ensure price >= debt_to_settle at any
    #   actual transaction. Even in the zombie path, no negative balance arises post-clearing.
    #
    # JAVA RETHINK CONSISTENCY (Household.java:252–267, manageHouse):
    #   Java: if (newPrice > mortgageFor(house).principal) { updateOffer(...); }
    #         else { Model.houseSaleMarket.removeOffer(forSale); }   ← EXPLICIT REMOVAL
    #   Julia: `should_withdraw = true` → `house.is_for_sale = false; delete!(active_sales_listings)`
    #   Java ALSO removes the listing — it does NOT silently skip. Both are explicit removals.
    #
    #   Re-listing after removal — both follow the same cycle:
    #   Java:  next tick → manageHouse → forSale == null →
    #          decideToSellInvestmentProperty → maturity cliff still true → putHouseForSale
    #          → fresh listing at max(EMA×η, principal)
    #   Julia: next tick → submit_market_bids! → decision_btl_sell! →
    #          maturity cliff still true → put_on_market!
    #          → fresh listing at max(EMA×η, principal)
    #
    #   Tick gap: both Java and Julia produce a 1-tick absence from the clearing order
    #   (removal happens before clearing, re-listing happens at the start of the next tick).
    #   FULLY CONSISTENT. No divergence in the rethink/removal path.
    #

    # --- Phase 5: Oracles ---
    # Update global statistics (HPI, Average Rent, etc.)
    update_market_stats!(model)
    nd31_log_phase!(model, "P12_post_market_stats")

    # ------------------------------------------------------------------
    # Phase 5b. Bank Regulatory Reporting & Counter Reset (Post-Clearing)
    # ------------------------------------------------------------------
    # Now that market clearing has fully settled all transactions for this
    # month, the Bank commits the finalised mortgage flow data to the
    # Central Bank's rolling LTI history, recomputes the adaptive
    # prospective approval target for the coming month, and zeros the
    # per-type flow counters so they accumulate cleanly from zero.
    #
    # This call MUST be post-clearing because register_mortgage! — invoked
    # from execute_transaction! during clearing — populates the flow counters
    # (current_month_total_ftb, current_month_high_lti_ftb, and HM counterparts).
    # Any earlier placement would reset those counters before clearing runs,
    # discarding that month's data before it reaches the rolling history.
    #
    # Placement here (after post-clearing statistics, before the interest rate
    # update) means the adaptive target is recomputed from a fully settled
    # month before the interest rate mechanism sees the updated supply signal.
    #
    # The OO LTV slot rotation is intentionally absent from this call — it was
    # separated into Phase 1c above because it requires a pre-clearing position.
    # See the docstring of report_and_reset_activity! in Bank.jl for the full
    # separation rationale and the consequences of re-merging.
    report_and_reset_activity!(model)
    nd31_log_phase!(model, "P13_post_bank_report")

    # --- Phase 5c: Central Bank policy activation and income refresh ---
    # An activation at model month t affects subsequent household decisions.
    # Keep this after clearing and the existing monthly quota accounting.
    central_bank_step!(model)
    nd31_log_phase!(model, "P13b_post_central_bank_step")

    # --- Phase 6: Macro-Financial Loop ---
    # Update Interest Rates based on Credit Supply changes (Eq 17)
    # This happens "after all transactions... and mortgages signed"
    update_interest_rate!(model.bank, model)
    nd31_log_phase!(model, "P14_post_interest_rate")


    # -------------------------------------------------------------------------
    # Since step! executes agents FIRST, this model_step! effectively 
    # acts as the "Pre-Step" for the subsequent iteration.
    #
    # 1. Update Global Parameters: Finalize interest rates/macro-shocks here
    #    so they are 'baked in' before the next agent_step! begins.
    # 2. Expectation Management: If agents use forward-looking heuristics,
    #    ensure the model state they will "see" at the start of next 
    #    period is fully updated now.
    # 3. Alternative: If period-congruent shocks are required (Step 0 shock),
    #    transition this logic to a custom evolution loop:
    #    `for i in 1:steps; model_step!(m); agent_step!(m); end` 
    #    to bypass the rigid [Agent -> Model] sequence.
    # -------------------------------------------------------------------------
end




