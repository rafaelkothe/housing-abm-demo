# src/model/HouseholdBehavior.jl
#
# Household decision rules for the housing market.
#
# Contents: gross total income, desired purchase price and its financial cap,
# the rent-or-buy tenure choice, buy-to-let (BTL) entry and exit decisions,
# expected house-price growth, the down-payment rule, and the household-side
# routines that value rentals, decide owner-occupier and BTL sales, and submit
# market bids.
#
# These functions are called from the scheduler, the demographics code and the
# market-clearing code; most of them consume random numbers from the model RNG, so
# the order of calls matters for reproducibility. Equation numbers refer to
# Carro et al. (2022); Java class and method names refer to the original Java model.

using Random
using Distributions

"""
    get_annual_gross_total_income(agent, model)

Annual gross total income of a household: employment income plus rental income
from every owned property that is currently let to a tenant other than the owner
(tenant with an active rental agreement). Mirrors Java's `getAnnualGrossTotalIncome()`,
`(monthlyGrossEmploymentIncome + getMonthlyGrossRentalIncome()) * 12`.

Used for the desired-wealth target (BTL investment decision, consumption) and for tax
calculations (via `calculate_net_income`). LTI and DSTI calculations use employment
income only (`agent.annual_income`).
"""
function get_annual_gross_total_income(agent::Household, model::AgentBasedModel)
    employment_income = agent.annual_income
    
    # Add rental income from all properties owned and rented out
    rental_income_annual = 0.0
    houses = model.housing_stock
    
    for prop_id in agent.properties_owned
        h = houses[prop_id]
        # Property must be occupied by someone OTHER than the owner
        if h.resident_id !== nothing && h.resident_id != agent.id
            # Get tenant and check for active rental agreement
            if Agents.hasid(model, h.resident_id)
                tenant = model[h.resident_id]
                if tenant.rental_agreement !== nothing && tenant.rental_agreement.months_remaining > 0
                    rental_income_annual += tenant.rental_agreement.monthly_rent * 12.0
                end
            end
        end
    end
    
    return employment_income + rental_income_annual
end

"""
    update_behavioral_state!(agent, model)

Draw the household's unconstrained desired purchase price (the fundamental anchor of
p_d in Carro et al. 2022) and store it in `agent.desired_purchase_price`:

    p_fundamental = alpha * y^beta * exp(epsilon),   epsilon ~ Normal(pd_epsilon_mu, pd_epsilon_sigma)

where `y` is `agent.annual_income`, `alpha = pd_alpha` and `beta = pd_beta`. The bank
constraint is applied separately by [`apply_financial_constraints`](@ref).

Consumes exactly one normal draw from the model RNG per call. It must be called once per
step for every agent, without conditional skipping, so that the random-number sequence
stays aligned with the Java model (`updateDesiredPurchasePrice`).
"""
function update_behavioral_state!(agent::Household, model::AgentBasedModel)
    params = model.params
    
    # --- Update desired purchase price (unconstrained) ---
    
    y = agent.annual_income
    alpha = params.pd_alpha
    beta = params.pd_beta
    
    # Idiosyncratic noise (enthusiasm), log-normal after exponentiation
    dist = Normal(params.pd_epsilon_mu, params.pd_epsilon_sigma)
    epsilon = rand(abmrng(model), dist)
    
    # Fundamental desired price, not yet limited by the bank.
    # Read later by the decision functions (decide_rent_or_buy, etc.)
    agent.desired_purchase_price = alpha * (y^beta) * exp(epsilon)
end

"""
    apply_financial_constraints(agent, model)

Limit the household's desired purchase price by its buying power (Eq. 1 of Carro et al.
2022): `p_d = min(p_fundamental, p_max)`, floored at zero. `p_max` is the maximum purchase
price the bank and the household's wealth allow, from `calculate_buying_power`.

Idempotent and free of random draws: it reads the value stored in
`agent.desired_purchase_price` by [`update_behavioral_state!`](@ref) and mutates nothing.

# Returns
A tuple `(p_d, p_fundamental, p_max)`:
- `p_d`: the effective desired price, `max(0, min(p_fundamental, p_max))`.
- `p_fundamental`: the unconstrained desired price.
- `p_max`: the buying power.
"""
function apply_financial_constraints(agent::Household, model::AgentBasedModel)
    p_fundamental = agent.desired_purchase_price
    
    # --- Cap by buying power ---
    # Eq 1: p_d = min(p_fund, p_max)
    p_max = calculate_buying_power(model.bank, agent, model) 
    
    # Anchor bids between desire and capacity.
    p_d = max(0.0, min(p_fundamental, p_max))
    
    return (p_d, p_fundamental, p_max)
end

