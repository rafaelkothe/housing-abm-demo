#=
DataCollection.jl

Model-level data collectors. Each `get_*` function takes the model and returns a
scalar that is recorded once per recorded step as a column of the model-level
time-series DataFrame (market volumes and prices, vacancy and tenure shares,
price-to-income and leverage ratios, credit stocks and flows, consumption and
wealth aggregates). The collectors only read model state; none of them draws
random numbers or mutates the model. `build_data_collectors()` at the end of the file
lists them as the `adata` and `mdata` specifications passed to Agents.jl `run!`.

Flow quantities that the Java model reports at UK scale are multiplied by
`model.uk_households / Config.N_HOUSEHOLDS`.
=#

using Statistics
using Agents

# --- Inventory and homelessness ---

"""Number of houses currently listed for sale."""
function get_inventory_count(model)
    return count(h -> h.is_for_sale, model.housing_stock)
end

"""Mean asking price over houses currently for sale (0.0 if there are none)."""
function get_average_listing_price(model)
    listings = filter(h -> h.is_for_sale, model.housing_stock)
    if isempty(listings)
        return 0.0
    end
    return mean(h.listing_price for h in listings)
end

"""Number of households without a residence."""
function get_homeless_count(model)
    return count(a -> a.residence_id === nothing, allagents(model))
end

# --- Vacancy ---
# House-side vacancy: `resident_id === nothing`. Split into three mutually exclusive
# states (for sale, for rent, unlisted), so that
#   vacancy_rate = vacant_for_sale + vacant_for_rent + vacant_unlisted.

"""Share of the housing stock with no resident."""
function get_vacancy_rate(model)
    stock = model.housing_stock
    n = length(stock)
    n == 0 && return 0.0
    return count(h -> h.resident_id === nothing, stock) / n
end

"""Share of the housing stock that is vacant and listed for sale."""
function get_vacant_for_sale(model)
    stock = model.housing_stock
    n = length(stock)
    n == 0 && return 0.0
    return count(h -> h.resident_id === nothing && h.is_for_sale, stock) / n
end

"""Share of the housing stock that is vacant and listed for rent."""
function get_vacant_for_rent(model)
    stock = model.housing_stock
    n = length(stock)
    n == 0 && return 0.0
    return count(h -> h.resident_id === nothing && h.is_for_rent, stock) / n
end

"""Share of the housing stock that is vacant and listed neither for sale nor for rent."""
function get_vacant_unlisted(model)
    stock = model.housing_stock
    n = length(stock)
    n == 0 && return 0.0
    return count(h -> h.resident_id === nothing && !h.is_for_sale && !h.is_for_rent, stock) / n
end

# --- Mortgage age ---
# Stock-based measure: age of an outstanding mortgage = current time - `start_date`.
# Under stationarity (Little's law) the mean age of the stock is about half the mean
# time to exit.

"""Mean age (in time steps) of all outstanding mortgages (0.0 if there are none)."""
function get_mean_mortgage_age(model)
    t = Agents.abmtime(model)
    total_age = 0
    n = 0
    for agent in allagents(model)
        for m in agent.mortgages_held
            total_age += (t - m.start_date)
            n += 1
        end
    end
    return n > 0 ? total_age / n : 0.0
end

"""75th percentile of outstanding mortgage ages in time steps (0.0 if there are none)."""
function get_p75_mortgage_age(model)
    t = Agents.abmtime(model)
    ages = Int[]
    for agent in allagents(model)
        for m in agent.mortgages_held
            push!(ages, t - m.start_date)
        end
    end
    isempty(ages) && return 0.0
    sort!(ages)
    return Float64(ages[ceil(Int, 0.75 * length(ages))])
end

# --- Market statistics accessors ---

"""
Sales transactions in the current step, scaled to the national household count
(`model.uk_households`) and truncated to an integer.

The Java `CoreIndicators.getHousingTransactions()` uses a rolling-window mean with the
same scaling; here the instantaneous monthly volume is reported.
"""
function get_sales_volume(model)
    return Int(floor(model.market_stats.sales_volume * model.uk_households / Config.N_HOUSEHOLDS))
end

"""
Mortgage approvals in the current step, scaled like `get_sales_volume`
(Java: `CoreIndicators.getMortgageApprovals()`).
"""
function get_mortgage_approvals(model)
    return Int(floor(model.market_stats.mortgage_approvals * model.uk_households / Config.N_HOUSEHOLDS))
end

"""
Gross new mortgage lending in the current step: the sum of `final_loan_principal`
over all mortgage clearances, scaled like `get_mortgage_approvals`. Parallels the
Java `CreditSupply.newLendingAmount`.
"""
function get_new_lending_flow(model)
    return model.market_stats.new_lending_flow * model.uk_households / Config.N_HOUSEHOLDS
end

"""Number of new rental contracts signed in the current step."""
function get_rental_transactions(model)
    return model.market_stats.rental_transactions
end

"""Exponential moving average of sale prices."""
function get_mean_house_price(model)
    return model.market_stats.ema_sales_price
end

"""Exponential moving average of rents."""
function get_mean_rent(model)
    return model.market_stats.ema_rent
end

# --- Market indices and aggregates ---

"""House price index level (raw index, not a growth rate)."""
function get_market_hpi(model)
    return model.market_stats.hpi
end

"""Government bank balance."""
function get_government_revenue(model)
    return model.government.bank_balance
end

"""Mean household bank balance (liquid wealth)."""
function get_avg_liquid_wealth(model)
    return mean(a.bank_balance for a in allagents(model))
end

"""House price appreciation as tracked by the market statistics."""
function get_market_hpa(model)
    return model.market_stats.hpa_oracle
end

"""
Stock rental yield: mean over non-BTL renting households of annual rent divided by the
exponential-average sale price for the quality of the rented home. Returned as a raw
ratio (the Java `CoreIndicators.getAvStockRentalYield()` multiplies by 100).

BTL-gene renters are excluded, mirroring the Java partition in
`HouseholdStats`. This is a stock measure of rent burden on occupied dwellings, as
opposed to the flow yield in `get_flow_yield`.
"""
function get_market_yield(model)
    sum_stock_yield = 0.0
    n_renting = 0
    houses = model.housing_stock
    for a in allagents(model)
        # Java parity: the yield sum only accumulates in the non-BTL branch.
        if !a.is_btl_investor && a.rental_agreement !== nothing && a.residence_id !== nothing
            h = houses[a.residence_id]
            q = h.quality
            n_renting += 1  # Java parity: counted before the price guard
            ema_price_q = model.market_stats.ema_prices_by_quality[q]
            if ema_price_q > 0.0
                annual_rent = a.rental_agreement.monthly_rent * Config.MONTHS_IN_YEAR
                sum_stock_yield += annual_rent / ema_price_q
            end
        end
    end
    return n_renting > 0 ? (sum_stock_yield / n_renting) : 0.0
end

