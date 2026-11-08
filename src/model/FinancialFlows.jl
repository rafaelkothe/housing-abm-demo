# src/model/FinancialFlows.jl
#
# Monthly household financial flows of the housing-market model.
#
# Contents:
#   - effective_essential_nominal_consumption: value of the fixed essential-consumption scalar
#   - resolve_insolvency!: bank-balance floor for households with negative balances
#   - process_income_and_obligations!: wages, contractual rent, taxes, essential
#     consumption and mortgage payments (mandatory flows)
#   - discretionary consumption, rental-income settlement and related bookkeeping
#
# The functions are called from the monthly scheduler in a fixed order; they mutate
# household bank balances and the market statistics held in `model.market_stats`.
# `calculate_net_income` is defined in institutions/Government.jl.

"""
    effective_essential_nominal_consumption(model)::Float64

Value of the fixed monthly essential-consumption scalar corresponding to the
Java constant `config.ESSENTIAL_NOMINAL_CONSUMPTION` of the Spain configuration.

Returns:
- `Config.ESSENTIAL_NOMINAL_CONSUMPTION_SPAIN_VALUE` (200.0) when
  `model.spain_essential_nominal_consumption == true`
- `Config.ESSENTIAL_NOMINAL_CONSUMPTION` (0.0) otherwise.

Combination of the two flags `:spain_gross_income_flow` and `:spain_essential_nominal_consumption`:

| gross_income_flow | essential_nominal_consumption | `essential_cost` used in the monthly flows |
|-------------------|-------------------------------|-------------------------------|
| false             | false                         | `ESSENTIAL_CONSUMPTION_MONTHLY` (fractional formula) |
| false             | true                          | `ESSENTIAL_CONSUMPTION_MONTHLY` (the income-flow flag decides the branch) |
| true              | false                         | helper returns 0.0 |
| true              | true                          | helper returns 200.0 |

`:spain_gross_income_flow` selects which essential-cost variable enters the
disposable-income computation; `:spain_essential_nominal_consumption` selects
which numeric value the gross-income-flow branch reads. The two flags are
orthogonal.

Non-stochastic; safe to call multiple times per tick.
"""
@inline effective_essential_nominal_consumption(model)::Float64 =
    model.spain_essential_nominal_consumption ?
        Config.ESSENTIAL_NOMINAL_CONSUMPTION_SPAIN_VALUE :
        Config.ESSENTIAL_NOMINAL_CONSUMPTION

"""
    resolve_insolvency!(model)

Scan all agents for negative bank balances and count each case as a bankruptcy
(`model.market_stats.n_bankruptcies`, plus the per-type counters for BTL investors,
first-time buyers and home movers).

Technical insolvency is not a termination event in the model (Carro et al. 2022,
Section 3.3.3). The Java implementation resets the balance to a small positive
buffer (Household.java) so that ratios, power transforms and `balance > 0` checks
in bidding logic stay well defined.

The function only updates the counters; it does not modify the bank balance.
"""
function resolve_insolvency!(model)
    for agent in allagents(model)
        if agent.bank_balance < 0.0
            model.market_stats.n_bankruptcies += 1
            # Per-type decomposition (not in the Java model). The BTL check comes first;
            # the FTB/HM split applies to non-BTL households, following the bid
            # classification in HousingMarket.jl.
            # Invariant: n_bankruptcies == ftb + hm + btl.
            if agent.is_btl_investor
                model.market_stats.n_bankruptcies_btl += 1
            elseif agent.borrower_type == FTB
                model.market_stats.n_bankruptcies_ftb += 1
            else  # HM (default for non-FTB non-BTL)
                model.market_stats.n_bankruptcies_hm  += 1
            end
        end
    end
end