"""
    decide_rent_or_buy(agent::Household, model::AgentBasedModel)

Tenure choice (Eq. 4 of Carro et al. 2022): returns `true` if the household decides to buy
and `false` if it stays in, or moves to, rented housing.

BTL investors always return `true`. Other households first pass affordability filters
(desired price against buying power, a target quality band they can afford, and the
buying power against the target band's price). They then compare the annual cost of owning
(mortgage payments at the bank's approved loan, less expected capital gains) with the
annual cost of renting (inflated by the psychological cost of renting), and buy with
logistic probability `1 / (1 + exp(-sensitivity_rent_buy * (cost_rent - cost_own)))`.

A random number is drawn only when the decision reaches the final logistic step.
Nothing is mutated.
"""
function decide_rent_or_buy(agent::Household, model::AgentBasedModel)
    params = model.params
    stats = model.market_stats
    bank = model.bank

    # The budget is computed up front because every return path needs it. The call is
    # idempotent and draws no random numbers; its p_max (buying power) is reused by the
    # affordability filters below.
    (p_d_income, p_fundamental, p_max_calculated) = apply_financial_constraints(agent, model)
    budget = p_d_income

    # BTL investors never rent. Carro et al. (2022), Section 3.3.1, after Eq. 4: households
    # with the BTL flag always decide to buy, so that investors do not rent or bid in the
    # rental market. Java's decideRentOrPurchase makes the same check as its first
    # statement; it must precede all affordability filters, otherwise investors who
    # cannot immediately afford a purchase would be pushed into renting.
    if agent.is_btl_investor
        return true
    end

    # Stubbornness check (as in Java's decideRentOrPurchase): if the household's fundamental
    # desired price, capped at the price of the top quality band, exceeds its buying power,
    # it chooses to rent rather than downgrade to what it can afford.
    max_market_price = isempty(stats.ema_prices_by_quality) ? stats.reference_price : stats.ema_prices_by_quality[end]
    p_max_check = p_max_calculated

    if min(p_fundamental, max_market_price) > p_max_check
        return false
    end

    # Target quality: the highest quality band whose average price the household can afford
    # (Java: HousingMarketStats.getMaxQualityForPrice). The scan runs from the top band down
    # because the smoothed band prices need not be monotonic in quality. No affordable band
    # (target_quality < 1) means the household rents.
    target_quality = -1
    for q in params.n_qualities:-1:1
        if stats.ema_prices_by_quality[q] <= budget
            target_quality = q
            break
        end
    end
    if target_quality < 1
        return false  # Cannot afford even the lowest quality house → forced to rent
    end

    # Retrieve Segment-Specific Anchors
    target_price = stats.ema_prices_by_quality[target_quality]
    target_rent = stats.ema_rents_by_quality[target_quality]
    
    # Fallback if EMAs are zero (start of sim)
    if target_price <= 1.0; target_price = stats.reference_prices_by_quality[target_quality]; end
    if target_rent <= 1.0; target_rent = stats.reference_rents_by_quality[target_quality]; end

    # Psychological cost of renting: renting is perceived as dearer than its listed rent.
    cost_renting_adjusted = target_rent * (1.0 + params.psychological_cost_renting)

    # The household compares costs at the desired price (budget), not at the band price.
    purchase_price = budget

    # Prime cap (Carro et al. 2022, Eq. 2): p'_d = min(p_d, p_Qmax). When the target is the
    # top band, the price is limited to that band's average price, to avoid unreasonable
    # mortgage costs in the comparison with renting (Java: purchasePrice is set to the
    # average price of the top quality band). Skipped while the band price is still zero.
    if target_quality == params.n_qualities
        prime_price = stats.ema_prices_by_quality[end]

        if prime_price > 0
            purchase_price = min(budget, prime_price)
        end
    end

    # Affordability: the target band's average price must not exceed the buying power.
    p_max = p_max_calculated
    if target_price > p_max
        return false
    end

    # Approved loan from the bank's credit evaluation (the equivalent of Java's
    # bank.requestApproval), which applies the LTV, LTI, DSTI and ICR limits.
    #
    # Java computes the desired down payment on the bank-capped price before the prime cap is
    # applied, so the deposit and the mortgage refer to different prices. The constant
    # Config.D5_DOWN_PAYMENT_COMPAT selects the price passed to calculate_down_payment:
    #   false: purchase_price (after the prime cap), so all cost inputs use the same price;
    #   true:  budget (before the prime cap), reproducing Java's sequence.
    # The two differ only when the target is the top band; for every other household
    # purchase_price equals budget. The loan limit and minimum down payment always use
    # purchase_price, and the down payment is clamped to purchase_price below.
    dp_price = Config.D5_DOWN_PAYMENT_COMPAT ? budget : purchase_price

    # Desired down payment
    max_loan_available = evaluate_credit(bank, agent, purchase_price, model)
    min_downpayment = purchase_price - max_loan_available

    # Agent may desire to put more down (from calculate_down_payment logic)
    desired_downpayment = calculate_down_payment(agent, dp_price, model, max_loan_available, false)
    
    # Determine actual down payment and principal
    actual_downpayment = max(min_downpayment, desired_downpayment)
    actual_downpayment = min(actual_downpayment, agent.bank_balance) # Can't exceed liquid wealth
    actual_downpayment = min(actual_downpayment, purchase_price)     # Can't exceed price
    
    approved_principal = purchase_price - actual_downpayment
    
    # Monthly payment on the approved principal (not the requested loan), over the age-adjusted
    # term as in Java's getMonthlyPaymentFactor: the lesser of the standard mortgage duration
    # and the months remaining until the bank's age limit. The age limit and standard duration
    # are read from the model so that country settings apply.
    monthly_mortgage = 0.0
    if approved_principal > 0
        age_adjusted_months  = floor(Int, (model.bank_age_limit - agent.age) * 12)
        term_months_decision = min(model.mortgage_duration_years * 12, age_adjusted_months)
        term_years_decision  = term_months_decision / 12.0
        monthly_mortgage = annuity_payment(approved_principal, bank.current_mortgage_rate, term_years_decision)
    end
    
    # Annual cost of owning: mortgage payments less expected capital gains, where the expected
    # growth rate is g = gamma * HPA + zeta (see calc_expected_growth). Java:
    # costOfHouse = monthlyPayment * 12 - purchasePrice * getLongTermHPAExpectation().
    expected_growth = calc_expected_growth(model)

    annual_mortgage_cost = monthly_mortgage * 12.0
    annual_capital_gain = purchase_price * expected_growth
    annual_cost_owning = annual_mortgage_cost - annual_capital_gain

    # Annual cost of renting, inflated by the psychological cost of renting.
    annual_rent_cost = target_rent * 12.0
    annual_cost_renting_adjusted = annual_rent_cost * (1.0 + params.psychological_cost_renting)

    # Tenure decision (Eq. 4): P(buy) = 1 / (1 + exp(-theta * delta)), with theta =
    # sensitivity_rent_buy and delta = adjusted annual cost of renting - annual cost of
    # owning. A positive delta (renting dearer) makes buying more likely.
    diff = annual_cost_renting_adjusted - annual_cost_owning
    prob_buy = 1.0 / (1.0 + exp(-params.sensitivity_rent_buy * diff))
    
    return rand(abmrng(model)) < prob_buy
end


