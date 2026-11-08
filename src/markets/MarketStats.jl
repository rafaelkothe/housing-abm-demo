# src/markets/MarketStats.jl

"""
    update_market_stats!(model)
Updates the price and yield oracles using Exponential Moving Averages (EMA).
Also calculates the House Price Appreciation (HPA) for behavioral expectations.
Matches Eq 1, 14, 16 and Appx A.3 smoothing logic.
"""
function update_market_stats!(model)
    stats = model.market_stats
    alpha = model.params.smoothing_factor 
    n_qualities = length(stats.ema_prices_by_quality)
    
    # 1. Update Counters (Public Stats)
    stats.mortgage_approvals = stats.mortgage_flow_temp
    stats.rental_transactions = stats.rental_flow_temp
    # Publish gross new lending flow (£, raw-agent units) and reset.
    stats.new_lending_flow = stats.mortgage_flow_principal_temp
    # Passive debt-service telemetry snapshots.
    stats.audit_interest_due = stats.audit_interest_due_temp
    stats.audit_interest_paid = stats.audit_interest_paid_temp
    stats.audit_principal_paid = stats.audit_principal_paid_temp

    stats.mortgage_flow_temp = 0
    stats.rental_flow_temp = 0
    stats.mortgage_flow_principal_temp = 0.0
    stats.audit_interest_due_temp = 0.0
    stats.audit_interest_paid_temp = 0.0
    stats.audit_principal_paid_temp = 0.0

    stats.rental_housing_consumption              = stats.rental_housing_consumption_counter
    stats.interest_payment_housing_consumption    = stats.interest_payment_housing_consumption_counter
    stats.principal_repayment_housing_consumption = stats.principal_repayment_housing_consumption_counter
    stats.downpayment_housing_consumption         = stats.downpayment_housing_consumption_counter
    stats.non_housing_consumption                 = stats.non_housing_consumption_counter
    stats.rental_housing_consumption_counter              = 0.0
    stats.interest_payment_housing_consumption_counter    = 0.0
    stats.principal_repayment_housing_consumption_counter = 0.0
    stats.downpayment_housing_consumption_counter         = 0.0
    stats.non_housing_consumption_counter                 = 0.0

    # =========================================================================
    # 2. Update Segmented EMAs (Price & Rent)
    # =========================================================================
    
    # Accumulators for Mix-Adjusted Indices (Java Parity / Appx A.7)
    # Tracks the actual value vs the reference value of specific transacted units.
    total_sales_val = 0.0
    total_sales_ref_val = 0.0
    total_sales_vol = 0
    
    total_rent_val = 0.0
    total_rent_ref_val = 0.0
    # Local accumulator: captures per-quality rental transaction counts from the bin vectors
    # before they are emptied at the end of this loop. Used later for the Java-matching
    # volume-weighted yield aggregation (RentalMarketStats.java lines 91-95).
    rental_counts_by_quality = zeros(Int, n_qualities)
    
    for q in 1:n_qualities
        # --- Sales Prices ---
        sales_in_bin = stats.current_sales_by_quality[q]
        if !isempty(sales_in_bin)
            bin_vol = length(sales_in_bin)
            bin_sum = sum(sales_in_bin)
            avg_p = bin_sum / bin_vol
            
            # EMA Update
            stats.ema_prices_by_quality[q] = (alpha * avg_p) + ((1.0 - alpha) * stats.ema_prices_by_quality[q])
            
            # Mix-Adjusted Accumulation
            total_sales_vol += bin_vol
            total_sales_val += bin_sum
            # Reference Value of these specific units = Vol * RefPrice[q]
            total_sales_ref_val += bin_vol * stats.reference_prices_by_quality[q]
        end
        # Note: If no sales, EMA holds steady (Per Plan)
        
        # --- Months on Market (Sales) ---
        if !isempty(stats.current_mom_by_quality[q])
            avg_mom = sum(stats.current_mom_by_quality[q]) / length(stats.current_mom_by_quality[q])
            stats.months_on_market_ema[q] = (alpha * avg_mom) + ((1.0 - alpha) * stats.months_on_market_ema[q])
        end

        # --- Rental Values (New Leases Only) ---
        # "Scan only new transactions completed in the current month"
        rents_in_bin = stats.current_rents_by_quality[q]
        if !isempty(rents_in_bin)
            bin_vol_rent = length(rents_in_bin)
            bin_sum_rent = sum(rents_in_bin)
            avg_r = bin_sum_rent / bin_vol_rent
            
            # EMA Update
            stats.ema_rents_by_quality[q] = (alpha * avg_r) + ((1.0 - alpha) * stats.ema_rents_by_quality[q])
            
            # Mix-Adjusted Accumulation
            total_rent_val += bin_sum_rent
            total_rent_ref_val += bin_vol_rent * stats.reference_rents_by_quality[q]
            # Snapshot transaction count for volume-weighted yield calculation below.
            # Must be captured here: bins are emptied at the end of this loop iteration.
            rental_counts_by_quality[q] = bin_vol_rent
        end

        # --- Months on Market (Rental) ---
        if !isempty(stats.current_rental_mom_by_quality[q])
            avg_rent_mom = sum(stats.current_rental_mom_by_quality[q]) / length(stats.current_rental_mom_by_quality[q])
            stats.months_on_market_ema_rental[q] = (alpha * avg_rent_mom) + ((1.0 - alpha) * stats.months_on_market_ema_rental[q])
        end
        
        # Reset Bins
        empty!(stats.current_sales_by_quality[q])
        empty!(stats.current_rents_by_quality[q])
        empty!(stats.current_mom_by_quality[q])
        empty!(stats.current_rental_mom_by_quality[q])
    end
    
    stats.sales_volume = total_sales_vol
    
    # =========================================================================
    # 3. Update Global Indices (HPI & RPI)
    # =========================================================================
    
    # A. Global Price EMA (Legacy Support & HPA)
    # We maintain the global EMA for the HPA Oracle
    if total_sales_vol > 0
        global_avg_sales = total_sales_val / total_sales_vol
        stats.ema_sales_price = (alpha * global_avg_sales) + ((1.0 - alpha) * stats.ema_sales_price)
    end
    
    # B. HPI (Mix-Adjusted)
    # Java: HousePriceIndex = sumSoldPrice / sumSoldReferencePrice
    if total_sales_ref_val > 0
        stats.hpi = total_sales_val / total_sales_ref_val
    end
    
    # =========================================================================
    # 3.5. Price Relaxation (Decay towards Reference Distribution)
    # =========================================================================
    # Mechanism: Equation 21 (Appendix A.7, Page 47) - Mix-Adjusted Average Price
    # Purpose: Prevents drift in segments with low transaction volume by anchoring
    #          EMA prices to the fundamental reference distribution scaled by HPI.
    # Formula: p'_Q = ρ * p_Q + (1 - ρ) * (HPI * pref_Q)
    # Parameter: ρ (rho) = MIX_ADJUSTMENT_WEIGHT (Appendix C.3.3, Page 56)
    # Matches Java: HousingMarketStats.java (lines 279-281)

    decay = model.params.mix_adjustment_weight
    for q in 1:n_qualities
        current_ema = stats.ema_prices_by_quality[q]
        # Target = Current HPI * Reference Price for this Quality
        ref_target = stats.hpi * stats.reference_prices_by_quality[q] 
        
        # Apply Relaxation
        stats.ema_prices_by_quality[q] = (decay * current_ema) + ((1.0 - decay) * ref_target)
    end
    
    # C. RPI (Rental Price Index)
    # Implements the Mix-Adjusted approach: sumNewRents / sumRefRents
    
    if total_rent_ref_val > 0
        stats.rental_price_index = total_rent_val / total_rent_ref_val
    end

    # =========================================================================
    # 3.6. Rent Relaxation (Decay towards Reference Distribution)
    # =========================================================================
    # Matches RentalMarketStats.java (inherits HousingMarketStats logic)
    # Using same decay parameter for consistency.
    
    for q in 1:n_qualities
        current_ema_rent = stats.ema_rents_by_quality[q]
        # Target = Current RPI * Reference Rent for this Quality
        ref_target_rent = stats.rental_price_index * stats.reference_rents_by_quality[q]
        
        # Apply Relaxation
        stats.ema_rents_by_quality[q] = (decay * current_ema_rent) + ((1.0 - decay) * ref_target_rent)
    end

    # =========================================================================
    # 4. Update Occupancy Rates (per quality band)
    # =========================================================================
    # Java replication: RentalMarketStats.java line 83
    #   avOccupancyPerQuality[q] = TENANCY_LENGTH_AVERAGE
    #       / (TENANCY_LENGTH_AVERAGE + getExpAvMonthsOnMarketForQuality(q))
    #
    # This is a queuing-theory analytic formula: the long-run fraction of time a
    # rental property is occupied equals tenancy duration divided by
    # (tenancy duration + expected vacancy duration).  Both inputs are EMA-smoothed,
    # so the result is inherently smooth — matching Java behaviour during ramp-up,
    # shocks, and thin markets.  The previous census snapshot (n_occupied / stock)
    # was instantaneous and noisy, causing BTL yield divergence.
    #
    # TENANCY_LENGTH_AVERAGE = (MIN + MAX) / 2.0  (Config.java line 366)
    tenancy_avg = (model.params.tenancy_length_min + model.params.tenancy_length_max) / 2.0

    for q in 1:n_qualities
        # EMA of months a property spent vacant on the rental market before being let
        # (Julia equivalent of expAvMonthsOnMarketPerQuality[] in HousingMarketStats.java)
        exp_av_vacant = stats.months_on_market_ema_rental[q]
        denom = tenancy_avg + exp_av_vacant
        # Guard: if denom == 0 (vacant EMA not yet seeded), default to full occupancy (1.0),
        # matching Java's initialisation: Arrays.fill(avOccupancyPerQuality, 1.0)
        stats.occupancy_rate_by_quality[q] = denom > 0.0 ? tenancy_avg / denom : 1.0
    end

    # =========================================================================
    # 5. Update HPA Oracle (Expectation Engine)
    # =========================================================================
    # Java parity: HousingMarketStats.java
    #   Line 273: HPIRecord.addValue(housePriceIndex)          ← push happens FIRST
    #   Line 291: housePriceAppreciation(HPA_YEARS_TO_CHECK)   ← compute with current HPI as [end]
    #
    # Invariant: price_history is ALWAYS exactly HPI_RECORD_LENGTH (27) elements.
    # The buffer is pre-seeded at initialisation (fill(1.0, 27)); the burn-in
    # guard below is unreachable in steady state and documents the contract only.

    # A. Slide the ring buffer left by one slot and record this tick's HPI at [end].
    #    Replaces push!/popfirst! pair: eliminates the O(n) heap reallocation on first
    #    push and the O(n) memmove inside popfirst!, replacing both with a single
    #    O(n) in-place memmove with zero heap allocation every tick.
    #    Java parity: HPIRecord.addValue(housePriceIndex)  (line 273)
    #
    #    CRITICAL: Must record stats.hpi (mix-adjusted, dimensionless ratio), NOT
    #    stats.ema_sales_price (absolute £ value). Two reasons:
    #    1. COMPOSITION BIAS: hpi = sumSoldPrice/sumSoldReferencePrice controls for
    #       which quality band transacted this month. If only cheap houses clear,
    #       ema_sales_price falls even though no individual house depreciated; hpi
    #       cancels the reference value of the transacting units and is immune.
    #    2. EMA DOUBLE-SMOOTHING: ema_sales_price carries an alpha≈0.109 EMA lag.
    #       Pushing it into price_history then averaging over 3-month quarters
    #       applies a second smoothing pass with no Java equivalent, introducing
    #       spurious lag into the HPA signal.
    #    Java: housePriceIndex = sumSoldPrice / sumSoldReferencePrice  (line 270)
    #          HPIRecord.addValue(housePriceIndex)                     (line 273)
    #
    hpi_record_length = model.hpi_record_length
    @inbounds begin
        for i in 1:(hpi_record_length - 1)
            stats.price_history[i] = stats.price_history[i + 1]
        end
        stats.price_history[hpi_record_length] = stats.hpi
    end

    # B. Calculate annualised HPA over HPA_YEARS_TO_CHECK years (UK 2 / Spain 4 / kwarg-override).
    #    Java formula: Math.pow(HPI_now / HPI_old, 1.0 / nYears) - 1.0
    #    Current quarter  → indices [end], [end-1], [end-2]    (t,    t-1,  t-2 )
    #    Historic quarter → indices [3],  [2],     [1]         (t-24/48, ..)
    #    Sums used instead of averages: the 1/3 factor cancels in the ratio.
    #    Guard: p_old_sum > 0.0 prevents division by zero if prices collapse.
    #
    #    BURN-IN NOTE: With a fully pre-seeded history the else-branch is never
    #    reached. If Java strict burn-in parity (hpa=0 for ticks 1-26/50) is ever
    #    required, add a `price_history_count::Int` field to MarketStats and
    #    gate this block on `stats.price_history_count == hpi_record_length`.
    if length(stats.price_history) == hpi_record_length
        @inbounds begin
            p_curr_sum = stats.price_history[hpi_record_length]     +
                         stats.price_history[hpi_record_length - 1] +
                         stats.price_history[hpi_record_length - 2]

            p_old_sum  = stats.price_history[3] +
                         stats.price_history[2] +
                         stats.price_history[1]
        end

        stats.hpa_oracle = p_old_sum > 0.0 ? (p_curr_sum / p_old_sum)^(1.0/model.hpa_years_to_check) - 1.0 : 0.0
    else
        # Unreachable with pre-seeded buffer; retained as a safety net.
        stats.hpa_oracle = 0.0
    end
    
    # Global Yield Update (For BTL Entry Decision)
    # Java replication: RentalMarketStats.java postClearingRecord() lines 79–99.
    #
    # Java uses a TWO-VARIABLE pattern:
    #   avFlowYield      — raw per-tick weighted average; sticky (unchanged) when no new rentals.
    #   expAvFlowYield   — EMA that converges toward avFlowYield EVERY tick unconditionally.
    #
    # Previously Julia collapsed these into one, using the fallback
    #   current_avg_yield = stats.ema_yield   (when yield_denominator == 0)
    # which made the EMA a no-op on zero-rental ticks (frozen), diverging from Java where the
    # EMA continues decaying toward the last raw value on every tick.
    #
    # FIX: replicate the two-variable structure via stats.flow_yield_raw (= Java avFlowYield):
    #   Step A — Conditional raw update (Java: if getnSales() > 0)
    #   Step B — Unconditional EMA update toward flow_yield_raw (Java: always fires)
    #
    # rental_counts_by_quality[q] is the Julia equivalent of getnSalesForQuality(q),
    # captured above before bin reset, requiring no additional per-tick allocations.
    yield_numerator   = 0.0
    yield_denominator = 0.0
    for q in 1:n_qualities
        p_q     = stats.ema_prices_by_quality[q]
        r_q     = stats.ema_rents_by_quality[q]
        occ_q   = stats.occupancy_rate_by_quality[q]
        count_q = rental_counts_by_quality[q]  # getnSalesForQuality(q) equivalent

        s_q = p_q > 0 ? (r_q * 12.0 * occ_q) / p_q : Config.INITIAL_RENTAL_YIELD

        yield_numerator   += s_q * count_q
        yield_denominator += count_q
    end

    # Step A: Sticky raw update — only overwrite when at least one rental cleared this tick.
    #         Java: if (getnSales() > 0) { avFlowYield = avFlowYieldCount / getnSales(); }
    if yield_denominator > 0
        stats.flow_yield_raw = yield_numerator / yield_denominator
    end
    # (If yield_denominator == 0, stats.flow_yield_raw retains its previous value — sticky.)

    # Step B: Unconditional EMA update driven by the sticky raw value every tick.
    #         Java: expAvFlowYield = SMOOTHING * avFlowYield + (1 - SMOOTHING) * expAvFlowYield;
    stats.ema_yield = (alpha * stats.flow_yield_raw) + ((1.0 - alpha) * stats.ema_yield)
    
    # =========================================================================
    # 6. Calculate Emergent Market Indicators (Rent-to-Income, BTL Stats)
    # =========================================================================
    # Requirement: Table 6 & Figure 2(g-h)
    # This involves iterating over agents, so it is O(N).
    
    total_rent_paid = 0.0
    total_tenant_income = 0.0
    n_tenants = 0
    
    # Average rent-to-income ratio of renting households.

    

    for agent in allagents(model)
        if agent.tenure_status == Renter && agent.rental_agreement !== nothing
            rent = agent.rental_agreement.monthly_rent
            income_monthly = agent.annual_income / 12.0
            
            total_rent_paid += rent
            total_tenant_income += income_monthly
            n_tenants += 1
        end
    end
    
    if n_tenants > 0
        # "Rent-to-Income Ratio: The average % of income tenants spend on rent"
        # Two ways: Average of Ratios or Ratio of Averages.
        # Standard macro metric is usually Total Rent / Total Income (Ratio of Averages).
        # Carro et al might imply Average of Ratios.
        # Let's use Ratio of Averages for stability.
        stats.avg_rent_to_income = total_rent_paid / total_tenant_income
        stats.average_rent = total_rent_paid / n_tenants # Actual paid rent vs listing average
    else
        stats.avg_rent_to_income = 0.0
        # If no tenants, use EMA as proxy for "Market Price"
        stats.average_rent = stats.ema_yield * stats.ema_sales_price / 12.0 # Approximation
    end

    # Update Global EMA Rent (The missing field)
    if stats.average_rent > 0
       stats.ema_rent = (alpha * stats.average_rent) + ((1.0 - alpha) * stats.ema_rent)
    end

    if model.spain_application_income_gate
        empty!(stats.sorted_household_incomes)  # guarded by :spain_application_income_gate

        # `sizehint!(stats.sorted_household_incomes, nagents(model))` before `push!`.
        # This avoids repeated geometric growth reallocations during the per-tick refill
        # while preserving semantics.
        for agent in allagents(model)           # guarded by :spain_application_income_gate
            if agent isa Household              # guarded by :spain_application_income_gate
                push!(stats.sorted_household_incomes, agent.annual_income)  # guarded by :spain_application_income_gate
            end
        end
        sort!(stats.sorted_household_incomes)   # guarded by :spain_application_income_gate
    end
    
    stats.n_bids_active = stats.measured_demand_buyers
    stats.n_offers_active = stats.measured_supply_sellers