"""
Exponential moving average of the flow yield of new rentals, as a fraction
(Java: `RentalMarketStats.getExpAvFlowYield()`):
`expAvFlowYield = SMOOTHING * avFlowYield + (1 - SMOOTHING) * expAvFlowYield`, where
`avFlowYield` is the weighted-average yield of the rentals signed in the step.
`stats.ema_yield` is updated every step in `MarketStats.jl`.
"""
function get_flow_yield(model)
    return model.market_stats.ema_yield
end

"""
Sector-wide price-to-income ratio: mix-adjusted mean house price times the number of
households, divided by the household sector's total annualised **net** (after income
tax and National Insurance) income. Mirrors Java
`CoreIndicators.getPriceToIncome()`:
`HPI * HOUSE_PRICES_MEAN * N_households / sum(annualised net total income)`.

The denominator is net income, so this ratio is larger than one built on gross income;
see `get_price_to_income_gross` for the gross-income version.

When `model.spain_gross_income_flow` is true, the denominator is instead the gross total
income (wage plus rental income, with no finance-cost deduction and no tax), mirroring
the Spanish Java variant. Returns 0.0 if total income is not positive.
"""
function get_price_to_income_ratio(model)
    houses = model.housing_stock
    # Annualised total income of all households, built as in Java's HouseholdStats.record().
    spain_mode = model.spain_gross_income_flow
    total_annualised_income = 0.0
    for a in allagents(model)
        # Reconstruct monthly net total income per Java's Household.getMonthlyNetTotalIncome()
        # = getMonthlyGrossTotalIncome() - (incomeTax(annualGross - financeCosts) + NIC(annualWage)) / 12
        wage = a.annual_income
        # Rental income: contracted rent of each let property, taken from the tenant's
        # rental agreement (Java: getMonthlyGrossRentalIncome() sums
        # rentalAgreement.nextPayment()), not the listing price.
        rental_income = 0.0
        if !isempty(a.properties_owned)
            for prop_id in a.properties_owned
                h = houses[prop_id]
                if h.resident_id !== nothing && h.resident_id != a.id
                    if Agents.hasid(model, h.resident_id)
                        tenant = model[h.resident_id]
                        if tenant.rental_agreement !== nothing && tenant.rental_agreement.house_id == prop_id
                            rental_income += tenant.rental_agreement.monthly_rent * 12.0
                        else
                            # Fallback to the listing rent if no matching agreement is found.
                            rental_income += h.rental_price * 12.0
                        end
                    end
                end
            end
        end
        if spain_mode
            # Spain: gross total income = wage + rental (no finance subtraction, no tax).
            total_annualised_income += wage + rental_income
        else
            # UK (Java parity): net total income via the calculate_net_income tax pass.
            # BTL finance costs (mortgage payments on non-residence loans, deductible for
            # tax) follow Java's getAnnualFinanceCosts(): monthly_payment × 12.
            finance_costs = 0.0
            if !isempty(a.mortgages_held)
                for m in a.mortgages_held
                    is_btl = (a.residence_id === nothing || m.house_id != a.residence_id)
                    if is_btl && m.term_months > 0 && m.monthly_payment > 0.0
                        finance_costs += m.monthly_payment * 12.0
                    end
                end
            end
            # calculate_net_income (Government.jl) takes annual inputs and returns
            # (annual net income, total tax).
            net_income, _ = calculate_net_income(wage, rental_income, finance_costs)
            total_annualised_income += net_income
        end
    end

    if total_annualised_income <= 0.0; return 0.0; end

    # Java: HPI * HOUSE_PRICES_MEAN * Model.households.size() / total_income
    return model.market_stats.hpi * Config.HOUSE_PRICES_MEAN * nagents(model) / total_annualised_income
end

"""
Gross-income price-to-income ratio: mix-adjusted mean house price divided by the mean
gross employment income (`annual_income`) of all households:
`HPI * HOUSE_PRICES_MEAN / mean(annual_income)`.

The only difference from `get_price_to_income_ratio` is the gross rather than net
income denominator. Returns 0.0 if there are no households or no positive income.
"""
function get_price_to_income_gross(model)
    n = nagents(model)
    n == 0 && return 0.0
    total_gross = sum(a.annual_income for a in allagents(model))
    total_gross <= 0.0 && return 0.0
    mean_gross = total_gross / n
    return model.market_stats.hpi * Config.HOUSE_PRICES_MEAN / mean_gross
end

# --- Price-to-income split by owner-occupier and buy-to-let households ---
# Owner-occupier (OO) buyers set their purchase budget as a multiple of personal income,
# whereas buy-to-let (BTL) investors set it from maximum leverage and rental yield, so a
# pooled ratio mixes two different buyer mechanisms. The functions below therefore
# report the ratio separately for non-BTL-gene households (`_oo`) and BTL-gene households
# (`_btl`, a diagnostic counterpart). The split key is `agent.is_btl_investor`, the same
# classifier used in HouseholdBehavior.jl and in the agent-data column of that name.
# All of them are deterministic reductions over the agent population.

"""
Gross-income price-to-income ratio restricted to non-BTL-gene (owner-occupier)
households. Returns `NaN` if there are no such households or no positive income.
"""
function get_price_to_income_gross_oo(model)
    total_gross = 0.0
    n_oo = 0
    for a in allagents(model)
        a.is_btl_investor && continue
        total_gross += a.annual_income
        n_oo += 1
    end
    n_oo == 0 && return NaN
    total_gross <= 0.0 && return NaN
    mean_gross = total_gross / n_oo
    return model.market_stats.hpi * Config.HOUSE_PRICES_MEAN / mean_gross
end

"""
Gross-income price-to-income ratio restricted to BTL-gene households (diagnostic).
BTL purchase budgets come from leverage and yield rather than an income multiple, so
the ratio is mainly informative as a counterpart to the owner-occupier series.
Returns `NaN` if there are no BTL households or no positive income.
"""
function get_price_to_income_gross_btl(model)
    total_gross = 0.0
    n_btl = 0
    for a in allagents(model)
        a.is_btl_investor || continue
        total_gross += a.annual_income
        n_btl += 1
    end
    n_btl == 0 && return NaN
    total_gross <= 0.0 && return NaN
    mean_gross = total_gross / n_btl
    return model.market_stats.hpi * Config.HOUSE_PRICES_MEAN / mean_gross
end

"""
Net-income price-to-income ratio restricted to non-BTL-gene (owner-occupier) households:
the counterpart of `get_price_to_income_ratio` with an owner-occupier-only mean income.
These households are taken to have no rental income or finance costs, so net income is
wage less income tax and National Insurance (via `calculate_net_income`), or simply the
wage when `model.spain_gross_income_flow` is true. Returns `NaN` if there are no such
households or no positive income.
"""
function get_price_to_income_ratio_oo(model)
    spain_mode = model.spain_gross_income_flow
    total_income = 0.0
    n_oo = 0
    for a in allagents(model)
        a.is_btl_investor && continue
        if spain_mode
            total_income += a.annual_income
        else
            # Owner-occupiers: no rental income, no BTL finance costs.
            net_income, _ = calculate_net_income(a.annual_income, 0.0, 0.0)
            total_income += net_income
        end
        n_oo += 1
    end
    n_oo == 0 && return NaN
    total_income <= 0.0 && return NaN
    # Mean income per household: the household count cancels against the price numerator.
    mean_income = total_income / n_oo
    return model.market_stats.hpi * Config.HOUSE_PRICES_MEAN / mean_income