"""
    evaluate_investment_entry(agent, model)

Decide whether a household that already owns property buys a new buy-to-let (BTL)
investment property (Eqs. 7 and 8 of Carro et al. 2022). Returns `true` if the household
should place an investment bid.

The checks run in this order:
1. Wealth gate: the bank balance must reach the desired wealth for the household's gross
   total income. Java's `HouseholdBehaviour` applies the same gate; the paper does not
   define it. `Config.D25C_DISABLE_BTL_WEALTH_GATE` bypasses it.
2. Forced first investment: with `Config.BTL_COMPAT_MODE`, a household owning fewer than two
   properties always attempts to buy, unless `spain_btl_hard_rules_off` is set.
3. Market floor: the buying power must cover the cheapest quality band.
4. Expected return V_buy on a purchase at maximum leverage (Eq. 7), a logistic entry
   probability (Eq. 8), and its conversion to a monthly probability.

One random number is drawn only if the decision reaches the last step. Nothing is mutated.
"""
function evaluate_investment_entry(agent::Household, model::AgentBasedModel)
    params = model.params
    stats = model.market_stats
    bank = model.bank

    # --- 1. Gate checks ---

    # A. Wealth gate. The paper defines no such gate (its only hard buying constraints are
    # the bank's LTV, LTI, DSTI and ICR limits), but Java's HouseholdBehaviour returns false
    # when the bank balance is below the desired bank balance for the household's gross total
    # income. The desired wealth uses gross total income (employment plus rental), as in
    # Java's getAnnualGrossTotalIncome().
    gross_total_income = get_annual_gross_total_income(agent, model)

    desired_wealth = calculate_wealth_from_rank(
        gross_total_income,
        agent.propensity_to_save, 
        model.wealth_dist
    )
    # Config.D25C_DISABLE_BTL_WEALTH_GATE = true bypasses the gate.
    if !Config.D25C_DISABLE_BTL_WEALTH_GATE && agent.bank_balance < desired_wealth
        return false
    end

    # B. Forced first investment. The paper models entry purely as a logistic function of
    # expected yield; Java's HouseholdBehaviour instead returns true for any investor owning
    # fewer than two properties (only their home), which seeds the BTL sector. It runs after
    # the wealth gate, so a cash-poor household is still blocked. It is active when
    # Config.BTL_COMPAT_MODE is true and is switched off by the model flag
    # `spain_btl_hard_rules_off` (the Spain variant of the Java model does not apply it).
    if Config.BTL_COMPAT_MODE && !model.spain_btl_hard_rules_off && length(agent.properties_owned) < 2
        return true
    end

    # --- 2. Maximum leverage ---

    # C. Maximum affordable price (p_max) under the bank's lending limits.
    p_max = calculate_buying_power(bank, agent, model)

    # D. Market floor: p_max must cover the cheapest quality band (quality 1).
    prices = isempty(stats.ema_prices_by_quality) ? stats.reference_prices_by_quality : stats.ema_prices_by_quality
    lowest_price = prices[1]
    
    if p_max < lowest_price
        return false
    end

    # --- 3. Expected return V_buy on a purchase at p_max ---

    # The hypothetical mortgage at p_max uses the same approval logic as transaction-time
    # underwriting, through the non-mutating evaluate_credit, so that leverage and equity
    # are consistent with the active lending limits. Equity is floored at 0.01 to avoid
    # division by zero.
    max_loan = evaluate_credit(bank, agent, p_max, model)
    max_loan = clamp(max_loan, 0.0, p_max)
    equity = max(0.01, p_max - max_loan)
    
    # Leverage (price / equity)
    leverage_factor = p_max / equity
    
    # Rental yield: the market-wide average
    yield_s = stats.ema_yield
    
    # Mortgage cost per unit of equity: the annual interest on the hypothetical loan at the
    # current mortgage rate (annualised) divided by equity. BTL mortgages are interest-only
    # (Carro et al. 2022, Section 3.4: "the only mortgage product that the bank offers to
    # BTL borrowers is a fixed-rate interest-only mortgage"), so the interest carry is the
    # whole payment. The `spain_btl_repayment_yield_formula` branch follows the Spain variant
    # of Java's decideToBuyInvestmentProperty, which uses the forward-looking interest carry
    # only (amortisation is equity recovery, not a cost); both branches currently evaluate
    # to the same expression.
    if model.spain_btl_repayment_yield_formula
        mortgage_cost_rel = (max_loan * bank.current_mortgage_rate) / equity
    else
        mortgage_cost_rel = (max_loan * bank.current_mortgage_rate) / equity
    end

    # Expected capital gain (calc_expected_growth)
    g = calc_expected_growth(model)
    delta = agent.btl_cap_gain_coeff 
    
    # Weighted return (Eq. 7)
    weighted_return = (delta * g) + ((1.0 - delta) * yield_s)
    
    # V_buy = leverage * (weighted return - alternative return) - mortgage cost per unit of
    # equity. `model.btl_alternative_return` is the alternative-asset benchmark return,
    # resolved at initialisation (see Initialization.jl).
    v_buy = (leverage_factor * (weighted_return - model.btl_alternative_return)) - mortgage_cost_rel
    
    # --- 4. Probability of entry (Eq. 8) ---
    xi = params.btl_xi 
    
    # Logistic: 1 / (1 + exp(-xi * V))
    prob_enter = 1.0 / (1.0 + exp(-xi * v_buy))
    
    # Monthly probability: P_monthly = 1 - (1 - P_annual)^(1/12)
    prob_enter_monthly = 1.0 - (1.0 - prob_enter)^(params.btl_annual_to_monthly)
    
    return rand(abmrng(model)) < prob_enter_monthly
end

"""
    calc_expected_growth(model)

Calculates the expected capital appreciation (growth rate) for housing assets.
This function implements Equation 2 from Carro et al. (2022).

# Logic
Expectations are formed via a backward-looking, extrapolative mechanism ("Animal Spirits"):
\$ g = \\gamma \\cdot HPA + \\zeta \$

Where:
- \$ g \$: The expected annualized growth rate.
- \$ HPA \$: Annualized House Price Appreciation (retrieved from `MarketStats.hpa_oracle`).
- \$ \\gamma \$ (`expectations_gamma`): Sensitivity to past price trends.
- \$ \\zeta \$ (`expectations_zeta`): Autonomous market sentiment.

# Returns
- `g::Float64`: The expected growth rate.
"""
function calc_expected_growth(model::AgentBasedModel)
    params = model.params
    stats = model.market_stats
    
    # Eq. 2: g = gamma * HPA + zeta, with the annualised HPA read from the market statistics.
    # Mirrors Java's HouseholdBehaviour.getLongTermHPAExpectation(), where
    # `expectations_gamma` is HPA_EXPECTATION_FACTOR and `expectations_zeta` is
    # HPA_EXPECTATION_CONST. The lookback period (HPA_YEARS_TO_CHECK) enters through
    # `hpa_oracle`, computed in `update_market_stats!` (MarketStats.jl).
    g = (params.expectations_gamma * stats.hpa_oracle) + params.expectations_zeta
    
    return g