end

"""
    record_pre_clearing_stats!(model, bids, offers)
Captures supply/demand metrics BEFORE clear_market execution.
Matches Java HousingMarketStats.preClearingRecord()
"""
function record_pre_clearing_stats!(model, bids, offers)
    stats = model.market_stats
    
    # 1. Demand Side
    stats.measured_demand_buyers = length(bids)
    sum_bids = 0.0
    for b in bids 
        # Sale bids carry `price`, rental bids carry `budget`.

        if hasproperty(b, :price)
            sum_bids += b.price
        elseif hasproperty(b, :budget)
             sum_bids += b.budget
        end
    end
    stats.measured_demand_bids_sum = sum_bids
    
    # 2. Supply Side
    stats.measured_supply_sellers = length(offers)
    sum_offers = 0.0
    for o in offers
        h = model.housing_stock[o]
        # Check market type context? 
        # Usually clear_sales_market passes sales listings.
        if h.is_for_sale
            sum_offers += h.listing_price
        elseif h.is_for_rent
            sum_offers += h.rental_price
        end
    end
    stats.measured_supply_offer_sum = sum_offers
end

"""
    income_at_percentile(stats::MarketStats, p::Float64) -> Float64

Return the nearest-rank income from `stats.sorted_household_incomes`.
For a nonempty ascending cache of N incomes, use rank 1 at p=0 and
`ceil(Int, p * N)` otherwise. This matches Spanish Java's
`HouseholdStats.getIncomeLevelFromPercentile` for valid, nonempty inputs.

The collector populates the cache from household `annual_income` when
`spain_application_income_gate` is enabled. This getter preserves that
income basis and the existing monthly collection/refresh order.

Require 0 <= p <= 1. Retain Julia's existing 0.0 fallback for an empty cache;
the Java method has no equivalent empty-list guard.

O(1) lookup. Does not sort, mutate the cache or consume RNG.

[Alignment Note] Spain `Bank.java#L716` calls `centralBank.getApplicationIncome()`, which
in turn was set by `CentralBank.step()` via `Model.householdStats.getIncomeLevelFromPercentile`.
not directly through the agent population. Layer alignment with the Java collector pattern.

# RNG discipline
Idempotent. Does not consume RNG.
"""
function income_at_percentile(stats::MarketStats, p::Float64)::Float64
    0.0 <= p <= 1.0 ||
        throw(ArgumentError("p must be in [0, 1]"))

    incomes = stats.sorted_household_incomes
    isempty(incomes) && return 0.0

    rank = p == 0.0 ? 1 : ceil(Int, p * length(incomes))
    return incomes[rank]
end