end

"""
Net-income price-to-income ratio restricted to BTL-gene households (diagnostic).
Repeats the sector-wide income reconstruction of `get_price_to_income_ratio` (wage,
contracted rental income, deductible finance costs) for this group, since these are the
households with non-zero rental income and finance costs. With
`model.spain_gross_income_flow` true, income is wage plus rental income with no finance
cost deduction and no tax. Returns `NaN` if there are no BTL households or no positive
income.
"""
function get_price_to_income_ratio_btl(model)
    spain_mode = model.spain_gross_income_flow
    houses = model.housing_stock
    total_income = 0.0
    n_btl = 0
    for a in allagents(model)
        a.is_btl_investor || continue
        wage = a.annual_income
        # Contracted rental income from let properties (as in the sector-wide function).
        rental_income = 0.0
        if !isempty(a.properties_owned)
            for prop_id in a.properties_owned
                h = houses[prop_id]
                if h.resident_id !== nothing && h.resident_id != a.id
                    if Agents.hasid(model, h.resident_id)
                        tenant = model[h.resident_id]
                        if tenant.rental_agreement !== nothing && tenant.rental_agreement.house_id == prop_id
                            rental_income += tenant.rental_agreement.monthly_rent * 12.0
                        else
                            rental_income += h.rental_price * 12.0
                        end
                    end
                end
            end
        end
        if spain_mode
            # Spain: gross BTL income = wage + rental (no finance subtraction, no tax).
            total_income += wage + rental_income
        else
            # UK (Java parity): net BTL income via tax pass with finance-cost relief.
            finance_costs = 0.0
            if !isempty(a.mortgages_held)
                for m in a.mortgages_held
                    is_btl_loan = (a.residence_id === nothing || m.house_id != a.residence_id)
                    if is_btl_loan && m.term_months > 0 && m.monthly_payment > 0.0
                        finance_costs += m.monthly_payment * 12.0
                    end
                end
            end
            net_income, _ = calculate_net_income(wage, rental_income, finance_costs)
            total_income += net_income
        end
        n_btl += 1
    end
    n_btl == 0 && return NaN
    total_income <= 0.0 && return NaN
    mean_income = total_income / n_btl
    return model.market_stats.hpi * Config.HOUSE_PRICES_MEAN / mean_income
end

"""
Share of households that live in a house they own, including active BTL investors
who also hold investment properties (Java: `(nOwnerOccupier + nActiveBTL) / population`;
the Java `getnOwnerOccupier()` count on its own excludes active BTL investors).
Homeless households and renters count as non-owners.
"""
function get_ownership_rate(model)
    houses = model.housing_stock
    owners = count(allagents(model)) do a
        a.residence_id !== nothing &&
        houses[a.residence_id].owner_id == a.id
    end
    return owners / nagents(model)
end

"""
Share of households that own their residence and hold a mortgage on that same house
(`m.house_id == residence_id`). A mortgage on some other property, as a BTL investor may
have, does not count. The Java model does not split owner-occupiers by mortgage status;
this is an additional breakdown.
"""
function get_oo_with_mortgage_rate(model)
    houses = model.housing_stock
    oo_with_mort = count(allagents(model)) do a
        a.residence_id !== nothing &&
        houses[a.residence_id].owner_id == a.id &&
        any(m -> m.house_id == a.residence_id, a.mortgages_held)
    end
    return oo_with_mort / nagents(model)
end

"""
Share of households that own their residence outright, with no mortgage on that house.
Together with `get_oo_with_mortgage_rate` this sums to `get_ownership_rate`.
"""
function get_oo_outright_rate(model)
    houses = model.housing_stock
    oo_outright = count(allagents(model)) do a
        a.residence_id !== nothing &&
        houses[a.residence_id].owner_id == a.id &&
        !any(m -> m.house_id == a.residence_id, a.mortgages_held)
    end
    return oo_outright / nagents(model)
end

"""
Share of households that are renters: non-BTL-gene households with a rental agreement.
BTL-gene households that rent are not counted, mirroring the Java partition in
`HouseholdStats` (`getnRenting()` is only incremented in the non-BTL branch).
"""
function get_rental_rate(model)
    renters = count(a -> a.rental_agreement !== nothing && !a.is_btl_investor, allagents(model))
    return renters / nagents(model)
end

"""Share of the housing stock that is owned by someone other than its resident."""
function get_investor_ownership_share(model)
    stock_size = length(model.housing_stock)
    if stock_size == 0; return 0.0; end
    
    investor_owned = count(h -> h.owner_id !== nothing && h.resident_id != h.owner_id, model.housing_stock)
    return investor_owned / stock_size
end

"""
Number of active BTL investors: BTL-gene households owning more than one property
(their home plus at least one investment property). Java:
`HouseholdStats.getnActiveBTL()`.
"""
function get_n_btl_investors(model)
    return count(a -> a.is_btl_investor && length(a.properties_owned) > 1, allagents(model))
end

"""
Total number of investment properties held by active BTL investors, excluding each
investor's own home (`properties_owned` includes the residence, hence the subtraction of
one per investor). Dividing by `get_n_btl_investors` gives properties per active investor.

The `residence_id !== nothing` condition is a safeguard: BTL purchases require an
owner-occupied home, so an investor with several properties is expected to have a
residence.
"""
function get_total_btl_properties(model)
    total = 0
    for a in allagents(model)
        if a.is_btl_investor && a.residence_id !== nothing && length(a.properties_owned) > 1
            total += length(a.properties_owned) - 1  # subtract the owner-occupied home
        end
    end
    return total
end

"""
Mean-above-median loan-to-income ratio of new owner-occupier mortgages (first-time
buyers and home movers) over the rolling window. Java:
`CoreIndicators.getOwnerOccupierLTIMeanAboveMedian()`.

The values come from `bank.oo_lti_window`, the counterpart of Java `CreditSupply.oo_lti`:
`ROLLING_WINDOW` monthly slots, each holding the origination principal divided by
annual gross employment income of the owner-occupier mortgages issued that month.
This is a flow measure over new lending, not a stock measure. All slots are flattened and
sorted, and the mean of the upper half is returned (0.0 if no loans are recorded).
"""
function get_avg_lti(model)
    combined = Float64[]
    for slot in model.bank.oo_lti_window
        append!(combined, slot)
    end
    if isempty(combined); return 0.0; end

    # Mean above the median (Java: getMeanAboveMedian).
    sort!(combined)
    # Java: midPoint = combined.size() / 2 (0-based); maps to (length ÷ 2) + 1 in 1-based Julia.
    mid = length(combined) ÷ 2 + 1
    return mean(@view combined[mid:end])