end


"""
    evaluate_investor_exit(agent, house, model)

Decide whether a buy-to-let (BTL) investor sells the investment property `house`.
Returns `true` to sell.

The checks run in this order:
1. Near-maturity liquidity override: if the mortgage on this property has at most 24 months
   left and its outstanding principal exceeds the owner's bank balance, sell.
2. Portfolio floor: with `Config.BTL_COMPAT_MODE`, an owner of fewer than three properties
   (home plus at most one investment property) never sells, unless `spain_btl_hard_rules_off`
   is set. The paper has no such floor; Java's `HouseholdBehaviour` does.
3. Otherwise a random sale decision based on the effective yield V_sell (Eq. 10) and
   the monthly sale probability (Eq. 11) of Carro et al. (2022).

One random number is drawn only if the decision reaches the last step. Nothing is mutated.
"""
function evaluate_investor_exit(agent::Household, house::House, model::AgentBasedModel)

    # --- 0. Mortgage on this property ---
    # Located once and reused by the liquidity override and the yield calculation.
    mortgage = nothing
    for m in agent.mortgages_held
        if m.house_id == house.id
            mortgage = m
            break
        end
    end

    # --- 1. Near-maturity liquidity override ---
    # Applies to interest-only and repayment mortgages alike, and is checked before the
    # portfolio floor below. It is a heuristic of the Spain variant of the Java model: a
    # mortgage close to maturity that the owner could not repay from the bank balance
    # triggers a sale.
    if mortgage !== nothing
        if mortgage.term_months <= 24
            if mortgage.remaining_principal > agent.bank_balance
                return true
            end
        end
    end

    # --- 2. Portfolio floor ---
    # The paper defines the sale decision (Eqs. 10-11) as purely yield-based, with no floor
    # on portfolio size. Java's HouseholdBehaviour returns false for owners of fewer than
    # three properties ("investor households with only one investment property never sell
    # it"), so an investor keeps at least the home and one investment property.
    # The floor applies when Config.BTL_COMPAT_MODE is true, after the liquidity override,
    # and is switched off by the model flag `spain_btl_hard_rules_off` (the Spain variant
    # of the Java model does not apply it).
    if Config.BTL_COMPAT_MODE && !model.spain_btl_hard_rules_off && length(agent.properties_owned) < 3
        return false
    end

    # --- 3. Discretionary sale: effective yield and sale probability ---
    stats = model.market_stats
    params = model.params
    
    # A. Market price of the property's quality band (p_bar_Q). As in Java's
    # getExpAvSalePriceForQuality, this is the smoothed band price after the monthly
    # relaxation towards the HPI-scaled reference price (see update_market_stats!), not a
    # raw moving average of transaction prices.
    p_market = stats.ema_prices_by_quality[house.quality]
    
    # B. Outstanding debt on this property (the mortgage located in step 0).
    outstanding_debt = 0.0
    if mortgage !== nothing
        outstanding_debt = mortgage.remaining_principal
    end
    
    # C. Equity: market price less debt, floored at 0.01 so that the leverage and mortgage-cost
    # terms never divide by zero (Java: Math.max(0.01, currentMarketPrice - principal)).
    equity = max(0.01, p_market - outstanding_debt)
    
    # D. Annual mortgage cost. The standard form is the contractual monthly payment times 12.
    # With `spain_btl_repayment_yield_formula`, it is the outstanding principal times the
    # annual rate fixed at origination, as in the Spain variant of Java's
    # decideToSellInvestmentProperty (Java's `principal` is the outstanding balance).
    annual_mortgage_cost = 0.0
    if mortgage !== nothing
        if model.spain_btl_repayment_yield_formula
            annual_mortgage_cost = mortgage.remaining_principal * mortgage.origination_rate
        else
            annual_mortgage_cost = mortgage.monthly_payment * 12.0
        end
    end
    
    # E. Expectations: g is the expected capital growth (calc_expected_growth) and s the
    # expected rental yield, s = (current rent * expected occupancy) / p_Q.
    g = calc_expected_growth(model)
    
    # The property's current asking rent, or the quality band's average rent if none is set.
    r_current = house.rental_price > 0 ? house.rental_price : stats.ema_rents_by_quality[house.quality]
    
    # Average occupancy of houses of the same quality.
    avg_occupancy = stats.occupancy_rate_by_quality[house.quality]
    
    # The same market price is used for equity, leverage and the yield denominator, as in Java.
    if p_market > 0
        # Monthly rent is annualised by the factor 12.
        s = (r_current * 12.0 * avg_occupancy) / p_market
    else
        s = stats.ema_yield
    end

    # Effective yield (Eq. 10):
    # V_sell = (Price/Equity) * [delta * g + (1 - delta) * s] - (MortgageCost/Equity)
    
    leverage_factor = p_market / equity
    delta = agent.btl_cap_gain_coeff
    
    weighted_return = (delta * g) + ((1.0 - delta) * s)
    cost_drag = annual_mortgage_cost / equity
    
    # `model.btl_alternative_return` is the alternative-asset benchmark return, resolved at
    # initialisation (see Initialization.jl); it is subtracted from the weighted return.
    v_sell = (leverage_factor * (weighted_return - model.btl_alternative_return)) - cost_drag

    # Sale probability (Eq. 11): P_sell = 1 - sigmoid(xi * V_sell)^(1/12), where
    # `btl_annual_to_monthly` converts the annual probability of keeping the property to a
    # monthly one, because the check runs every month.
    xi = params.btl_xi
    
    sigmoid_val = 1.0 / (1.0 + exp(-xi * v_sell))
    
    # Monthly probability of keeping the property, and its complement, selling.
    p_keep_monthly = sigmoid_val^(params.btl_annual_to_monthly)
    
    p_sell = 1.0 - p_keep_monthly
    
    return rand(abmrng(model)) < p_sell
end