"""
    process_income_and_obligations!(model; audit_cb=nothing)

Mandatory monthly flows, computed from a common monthly boundary.
1. Snapshot opening balances and active leases.
2. Update incomes and credit wages for all households.
3. Settle contractual rent for the captured leases.
4. Apply taxes, essential consumption and mortgage servicing (including the
   payment of any remaining principal at maturity and, if enabled, residual loans).
5. Advance the lease countdown and handle lease expiry.
6. Record realised disposable income relative to the common opening balances
   (`agent.realized_disposable_income`).

Mutates household bank balances, mortgages, leases, `model.bank`, `model.government`
and the audit and consumption counters in `model.market_stats`. `audit_cb`, if given,
is called as `audit_cb(agent, flow_label, balance_before, balance_after)` after each
cash flow.
"""
function process_income_and_obligations!(model; audit_cb=nothing)
    # Under `spain_gross_income_flow=true` the Spain Java constant
    # `ESSENTIAL_NOMINAL_CONSUMPTION` is used, resolved via
    # `effective_essential_nominal_consumption(model)` (see its docstring for the
    # flag combinations). Otherwise the fractional UK formula applies.
    essential_cost = model.spain_gross_income_flow ?
        effective_essential_nominal_consumption(model) :
        Config.ESSENTIAL_CONSUMPTION_MONTHLY

    houses = model.housing_stock
    agents = collect(allagents(model))
    opening_balances = Dict{Int, Float64}(a.id => a.bank_balance for a in agents)
    lease_snapshots = Vector{NamedTuple{(:tenant_id, :house_id, :rent, :months_remaining), Tuple{Int, Int, Float64, Int}}}()
    contractual_monthly_rent_by_landlord = Dict{Int, Float64}()

    # Snapshot leases at the mandatory-flow boundary.
    for agent in agents
        if agent.tenure_status == Renter && agent.rental_agreement !== nothing
            lease = agent.rental_agreement
            if lease.months_remaining > 0
                push!(lease_snapshots, (
                    tenant_id = agent.id,
                    house_id = lease.house_id,
                    rent = lease.monthly_rent,
                    months_remaining = lease.months_remaining,
                ))
            end
        end
    end

    # Apply wage updates for all households once.
    for agent in agents
        # Receive gross income (dynamic update).
        # Source: Carro et al. (2022), Section 3.2: "actual incomes change to reflect the
        # income distribution over households of that age".

        # Update annual income according to current age. The function queries
        # AgeGrossIncomeJointDist.csv with the inverse-CDF method, giving life-cycle
        # dynamics (rising income, then a drop at retirement).
        agent.annual_income = calculate_income_from_rank(
            agent.age, # Passed as continuous value to match Java's getBinAt logic
            agent.income_percentile,
            model.income_dist;
            # With the flag set, the income floor at draw time follows Spain Java
            # (EmploymentIncome.java); otherwise the UK floor
            # (MINIMUM_GOVT_SUPPORT*12) applies.
            spain_essential_nominal_consumption = model.spain_essential_nominal_consumption,
        )

        # Monthly wage
        wage_monthly = agent.annual_income / 12.0
        agent.bank_balance += wage_monthly
    end

    # Settle contractual rent before tax, essentials and mortgages.
    for lease in lease_snapshots
        Agents.hasid(model, lease.tenant_id) || continue
        tenant = model[lease.tenant_id]

        if lease.rent > 0.0
            before = tenant.bank_balance
            tenant.bank_balance -= lease.rent
            audit_cb !== nothing && audit_cb(tenant, :rent, before, tenant.bank_balance)

            # Java records rental housing consumption at the contract's monthly
            # payment site (Household.java::recordHousingConsumption).
            if model.spain_consumption_recording
                model.market_stats.rental_housing_consumption_counter += lease.rent
            end

            owner_id = houses[lease.house_id].owner_id
            if owner_id !== nothing && Agents.hasid(model, owner_id)
                landlord = model[owner_id]
                landlord.bank_balance += lease.rent
                contractual_monthly_rent_by_landlord[owner_id] =
                    get(contractual_monthly_rent_by_landlord, owner_id, 0.0) + lease.rent
            end
        end
    end

    # Remaining mandatory deductions and debt servicing.
    for agent in agents
        wage_monthly = agent.annual_income / 12.0
        annual_rental_income = get(contractual_monthly_rent_by_landlord, agent.id, 0.0) * 12.0
        monthly_rental_income_approx = annual_rental_income / 12.0
        gross_monthly_estimated = wage_monthly + monthly_rental_income_approx

        # Interest calculation for tax relief
        btl_interest_monthly = 0.0
        total_mortgage_payment = 0.0

        if !isempty(agent.mortgages_held)
            for m in agent.mortgages_held

                # Java conditions 1 and 2: the mortgage is owned by this agent (implicit via mortgages_held)
                # Java condition: BTL mortgage, i.e. not on the owner's residence
                is_btl_loan = (agent.residence_id === nothing || m.house_id != agent.residence_id)
                
                # Java condition 3: the mortgage has an active term and a non-zero payment
                # Java: payment.nextPayment() != 0.0 (returns 0 if nPayments==0 OR monthlyPayment==0)
                has_active_mortgage = (m.term_months > 0 && m.monthly_payment > 0.0)
                
                # Java condition 4: the property is occupied (house.resident != null)
                is_occupied = houses[m.house_id].resident_id !== nothing
                
                # Java condition 5: the tenant has an active rental agreement with non-zero rent
                # Java: house.resident.getHousePayments().get(house).nextPayment() != 0.0
                tenant_paying_rent = false
                if is_occupied
                    resident_id = houses[m.house_id].resident_id
                    if Agents.hasid(model, resident_id)
                        tenant = model[resident_id]
                        if tenant.rental_agreement !== nothing
                            # Check: rental_agreement.nextPayment() != 0.0 equivalent
                            # In Java: returns 0 if nPayments==0 OR monthlyPayment==0
                            tenant_paying_rent = (tenant.rental_agreement.monthly_rent > 0.0 && 
                                                tenant.rental_agreement.months_remaining > 0)
                        end
                    else
                        # Resident was removed (died) but house.resident_id not yet cleared
                        houses[m.house_id].resident_id = nothing
                    end
                end

                # All five Java conditions combined
                if is_btl_loan && has_active_mortgage && is_occupied && tenant_paying_rent
                    # Interest component: interest = principal * rate.
                    # For BTL the monthly payment is interest-only (principal * monthly rate).
                    # Java parity: MortgageAgreement.monthlyInterestRate is frozen at origination.
                    interest = m.remaining_principal * (m.origination_rate / 12.0)
                    btl_interest_monthly += interest
                end
                # Amount owed regardless of the conditions above
                total_mortgage_payment += m.monthly_payment

                # Housing cost (amortisation)
                # Java: principal = principal*(1 + monthlyInterestRate) - monthlyPayment
                # The monthly interest rate is frozen in the contract: m.origination_rate (annual) / 12.
                interest_payment = m.remaining_principal * (m.origination_rate / 12.0)

                # The interest-only branch is chosen per mortgage (`is_btl_loan`: is this
                # mortgage on an investment property?), not by the agent-level BTL gene:
                # `agent.is_btl_investor` is also true for a BTL-gene agent buying a first
                # home with an owner-occupier mortgage, which must amortise.
                #
                # Spain Java (`MortgageAgreement.java`) amortises the principal of every
                # mortgage, BTL or owner-occupier, when `interestOnlyMortgagesForBTL = false`:
                #     principal = principal * (1 + monthlyInterestRate) - monthlyPayment
                # At issuance (HousingMarket.jl) the annuity payment is set under
                # `:spain_btl_repayment_mode`, so the interest-only branch below is restricted
                # to the case where that flag is off:
                #   - flag off (UK, default): BTL mortgages are interest-only
                #     (principal_payment = 0.0)
                #   - flag on (Spain Java): every mortgage amortises (BTL and owner-occupier annuity)
                if is_btl_loan && !model.spain_btl_repayment_mode
                    # Interest-only BTL product: principal never decreases
                    principal_payment = 0.0
                else
                    # Owner-occupier (always) or BTL with the flag on: annuity,
                    # principal = payment - interest
                    principal_payment = max(0.0, m.monthly_payment - interest_payment)
                end

                model.market_stats.audit_interest_due_temp += interest_payment
                model.market_stats.audit_interest_paid_temp += interest_payment
                model.market_stats.audit_principal_paid_temp += principal_payment

                # Housing-consumption ledger (interest and principal components).
                # Mirrors Spain Java `Household.java::recordHousingConsumption`:
                #   `addInterestPaymentHousingConsumption(principal * monthlyInterestRate)`
                #   `addPrincipalRepaymentHousingConsumption(nextPayment - monthlyInterestExpense)`
                # Bookkeeping only: the counters do not feed back into behaviour.
                if model.spain_consumption_recording
                    model.market_stats.interest_payment_housing_consumption_counter    += interest_payment
                    model.market_stats.principal_repayment_housing_consumption_counter += principal_payment
                end

                # Update loan state
                m.remaining_principal -= principal_payment
                if m.remaining_principal < 0.0; m.remaining_principal = 0.0; end

                # Update bank accounts (system consistency)
                model.bank.outstanding_credit -= principal_payment
                model.bank.cash_reserves += m.monthly_payment

                # Maturity and principal repayment (BTL and owner-occupier).
                # Decrement the term.
                if m.term_months > 0
                    m.term_months -= 1
                end

                # Maturity cliff: when the term is complete, any remaining principal is
                # due immediately. Java parity: MortgageAgreement.makeMonthlyPayment
                # returns monthlyPayment + payoff(principal) on the final tick.
                if m.term_months <= 0 && m.remaining_principal > 0.0
                    balloon_payment = m.remaining_principal

                    # The agent pays the remainder (principal repayment cliff)
                    before = agent.bank_balance
                    agent.bank_balance -= balloon_payment
                    audit_cb !== nothing && audit_cb(agent, :balloon, before, agent.bank_balance)

                    # Discharge the loan
                    m.remaining_principal = 0.0

                    # Bank accounting (asset swap: credit -> cash)
                    model.bank.outstanding_credit -= balloon_payment
                    model.bank.cash_reserves += balloon_payment
                    model.market_stats.audit_principal_paid_temp += balloon_payment

                    # Zero the contractual payment so the contract reads as discharged.
                    # Java: payoff() sets monthlyPayment = 0 and nPayments = 0
                    # (MortgageAgreement.java) before calling endMortgageContract.
                    # Otherwise m.monthly_payment > 0 would keep has_active_mortgage true and
                    # the agent would keep paying interest on a fully discharged loan.
                    m.monthly_payment = 0.0
                end
            end
        end

        # Prune discharged mortgage entries after the loop.
        # Java: endMortgageContract() removes the agreement from bank.mortgages (Bank.java),
        # and nPayments > 0 is the liveness test (PaymentAgreement.makeMonthlyPayment).
        # `term_months` is the Julia equivalent of nPayments: it reaches 0 in the same
        # step that exhausts the mortgage.
        #
        # A predicate such as `remaining_principal > 0.0 || monthly_payment > 0.0` is not
        # used: an owner-occupier repayment mortgage whose amortisation drives
        # remaining_principal to exactly 0.0 (clamped from a floating-point negative on the
        # final step) does not trigger the balloon branch above, so monthly_payment is
        # never zeroed and the entry would stay alive indefinitely. Testing
        # `term_months > 0` handles both discharge paths uniformly.
        if !isempty(agent.mortgages_held)
            filter!(m -> m.term_months > 0, agent.mortgages_held)
        end

        # Servicing of residual loans from sales (only when `Config.D3_ZOMBIE_DEBT` is true).
        # Purpose: recover bank cash step by step from a seller whose balance did not
        # cover the mortgage at the time of sale. In that case execute_transaction!
        # (HousingMarket.jl) transferred only min(post_sale_balance, principal) to
        # bank.cash_reserves and moved the shortfall to `zombie_debts`. Each month this
        # loop recovers more cash as the seller's balance rebuilds from income.
        # Accounting invariant:
        #   cash_reserves credited at sale + sum of cash_reserves credited here
        #   = original remaining_principal (the full amount already deducted from
        #     outstanding_credit at sale time).
        # The bank's asset side is therefore consistent however many steps the recovery takes.
        #
        # Java: Household.java - each step, households attempt to service residual
        # obligations from earlier sales whose proceeds did not cover the full remaining
        # principal. payoff(bankBalance) books min(balance, principal), scales the monthly
        # payment and removes the entry once principal = 0 and nPayments = 0.
        #
        # With `Config.D3_ZOMBIE_DEBT = false` (default) `zombie_debts` is always empty and
        # the block performs no iterations. With `true`, the residual Mortgage objects
        # created by execute_transaction! are serviced here until fully discharged.
        #
        # Sequencing: Java services these debts after the consumption step and the
        # insolvency reset, so agents always have at least a small positive balance. Here
        # the loop runs before resolve_insolvency!, so bank_balance may be temporarily
        # negative; `max(0.0, ...)` prevents negative payments, matching Java's lower
        # bound without changing the order of the steps.
        #
        # Iteration order: Java's `housePayments` is a `TreeMap<House, PaymentAgreement>`
        # (Household.java) iterating in ascending house id. Sorting `agent.zombie_debts`
        # by `house_id` reproduces that order. The loop body is a waterfall
        # (`payment = min(remaining_principal, bank_balance); bank_balance -= payment`),
        # so the order determines which residual loan keeps the largest balance.
        # Aggregate quantities (`cash_reserves`, `cumulative_zombie_recovered`,
        # `outstanding_credit`) do not depend on the order.
        if Config.D3_ZOMBIE_DEBT && !isempty(agent.zombie_debts)
            zombie_to_remove = Int[]
            for (z_idx, zm) in enumerate(sort(agent.zombie_debts, by = z -> z.house_id))
                # Pay off as much as possible from the available balance
                # (MortgageAgreement.java: amount = min(bankBalance, principal))
                available = max(0.0, agent.bank_balance)
                payment   = min(available, zm.remaining_principal)

                if payment > 0.0
                    before = agent.bank_balance
                    agent.bank_balance       -= payment
                    audit_cb !== nothing && audit_cb(agent, :zombie, before, agent.bank_balance)
                    model.bank.cash_reserves += payment
                    model.bank.cumulative_zombie_recovered += payment  # audit counter
                    zm.remaining_principal   -= payment

                    # Scale monthly_payment to the remaining balance
                    # (MortgageAgreement.java: monthlyPayment *= (principal-amount)/principal).
                    # zm.remaining_principal already holds the post-payment value, while Java
                    # uses the pre-payment principal as denominator, so reconstruct it:
                    pre_payment_principal = zm.remaining_principal + payment
                    if pre_payment_principal > 0.0
                        zm.monthly_payment *= zm.remaining_principal / pre_payment_principal
                    end
                end

                # Mark for removal once fully discharged
                # (Household.java: nPayments == 0 && principal == 0.0)
                if zm.remaining_principal <= 0.0
                    zm.remaining_principal = 0.0
                    zm.monthly_payment     = 0.0
                    push!(zombie_to_remove, z_idx)
                end
            end
            # Prune discharged entries (reverse order to preserve indices)
            if !isempty(zombie_to_remove)
                deleteat!(agent.zombie_debts, sort!(zombie_to_remove))
            end
        end

        # Pay tax (skipped under the Spain gross income flow).
        # With `model.spain_gross_income_flow=true` the whole UK tax and National Insurance
        # calculation is bypassed and income flows gross of tax, following Spain Java
        # (Household.java, Government.java).
        if !model.spain_gross_income_flow
            # Project to annual for the precise tax band logic
            annual_wage = wage_monthly * 12.0
            annual_btl_interest = btl_interest_monthly * 12.0

            # Calculate Tax
            # Returns (net_income, total_tax)
            _, annual_tax = calculate_net_income(annual_wage, annual_rental_income, annual_btl_interest)
            monthly_tax = annual_tax / 12.0

            # Pay Tax
            before = agent.bank_balance
            agent.bank_balance -= monthly_tax
            audit_cb !== nothing && audit_cb(agent, :tax, before, agent.bank_balance)
            model.government.bank_balance += monthly_tax
        end

        # Spending: essentials, then housing costs.

        # Essentials
        # Accounting difference to Java: Java deducts implicitly, computing
        # "monthlyDisposableIncome" (income - tax - essentials - housing) and adding the net
        # amount to bankBalance in one operation (Household.java). Here income is added
        # first and each cost component is then subtracted explicitly. The final state is
        # the same and the cash-flow sequence can be audited step by step.
        before = agent.bank_balance
        agent.bank_balance -= essential_cost
        audit_cb !== nothing && audit_cb(agent, :essential, before, agent.bank_balance)

        # Housing costs
        # Amortisation and bank accounting were settled in the mortgage loop above.
        before = agent.bank_balance
        agent.bank_balance -= total_mortgage_payment
        audit_cb !== nothing && audit_cb(agent, :mortgage, before, agent.bank_balance)

    end

    # Advance captured leases after servicing, so that rent settlement and lease expiry are decoupled.
    for lease in lease_snapshots
        Agents.hasid(model, lease.tenant_id) || continue
        tenant = model[lease.tenant_id]
        tenant.rental_agreement === nothing && continue
        tenant.rental_agreement.house_id == lease.house_id || continue

        if tenant.rental_agreement.months_remaining > 0
            tenant.rental_agreement.months_remaining -= 1
        end

        if tenant.rental_agreement.months_remaining == 0
            house = houses[lease.house_id]

            tenant.rental_agreement = nothing
            if house.resident_id == tenant.id
                house.resident_id = nothing
            end
            if tenant.residence_id == house.id
                tenant.residence_id = nothing
            end
            house.is_for_rent = true
            tenant.tenure_status = SocialHousing

            # Eq. 9 / Table 12: expiry re-listing uses rental markup draws.
            # The fresh rent is set here so that RentalMarket's zero-price fallback does
            # not make a second markup draw for the same expiry event.
            house.months_on_rental_market = 0
            r_Q = model.market_stats.ema_rents_by_quality[house.quality]
            markup_ratio = draw_rental_markup(model)
            house.rental_price = r_Q * markup_ratio

            push!(model.market_stats.active_rental_listings, house.id)
            model.market_stats.occupied_rentals_by_quality[house.quality] -= 1
            model.market_stats.vacant_rentals_by_quality[house.quality] += 1
        end
    end

    # Realised disposable income is measured against the common opening balance of the
    # monthly boundary; it is used when `model.d22_use_realized_disposable_income` is set.
    for agent in agents
        agent.realized_disposable_income = agent.bank_balance - opening_balances[agent.id]
    end