end

"""
Stock loan-to-value ratio: total remaining mortgage principal divided by the value of
the mortgaged houses. Each house is valued at the exponentially averaged sale price for
its quality band (Java: `getExpAvSalePriceForQuality(house.quality)` in `HouseholdStats`),
not at a single average price. Returns 0.0 if the total value is not positive.
"""
function get_avg_ltv_stock(model)
    houses = model.housing_stock
    total_debt = 0.0
    total_asset_value = 0.0

    for a in allagents(model)
        for m in a.mortgages_held
            total_debt += m.remaining_principal
            h = houses[m.house_id]
            total_asset_value += model.market_stats.ema_prices_by_quality[h.quality]
        end
    end

    if total_asset_value <= 0.0; return 0.0; end
    return total_debt / total_asset_value
end

"""
Mean-above-median loan-to-value ratio of new owner-occupier mortgages (first-time
buyers and home movers) over the rolling window. Java:
`CoreIndicators.getOwnerOccupierLTVMeanAboveMedian()`.

The values come from `bank.oo_ltv_window`, the counterpart of Java `CreditSupply.oo_ltv`:
`ROLLING_WINDOW` monthly slots, each holding the loan-to-value ratio at origination
(`principal / (principal + down_payment)`) of the owner-occupier mortgages issued that
month. This is a flow measure over new lending, not a stock measure. All slots are
flattened and sorted, and the mean of the upper half is returned (0.0 if no loans are
recorded).

The window is only unbiased if the slot timing is respected: the active slot is advanced
and cleared before clearing in each step (see the scheduler), mortgage registration then
fills it during clearing, and this collector runs after the step. A slot advanced after
clearing would always be empty when read, shrinking the effective window by one month;
the emptiness check below would not detect that. Months with no new mortgages
legitimately leave a slot empty.
"""
function get_avg_ltv_owner_occupier(model)
    combined = Float64[]
    for slot in model.bank.oo_ltv_window
        append!(combined, slot)
    end
    if isempty(combined); return 0.0; end

    # Mean above the median (Java: getMeanAboveMedian).
    sort!(combined)
    # Java: midPoint = combined.size() / 2 (0-based, integer division) and the sum runs from
    # midPoint to the end; in 1-based Julia midPoint maps to (length ÷ 2) + 1.
    mid = length(combined) ÷ 2 + 1
    # Java returns a percentage (100×); this collector returns the raw ratio.
    return mean(@view combined[mid:end])
end

"""
Stock mortgage debt-to-income ratio: total remaining mortgage principal divided by the
household sector's total annualised net income, computed as in
`get_price_to_income_ratio`. Java: `CoreIndicators.getMortgageDebtToIncome()`, which
returns `100 * (totalBTLCredit + totalOOCredit) / sum(annualised net total income)`; this
collector returns the raw ratio.

When `model.spain_gross_income_flow` is true, the income denominator is gross total
income (wage plus rental income, no finance-cost deduction, no tax); the numerator is
unaffected. Returns 0.0 if total income is not positive.
"""
function get_avg_dti_stock(model)
    spain_mode = model.spain_gross_income_flow
    houses = model.housing_stock
    # Total mortgage debt (remaining principal across all agents)
    total_debt = 0.0
    # Total annualised income (gross in Spain mode, net of tax otherwise)
    total_annualised_income = 0.0

    for a in allagents(model)
        # Accumulate debt
        for m in a.mortgages_held
            total_debt += m.remaining_principal
        end

        # Annualised total income, reconstructed as in get_price_to_income_ratio
        wage = a.annual_income
        # Contracted rent from the tenant's rental agreement (Java: getMonthlyGrossRentalIncome()
        # sums rentalAgreement.nextPayment()), not the current listing rent.
        rental_income = 0.0
        if !isempty(a.properties_owned)
            for prop_id in a.properties_owned
                h = houses[prop_id]
                if h.resident_id !== nothing && h.resident_id != a.id
                    if Agents.hasid(model, h.resident_id)
                        tenant = model[h.resident_id]
                        if tenant.rental_agreement !== nothing && tenant.rental_agreement.house_id == prop_id
                            rental_income += tenant.rental_agreement.monthly_rent * 12.0
                        else
                            rental_income += h.rental_price * 12.0  # fallback if no agreement found
                        end
                    end
                end
            end
        end
        if spain_mode
            # Spain: gross total income = wage + rental (no finance subtraction, no tax).
            total_annualised_income += wage + rental_income
        else
            # UK (Java parity): net total income via tax pass with finance-cost relief.
            # Finance costs follow Java's getAnnualFinanceCosts(): monthly_payment × 12 on
            # mortgages that are not on the owner's residence.
            finance_costs = 0.0
            if !isempty(a.mortgages_held)
                for m in a.mortgages_held
                    is_btl = (a.residence_id === nothing || m.house_id != a.residence_id)
                    if is_btl && m.term_months > 0 && m.monthly_payment > 0.0
                        finance_costs += m.monthly_payment * 12.0
                    end
                end
            end
            net_income, _ = calculate_net_income(wage, rental_income, finance_costs)
            total_annualised_income += net_income
        end
    end

    if total_annualised_income <= 0.0; return 0.0; end
    return total_debt / total_annualised_income
end

"""
    get_avg_dsti_stock(model) -> Float64

Owner-occupier debt-service-to-income ratio over the current mortgage stock.

Numerator: annual debt service (`monthly_payment * 12`) on all non-buy-to-let mortgages.
Denominator: gross employment income (`annual_income`) of all agents that are not
buy-to-let investors. Both sides are restricted to the owner-occupier side because the
regulatory DSTI ceiling (`effective_dsti_limit`) is applied to `monthly_payment` over
monthly employment income at owner-occupier origination, and buy-to-let borrowers are
serviced from rental income. The buy-to-let slice is reported by `get_avg_dsti_stock_btl`.
Returns 0.0 if the denominator is zero.
"""
function get_avg_dsti_stock(model)
    total_annual_service = 0.0
    total_gross_income   = 0.0
    for a in allagents(model)
        if a.is_btl_investor; continue; end   # OO-side denominator only
        total_gross_income += a.annual_income
        for m in a.mortgages_held
            m.is_buy_to_let && continue        # OO-side numerator only
            total_annual_service += m.monthly_payment * 12.0
        end
    end
    return total_gross_income > 0.0 ? total_annual_service / total_gross_income : 0.0
end