"""
    calculate_down_payment(agent, price, model, max_bank_loan, is_investment_purchase=nothing)

Desired and feasible down payment for a purchase, following the heterogeneous
down-payment mechanism of the Java model.

`is_investment_purchase` (optional) explicitly states transaction purpose:
- `true`: force the investment-purpose branch.
- `false`: force the owner-occupier branch (`FTB`/`HM` logic).
- `nothing` (default): infer purpose from agent state
    (`agent.is_btl_investor && agent.tenure_status == OwnerOccupier`).

When provided, explicit purpose takes precedence over borrower label; this avoids
routing investment purchases through the `HM` branch solely because `borrower_type`
is `HM`.

# Logic by Agent Type
1. **FTB (First-Time Buyer):**
    - "All-In Strategy". Wealth constrained.
    - \$d_{desired} = w\$ (Total Financial Wealth).
2. **HM (Home Mover):**
    - "Income-Linked Strategy".
    - \$d_{desired} = F^{-1}_{LogNormal}(pct) \\times HPI_t\$.
    - Distribution: LogNormal(\$\\mu=11.15\$, \$\\sigma=0.958\$).
3. **BTL (Buy-to-Let):**
    - "Leverage Strategy".
    - \$d_{desired} = fraction \\times Price\$.
    - Fraction ~ Normal(\$\\mu=0.34\$, \$\\sigma=0.15\$).

# Constraints
- **Bank Minimum (\$d_{min}\$):** \$Price \\times (1 - LTV_{max})\$.
- **Wallet Maximum (\$w\$):** Agent cannot pay more than they have.
- **Cash Buyer:** If \$w \\ge Price\$, pays 100% cash.

# Returns
- `Float64`: The final down-payment amount.
"""
function calculate_down_payment(agent::Household, price::Float64, model::AgentBasedModel, max_bank_loan::Float64, is_investment_purchase::Union{Nothing,Bool}=nothing)
    params = model.params
    bank = model.bank
    wealth = agent.bank_balance
    
    # --- 1. Cash buyer rule ---
    # A household whose financial wealth exceeds the price (scaled by
    # `downpayment_bank_balance_for_cash_sale`) pays in cash. This check overrides
    # any down-payment distribution.
    if wealth > price * params.downpayment_bank_balance_for_cash_sale
        return price # 100% Down Payment
    end

    # --- 2. Desired down payment ---

    d_desired = 0.0

    inferred_is_investment_purchase = agent.is_btl_investor && agent.tenure_status == OwnerOccupier
    use_investment_branch = is_investment_purchase === nothing ? inferred_is_investment_purchase : is_investment_purchase

    if use_investment_branch
        # Explicit purchase purpose takes precedence over borrower label.
        # This avoids routing HM-typed investors through the HM branch when
        # the transaction purpose is an investment purchase.
        if model.spain_btl_downpayment_distribution
            # Spain branch: LogNormal inverse-CDF at the household income percentile,
            # then scaled by HPI. The result is a monetary amount, not a fraction.
            # Deterministic quantile path: consumes no RNG draw.
            dist = LogNormal(model.btl_downpayment_scale, model.btl_downpayment_shape)
            base_val = quantile(dist, agent.income_percentile)
            current_hpi = model.market_stats.hpi
            d_desired = base_val * current_hpi
        else
            # UK branch: draw a down-payment fraction from a Normal distribution and
            # multiply by price. Consumes one RNG draw.
            dist = Normal(params.btl_downpayment_mu, params.btl_downpayment_sigma)
            fraction = rand(abmrng(model), dist)
            # `Config.D16_BTL_DP_NO_UPPER_CLAMP`:
            # - `true`: Java-style lower bound only (`max(0.0, fraction)`).
            # - `false`: clamp to [0, 1] (adds an upper bound).
            if Config.D16_BTL_DP_NO_UPPER_CLAMP
                fraction = max(0.0, fraction)
            else
                fraction = clamp(fraction, 0.0, 1.0)
            end
            d_desired = price * fraction
        end

    elseif agent.borrower_type == FTB
        # A. First-time buyer: all-in. The desired down payment is the full financial wealth.
        d_desired = wealth

    else
        # B. Home mover: income-linked distribution. The desired down payment is the
        # inverse CDF of a LogNormal at the household's income percentile.
        dist = LogNormal(params.hm_downpayment_mu, params.hm_downpayment_sigma)

        # Quantile function (inverse CDF) at the household's permanent income percentile.
        # No clamping, as in the Java model; the wealth cap below handles infinite values.
        base_val = quantile(dist, agent.income_percentile)

        # Scale by the current HPI (normalised to 1.0 at the start of the run).
        current_hpi = model.market_stats.hpi
        
        d_desired = base_val * current_hpi
    end

    # --- 3. Regulatory minimum ---
    # The minimum down payment is the gap between the price and the maximum loan the bank
    # authorises. `max_bank_loan` comes from `evaluate_credit` and reflects all binding
    # limits (LTV, LTI, DSTI), so whichever limit binds, the buyer must cover the difference.

    d_min = max(0.0, price - max_bank_loan)

    # --- 4. Apply constraints ---
    # Affordability is checked by the caller; if `d_min` exceeds wealth, the result is
    # capped at wealth.

    # The down payment is at least the bank minimum ...
    d_effective = max(d_desired, d_min)

    # ... and cannot exceed the household's wealth.
    d_final = min(d_effective, wealth)

    # --- 5. Cash buyer override ---
    if wealth > price * params.downpayment_bank_balance_for_cash_sale
        d_final = price
    end
    
    return d_final
end