end

"""
    process_discretionary_consumption!(model)

Discretionary consumption (Eq. 16, Carro et al. 2022): reconstructs each household's
monthly disposable income, derives its target wealth from the wealth distribution and
deducts the resulting consumption from the bank balance.

Must run before `resolve_insolvency!`. Java (Household.java) lets bankBalance go
negative from consumption; the insolvency step then handles negative balances
(Carro et al.: "artificially injecting as much cash as necessary").

Mutates `agent.bank_balance`, `agent.consumption_observation` and, when
`model.spain_consumption_recording` is set, `model.market_stats.non_housing_consumption_counter`.
"""
function process_discretionary_consumption!(model)
    c_gamma = Config.CONSUMPTION_GAMMA  # Java: hardcoded 0.5 in HouseholdBehaviour.java
    # Same essential-cost choice as in process_income_and_obligations!
    essential_cost = model.spain_gross_income_flow ?
        effective_essential_nominal_consumption(model) :
        Config.ESSENTIAL_CONSUMPTION_MONTHLY
    # Cap on discretionary consumption as a share of gross income, read from the live
    # ModelParameters field `windfall_cap_share`.
    # Java: MAXIMUM_CONSUMPTION_FRACTION (UK 0.17 / Spain 0.17509309751065444).
    windfall_share = model.params.windfall_cap_share
    houses = model.housing_stock
    # BTL interest below uses the per-mortgage m.origination_rate, as in
    # process_income_and_obligations!.

    for agent in allagents(model)
        # Reconstruct disposable income (y_d)
        # y_d = gross - tax - essentials - housing

        # Gross income
        wage_monthly = agent.annual_income / 12.0

        # Rental income from houses let to a resident other than the owner. The same scan
        # appears in `calc_rental_budget` (HouseholdBehavior.jl).
        annual_rental_income = 0.0
        if !isempty(agent.properties_owned)
             for prop_id in agent.properties_owned
                h = houses[prop_id]
                if h.resident_id !== nothing && h.resident_id != agent.id
                    annual_rental_income += h.rental_price * 12.0
                end
            end
        end
        monthly_rental_income_approx = annual_rental_income / 12.0
        gross_monthly_estimated = wage_monthly + monthly_rental_income_approx

        # Tax and housing costs
        btl_interest_monthly = 0.0
        housing_outflow = 0.0

        if !isempty(agent.mortgages_held)
            for m in agent.mortgages_held
                housing_outflow += m.monthly_payment

                # BTL interest component for the tax-relief reconstruction.
                # Uses m.origination_rate, the contract-frozen rate (Java:
                # MortgageAgreement.monthlyInterestRate is frozen at origination), not the
                # bank's current market rate.
                # Java's getAnnualFinanceCosts() (Household.java) applies five conditions, as
                # in process_income_and_obligations!. `Config.D13_BTL_INTEREST_FULL_GUARD`
                # (default true) selects that full guard; when false a simplified check
                # (loan not on the residence) is used, which also counts interest on vacant
                # properties and so raises disposable income.
                is_btl_loan_2b = (agent.residence_id === nothing || m.house_id != agent.residence_id)

                if Config.D13_BTL_INTEREST_FULL_GUARD
                    # Full five-condition guard (as in process_income_and_obligations!)
                    # Condition 3: active mortgage (redundant after the mortgage pruning there; defensive)
                    has_active_2b = (m.term_months > 0 && m.monthly_payment > 0.0)
                    # Condition 4: property is occupied
                    is_occupied_2b = houses[m.house_id].resident_id !== nothing
                    # Condition 5: tenant paying rent
                    tenant_paying_2b = false
                    if is_occupied_2b
                        rid_2b = houses[m.house_id].resident_id
                        if Agents.hasid(model, rid_2b)
                            t_2b = model[rid_2b]
                            if t_2b.rental_agreement !== nothing
                                tenant_paying_2b = (t_2b.rental_agreement.monthly_rent > 0.0 &&
                                                    t_2b.rental_agreement.months_remaining > 0)
                            end
                        end
                    end
                    if is_btl_loan_2b && has_active_2b && is_occupied_2b && tenant_paying_2b
                        interest = m.remaining_principal * (m.origination_rate / 12.0)
                        btl_interest_monthly += interest
                    end
                else
                    # Simplified check: any loan not on the residence
                    if is_btl_loan_2b
                        interest = m.remaining_principal * (m.origination_rate / 12.0)
                        btl_interest_monthly += interest
                    end
                end
            end
        end

        if agent.tenure_status == Renter && agent.rental_agreement !== nothing
             housing_outflow += agent.rental_agreement.monthly_rent
        end

        # Tax flow gated as in process_income_and_obligations!
        if model.spain_gross_income_flow
            monthly_tax = 0.0
        else
            annual_wage = wage_monthly * 12.0
            annual_btl_interest = btl_interest_monthly * 12.0
            _, annual_tax = calculate_net_income(annual_wage, annual_rental_income, annual_btl_interest)
            monthly_tax = annual_tax / 12.0
        end

        disposable_income = (wage_monthly + monthly_rental_income_approx) - monthly_tax - essential_cost - housing_outflow
        if model.d22_use_realized_disposable_income
            disposable_income = agent.realized_disposable_income
        end
        
        # Current wealth state
        # agent.bank_balance may be negative at this point: process_income_and_obligations!
        # can leave balances negative if a household's total monthly obligations (tax +
        # essentials + mortgage payments + rent) exceed its income. resolve_insolvency!
        # runs only after this function returns. The `max(..., 0.0)` floor in the
        # consumption formula (Step 2 below) handles a negative balance correctly.

        # Target wealth and consumption
        # Target wealth is a dynamic lookup (Carro et al. 2022, Passages 51 and 241): "computed
        # with the inverse cumulative distribution of financial wealth conditional on gross
        # income analysed at the household's propensity to save".

        # This uses the same data structure as initialisation (GrossIncomeNetWealthJointDist).
        # Java uses getAnnualGrossTotalIncome() here (employment + rental income):
        # data.Wealth.getDesiredBankBalance(getAnnualGrossTotalIncome(), behaviour.getPropensityToSave())
        gross_total_income_for_wealth = agent.annual_income + annual_rental_income
        target_wealth = calculate_wealth_from_rank(
            gross_total_income_for_wealth,  # Employment + Rental (matches Java)
            agent.propensity_to_save,       # Fixed percentile (assigned at birth)
            model.wealth_dist
        )

        # Consumption function (replicates the Java implementation)
        # Paper: Carro et al. (2022) Appendix A.3 (Passages 240-243), Equation 16
        # Java: Household.java and HouseholdBehaviour.java
        #
        # Paper formula: C = min( max( 0.5 * (w - w_t + y_d), 0), C_max )
        # where w = wealth, w_t = target wealth, y_d = disposable income
        #
        # Java logic:
        # 1. bankBalance += monthlyDisposableIncome
        # 2. desiredConsumption = 0.5 * max(bankBalance - targetWealth + monthlyDisposableIncome, 0)
        #    where bankBalance already includes monthlyDisposableIncome from step 1
        #
        # The formula therefore becomes:
        # C = 0.5 * max((oldBalance + disposable) - targetWealth + disposable, 0)
        # C = 0.5 * max(oldBalance + 2*disposable - targetWealth, 0)
        #
        # Disposable income thus enters the Java calculation twice: once as an update to
        # bankBalance and once as an explicit additive term in getDesiredConsumption().
        #
        # Here process_income_and_obligations! has already updated agent.bank_balance to
        # (BB_old + d), so agent.bank_balance is used directly as `w` and disposable_income
        # is added once more, which gives the same double count.

        # Step 1: effective wealth (Java's bankBalance after the update in step 1 above).
        # agent.bank_balance already equals (BB_old + d), because the mandatory flows added
        # the wage and deducted tax, essentials and housing costs. Adding disposable_income
        # again here would count it three times where Java counts it twice.
        effective_wealth = agent.bank_balance

        # Step 2: consumption basis (HouseholdBehaviour.java)
        # Java: 0.5*Math.max(bankBalance - getDesiredBankBalance(...) + monthlyDisposableIncome, 0.0)
        # With effective_wealth = BB_old + d this gives
        #   0.5 * ((BB_old + d) - target + d) = 0.5 * (BB_old + 2d - target)
        # which is the Java double count.
        consumption_basis = c_gamma * max(effective_wealth - target_wealth + disposable_income, 0.0)

        # Step 3: cap (Household.java)
        # Java: Math.min(desiredConsumption, getAnnualGrossTotalIncome()*config.MAXIMUM_CONSUMPTION_FRACTION)
        # The Java fraction MAXIMUM_CONSUMPTION_FRACTION corresponds to `windfall_cap_share`.
        c_max = windfall_share * (gross_monthly_estimated * 12.0)

        # Step 4: apply the cap. The floor at zero is already applied in step 2 via max(..., 0.0).
        consumption = min(consumption_basis, c_max)

        # Step 5: deduct consumption (bankruptcy is handled afterwards)
        # Java (Household.java): bankBalance may go negative from consumption; the
        # subsequent check sets bankBalance = 1.0 and isBankrupt = true if it is below zero.
        # Here the overdraft is allowed and the insolvency step runs later
        # (resolve_insolvency!).
        agent.bank_balance -= consumption

        agent.consumption_observation = ConsumptionObservation(
            true,
            Agents.abmtime(model),
            agent.age,
            agent.tenure_status,
            essential_cost,
            consumption,
            essential_cost + consumption,
            wage_monthly,
            monthly_rental_income_approx,
            gross_monthly_estimated,
        )

        # Java's bankruptcy reset happens afterwards (resolve_insolvency!).
        # There is no liquidity constraint here, matching Java's overdraft behaviour.

        # Housing-consumption ledger: non-housing consumption.
        # Mirrors Spain Java `Household.java::recordHousingConsumption`:
        #   `addNonHousingConsumption(getDesiredConsumption() + essentialConsumption)`.
        # `consumption` is the capped discretionary amount (Java `getDesiredConsumption()`)
        # and `essential_cost` is the essential floor used in process_income_and_obligations!.
        if model.spain_consumption_recording
            model.market_stats.non_housing_consumption_counter += consumption + essential_cost
        end

    end # End agent loop
end