"""
    get_avg_dsti_stock_btl(model) -> Float64

Buy-to-let counterpart of `get_avg_dsti_stock`, reported as a diagnostic.

Numerator: annual debt service on the buy-to-let mortgages held by buy-to-let investors.
Denominator: gross employment income (`annual_income`) of buy-to-let investors. The
wage-only denominator follows the Java model, whose regulatory affordability check in
`Bank` uses `getMonthlyGrossEmploymentIncome`. Buy-to-let lending is constrained by
ICR and LTV rather than DSTI, so this ratio is informative only and is not a limit.
Returns 0.0 if the denominator is zero. Deterministic and read-only.
"""
function get_avg_dsti_stock_btl(model)
    total_annual_service = 0.0
    total_gross_income   = 0.0
    for a in allagents(model)
        a.is_btl_investor || continue
        total_gross_income += a.annual_income
        for m in a.mortgages_held
            m.is_buy_to_let || continue
            total_annual_service += m.monthly_payment * 12.0
        end
    end
    return total_gross_income > 0.0 ? total_annual_service / total_gross_income : 0.0
end

"""
    get_avg_dsti_flow(model) -> Float64

Mean DSTI of the new owner-occupier mortgages originated in the current step:
`(monthly_payment * 12) / annual_income` per transaction, averaged over transactions
that are not buy-to-let, carry a loan and have positive income. Returns 0.0 if there
are none. The buy-to-let slice is reported by `get_avg_dsti_flow_btl`.
"""
function get_avg_dsti_flow(model)
    # Agents.step! advances abmtime after model_step!, so when the collector runs
    # post-step the clock is one ahead of the step stored in transaction_log.
    current_step = Agents.abmtime(model) - 1
    sum_dsti = 0.0
    n = 0
    for tx in model.transaction_log
        tx.step != current_step && continue
        tx.is_buy_to_let && continue          # OO-only flow
        tx.loan_amount <= 0.0 && continue    # cash purchase — no DSTI
        tx.annual_income <= 0.0 && continue   # guard
        sum_dsti += (tx.monthly_payment * 12.0) / tx.annual_income
        n += 1
    end
    return n > 0 ? sum_dsti / n : 0.0
end

"""
    get_avg_dsti_flow_btl(model) -> Float64

Buy-to-let counterpart of `get_avg_dsti_flow`: mean `(monthly_payment * 12) / annual_income`
over buy-to-let mortgages originated in the current step. The wage-only income
denominator is explained in `get_avg_dsti_stock_btl`. Returns 0.0 if there are none.
"""
function get_avg_dsti_flow_btl(model)
    current_step = Agents.abmtime(model) - 1
    sum_dsti = 0.0
    n = 0
    for tx in model.transaction_log
        tx.step != current_step && continue
        tx.is_buy_to_let || continue          # BTL-only
        tx.loan_amount <= 0.0 && continue
        tx.annual_income <= 0.0 && continue
        sum_dsti += (tx.monthly_payment * 12.0) / tx.annual_income
        n += 1
    end
    return n > 0 ? sum_dsti / n : 0.0
end

"""
    get_avg_dsti_flow_ftb(model) -> Float64

Mean DSTI at origination, `(monthly_payment * 12) / annual_income`, over the new
first-time-buyer mortgages of the current step. Returns 0.0 if there are none.
"""
function get_avg_dsti_flow_ftb(model)
    current_step = Agents.abmtime(model) - 1
    sum_dsti = 0.0
    n = 0
    for tx in model.transaction_log
        tx.step != current_step && continue
        tx.loan_amount <= 0.0 && continue
        tx.annual_income <= 0.0 && continue
        tx.buyer_type == FTB || continue
        sum_dsti += (tx.monthly_payment * 12.0) / tx.annual_income
        n += 1
    end
    return n > 0 ? sum_dsti / n : 0.0
end

"""
    get_avg_dsti_flow_hm_btl(model) -> Float64

Mean DSTI at origination over the new mortgages of the current step taken by borrowers
other than first-time buyers (home movers and buy-to-let investors). Returns 0.0 if
there are none.
"""
function get_avg_dsti_flow_hm_btl(model)
    current_step = Agents.abmtime(model) - 1
    sum_dsti = 0.0
    n = 0
    for tx in model.transaction_log
        tx.step != current_step && continue
        tx.loan_amount <= 0.0 && continue
        tx.annual_income <= 0.0 && continue
        tx.buyer_type == FTB && continue
        sum_dsti += (tx.monthly_payment * 12.0) / tx.annual_income
        n += 1
    end
    return n > 0 ? sum_dsti / n : 0.0
end

# --- Owner-occupier / buy-to-let credit stock ---
#
# Mirrors the Java CreditSupply.postClearingRecord(), which splits the bank's mortgages by
# `isBuyToLet`. Here the split iterates every agent's `mortgages_held` on `is_buy_to_let`.
# Java's `MortgageAgreement.principal` is the remaining principal (reduced by each monthly
# payment), which corresponds to `remaining_principal` in this model.

"""
    get_btl_credit_stock(model)

Total outstanding buy-to-let mortgage credit: the sum of `remaining_principal` over
mortgages with `is_buy_to_let`. Java counterpart: `CreditSupply.getTotalBTLCredit()`.
"""
function get_btl_credit_stock(model)
    total = 0.0
    for a in allagents(model)
        for m in a.mortgages_held
            if m.is_buy_to_let
                total += m.remaining_principal
            end
        end
    end
    return total
end

"""
    get_oo_credit_stock(model)

Total outstanding owner-occupier mortgage credit: the sum of `remaining_principal` over
mortgages that are not buy-to-let. Java counterpart: `CreditSupply.getTotalOOCredit()`.
"""
function get_oo_credit_stock(model)
    total = 0.0
    for a in allagents(model)
        for m in a.mortgages_held
            if !m.is_buy_to_let
                total += m.remaining_principal
            end
        end
    end
    return total
end

"""
    get_oo_dti_stock(model)

Owner-occupier mortgage debt-to-income ratio: owner-occupier credit divided by the
annualised income of all agents, returned as a raw ratio (not multiplied by 100).
Java counterpart: `CoreIndicators.getOOMortgageDebtToIncome()`, which is
`100 * totalOOCredit / income_sum` over the whole sector.

Income is accumulated as in `get_avg_dti_stock`: wage plus rental income, net of tax and
finance-cost relief in the UK mode, or the gross sum when `model.spain_gross_income_flow`
is true. Returns 0.0 if total income is not positive.
"""
function get_oo_dti_stock(model)
    spain_mode = model.spain_gross_income_flow
    houses = model.housing_stock
    oo_credit = 0.0
    total_annualised_income = 0.0
    for a in allagents(model)
        for m in a.mortgages_held
            if !m.is_buy_to_let
                oo_credit += m.remaining_principal
            end
        end
        wage = a.annual_income
        rental_income = 0.0
        if !isempty(a.properties_owned)
            for prop_id in a.properties_owned
                h = houses[prop_id]
                if h.resident_id !== nothing && h.resident_id != a.id
                    if Agents.hasid(model, h.resident_id)
                        tenant = model[h.resident_id]
                        if tenant.rental_agreement !== nothing && tenant.rental_agreement.house_id == prop_id
                            rental_income += tenant.rental_agreement.monthly_rent * 12.0
                        else
                            rental_income += h.rental_price * 12.0
                        end
                    end
                end
            end
        end
        if spain_mode
            total_annualised_income += wage + rental_income
        else
            finance_costs = 0.0
            if !isempty(a.mortgages_held)
                for m in a.mortgages_held
                    is_btl = (a.residence_id === nothing || m.house_id != a.residence_id)
                    if is_btl && m.term_months > 0 && m.monthly_payment > 0.0
                        finance_costs += m.monthly_payment * 12.0
                    end
                end
            end
            net_income, _ = calculate_net_income(wage, rental_income, finance_costs)
            total_annualised_income += net_income
        end
    end
    if total_annualised_income <= 0.0; return 0.0; end
    return oo_credit / total_annualised_income