"""
    calc_rental_budget(agent, model)

Maximum monthly rent a household bids when looking for a rental, `min(desired, r_max)`:
a non-linear behavioural desire capped by an income-based limit.

Mirrors the Java `HouseholdBehaviour.getDesiredRentPrice()`:
- Desire component: power law of gross employment income only, times log-normal noise.
- Constraint component: net total income (employment + rental - tax) minus essential
  consumption in the UK branch; gross employment income minus essential nominal
  consumption when `model.spain_gross_income_flow` is set.

Consumes one standard-normal RNG draw per call, in both branches.
"""
function calc_rental_budget(agent, model)
    # 1. Non-linear desire (behavioural component): mu * y^nu * noise.
    mu = model.params.rental_bid_scale
    nu = model.params.rental_bid_exponent
    gross_annual_employment = agent.annual_income

    # Rich agents spend a smaller share of income on rent but a higher absolute amount.

    # The log-normal noise multiplier mirrors the Java model's
    # `Math.exp(DESIRED_RENT_MU + DESIRED_RENT_SIGMA * prng.nextGaussian())`. The draw is
    # consumed even when mu = sigma = 0 (multiplier exactly 1.0), so that the RNG stream
    # matches the Java model's.
    noise_multiplier = exp(model.params.rental_bid_noise_mu + 
                          model.params.rental_bid_noise_sigma * randn(abmrng(model)))
    
    desired_rent_behavioral = mu * (gross_annual_employment ^ nu) * noise_multiplier

    # 2. Hard constraint (income-based component).
    #
    # `model.spain_gross_income_flow == true` switches the rent cap from UK net-of-tax
    # total income to gross employment income, mirroring the Spanish Java configuration's
    # `getDesiredRentPrice()`.
    #
    # Spain branch:
    #   r_max_raw = monthly_gross_employment - essential nominal consumption
    #   (no rental-income loop, no finance-cost loop and no `calculate_net_income` call).
    #
    # UK branch:
    #   r_max_raw = monthly_net_total - ESSENTIAL_CONSUMPTION_MONTHLY
    #   (net total income is rebuilt from gross wage + rental income - finance costs via
    #   `calculate_net_income`).
    #
    # The `noise_multiplier` above is evaluated unconditionally, so both branches consume
    # the same RNG draws.

    if model.spain_gross_income_flow
        # Spanish Java `getDesiredRentPrice()`. The essential-consumption value comes from
        # `effective_essential_nominal_consumption(model)`, which returns 0.0 unless
        # `model.spain_essential_nominal_consumption` is true (then 200.0).
        monthly_gross_employment = gross_annual_employment / 12.0
        essential_consumption = effective_essential_nominal_consumption(model)
        r_max_raw = monthly_gross_employment - essential_consumption
    else
        # UK branch: r_max = net monthly total income - essential consumption, where net
        # total income = (employment + rental income) - tax, as in the Java model.

        # 2a. Annual rental income from owned properties.
        annual_rental_income = 0.0
        if !isempty(agent.properties_owned)
            for prop_id in agent.properties_owned
                house = model.housing_stock[prop_id]
                # Only count rent if the property is occupied by someone else.
                if house.resident_id !== nothing && house.resident_id != agent.id
                    if Config.D11_RENTAL_CONTRACTED_RENT
                        # Use the contracted rent frozen at lease signing, as in the Java
                        # `Household.getMonthlyGrossRentalIncome()` (the rental agreement's
                        # next payment).
                        if Agents.hasid(model, house.resident_id)
                            tenant = model[house.resident_id]
                            if tenant.rental_agreement !== nothing && tenant.rental_agreement.house_id == prop_id
                                annual_rental_income += tenant.rental_agreement.monthly_rent * 12.0
                            end
                        end
                    else
                        # Use the landlord's current rent expectation held in model state
                        # (`house.rental_price`).
                        annual_rental_income += house.rental_price * 12.0
                    end
                end
            end
        end

        # 2b. Annual finance costs of rented BTL properties, used for tax relief
        # (Java `getAnnualFinanceCosts()`).
        annual_finance_costs = 0.0
        if !isempty(agent.mortgages_held)
            for mortgage in agent.mortgages_held
                house = model.housing_stock[mortgage.house_id]
                # Finance cost relief only applies to rented BTL properties: the household
                # owns the house and it is occupied by someone else. The Java check has two
                # further conditions (non-zero mortgage and tenant next payments), which are
                # not applied here.
                if house.owner_id == agent.id && house.resident_id !== nothing && house.resident_id != agent.id
                    annual_finance_costs += mortgage.monthly_payment * 12.0
                end
            end
        end

        # 2c. Net total income (rental income and tax relief included), as in Java
        # `getMonthlyNetTotalIncome()`.
        annual_net_total, _ = calculate_net_income(gross_annual_employment, annual_rental_income, annual_finance_costs)
        monthly_net_total = annual_net_total / 12.0

        essential_consumption = Config.ESSENTIAL_CONSUMPTION_MONTHLY

        # Essential consumption is subtracted from net total income. The Java model has no
        # `max(0, ...)` floor here, so r_max can be negative for a very poor household;
        # the optional floor is applied below (`Config.D17_RENTAL_BID_NO_FLOOR`).
        r_max_raw = monthly_net_total - essential_consumption
    end

    # Rental bid floor (both UK and Spain branches):
    # `Config.D17_RENTAL_BID_NO_FLOOR == false`: `max(0.0, r_max_raw)` prevents negative bids.
    # `Config.D17_RENTAL_BID_NO_FLOOR == true`: no floor, as in the Java model; a negative
    # r_max can propagate to the bid.
    if Config.D17_RENTAL_BID_NO_FLOOR
        r_max = r_max_raw
    else
        r_max = max(0.0, r_max_raw)
    end

    # 3. Final budget: min(desired_rent_behavioral, r_max)
    desired_rent = min(desired_rent_behavioral, r_max)

    return desired_rent
end