end

"""
    get_interest_rate_spread(model)

Current mortgage interest-rate spread of the bank (`bank.current_spread`) as a raw ratio.
Java's `CoreIndicators.getInterestRateSpread()` returns the same quantity multiplied by 100.
"""
function get_interest_rate_spread(model)
    return model.bank.current_spread
end

# --- Zombie-debt and bank balance-sheet getters ---
# These collectors expose the effect of the `Config.D3_ZOMBIE_DEBT` and
# `Config.D4_INHERITANCE_OVERPAY` switches. With both false (the default) no zombie debts
# exist and inheritance shortfalls are written off. With D3_ZOMBIE_DEBT true the zombie
# counters can become positive; with D4_INHERITANCE_OVERPAY true no shortfall arises.

"""
    get_zombie_agent_count(model)

Number of agents holding at least one zombie debt (a mortgage residual left after a sale,
only created when `Config.D3_ZOMBIE_DEBT` is true).
"""
function get_zombie_agent_count(model)
    return count(a -> !isempty(a.zombie_debts), allagents(model))
end

"""
    get_zombie_total_principal(model)

Total `remaining_principal` over all zombie debts in the economy. Always 0.0 unless
`Config.D3_ZOMBIE_DEBT` is true.
"""
function get_zombie_total_principal(model)
    total = 0.0
    for a in allagents(model)
        for zm in a.zombie_debts
            total += zm.remaining_principal
        end
    end
    return total
end

"""
    get_bank_outstanding_credit(model)

Bank's outstanding credit: issued principal that has not yet been discharged. It falls by
the full principal at a sale whichever way the `D3_ZOMBIE_DEBT` switch is set.
"""
function get_bank_outstanding_credit(model)
    return model.bank.outstanding_credit
end

"""
    get_bank_cash_reserves(model)

Bank cash reserves. With `Config.D3_ZOMBIE_DEBT` false the bank receives the full
remaining principal at each sale. With it true the bank receives only the amount the
seller can pay at the sale, plus later instalments on the zombie debts.
"""
function get_bank_cash_reserves(model)
    return model.bank.cash_reserves
end

"""
    get_cumulative_zombie_recovered(model)

Cumulative cash credited to the bank through monthly servicing of zombie debts.
Non-decreasing; stays 0.0 unless `Config.D3_ZOMBIE_DEBT` is true.
"""
function get_cumulative_zombie_recovered(model)
    return model.bank.cumulative_zombie_recovered
end

"""
    get_cumulative_inheritance_writeoffs(model)

Cumulative shortfall written off when a deceased agent's mortgages exceed their bank
balance (`Config.D4_INHERITANCE_OVERPAY` false). Stays 0.0 when it is true, because the
full outstanding principal is then paid.
"""
function get_cumulative_inheritance_writeoffs(model)
    return model.bank.cumulative_inheritance_writeoffs
end

# --- Per-step market and population counters ---

"""
    get_rpi(model)

Rental price index (`market_stats.rental_price_index`): monthly exponential moving average
of achieved rent relative to the initial rent. Java counterpart:
`HouseholdStats.rentalPriceIndex`.
"""
function get_rpi(model)
    return model.market_stats.rental_price_index
end

"""
    get_btl_population_share(model)

Share of the population that are active buy-to-let investors, i.e. agents with
`is_btl_investor` who own more than one property. Java counterpart:
`HouseholdStats.nActiveBTL / N`. This is a share of agents, unlike
`get_investor_ownership_share`, which is a fraction of the housing stock.
"""
function get_btl_population_share(model)
    return count(a -> a.is_btl_investor && length(a.properties_owned) > 1, allagents(model)) / nagents(model)
end

"""Number of sale listings withdrawn from the market in the current step (`market_stats.n_withdrawals`)."""
function get_n_withdrawals(model)
    return model.market_stats.n_withdrawals
end

"""Number of household bankruptcies in the current step (`market_stats.n_bankruptcies`)."""
function get_n_bankruptcies(model)
    return model.market_stats.n_bankruptcies
end

# Bankruptcies split by borrower type. The per-type counters are read from `market_stats`
# and reset every step in Scheduler.jl, so
# get_n_bankruptcies == get_n_bankruptcies_ftb + get_n_bankruptcies_hm + get_n_bankruptcies_btl.

"""Number of first-time-buyer bankruptcies in the current step."""
function get_n_bankruptcies_ftb(model)
    return model.market_stats.n_bankruptcies_ftb
end

"""Number of home-mover bankruptcies in the current step."""
function get_n_bankruptcies_hm(model)
    return model.market_stats.n_bankruptcies_hm
end

"""Number of buy-to-let investor bankruptcies in the current step."""
function get_n_bankruptcies_btl(model)
    return model.market_stats.n_bankruptcies_btl
end

"""
    get_n_bids(model)

Number of active bids recorded by the pre-clearing snapshot (`market_stats.n_bids_active`).
Both the sales and rental markets write the underlying demand measure and rental clearing
runs last, so this reflects the rental market at snapshot time.
"""
function get_n_bids(model)
    return model.market_stats.n_bids_active
end

"""
    get_n_offers(model)

Number of active offers recorded by the pre-clearing snapshot
(`market_stats.n_offers_active`); like `get_n_bids`, it reflects the rental market.
"""
function get_n_offers(model)
    return model.market_stats.n_offers_active
end

"""Total outstanding mortgage principal across all agents (owner-occupier and buy-to-let combined)."""
function get_total_debt(model)
    total = 0.0
    for a in allagents(model)
        for m in a.mortgages_held
            total += m.remaining_principal
        end
    end
    return total
end

"""
    get_n_active_mortgages(model) -> Int

Number of outstanding mortgage contracts across all agents. An agent can hold several
mortgages (buy-to-let investors), so this sums `length(a.mortgages_held)` rather than
counting indebted agents. Dividing the per-step mortgage approvals by this count gives
mortgage turnover. Java counterpart: `Model.bank.mortgages.size()`, which is tracked on
the bank rather than on the agent side.
"""
function get_n_active_mortgages(model)
    count = 0
    for a in allagents(model)
        count += length(a.mortgages_held)
    end
    return count
end

"""Number of households (agents) in the model."""
function get_n_households(model)
    return nagents(model)
end

# Consumption collectors read the per-household `ConsumptionObservation` records (Types.jl),
# which are written where discretionary consumption is executed. Only observations with
# `valid == true` are aggregated; the sum collectors return NaN if there are none.

"""Number of households with a valid consumption observation in the current step."""
function get_n_consumption_observations(model)
    return count(a -> a.consumption_observation.valid, allagents(model))
end

"""Sum of essential consumption over valid observations; NaN if there are none."""
function get_essential_consumption(model)
    n_obs = get_n_consumption_observations(model)
    n_obs == 0 && return NaN
    return sum(a.consumption_observation.essential for a in allagents(model) if a.consumption_observation.valid)
end

"""Sum of discretionary consumption over valid observations; NaN if there are none."""
function get_discretionary_consumption(model)
    n_obs = get_n_consumption_observations(model)
    n_obs == 0 && return NaN
    return sum(a.consumption_observation.discretionary for a in allagents(model) if a.consumption_observation.valid)
end

"""
    get_non_housing_consumption(model)

Total non-housing consumption. When `model.spain_consumption_recording` is true it is the
per-step ledger kept in `market_stats`; otherwise it is the sum over valid consumption
observations (NaN if there are none).
"""
function get_non_housing_consumption(model)
    if model.spain_consumption_recording
        return model.market_stats.non_housing_consumption
    end
    n_obs = get_n_consumption_observations(model)
    n_obs == 0 && return NaN
    return sum(a.consumption_observation.non_housing for a in allagents(model) if a.consumption_observation.valid)
end

"""Non-housing consumption divided by the number of households; NaN if undefined."""
function get_non_housing_consumption_per_household(model)
    n_hh = get_n_households(model)
    n_hh == 0 && return NaN
    c = get_non_housing_consumption(model)
    return isnan(c) ? NaN : c / n_hh
end

"""Sum of monthly gross income (employment plus rental) over valid consumption observations; NaN if there are none."""
function get_consumption_gross_income_monthly(model)
    n_obs = get_n_consumption_observations(model)
    n_obs == 0 && return NaN
    return sum(a.consumption_observation.gross_income_monthly for a in allagents(model) if a.consumption_observation.valid)
end

"""Number of active owner-occupier (non-buy-to-let) mortgage contracts."""
function get_n_oo_mortgages(model)
    count = 0
    for a in allagents(model)
        for m in a.mortgages_held
            m.is_buy_to_let && continue
            count += 1
        end
    end
    return count
end

"""Number of active buy-to-let mortgage contracts."""
function get_n_btl_mortgages(model)
    count = 0
    for a in allagents(model)
        for m in a.mortgages_held
            m.is_buy_to_let || continue
            count += 1
        end
    end
    return count
end

"""Mean liquid wealth (`bank_balance`) across all agents."""
function get_mean_bank_balance(model)
    return mean(a.bank_balance for a in allagents(model))
end

"""
    get_total_housing_wealth(model)

Net housing wealth: for every property owned, the exponential-average sale price for its
quality band minus the remaining principal of the mortgage on that property (if any),
summed over all agents. Java counterpart: `HouseholdStats.recordHousingWealth`, which adds
`expAvSalePriceForQuality(quality) - MortgageAgreement.principal`.
"""
function get_total_housing_wealth(model)
    houses = model.housing_stock
    total = 0.0
    for a in allagents(model)
        for prop_id in a.properties_owned
            h = houses[prop_id]
            gross = model.market_stats.ema_prices_by_quality[h.quality]
            # Deduct remaining principal for this property's mortgage, if any
            debt = 0.0
            for m in a.mortgages_held
                if m.house_id == prop_id
                    debt = m.remaining_principal
                    break
                end
            end
            total += gross - debt
        end
    end
    return total
end

# ============================================================================
# Wealth aggregate collectors
#
# Three observational collectors that mirror the Java
# `HouseholdStats.recordHousingWealth`. They are gated by
# `model.spain_record_wealth_aggregates`: when it is false (the default) each returns 0.0
# immediately, so there is no iteration cost. When it is true each makes one pass over the
# households, executed only when model data is collected. They use no random numbers and
# can be called any number of times per step.
# ============================================================================

"""
    get_total_financial_wealth(model)

Sum of `bank_balance` over all agents, in raw agent units (not scaled to a population).
Java counterpart: the `totalBankBalance` accumulator of `HouseholdStats`. Returns 0.0
unless `model.spain_record_wealth_aggregates` is true.
"""
function get_total_financial_wealth(model)
    model.spain_record_wealth_aggregates || return 0.0
    total = 0.0
    for a in allagents(model)
        total += a.bank_balance
    end
    return total
end

"""
    get_total_housing_net_wealth(model)

Net housing wealth as in `get_total_housing_wealth` (mark-to-market value minus remaining
mortgage principal), but returned only when `model.spain_record_wealth_aggregates` is
true; otherwise 0.0.
"""
function get_total_housing_net_wealth(model)
    model.spain_record_wealth_aggregates || return 0.0
    return get_total_housing_wealth(model)
end

"""
    get_total_housing_gross_wealth(model)

Gross housing wealth: the exponential-average sale price for each owned property's
quality band, summed without deducting mortgage principal. The difference to
`get_total_housing_net_wealth` is the remaining principal deducted per property.
Returns 0.0 unless `model.spain_record_wealth_aggregates` is true.
"""
function get_total_housing_gross_wealth(model)
    model.spain_record_wealth_aggregates || return 0.0
    houses = model.housing_stock
    total = 0.0
    for a in allagents(model)
        for prop_id in a.properties_owned
            h = houses[prop_id]
            total += model.market_stats.ema_prices_by_quality[h.quality]
        end
    end
    return total
end

# --- Mortgage cash flows and exposure-weighted rates ---
"""Per-step contractual interest due on active mortgages (raw-agent currency units)."""
function get_interest_due_this_step(model)
    return model.market_stats.audit_interest_due
end

"""Per-step interest cash paid by households on active mortgages."""
function get_interest_paid_this_step(model)
    return model.market_stats.audit_interest_paid
end

"""Per-step principal cash paid by households on active mortgages (incl. balloon payoffs)."""
function get_principal_paid_this_step(model)
    return model.market_stats.audit_principal_paid
end