"""
    decision_owner_occupier_sell!(agent, model)

Exogenous moving decision of an owner-occupier (non-BTL household living in a home it
owns). With monthly probability `params.p_sale_monthly` the home is put on the market
(life events such as divorce or a job change are not modelled explicitly). Optional
Spanish-configuration vetoes can suppress the listing before the random draw.

Side effects: may list the home via `put_on_market!` and clear its rental listing.
The household stays an owner-occupier while the home is listed; the move to social
housing happens in `execute_transaction!` when the home is sold.
"""
function decision_owner_occupier_sell!(agent, model)
    # Only owner-occupiers move here (renters are handled by the rental logic) and BTL
    # investors are excluded (they use the yield-based logic in `decision_btl_sell!`).

    # Monthly probability of the exogenous moving event.
    moving_prob = model.params.p_sale_monthly

    # Exogenous moving (life events).
    if agent.residence_id !== nothing && !agent.is_btl_investor
        home = model.housing_stock[agent.residence_id]
        if home.owner_id == agent.id && !home.is_for_sale

            # Sell-home vetoes, applied before the exogenous-moving draw. They mirror two
            # checks of the Spanish Java `HouseholdBehaviour` that the UK configuration does
            # not have; both flags default to `false`.
            #
            # Affordability veto (`spain_sell_home_veto_affordability`), age > 35:
            #   a homeowner whose desired purchase price exceeds the maximum price the bank
            #   would finance does not list the current home.
            if model.spain_sell_home_veto_affordability && agent.age > 35.0
                p_max = calculate_buying_power(model.bank, agent, model)
                if agent.desired_purchase_price > p_max
                    return  # affordability veto — don't list
                end
            end

            # Upgrade-quality veto (`spain_sell_home_veto_upgrade`), age > 45:
            #   a homeowner whose net wealth (bank balance + expected sale price of the
            #   home - outstanding principal) would not buy a higher-quality house does
            #   not list the current home.
            # `getMaxQualityForPrice` is inlined as a top-down scan of the quality ladder.
            if model.spain_sell_home_veto_upgrade && agent.age > 45.0
                stats        = model.market_stats
                quality_price = stats.ema_prices_by_quality[home.quality]
                sale_price   = quality_price > 0.0 ? quality_price : stats.reference_prices_by_quality[home.quality]
                m_idx        = findfirst(m -> m.house_id == home.id, agent.mortgages_held)
                principal    = m_idx === nothing ? 0.0 : agent.mortgages_held[m_idx].remaining_principal
                net_wealth   = agent.bank_balance + sale_price - principal
                # Inline getMaxQualityForPrice: highest quality whose EMA price <= net_wealth.
                max_q_for_nw = 0
                for q in length(stats.ema_prices_by_quality):-1:1
                    q_price = stats.ema_prices_by_quality[q]
                    effective_price = q_price > 0.0 ? q_price : stats.reference_prices_by_quality[q]
                    if effective_price <= net_wealth
                        max_q_for_nw = q
                        break
                    end
                end
                if max_q_for_nw <= home.quality
                    return  # upgrade-quality veto — don't list
                end
            end

            # Draw for the exogenous move.
            if rand(abmrng(model)) < moving_prob
                put_on_market!(home, model)

                # The household is not evicted here: it remains an owner-occupier while the
                # home is listed and keeps paying its mortgage. The move to social housing
                # happens in `execute_transaction!` when the sale completes.

                # Sale only: make sure the home is not also listed for rent.
                if home.is_for_rent
                    home.is_for_rent = false 
                    delete!(model.market_stats.active_rental_listings, home.id)
                end
            end
        end
    end
end

"""
    decision_btl_sell!(agent, model)

Evaluate sale listings for the investment properties of a BTL investor. For each owned
property that is not the household's residence and is not already for sale:
1. Near-maturity liquidity override: remaining mortgage term <= 24 months and
   outstanding principal exceeds the household's cash. The property is listed for sale.
2. Ordinary discretionary exit: for a vacant property listed for rent, the
   holding-return signal from `evaluate_investor_exit` decides.

The override bypasses the vacancy, rental-listing and yield conditions. It comes from the
Spanish Java model, applies to both interest-only and repayment mortgages, and compares
cash with outstanding debt only.

Side effects: lists properties for sale via `put_on_market!`; vacant properties are also
kept (or put) on the rental market, updating `active_rental_listings` and
`vacant_rentals_by_quality`.
"""
function decision_btl_sell!(agent, model)
    if !agent.is_btl_investor; return; end
    
    # Iterate over the investment properties (`properties_owned`).
    # OPTIMIZATION: Use `properties_owned` vector (O(1) Access) instead of scanning Stock (O(N)).
    for house_id in agent.properties_owned
        # Skip if this is their residence
        if house_id == agent.residence_id
            continue
        end

        house = model.housing_stock[house_id]

        # Skip if already for sale
        if house.is_for_sale
            continue
        end

        # --- A. Near-maturity liquidity override ---
        # Spanish Java heuristic, applied to both repayment modes: remaining term
        # <= 24 months and outstanding principal exceeds cash.
        is_forced_sale = false

        # Find the mortgage for this investment property.
        m_idx = findfirst(m -> m.house_id == house_id, agent.mortgages_held)
        if m_idx !== nothing
            m = agent.mortgages_held[m_idx]
            if m.term_months <= 24
                if agent.bank_balance < m.remaining_principal
                    is_forced_sale = true
                end
            end
        end

        # --- B. Decision ---
        # Ordinary yield-based selling requires the property to be vacant and listed for
        # rent. The near-maturity override bypasses this condition and the yield decision.

        if (house.resident_id === nothing && house.is_for_rent) || is_forced_sale
            should_sell = false
            
            if is_forced_sale
                should_sell = true
            else
                # Vacant and listed for rent: apply the yield-based exit rule
                # (`evaluate_investor_exit`).
                should_sell = evaluate_investor_exit(agent, house, model)
            end
            
            if should_sell
                put_on_market!(house, model)
                
                # Dual listing: a vacant property is also kept on the rental market while it
                # is for sale. An occupied property (possible under the near-maturity
                # override) is listed for sale only, as in the Java model; the vacancy
                # check keeps `vacant_rentals_by_quality` consistent.
                if !house.is_for_rent && house.resident_id === nothing
                        house.is_for_rent = true
                        push!(model.market_stats.active_rental_listings, house.id)
                        model.market_stats.vacant_rentals_by_quality[house.quality] += 1
                end
            elseif !house.is_for_rent && house.resident_id === nothing
                 # Not selling and vacant: make sure the property is on the rental market
                 # (it may have just been vacated).
                 house.is_for_rent = true
                 push!(model.market_stats.active_rental_listings, house.id)
                 model.market_stats.vacant_rentals_by_quality[house.quality] += 1
            end
        end
    end
end