"""
    _ead_weighted_terms(model) -> NamedTuple

Single pass over all mortgages with positive `remaining_principal`, used by the
`get_ead_weighted_*` collectors. The exposure (EAD) of a mortgage is its remaining
principal. For all mortgages and separately for owner-occupier (`_oo`) and buy-to-let
(`_btl`) mortgages the result holds the total exposure (`ead*`) and the exposure-weighted
numerators of the origination rate (`rate_num*`) and of the spread of the origination rate
over the central bank's current base rate (`spread_num*`). Dividing a numerator by the
matching exposure gives the weighted mean.
"""
function _ead_weighted_terms(model)
    ead_total = 0.0
    rate_num = 0.0
    spread_num = 0.0

    ead_oo = 0.0
    rate_num_oo = 0.0
    spread_num_oo = 0.0

    ead_btl = 0.0
    rate_num_btl = 0.0
    spread_num_btl = 0.0

    base_rate = model.central_bank.base_rate

    for a in allagents(model)
        for m in a.mortgages_held
            ead = m.remaining_principal
            ead <= 0.0 && continue

            rate = m.origination_rate
            spread = rate - base_rate

            ead_total += ead
            rate_num += ead * rate
            spread_num += ead * spread

            if m.is_buy_to_let
                ead_btl += ead
                rate_num_btl += ead * rate
                spread_num_btl += ead * spread
            else
                ead_oo += ead
                rate_num_oo += ead * rate
                spread_num_oo += ead * spread
            end
        end
    end

    return (
        ead_total = ead_total,
        rate_num = rate_num,
        spread_num = spread_num,
        ead_oo = ead_oo,
        rate_num_oo = rate_num_oo,
        spread_num_oo = spread_num_oo,
        ead_btl = ead_btl,
        rate_num_btl = rate_num_btl,
        spread_num_btl = spread_num_btl,
    )
end

"""EAD-weighted annual mortgage rate across all active mortgages (0.0 if there are none)."""
function get_ead_weighted_mortgage_rate(model)
    s = _ead_weighted_terms(model)
    return s.ead_total > 0.0 ? s.rate_num / s.ead_total : 0.0
end

"""EAD-weighted annual mortgage rate for owner-occupier mortgages."""
function get_ead_weighted_mortgage_rate_oo(model)
    s = _ead_weighted_terms(model)
    return s.ead_oo > 0.0 ? s.rate_num_oo / s.ead_oo : 0.0
end

"""EAD-weighted annual mortgage rate for BTL mortgages."""
function get_ead_weighted_mortgage_rate_btl(model)
    s = _ead_weighted_terms(model)
    return s.ead_btl > 0.0 ? s.rate_num_btl / s.ead_btl : 0.0
end

"""EAD-weighted spread to current base rate across all active mortgages (0.0 if there are none)."""
function get_ead_weighted_mortgage_spread(model)
    s = _ead_weighted_terms(model)
    return s.ead_total > 0.0 ? s.spread_num / s.ead_total : 0.0
end

"""EAD-weighted spread to current base rate for owner-occupier mortgages."""
function get_ead_weighted_mortgage_spread_oo(model)
    s = _ead_weighted_terms(model)
    return s.ead_oo > 0.0 ? s.spread_num_oo / s.ead_oo : 0.0
end

"""EAD-weighted spread to current base rate for BTL mortgages."""
function get_ead_weighted_mortgage_spread_btl(model)
    s = _ead_weighted_terms(model)
    return s.ead_btl > 0.0 ? s.spread_num_btl / s.ead_btl : 0.0
end

# ────────────────────────────────────────────────────────────────────────────────────────

"""
    build_data_collectors()

Return the `adata` and `mdata` collector definitions passed to Agents.jl `run!`.
"""
function build_data_collectors()
    # 1. Agent Data (adata)
    # Format: Tuple(:field, aggregation_function)
    adata = [
        (:age, mean),           # Average Age
        (:bank_balance, mean),  # Average Wealth
        (:bank_balance, maximum), # Richest agent
        (a -> a.residence_id === nothing, mean) # % Homeless
    ]

    # 2. Model data (mdata): one function per recorded model-level column
    mdata = [
        get_inventory_count,
        get_average_listing_price,
        get_homeless_count,
        get_sales_volume,
        get_mortgage_approvals,
        get_new_lending_flow,   # gross new lending flow (per tick, UK-scaled)
        get_rental_transactions,
        get_mean_house_price,
        get_mean_rent,
        get_market_hpi,
        get_market_hpa,
        get_market_yield,
        get_flow_yield,
        get_price_to_income_ratio,
        get_price_to_income_gross,
        # Price-to-income ratios split into owner-occupier and buy-to-let; the
        # sector-wide ratios above are kept as the aggregate measure.
        get_price_to_income_ratio_oo,
        get_price_to_income_ratio_btl,
        get_price_to_income_gross_oo,
        get_price_to_income_gross_btl,
        get_ownership_rate,
        get_rental_rate,
        get_investor_ownership_share,
        get_n_btl_investors,
        get_total_btl_properties,
        get_avg_ltv_stock,
        get_avg_ltv_owner_occupier,
        get_avg_lti,
        get_avg_dti_stock,
        get_btl_credit_stock,
        get_oo_credit_stock,
        get_oo_dti_stock,
        get_government_revenue,
        get_avg_liquid_wealth,
        get_interest_rate_spread,
        # Market, population, mortgage-count and consumption collectors
        get_rpi,
        get_btl_population_share,
        get_n_withdrawals,
        get_n_bankruptcies,
        get_n_bankruptcies_ftb,
        get_n_bankruptcies_hm,
        get_n_bankruptcies_btl,
        get_n_bids,
        get_n_offers,
        get_total_debt,
        get_n_active_mortgages,
        get_n_oo_mortgages,
        get_n_btl_mortgages,
        get_mean_bank_balance,
        get_n_households,
        get_n_consumption_observations,
        get_essential_consumption,
        get_discretionary_consumption,
        get_non_housing_consumption,
        get_non_housing_consumption_per_household,
        get_consumption_gross_income_monthly,
        get_total_housing_wealth,
        get_avg_dsti_stock,
        get_avg_dsti_stock_btl,
        get_avg_dsti_flow,
        get_avg_dsti_flow_btl,
        get_avg_dsti_flow_ftb,
        get_avg_dsti_flow_hm_btl,
        get_oo_with_mortgage_rate,
        get_oo_outright_rate,
        get_vacancy_rate,
        get_vacant_for_sale,
        get_vacant_for_rent,
        get_vacant_unlisted,
        get_mean_mortgage_age,
        get_p75_mortgage_age,
        # Wealth aggregates; each returns 0.0 unless `spain_record_wealth_aggregates` is true
        get_total_financial_wealth,
        get_total_housing_net_wealth,
        get_total_housing_gross_wealth,
        # Per-step mortgage cash flows and exposure-weighted rates and spreads
        get_interest_due_this_step,
        get_interest_paid_this_step,
        get_principal_paid_this_step,
        get_ead_weighted_mortgage_rate,
        get_ead_weighted_mortgage_rate_oo,
        get_ead_weighted_mortgage_rate_btl,
        get_ead_weighted_mortgage_spread,
        get_ead_weighted_mortgage_spread_oo,
        get_ead_weighted_mortgage_spread_btl,

    ]

    return adata, mdata
end