"""
    submit_market_bids!(model)

Housing decision phase: every household decides whether to buy, rent or do nothing, and
the resulting sales bids and rental bids are pushed onto `market_stats.bids_queue` and
`market_stats.rental_bids_queue`. Run after the financial-flows phase so that decisions
use current-step wealth. The function then applies the independent seller logic
(`decision_owner_occupier_sell!`, `decision_btl_sell!`) for each household.

Mutates: the bid queues, the households' `persistent_ltv_limit` / `persistent_lti_limit`,
the bank's soft-LTI counters (via `register_approval_in_principle!`), and market listings.
Consumes RNG draws in households' decision functions.
"""
function submit_market_bids!(model)
    # Households are processed in ascending ID order, which equals insertion order
    # (`add_agent!` assigns increasing IDs) and so mirrors the Java model, whose
    # household list is iterated in insertion order (older households first, newborns last).
    # `allids(model)` alone would return hash-table order, unrelated to age.
    #
    # Order matters because the soft LTI quota (`check_soft_limit_capacity` /
    # `register_approval_in_principle!`) is a sequential within-step accumulator: households
    # processed early use up quota slots and later ones may face the restricted limit
    # instead of the hard maximum. A fixed insertion order therefore fixes which borrower
    # types see a full quota, as in the Java model.
    sorted_ids = sort!(collect(allids(model)))
    for id in sorted_ids
        agent = model[id]
        
        # Each household makes one decision per step: buy or rent. A buyer submits a
        # sales bid; a household that prefers to rent submits a rental bid. Never both.
        
        # 1. Determine intent
        is_buyer = false
        is_btl = false
        
        # Case A: households in social housing, or renters whose lease has expired, decide
        # between buying (first-time buyers and movers) and renting.
        is_lease_expired = (agent.rental_agreement === nothing) || (agent.rental_agreement.months_remaining == 0)
        
        eligible_for_housing = (agent.tenure_status == SocialHousing || (agent.tenure_status == Renter && is_lease_expired))
        
        if eligible_for_housing
            # Bid-time freeze of the LTV and LTI limits, set in the same order as the Spanish
            # Java model (LTV first, then LTI). Both are used later in `calculate_buying_power`
            # and in `evaluate_credit` at clearing. When the Spanish-configuration flags are
            # off, both limit functions return the UK values without advancing the RNG.
            is_ftb_agent_oo = (agent.borrower_type == FTB)
            agent.persistent_ltv_limit = get_loan_to_value_limit(model, agent, is_ftb_agent_oo, true)
            agent.persistent_lti_limit = get_loan_to_income_limit(model, is_ftb_agent_oo, true, agent.annual_income)

            # Single stochastic call: buy or rent.
            if decide_rent_or_buy(agent, model)
                is_buyer = true
                is_btl = false
            else
                # Rent instead.
                budget = calc_rental_budget(agent, model)
                if isfinite(budget) && budget > 0.0
                    bid = RentalBid(agent.id, 0, budget)
                    push!(model.market_stats.rental_bids_queue, bid)
                end
            end
        
        # Case B: BTL investors who own their residence decide whether to buy another property.
        elseif agent.is_btl_investor && agent.tenure_status == OwnerOccupier
            # Bid-time LTV and LTI limit freeze for the BTL path, as in the Spanish Java
            # model. It happens before `evaluate_investment_entry`, even if that returns
            # false. With the Spanish-configuration flags off, both functions return the UK
            # values without advancing the RNG.
            agent.persistent_ltv_limit = get_loan_to_value_limit(model, agent, false, false)
            agent.persistent_lti_limit = get_loan_to_income_limit(model, false, false, agent.annual_income)
            if evaluate_investment_entry(agent, model)
                is_buyer = true
                is_btl = true
            end
        end
        
        # 2. Buying action
        if is_buyer
            (p_bid_behavioral, _, p_max) = apply_financial_constraints(agent, model)
            
            budget = 0.0
            if is_btl
                budget = p_max
            else
                budget = p_bid_behavioral
            end

            # Do not enqueue malformed or insolvent bids.
            if agent.bank_balance < 0.0 || !isfinite(budget) || budget <= 0.0
                continue
            end
            
            # Approval-in-principle counters. `register_approval_in_principle!` checks the
            # intended LTV and LTI internally and increments the soft-limit counters for
            # all three segments (FTB, HM, BTL), following the Spanish Java model. With the
            # Spanish-configuration flags off, FTB/HM behave as in the UK model (intended-LTI
            # check `budget > bank_balance + income * soft_lti`) and the BTL call writes nothing.
            if is_btl
                register_approval_in_principle!(model, agent.bank_balance, budget,
                                                agent.annual_income, false, false)
            else
                is_ftb_agent = agent.borrower_type == FTB
                register_approval_in_principle!(model, agent.bank_balance, budget,
                                                agent.annual_income, is_ftb_agent, true)
            end
            
            # Bid-time down payment (`Config.D19_MODE`).
            #
            # In the Java model the desired down payment is computed at bid time for every
            # bidder and stored in the bid record (so the BTL Normal draw is consumed by
            # winners and losers alike); it is passed to the purchase at clearing. The
            # alternative is to compute it at clearing time, for winning bidders only,
            # inside `execute_transaction!`.
            #
            # `D19_MODE` selects between these:
            #   :OFF   -> `bid_dp = NaN` for all bidders; the down payment is computed at
            #             clearing time.
            #   :ON    -> `bid_dp` computed at bid time for all bidders (Java behaviour).
            #   :PAPER -> `bid_dp` computed at bid time for owner-occupier and first-time
            #             buyers only; BTL bidders keep NaN and compute it at clearing time,
            #             after the bid has succeeded. This is the default mode.
            #
            # Even when `bid_dp` is computed here, the maximum loan is recomputed at
            # clearing against the sale price (not the budget), because the bank's LTV check
            # uses the sale price. The stored value is the household's desired down payment;
            # the bank's constraints are reapplied at clearing.
            bid_dp = NaN
            compute_bid_dp =
                Config.D19_MODE === :ON ||
                (Config.D19_MODE === :PAPER && !is_btl)
            if compute_bid_dp
                max_loan_at_bid = evaluate_credit(model.bank, agent, budget, model)
                bid_dp = calculate_down_payment(agent, budget, model, max_loan_at_bid, is_btl)
                if !isfinite(bid_dp) || bid_dp < 0.0
                    continue
                end
            end

            bid = Bid(agent.id, 0, budget, bid_dp, p_max)
            push!(model.market_stats.bids_queue, bid)
        end

        # 3. Independent Seller Logic
        decision_owner_occupier_sell!(agent, model)
        decision_btl_sell!(agent, model)
    end
end



