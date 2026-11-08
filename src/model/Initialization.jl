# src/model/Initialization.jl
#
# Model factory. `initialize_model` is the single entry point that builds a ready-to-run
# Agents.jl model: it resolves every parameter (Config defaults, country-specific
# defaults selected by the Spain mechanism switches, profiles and explicit keyword
# overrides), constructs the parameter object, the central bank, the private bank and
# the market statistics, and then populates the model with the initial households,
# houses and mortgages drawn from the empirical distributions.

# ─── Consistency check between the Spain switches and Config (load time) ─────
# The Spain mechanism switches declared in `initialize_model()` (listed in
# `_INIT_SPAIN_KWARGS` below) must match `Config.SPAIN_MECHANISMS` exactly. If the
# two lists differ, the package fails to load.
const _INIT_SPAIN_KWARGS = (
    :spain_gross_income_flow,
    :spain_pdf_precision,
    # Central bank and bank soft-limit bookkeeping switches (one per lever).
    :spain_soft_ltv_ftb,
    :spain_soft_ltv_hm,
    :spain_soft_ltv_btl,
    :spain_soft_lti_btl,
    :spain_application_income_gate,
    :spain_application_age_ltv_gate,
    # Bank prudential switch: minimum borrower age floor.
    :spain_bank_min_age,
    # Buy-to-let yield formula switch.
    :spain_btl_repayment_yield_formula,
    # Household consumption ledger (five counters on MarketStats).
    :spain_consumption_recording,
    # Buy-to-let mortgages follow the owner-occupier underwriting and annuity repayment.
    :spain_btl_repayment_mode,
    # Household-side essential nominal consumption.
    :spain_essential_nominal_consumption,
    # Bank DSTI hard-maximum ceiling (independent of the household-side switch above).
    :spain_dynamic_affordability_ceiling,
    # Buy-to-let alternative-asset benchmark return.
    :spain_btl_alternative_return,
    # Bank maximum age and mortgage duration (switched together).
    :spain_bank_age_limits,
    # Buy-to-let down payment drawn from a log-normal amount distribution.
    :spain_btl_downpayment_distribution,
    # Price expectations regime: expectations gamma, expectations zeta and the look-back
    # length (HPA_YEARS_TO_CHECK in the Java model) change together.
    :spain_expectations_naive,
    # Bank prudential calibration values (hard caps, policy rate, credit supply, etc.).
    :spain_bank_calibration_values,
    # Distribution calibration values (price and rent distributions, down payments,
    # budget and rental-bid coefficients, tenancy maximum, windfall cap, holding period).
    :spain_distribution_calibration,
    # Population scalars (household count for reporting, houses per household).
    :spain_population_scalars,
    # Behavioural scalars: rent-or-buy logit, buy-to-let probability multiplier and
    # market average price decay (`mix_adjustment_weight`; Java `MARKET_AVERAGE_PRICE_DECAY`).
    :spain_rent_buy_logit,
    :spain_btl_probability_multiplier,
    :spain_market_avg_price_decay,
    # Empirical-distribution dataset switches: each selects the Spain CSV instead of the UK
    # CSV for one distribution (the path is resolved in `_init_from_files`).
    :spain_demographics_dataset,
    :spain_income_age_joint_dataset,
    :spain_income_wealth_joint_dataset,
    :spain_btl_dataset,
    # Sell-home lifecycle vetoes and the switch that disables the buy-to-let hard rules
    # governed by `Config.BTL_COMPAT_MODE`.
    :spain_sell_home_veto_affordability,
    :spain_sell_home_veto_upgrade,
    :spain_btl_hard_rules_off,
    # Wealth aggregate collectors.
    :spain_record_wealth_aggregates,
    # Buy-to-let flat 25-year term with a strict age cut-off, independent of
    # `:spain_btl_repayment_mode`.
    :spain_btl_paper_maturity,
)
@assert Set(_INIT_SPAIN_KWARGS) == Set(Config.SPAIN_MECHANISMS) """
sync with `Config.SPAIN_MECHANISMS`. Every Spain mechanism kwarg in
`initialize_model()` must appear in BOTH lists. Fix the mismatch in either
src/core/Config.jl or src/model/Initialization.jl before the package can load.
"""

# Return `default` when `value` is `nothing`. Explicitly supplied values, including
# values equal to the UK default, are retained.
resolve_parameter(value, default) = value === nothing ? default : value

# As `resolve_parameter`, with the default chosen by country: `spain_default` when
# `use_spain` is true, `uk_default` otherwise.
resolve_country_parameter(value, use_spain, uk_default, spain_default) =
    resolve_parameter(value, use_spain ? spain_default : uk_default)


"""
    initialize_model(; kwargs...)

Build an Agents.jl model pre-filled with households, houses, mortgages, banks and
market structures, and return it.

Keyword arguments fall into these groups:

- Experiment controls: `n_households`, `n_houses`, `n_qualities`, `n_steps`, `seed`.
  An omitted `n_houses` uses the floored target population times the resolved
  houses-per-household ratio; an omitted `n_qualities` uses the resolved population,
  ratio and monthly sale probability before stock rounding.
- Market and behavioural parameters (for example `bid_up_factor`, `days_under_offer`,
  `pd_alpha`, `expectations_gamma`). Arguments left as `nothing` take the Config default,
  or the Spain default when the matching `spain_*` switch is `true`. An explicitly
  supplied value always takes precedence, even when it equals the UK default.
- Bank and regulatory limits (`bank_*`, `limit_*`, `soft_lti_*`, `central_bank_*`,
  `pre_*`), optionally overlaid by `bank_underwriting_profile` and `central_bank_profile`.
- `spain_*` switches that select country-specific mechanisms, calibration values and
  datasets. Their names must match `Config.SPAIN_MECHANISMS`.

The model is built in this order: parameter resolution, `ModelParameters`, the banks and
other institutions, the market statistics, then the initial households, houses and mortgages.
"""
function initialize_model(; 


    # -------------------------------------------------------
    # 0. Parameters (defaults from Config.jl)
    # -------------------------------------------------------


    # --- Experiment controls ---
    n_households = Config.N_HOUSEHOLDS,
    n_houses = nothing,
    n_steps = Config.N_STEPS,
    n_qualities = nothing,
    
    # Behavioural parameters
    pd_alpha = nothing,
    pd_beta = nothing,
    pd_epsilon_mu = nothing,
    pd_epsilon_sigma = nothing,
    psychological_cost_renting::Union{Nothing,Float64} = nothing,
    sensitivity_rent_buy::Union{Nothing,Float64} = nothing,
    expectations_gamma = nothing,
    expectations_zeta = nothing,

    # --- Market parameters (defaults from Config.jl) ---
    bid_up_factor = Config.BID_UP_FACTOR,
    days_under_offer = Config.DAYS_UNDER_OFFER,
    sale_price_reduction_prob = Config.SALE_PRICE_REDUCTION_PROB,
    rent_price_reduction_prob = Config.RENT_PRICE_REDUCTION_PROB,
    market_smoothing = Config.MARKET_SMOOTHING_FACTOR,
    mix_adjustment_weight::Union{Nothing,Float64} = nothing, # Eq 21: Rho (ρ)
    holding_period_years = nothing,

    # --- Further parameters (defaults from Config.jl) ---
    rental_bid_scale = nothing,
    rental_bid_exponent = nothing,
    rental_bid_noise_mu = Config.RENTAL_BID_NOISE_MU,
    rental_bid_noise_sigma = Config.RENTAL_BID_NOISE_SIGMA,
    essential_consumption_fraction = Config.ESSENTIAL_CONSUMPTION_FRACTION,
    minimum_govt_support = Config.MINIMUM_GOVT_SUPPORT,
    p_sale_monthly = nothing,
    sale_price_reduction_mean = Config.SALE_PRICE_REDUCTION_MEAN,
    sale_price_reduction_std = Config.SALE_PRICE_REDUCTION_STD,
    rent_reduction_mean = Config.RENT_REDUCTION_MEAN,
    rent_reduction_std = Config.RENT_REDUCTION_STD,
    tenancy_length_min = Config.TENANCY_LENGTH_MIN,
    tenancy_length_max = nothing,
    hm_downpayment_mu = nothing,
    hm_downpayment_sigma = nothing,
    btl_downpayment_mu = nothing,
    btl_downpayment_sigma = nothing,
    downpayment_bank_balance_for_cash_sale = Config.DOWNPAYMENT_BANK_BALANCE_FOR_CASH_SALE,
    btl_xi::Union{Nothing,Float64} = nothing,
    btl_annual_to_monthly = Config.BTL_ANNUAL_TO_MONTHLY,
    btl_probability_adjustment::Union{Nothing,Float64} = nothing,
    interest_rate_elasticity_phi = nothing,

    # Bank and central bank initial values; the defaults are chosen by
    # `spain_bank_calibration_values` (see the resolvers below).
    central_bank_policy_rate       = nothing,
    initial_interest_rate_spread   = nothing,
    initial_credit_supply_per_hh   = nothing,

    # Distribution and consumption scalars; the defaults are chosen by
    # `spain_distribution_calibration`. They are used for:
    #   • price_dist_mu / price_dist_sigma: the house price log-normal distribution and
    #     the global mean price fallback in the market statistics
    #   • rent_dist_mu / rent_dist_sigma: the rent log-normal distribution and the global
    #     mean rent fallback
    #   • initial_rental_yield: the initial values of the market statistics yield averages
    #   • windfall_cap_share: the windfall consumption cap, read from the model parameters
    #     in the financial flows
    # The per-quality seed in `src/markets/MarketStats.jl` that falls back to
    # `Config.INITIAL_RENTAL_YIELD` when a quality band has no price data is not affected.
    price_dist_mu              = nothing,
    price_dist_sigma           = nothing,
    rent_dist_mu               = nothing,
    rent_dist_sigma            = nothing,
    initial_rental_yield       = nothing,
    windfall_cap_share         = nothing,

    # Population scalars; the defaults are chosen by `spain_population_scalars`.
    #   • uk_households: national household count used by DataCollection.jl to scale
    #     reported sales, approvals and lending flows
    #   • houses_per_household: target stock ratio used by Construction.jl
    # For Spain, `houses_per_household` is the Spain dwellings value divided by the Spain
    # households value, the same algebra as the Java `derivedParams.UK_HOUSES_PER_HOUSEHOLD`.
    uk_households              = nothing,
    houses_per_household       = nothing,

    # -------------------------------------------------------

    # Bank defaults from Config.jl
    # The FTB limits serve as the baseline values.
    ltv_max = Config.LTV_MAX_FTB,
    dti_max = Config.LTI_MAX_FTB,
    lti_max_ftb = Config.LTI_MAX_FTB,

    # Regulatory limit overrides
    limit_ltv_ftb = nothing,
    limit_ltv_hm = nothing,
    limit_ltv_btl = nothing,
    limit_dsti = nothing,
    limit_dsti_ftb = nothing,
    limit_dsti_hm_btl = nothing,
    limit_icr = nothing,

    # Optional pre-activation regulatory state, used only when
    # central_bank_policy_application_time is an integer.
    pre_limit_ltv_ftb = nothing,
    pre_limit_ltv_hm = nothing,
    pre_limit_ltv_btl = nothing,
    pre_limit_dsti = nothing,
    pre_limit_dsti_ftb = nothing,
    pre_limit_dsti_hm_btl = nothing,
    pre_soft_lti_limit_ftb = nothing,
    pre_soft_lti_limit_hm = nothing,

    # Bank-internal DSTI appetite
    bank_dsti_max = nothing,
    bank_dsti_max_ftb = nothing,
    bank_dsti_max_hm_btl = nothing,

    # Bank-internal hard limits. They can be lifted so that the model runs with neither
    # regulatory nor bank-internal limits. Defaults follow the bank-side hard caps in Config.jl.
    bank_ltv_max_ftb = nothing,
    bank_ltv_max_hm  = nothing,
    bank_ltv_max_btl = nothing,
    bank_lti_max_ftb = nothing,
    bank_lti_max_hm  = nothing,
    # Buy-to-let hard LTI; the UK default of 99.0 never binds.
    bank_lti_max_btl = nothing,
    bank_icr_min     = nothing,

    # Profiles are partial overlays of the fields assigned in each block.
    # They do not disable independent soft-limit mechanisms or exemptions.
    # The `no_policy` profile name does not imply every regulatory restriction is off.
    
    # Two-layer calibration profiles: one for bank underwriting, one for the central bank.
    # An empty string leaves the resolved values unchanged.
    bank_underwriting_profile::String = "",
    central_bank_profile::String = "",
    
    # Regulatory soft-LTI (per borrower type)
    soft_lti_active       = nothing,
    soft_lti_limit_ftb    = nothing,
    soft_lti_limit_hm     = nothing,
    flow_limit_ftb        = nothing,
    flow_limit_hm         = nothing,
    use_pooled_lti_quota  = Config.USE_POOLED_LTI_QUOTA,

    # Switch for the realised-disposable-income variant of the financial flows (per model
    # instance). Environment variable: D22_USE_REALIZED_DISPOSABLE_INCOME.
    # The alias D22_PHASE2A_DISPOSABLE_CACHE is also accepted.
    d22_use_realized_disposable_income = haskey(ENV, "D22_USE_REALIZED_DISPOSABLE_INCOME") ?
        (ENV["D22_USE_REALIZED_DISPOSABLE_INCOME"] == "true") :
        (get(ENV, "D22_PHASE2A_DISPOSABLE_CACHE", "true") == "true"),

    # ─── Spain mechanism switches ────────────────────────────────────────────
    # The switches default to `false`, which keeps the UK behaviour. The load-time `@assert`
    # above checks that these keyword names match Config.SPAIN_MECHANISMS.
    #   spain_gross_income_flow → src/model/FinancialFlows.jl
    #   spain_pdf_precision     → src/model/EmpiricalLoader.jl: raises the Pdf sample
    #                             resolution (100 to 100k) and the integration steps
    #                             (2048 to 262144), and applies the Java getStart/getEnd
    #                             zero-bin trim used by the Spain Pdf class.
    spain_gross_income_flow::Bool = false,
    spain_pdf_precision::Bool     = false,

    # Central bank and bank soft-limit bookkeeping switches, one per lever. With `false`
    # the UK behaviour is unchanged.
    spain_soft_ltv_ftb::Bool             = false,
    spain_soft_ltv_hm::Bool              = false,
    spain_soft_ltv_btl::Bool             = false,
    spain_soft_lti_btl::Bool             = false,  # the UK IS_SOFT_LIMIT_ACTIVE setting is retained for FTB and HM LTI
    spain_application_income_gate::Bool  = false,
    spain_application_age_ltv_gate::Bool = false,
    # Applies the Spain BANK_MIN_AGE_LIMIT floor in getNPayments. The UK default value of
    # the limit is 0, so enabling the switch alone has no effect until the limit is raised.
    spain_bank_min_age::Bool             = false,
    # Buy-to-let yield formula: the expected-equity-yield mortgage-cost term becomes
    # `principal * annual_rate / equity` (interest carry) instead of `nextPayment * 12 / equity`.
    # For interest-only mortgages the two are algebraically equivalent.
    spain_btl_repayment_yield_formula::Bool = false,

    # When `true`, activates the five per-step consumption-component counters on
    # `MarketStats` (rental, interest, principal repayment, down payment, non-housing).
    # This is a collector-side ledger with no behavioural feedback. Java parity:
    # `HouseholdStats.java` (five adders) and the write sites in `Household.java::step`
    # and `completeHousePurchase`. The income-percentile cache (Java `addIncome`) is
    # independent and is controlled by `:spain_application_income_gate`.
    spain_consumption_recording::Bool = false,

    # When `true`, buy-to-let borrowers are routed through the owner-occupier branch in
    # Bank.evaluate_credit and calculate_buying_power (LTV, LTI and DSTI underwriting; no
    # ICR), the buy-to-let monthly payment uses the annuity formula instead of
    # interest-only, and the buy-to-let term follows the owner-occupier age ladder
    # (shortened past 40, zero past 65). Intended to be combined with
    # `:spain_btl_repayment_yield_formula`.
    spain_btl_repayment_mode::Bool = false,

    # When `true`, five consumer sites switch from the UK semantics (0.0 or
    # MINIMUM_GOVT_SUPPORT*12) to the Spain semantics (essential nominal consumption 200.0;
    # income floor 2400 per year). Sites: Household.java disposable-income floor (via
    # helper in FinancialFlows.jl); HouseholdBehaviour.java rental-bid cap (via helper);
    # the non-housing consumption addend (via `:spain_consumption_recording`); the Bank.java
    # DSTI hard-maximum ceiling (two sub-sites in Bank.jl); and the EmploymentIncome.java
    # income floor at draw time (EmpiricalLoader.jl, passed as a keyword argument).
    spain_essential_nominal_consumption::Bool = false,

    # When `true`, the Bank.java DSTI hard-maximum fold applies at two sub-sites in Bank.jl
    # (`evaluate_credit` and `calculate_buying_power`), folding `1.0 - ENC / gross_monthly`
    # into `effective_dsti_limit` via `min(...)`. This is separate from
    # `:spain_essential_nominal_consumption` so that the household-side and bank-side effects
    # can be switched independently; with both on, the combined behaviour is the same as a
    # single joint switch.
    spain_dynamic_affordability_ceiling::Bool = false,

    # When `true`, the default of `btl_alternative_return` changes from the UK 0.0 to the
    # Spain 0.040755. An explicit `btl_alternative_return` always wins. The value is read
    # as `model.btl_alternative_return` in the buy and sell value decisions in
    # HouseholdBehavior.jl.
    spain_btl_alternative_return::Bool = false,
    btl_alternative_return = nothing,

    # When `true`, `bank_age_limit` defaults to 61.0 (UK 65.0) and `mortgage_duration_years`
    # to 30 (UK 25). Explicit keyword arguments always win. Read in:
    #   • Bank.jl::evaluate_credit and calculate_buying_power (maximum entry age and term)
    #   • HousingMarket.jl::execute_transaction! (bank age limit and maximum term in months)
    #   • HouseholdBehavior.jl::decide_rent_or_buy (BANK_AGE_LIMIT and MORTGAGE_DURATION_YEARS)

    # ─── Further switches and constants ─────────────────────────────────────────
    # Defaults are UK-equivalent; the matching Config.jl constants are documented there.
    interest_only_mortgages_for_btl = Config.INTEREST_ONLY_MORTGAGES_FOR_BTL,

    # ─── Bank age envelope ──────────────────────────────────────────────────────
    # Maximum age, minimum age and mortgage duration. They are resolved below: maximum age
    # and duration by `:spain_bank_age_limits`, minimum age by `:spain_bank_min_age`.
    spain_bank_age_limits      = false,
    bank_age_limit             = nothing,
    mortgage_duration_years    = nothing,
    bank_min_age_limit         = nothing,

    # When `true`, the defaults of `btl_downpayment_scale` and `btl_downpayment_shape`
    # change from the UK NaN sentinels to the Spain values 10.2693 and 1.0061. Explicit
    # keyword arguments always win. The buy-to-let branch of
    # HouseholdBehavior.jl::calculate_down_payment reads `model.btl_downpayment_scale`,
    # `model.btl_downpayment_shape` and `agent.income_percentile` and applies the inverse CDF
    # (deterministic, no random draw). With `false` the UK path (normal fraction times price)
    # is used.
    spain_btl_downpayment_distribution = false,
    btl_downpayment_scale              = Config.BTL_DOWNPAYMENT_SCALE,  # NaN sentinel (UK path never reads it)
    btl_downpayment_shape              = Config.BTL_DOWNPAYMENT_SHAPE,  # NaN sentinel (UK path never reads it)

    # `spain_expectations_naive` changes the defaults of three keyword arguments when `true`:
    #   • `expectations_gamma`     : UK 0.44   → Spain 1.0      (Java HPA_EXPECTATION_FACTOR)
    #   • `expectations_zeta`      : UK -0.007 → Spain 0.0      (Java HPA_EXPECTATION_CONST)
    #   • `hpa_years_to_check`     : UK 2      → Spain 4        (Java HPA_YEARS_TO_CHECK)
    # Explicit keyword arguments always win; an explicit `hpa_years_to_check` is used as given,
    # even when equal to the UK default. The Spain value applies only when it is omitted (`nothing`).
    spain_expectations_naive::Bool = false,
    hpa_years_to_check::Union{Nothing,Int} = nothing,

    # Selects the Spain values for the private bank's hard caps (LTV, LTI, DSTI, ICR), the
    # central bank's policy rate, the initial credit supply, the interest-rate elasticity, the
    # soft-LTI limits for first-time buyers and home movers, and the central-bank
    # affordability and ICR limits. Explicit keyword arguments always win; the resolvers below
    # apply the Spain value only to arguments that were omitted.
    spain_bank_calibration_values::Bool = false,

    # Selects the Spain values for the static empirical distributions and calibration constants
    # that drive household behaviour and stock pricing. Explicit keyword arguments always win.
    # When `holding_period_years` changes, `p_sale_monthly` (and `n_qualities` when omitted)
    # are recomputed from the resolved value rather than the Config constants.
    spain_distribution_calibration::Bool = false,

    # Selects the Spain national population aggregates: the target-stock ratio
    # (`houses_per_household`, used by Construction.jl) and the household count used to scale
    # reported indicators in DataCollection.jl (sales volume, mortgage approvals, new lending).
    # The Spain Java code keeps the `UK_*` variable names, so they are kept here as well.
    # Explicit keyword arguments always win.
    spain_population_scalars::Bool = false,

    # Three switches that change the defaults of four behavioural scalars: the rent-or-buy
    # logit (`psychological_cost_renting` and `sensitivity_rent_buy`), the buy-to-let
    # probability multiplier (`btl_probability_adjustment`) and the market average price decay
    # (`mix_adjustment_weight`). Explicit keyword arguments always win.
    spain_rent_buy_logit::Bool             = false,
    spain_btl_probability_multiplier::Bool = false,
    spain_market_avg_price_decay::Bool     = false,

    # ─── Dataset switches ─────────────────────────────────────────────────────
    # One switch per empirical-distribution CSV family: `false` selects the UK CSV,
    # `true` the Spain CSV. The path is resolved in `_init_from_files`. The two joint
    # distribution datasets (income-age and income-wealth) need `:spain_pdf_precision`
    # for accurate inverse-CDF sampling on the Spain bin schema; this is only warned about.
    spain_demographics_dataset::Bool        = false,
    spain_income_age_joint_dataset::Bool    = false,
    spain_income_wealth_joint_dataset::Bool = false,
    spain_btl_dataset::Bool                 = false,

    # ─── Sell-home vetoes and buy-to-let hard rules ───────────────────────────
    # Sell-home lifecycle vetoes (one switch per veto) and the switch that turns off the
    # buy-to-let hard rules. All default to `false`, which keeps the UK behaviour.
    spain_sell_home_veto_affordability::Bool = false,
    spain_sell_home_veto_upgrade::Bool       = false,
    spain_btl_hard_rules_off::Bool           = false,

    # ─── Wealth aggregates ────────────────────────────────────────────────────
    # When `true`, the three wealth aggregate collectors in `DataCollection.jl` (financial,
    # housing net, housing gross) report non-zero per-step values; otherwise each returns 0.0
    # immediately. Java parity: HouseholdStats.java.
    spain_record_wealth_aggregates::Bool     = false,

    # ─── Buy-to-let maturity ──────────────────────────────────────────────────
    # Decouples the buy-to-let term resolution from `:spain_btl_repayment_mode`. When `true`
    # and the Spain buy-to-let mode is on, buy-to-let loans use annuity repayment, LTV, LTI and
    # DSTI underwriting, a flat 25-year term and a strict age cut-off, instead of the
    # owner-occupier age ladder that the Spain Java code applies to buy-to-let loans. Has no
    # effect when the Spain buy-to-let mode is off (the UK buy-to-let path is already
    # interest-only with a flat 25-year term).
    spain_btl_paper_maturity::Bool           = false,

    # ─── Bank soft-LTV rationing ──────────────────────────────────────────────
    # Six bank-internal soft-LTV parameters.
    bank_ltv_soft_max_ftb            = Config.BANK_LTV_SOFT_MAX_FTB,
    bank_ltv_soft_max_hm             = Config.BANK_LTV_SOFT_MAX_HM,
    bank_ltv_soft_max_btl            = Config.BANK_LTV_SOFT_MAX_BTL,
    bank_ltv_frac_over_soft_max_ftb  = Config.BANK_LTV_FRAC_OVER_SOFT_MAX_FTB,
    bank_ltv_frac_over_soft_max_hm   = Config.BANK_LTV_FRAC_OVER_SOFT_MAX_HM,
    bank_ltv_frac_over_soft_max_btl  = Config.BANK_LTV_FRAC_OVER_SOFT_MAX_BTL,

    # ─── Central bank policy parameters ───────────────────────────────────────
    # Eleven central-bank policy parameters.
    central_bank_policy_application_time         = Config.CENTRAL_BANK_POLICY_APPLICATION_TIME,
    central_bank_ltv_soft_max_ftb                = Config.CENTRAL_BANK_LTV_SOFT_MAX_FTB,
    central_bank_ltv_soft_max_hm                 = Config.CENTRAL_BANK_LTV_SOFT_MAX_HM,
    central_bank_ltv_soft_max_btl                = Config.CENTRAL_BANK_LTV_SOFT_MAX_BTL,
    central_bank_ltv_max_frac_over_soft_max_ftb  = Config.CENTRAL_BANK_LTV_MAX_FRAC_OVER_SOFT_MAX_FTB,
    central_bank_ltv_max_frac_over_soft_max_hm   = Config.CENTRAL_BANK_LTV_MAX_FRAC_OVER_SOFT_MAX_HM,
    central_bank_ltv_max_frac_over_soft_max_btl  = Config.CENTRAL_BANK_LTV_MAX_FRAC_OVER_SOFT_MAX_BTL,
    central_bank_ltv_application_age             = Config.CENTRAL_BANK_LTV_APPLICATION_AGE,
    central_bank_lti_soft_max_btl                = Config.CENTRAL_BANK_LTI_SOFT_MAX_BTL,
    central_bank_lti_max_frac_over_soft_max_btl  = Config.CENTRAL_BANK_LTI_MAX_FRAC_OVER_SOFT_MAX_BTL,
    central_bank_application_income_percentile   = Config.CENTRAL_BANK_APPLICATION_INCOME_PERCENTILE,

    central_bank_pre_ltv_soft_max_ftb = nothing,
    central_bank_pre_ltv_soft_max_hm = nothing,
    central_bank_pre_ltv_soft_max_btl = nothing,
    central_bank_pre_lti_soft_max_btl = nothing,
    central_bank_pre_application_income_percentile = nothing,

    # RNG Seed
    seed = 42
)
    # Validate the optional end-of-month policy schedule before building the model.
    resolved_cb_policy_application_time = if central_bank_policy_application_time === nothing
        nothing
    elseif central_bank_policy_application_time isa Integer &&
           central_bank_policy_application_time >= 0
        Int(central_bank_policy_application_time)
    else
        throw(ArgumentError(
            "central_bank_policy_application_time must be nothing or a nonnegative integer"))
    end

    # -------------------------------------------------------
    # Random number generator
    # -------------------------------------------------------
    # Created before the model so that it can also be used for the initial setup.

    rng = Xoshiro(seed)

    # -------------------------------------------------------
    # Parameter resolution
    # -------------------------------------------------------
    # The resolved values below are passed to the `ModelParameters` struct defined in
    # Types.jl. Its constructor arguments must follow the field order of that struct.

    resolved_expectations_gamma = Float64(resolve_country_parameter(
        expectations_gamma, spain_expectations_naive,
        Config.EXPECTATIONS_GAMMA, Config.EXPECTATIONS_GAMMA_SPAIN_VALUE))
    resolved_expectations_zeta  = Float64(resolve_country_parameter(
        expectations_zeta, spain_expectations_naive,
        Config.EXPECTATIONS_ZETA, Config.EXPECTATIONS_ZETA_SPAIN_VALUE))
    resolved_hpa_years_to_check = isnothing(hpa_years_to_check) ?
                                   (spain_expectations_naive ? Config.HPA_YEARS_TO_CHECK_SPAIN_VALUE : Config.HPA_YEARS_TO_CHECK) :
                                   Int(hpa_years_to_check)
    resolved_hpi_record_length  = resolved_hpa_years_to_check * Config.MONTHS_IN_YEAR + 3

    # Omitted values select existing country defaults; explicit values are retained.
    resolved_bank_ltv_max_ftb = Float64(resolve_country_parameter(
        bank_ltv_max_ftb, spain_bank_calibration_values,
        Config.LTV_MAX_FTB, Config.LTV_MAX_FTB_SPAIN_VALUE))
    resolved_bank_ltv_max_hm = Float64(resolve_country_parameter(
        bank_ltv_max_hm, spain_bank_calibration_values,
        Config.LTV_MAX_HM, Config.LTV_MAX_HM_SPAIN_VALUE))
    resolved_bank_ltv_max_btl = Float64(resolve_country_parameter(
        bank_ltv_max_btl, spain_bank_calibration_values,
        Config.LTV_MAX_BTL, Config.LTV_MAX_BTL_SPAIN_VALUE))
    resolved_bank_lti_max_ftb = Float64(resolve_country_parameter(
        bank_lti_max_ftb, spain_bank_calibration_values,
        Config.LTI_MAX_FTB, Config.LTI_MAX_FTB_SPAIN_VALUE))
    resolved_bank_lti_max_hm = Float64(resolve_country_parameter(
        bank_lti_max_hm, spain_bank_calibration_values,
        Config.LTI_MAX_HM, Config.LTI_MAX_HM_SPAIN_VALUE))
    resolved_bank_lti_max_btl = Float64(resolve_country_parameter(
        bank_lti_max_btl, spain_bank_calibration_values,
        Config.LTI_MAX_BTL, Config.LTI_MAX_BTL_SPAIN_VALUE))
    resolved_bank_dsti_max_common = Float64(resolve_country_parameter(
        bank_dsti_max, spain_bank_calibration_values,
        Config.DSTI_MAX, Config.DSTI_MAX_SPAIN_VALUE))
    resolved_bank_dsti_max_ftb = Float64(resolve_country_parameter(
        bank_dsti_max_ftb, spain_bank_calibration_values,
        Config.DSTI_MAX, Config.DSTI_MAX_SPAIN_VALUE))
    resolved_bank_dsti_max_hm_btl = Float64(resolve_country_parameter(
        bank_dsti_max_hm_btl, spain_bank_calibration_values,
        Config.DSTI_MAX, Config.DSTI_MAX_SPAIN_VALUE))
    resolved_bank_icr_min = Float64(resolve_country_parameter(
        bank_icr_min, spain_bank_calibration_values,
        Config.ICR_MIN, Config.ICR_MIN_SPAIN_VALUE))
    resolved_soft_lti_limit_ftb = Float64(resolve_country_parameter(
        soft_lti_limit_ftb, spain_bank_calibration_values,
        Config.SOFT_LTI_LIMIT_FTB, Config.SOFT_LTI_LIMIT_FTB_SPAIN_VALUE))
    resolved_soft_lti_limit_hm = Float64(resolve_country_parameter(
        soft_lti_limit_hm, spain_bank_calibration_values,
        Config.SOFT_LTI_LIMIT_HM, Config.SOFT_LTI_LIMIT_HM_SPAIN_VALUE))
    resolved_flow_limit_ftb = Float64(resolve_country_parameter(
        flow_limit_ftb, spain_bank_calibration_values,
        Config.FLOW_LIMIT_ALLOWANCE_FTB, Config.FLOW_LIMIT_ALLOWANCE_FTB_SPAIN_VALUE))
    resolved_flow_limit_hm = Float64(resolve_country_parameter(
        flow_limit_hm, spain_bank_calibration_values,
        Config.FLOW_LIMIT_ALLOWANCE_HM, Config.FLOW_LIMIT_ALLOWANCE_HM_SPAIN_VALUE))
    resolved_limit_dsti_common = Float64(resolve_country_parameter(
        limit_dsti, spain_bank_calibration_values,
        Config.REGULATORY_DSTI_MAX, Config.REGULATORY_DSTI_MAX_SPAIN_VALUE))
    resolved_limit_dsti_ftb = Float64(resolve_country_parameter(
        limit_dsti_ftb, spain_bank_calibration_values,
        Config.REGULATORY_DSTI_MAX, Config.REGULATORY_DSTI_MAX_SPAIN_VALUE))
    resolved_limit_dsti_hm_btl = Float64(resolve_country_parameter(
        limit_dsti_hm_btl, spain_bank_calibration_values,
        Config.REGULATORY_DSTI_MAX, Config.REGULATORY_DSTI_MAX_SPAIN_VALUE))
    resolved_limit_icr = Float64(resolve_country_parameter(
        limit_icr, spain_bank_calibration_values,
        Config.REGULATORY_ICR_MIN, Config.REGULATORY_ICR_MIN_SPAIN_VALUE))
    resolved_interest_rate_elasticity_phi = Float64(resolve_country_parameter(
        interest_rate_elasticity_phi, spain_bank_calibration_values,
        Config.INTEREST_RATE_ELASTICITY_PHI, Config.INTEREST_RATE_ELASTICITY_PHI_SPAIN_VALUE))
    resolved_central_bank_policy_rate = Float64(resolve_country_parameter(
        central_bank_policy_rate, spain_bank_calibration_values,
        Config.CENTRAL_BANK_POLICY_RATE, Config.CENTRAL_BANK_POLICY_RATE_SPAIN_VALUE))
    resolved_initial_interest_rate_spread = Float64(resolve_country_parameter(
        initial_interest_rate_spread, spain_bank_calibration_values,
        Config.INITIAL_INTEREST_RATE_SPREAD, Config.INITIAL_INTEREST_RATE_SPREAD_SPAIN_VALUE))
    resolved_initial_credit_supply_per_hh = Float64(resolve_country_parameter(
        initial_credit_supply_per_hh, spain_bank_calibration_values,
        Config.INITIAL_CREDIT_SUPPLY_PER_HH, Config.INITIAL_CREDIT_SUPPLY_PER_HH_SPAIN_VALUE))

    # Regulatory soft-LTV settings come from their own arguments.
    # Selecting private-bank calibration does not replace policy settings.
    resolved_central_bank_ltv_soft_max_ftb =
        Float64(central_bank_ltv_soft_max_ftb)

    resolved_central_bank_ltv_soft_max_hm =
        Float64(central_bank_ltv_soft_max_hm)

    resolved_central_bank_ltv_soft_max_btl =
        Float64(central_bank_ltv_soft_max_btl)

    resolved_central_bank_ltv_max_frac_over_soft_max_ftb =
        Float64(central_bank_ltv_max_frac_over_soft_max_ftb)

    resolved_central_bank_ltv_max_frac_over_soft_max_hm =
        Float64(central_bank_ltv_max_frac_over_soft_max_hm)

    resolved_central_bank_ltv_max_frac_over_soft_max_btl =
        Float64(central_bank_ltv_max_frac_over_soft_max_btl)

    resolved_central_bank_lti_soft_max_btl =
        Float64(central_bank_lti_soft_max_btl)

    resolved_central_bank_lti_max_frac_over_soft_max_btl =
        Float64(central_bank_lti_max_frac_over_soft_max_btl)

    resolved_central_bank_application_income_percentile =
        Float64(central_bank_application_income_percentile)

    resolved_central_bank_ltv_application_age =
        Float64(central_bank_ltv_application_age)

    # Pre-activation defaults when the pre-activation arguments are not supplied.
    resolved_pre_limit_ltv_ftb = isnothing(pre_limit_ltv_ftb) ? 0.9999 : Float64(pre_limit_ltv_ftb)
    resolved_pre_limit_ltv_hm = isnothing(pre_limit_ltv_hm) ? 0.9999 : Float64(pre_limit_ltv_hm)
    resolved_pre_limit_ltv_btl = isnothing(pre_limit_ltv_btl) ? 0.9999 : Float64(pre_limit_ltv_btl)
    resolved_pre_limit_dsti_common = isnothing(pre_limit_dsti) ? 0.9999 : Float64(pre_limit_dsti)
    resolved_pre_limit_dsti_ftb = isnothing(pre_limit_dsti_ftb) ? resolved_pre_limit_dsti_common : Float64(pre_limit_dsti_ftb)
    resolved_pre_limit_dsti_hm_btl = isnothing(pre_limit_dsti_hm_btl) ? resolved_pre_limit_dsti_common : Float64(pre_limit_dsti_hm_btl)
    resolved_pre_soft_lti_limit_ftb = isnothing(pre_soft_lti_limit_ftb) ? 15.0 : Float64(pre_soft_lti_limit_ftb)
    resolved_pre_soft_lti_limit_hm = isnothing(pre_soft_lti_limit_hm) ? 15.0 : Float64(pre_soft_lti_limit_hm)
    resolved_pre_central_bank_lti_soft_max_btl = isnothing(central_bank_pre_lti_soft_max_btl) ? 15.0 : Float64(central_bank_pre_lti_soft_max_btl)
    resolved_pre_central_bank_ltv_soft_max_ftb = isnothing(central_bank_pre_ltv_soft_max_ftb) ? 0.9999 : Float64(central_bank_pre_ltv_soft_max_ftb)
    resolved_pre_central_bank_ltv_soft_max_hm = isnothing(central_bank_pre_ltv_soft_max_hm) ? 0.9999 : Float64(central_bank_pre_ltv_soft_max_hm)
    resolved_pre_central_bank_ltv_soft_max_btl = isnothing(central_bank_pre_ltv_soft_max_btl) ? 0.9999 : Float64(central_bank_pre_ltv_soft_max_btl)
    resolved_pre_central_bank_application_income_percentile = isnothing(central_bank_pre_application_income_percentile) ? 0.0 : Float64(central_bank_pre_application_income_percentile)

    # Profile resolvers: explicit two-layer overlays.
    # The bank profile controls only internal underwriting limits.
    if !isempty(bank_underwriting_profile)
        if bank_underwriting_profile == "spain_carro_2016"
            resolved_bank_ltv_max_ftb = 0.9999
            resolved_bank_ltv_max_hm = 0.9999
            resolved_bank_ltv_max_btl = 0.9999
            resolved_bank_lti_max_ftb = 13.8266
            resolved_bank_lti_max_hm = 13.8266
            resolved_bank_lti_max_btl = 13.8266
            resolved_bank_dsti_max_common = 0.8974
            resolved_bank_dsti_max_ftb = 0.8974
            resolved_bank_dsti_max_hm_btl = 0.8974
        else
            error("Unknown bank_underwriting_profile=$(bank_underwriting_profile). Expected 'spain_carro_2016' or empty.")
        end
    end

    # The central-bank profile controls only the regulatory/policy layer limits.
    resolved_limit_ltv_ftb = Float64(resolve_parameter(limit_ltv_ftb, Config.REGULATORY_LTV_FTB))
    resolved_limit_ltv_hm = Float64(resolve_parameter(limit_ltv_hm, Config.REGULATORY_LTV_HM))
    resolved_limit_ltv_btl = Float64(resolve_parameter(limit_ltv_btl, Config.REGULATORY_LTV_BTL))
    resolved_soft_lti_active = Bool(resolve_parameter(soft_lti_active, Config.IS_SOFT_LIMIT_ACTIVE))
    if !isempty(central_bank_profile)
        if central_bank_profile == "no_policy"
            resolved_limit_ltv_ftb = 0.9999
            resolved_limit_ltv_hm = 0.9999
            resolved_limit_ltv_btl = 0.9999
            resolved_limit_dsti_common = 0.9999
            resolved_limit_dsti_ftb = 0.9999
            resolved_limit_dsti_hm_btl = 0.9999
            resolved_soft_lti_active = true
            resolved_soft_lti_limit_ftb = 15.0
            resolved_soft_lti_limit_hm = 15.0
            resolved_flow_limit_ftb = 0.0
            resolved_flow_limit_hm = 0.0
            resolved_central_bank_policy_rate = 0.0
        elseif central_bank_profile == "ea_policy_baseline"
            resolved_limit_ltv_ftb = 0.95
            resolved_limit_ltv_hm = 0.85
            resolved_limit_ltv_btl = 0.85
            resolved_limit_dsti_common = 0.50
            resolved_limit_dsti_ftb = 0.50
            resolved_limit_dsti_hm_btl = 0.50
            resolved_soft_lti_active = true
            resolved_soft_lti_limit_ftb = 15.0
            resolved_soft_lti_limit_hm = 15.0
            resolved_flow_limit_ftb = 0.0
            resolved_flow_limit_hm = 0.0
            resolved_central_bank_policy_rate = 0.0
        else
            error("Unknown central_bank_profile=$(central_bank_profile). Expected 'no_policy', 'ea_policy_baseline', or empty.")
        end
    end

    # Profiles supply defaults. Explicit arguments take final precedence.
    resolved_bank_ltv_max_ftb = Float64(resolve_parameter(bank_ltv_max_ftb, resolved_bank_ltv_max_ftb))
    resolved_bank_ltv_max_hm  = Float64(resolve_parameter(bank_ltv_max_hm, resolved_bank_ltv_max_hm))
    resolved_bank_ltv_max_btl = Float64(resolve_parameter(bank_ltv_max_btl, resolved_bank_ltv_max_btl))
    resolved_bank_lti_max_ftb = Float64(resolve_parameter(bank_lti_max_ftb, resolved_bank_lti_max_ftb))
    resolved_bank_lti_max_hm  = Float64(resolve_parameter(bank_lti_max_hm, resolved_bank_lti_max_hm))
    resolved_bank_lti_max_btl = Float64(resolve_parameter(bank_lti_max_btl, resolved_bank_lti_max_btl))

    # A supplied common DSTI applies unless a borrower-specific value is supplied.
    resolved_bank_dsti_max_common = Float64(resolve_parameter(bank_dsti_max, resolved_bank_dsti_max_common))
    resolved_bank_dsti_max_ftb = Float64(resolve_parameter(bank_dsti_max_ftb, resolved_bank_dsti_max_common))
    resolved_bank_dsti_max_hm_btl = Float64(resolve_parameter(bank_dsti_max_hm_btl, resolved_bank_dsti_max_common))

    resolved_limit_ltv_ftb = Float64(resolve_parameter(limit_ltv_ftb, resolved_limit_ltv_ftb))
    resolved_limit_ltv_hm  = Float64(resolve_parameter(limit_ltv_hm, resolved_limit_ltv_hm))
    resolved_limit_ltv_btl = Float64(resolve_parameter(limit_ltv_btl, resolved_limit_ltv_btl))
    resolved_limit_dsti_common = Float64(resolve_parameter(limit_dsti, resolved_limit_dsti_common))
    resolved_limit_dsti_ftb = Float64(resolve_parameter(limit_dsti_ftb, resolved_limit_dsti_common))
    resolved_limit_dsti_hm_btl = Float64(resolve_parameter(limit_dsti_hm_btl, resolved_limit_dsti_common))

    resolved_soft_lti_active = Bool(resolve_parameter(soft_lti_active, resolved_soft_lti_active))
    resolved_soft_lti_limit_ftb = Float64(resolve_parameter(soft_lti_limit_ftb, resolved_soft_lti_limit_ftb))
    resolved_soft_lti_limit_hm = Float64(resolve_parameter(soft_lti_limit_hm, resolved_soft_lti_limit_hm))
    resolved_flow_limit_ftb = Float64(resolve_parameter(flow_limit_ftb, resolved_flow_limit_ftb))
    resolved_flow_limit_hm = Float64(resolve_parameter(flow_limit_hm, resolved_flow_limit_hm))
    resolved_central_bank_policy_rate = Float64(resolve_parameter(central_bank_policy_rate, resolved_central_bank_policy_rate))

    resolved_price_dist_mu = Float64(resolve_country_parameter(
        price_dist_mu, spain_distribution_calibration,
        Config.PRICE_DIST_MU, Config.PRICE_DIST_MU_SPAIN_VALUE))
    resolved_price_dist_sigma = Float64(resolve_country_parameter(
        price_dist_sigma, spain_distribution_calibration,
        Config.PRICE_DIST_SIGMA, Config.PRICE_DIST_SIGMA_SPAIN_VALUE))
    resolved_rent_dist_mu = Float64(resolve_country_parameter(
        rent_dist_mu, spain_distribution_calibration,
        Config.RENT_DIST_MU, Config.RENT_DIST_MU_SPAIN_VALUE))
    resolved_rent_dist_sigma = Float64(resolve_country_parameter(
        rent_dist_sigma, spain_distribution_calibration,
        Config.RENT_DIST_SIGMA, Config.RENT_DIST_SIGMA_SPAIN_VALUE))
    resolved_initial_rental_yield = Float64(resolve_country_parameter(
        initial_rental_yield, spain_distribution_calibration,
        Config.INITIAL_RENTAL_YIELD, Config.INITIAL_RENTAL_YIELD_SPAIN_VALUE))
    resolved_hm_downpayment_mu = Float64(resolve_country_parameter(
        hm_downpayment_mu, spain_distribution_calibration,
        Config.HM_DOWNPAYMENT_MU, Config.HM_DOWNPAYMENT_MU_SPAIN_VALUE))
    resolved_hm_downpayment_sigma = Float64(resolve_country_parameter(
        hm_downpayment_sigma, spain_distribution_calibration,
        Config.HM_DOWNPAYMENT_SIGMA, Config.HM_DOWNPAYMENT_SIGMA_SPAIN_VALUE))
    resolved_btl_downpayment_mu = Float64(resolve_country_parameter(
        btl_downpayment_mu, spain_distribution_calibration,
        Config.BTL_DOWNPAYMENT_MU, Config.BTL_DOWNPAYMENT_MU_SPAIN_VALUE))
    resolved_btl_downpayment_sigma = Float64(resolve_country_parameter(
        btl_downpayment_sigma, spain_distribution_calibration,
        Config.BTL_DOWNPAYMENT_SIGMA, Config.BTL_DOWNPAYMENT_SIGMA_SPAIN_VALUE))
    resolved_pd_alpha = Float64(resolve_country_parameter(
        pd_alpha, spain_distribution_calibration,
        Config.PD_ALPHA, Config.PD_ALPHA_SPAIN_VALUE))
    resolved_pd_beta = Float64(resolve_country_parameter(
        pd_beta, spain_distribution_calibration,
        Config.PD_BETA, Config.PD_BETA_SPAIN_VALUE))
    resolved_pd_epsilon_mu = Float64(resolve_country_parameter(
        pd_epsilon_mu, spain_distribution_calibration,
        Config.PD_EPSILON_MU, Config.PD_EPSILON_MU_SPAIN_VALUE))
    resolved_pd_epsilon_sigma = Float64(resolve_country_parameter(
        pd_epsilon_sigma, spain_distribution_calibration,
        Config.PD_EPSILON_SIGMA, Config.PD_EPSILON_SIGMA_SPAIN_VALUE))
    resolved_rental_bid_scale = Float64(resolve_country_parameter(
        rental_bid_scale, spain_distribution_calibration,
        Config.RENTAL_BID_SCALE, Config.RENTAL_BID_SCALE_SPAIN_VALUE))
    resolved_rental_bid_exponent = Float64(resolve_country_parameter(
        rental_bid_exponent, spain_distribution_calibration,
        Config.RENTAL_BID_EXPONENT, Config.RENTAL_BID_EXPONENT_SPAIN_VALUE))
    resolved_tenancy_length_max = Int(resolve_country_parameter(
        tenancy_length_max, spain_distribution_calibration,
        Config.TENANCY_LENGTH_MAX, Config.TENANCY_LENGTH_MAX_SPAIN_VALUE))
    resolved_windfall_cap_share = Float64(resolve_country_parameter(
        windfall_cap_share, spain_distribution_calibration,
        Config.WINDFALL_CAP_SHARE, Config.WINDFALL_CAP_SHARE_SPAIN_VALUE))
    # Population and housing geometry: explicit values override country defaults.
    resolved_uk_households = Int(resolve_country_parameter(
        uk_households, spain_population_scalars,
        Config.UK_HOUSEHOLDS, Config.UK_HOUSEHOLDS_SPAIN_VALUE))
    resolved_houses_per_household = Float64(resolve_country_parameter(
        houses_per_household, spain_population_scalars,
        Config.HOUSES_PER_HOUSEHOLD, Config.HOUSES_PER_HOUSEHOLD_SPAIN_VALUE))
    resolved_holding_period_years = Float64(resolve_country_parameter(
        holding_period_years, spain_distribution_calibration,
        Config.HOLDING_PERIOD_YEARS, Config.HOLDING_PERIOD_YEARS_SPAIN_VALUE))

    isfinite(resolved_houses_per_household) && resolved_houses_per_household > 0 ||
        throw(ArgumentError("houses_per_household must be finite and positive"))
    isfinite(resolved_holding_period_years) && resolved_holding_period_years > 0 ||
        throw(ArgumentError("holding_period_years must be finite and positive"))

    resolved_p_sale_monthly = Float64(resolve_parameter(
        p_sale_monthly,
        1.0 / (resolved_holding_period_years * Config.MONTHS_IN_YEAR)))
    isfinite(resolved_p_sale_monthly) && 0.0 <= resolved_p_sale_monthly <= 1.0 ||
        throw(ArgumentError("p_sale_monthly must lie between zero and one"))

    n_households > 0 || throw(ArgumentError("n_households must be positive"))

    # Java floors the stock target. Use the requested target population here.
    target_stock_unrounded = n_households * resolved_houses_per_household
    resolved_n_houses = n_houses === nothing ?
        floor(Int, target_stock_unrounded) : Int(n_houses)

    # Java derives quality bands before rounding stock, then rounds half upward.
    # A custom initial stock does not redefine the reference quality grid.
    resolved_n_qualities = n_qualities === nothing ?
        max(1, floor(Int, target_stock_unrounded * resolved_p_sale_monthly + 0.5)) :
        Int(n_qualities)

    resolved_n_houses >= 0 || throw(ArgumentError("n_houses must be nonnegative"))
    resolved_n_qualities >= 1 || throw(ArgumentError("n_qualities must be positive"))

    # Every downstream allocation and house-creation loop uses these bindings.
    n_houses = resolved_n_houses
    n_qualities = resolved_n_qualities

    # Behavioural scalars: four numerics under three switches. An omitted keyword argument
    # (`nothing`) resolves to the UK or Spain value according to its switch; an explicit
    # value is used as given. All four feed `ModelParameters` below; the
    # `mix_adjustment_weight` consumer in MarketStats.jl::update_market_stats! reads
    # `model.params.mix_adjustment_weight`, so the resolved value takes effect there.
    resolved_psychological_cost_renting = isnothing(psychological_cost_renting) ?
                                           (spain_rent_buy_logit ? Config.PSYCHOLOGICAL_COST_RENTING_SPAIN_VALUE : Config.PSYCHOLOGICAL_COST_RENTING) :
                                           Float64(psychological_cost_renting)
    resolved_sensitivity_rent_buy       = isnothing(sensitivity_rent_buy) ?
                                           (spain_rent_buy_logit ? Config.SENSITIVITY_RENT_BUY_SPAIN_VALUE : Config.SENSITIVITY_RENT_BUY) :
                                           Float64(sensitivity_rent_buy)
    resolved_btl_probability_adjustment = isnothing(btl_probability_adjustment) ?
                                           (spain_btl_probability_multiplier ? Config.BTL_PROBABILITY_ADJUSTMENT_SPAIN_VALUE : Config.BTL_PROBABILITY_ADJUSTMENT) :
                                           Float64(btl_probability_adjustment)
    resolved_mix_adjustment_weight      = isnothing(mix_adjustment_weight) ?
                                           (spain_market_avg_price_decay ? Config.MIX_ADJUSTMENT_WEIGHT_SPAIN_VALUE : Config.MIX_ADJUSTMENT_WEIGHT) :
                                           Float64(mix_adjustment_weight)
    resolved_btl_xi                     = isnothing(btl_xi) ? Config.BTL_XI : Float64(btl_xi)


    

    params = ModelParameters(
            n_households,                # target_population
            n_houses,                    # n_houses
            n_steps,                     # n_steps
            bid_up_factor,               # bid_up_factor (passed from args)
            days_under_offer / 30.0,     # months_under_offer (CONVERSION: Days -> Months)
            market_smoothing,            # smoothing_factor (passed from args
            resolved_mix_adjustment_weight,  # Eq 21: Rho (ρ) (UK 0.5 / Spain 0.7 / kwarg override)
            n_qualities,                 # n_qualities (resolved from the holding period and stock size)
            resolved_pd_alpha,           # Scale for desired price
            resolved_pd_beta,            # Exponent for income
            resolved_pd_epsilon_mu,      # Noise Mean
            resolved_pd_epsilon_sigma,   # Noise Std Dev
            resolved_psychological_cost_renting,  # Lambda (UK 0.4 / Spain 0.8 / kwarg override)
            resolved_sensitivity_rent_buy,        # Theta  (UK 0.001 / Spain 0.01 / kwarg override)
            resolved_expectations_gamma, # Sensitivity to past growth (γ; Java HPA_EXPECTATION_FACTOR; UK 0.44 / Spain 1.0 / kwarg override)
            resolved_expectations_zeta,  # Sentiment bias            (ζ; Java HPA_EXPECTATION_CONST;  UK -0.007 / Spain 0.0 / kwarg override)
            resolved_rental_bid_scale,    # rental bid scale
            resolved_rental_bid_exponent, # rental bid exponent
            rental_bid_noise_mu,
            rental_bid_noise_sigma,
            essential_consumption_fraction,
            minimum_govt_support,
            resolved_windfall_cap_share,         # windfall_cap_share (Java MAXIMUM_CONSUMPTION_FRACTION)
            resolved_holding_period_years,       # holding_period_years
            resolved_p_sale_monthly,             # p_sale_monthly (derived from holding_period_years)
            sale_price_reduction_prob,          # sale_price_reduction_prob (Passed Argument)
            sale_price_reduction_mean,          # Mean of price reduction percentage
            sale_price_reduction_std,           # Std Dev of price reduction percentage
            rent_price_reduction_prob,          # rent_price_reduction_prob (Passed Argument)
            rent_reduction_mean,                # Mean of rent reduction percentage
            rent_reduction_std,                 # Std Dev of rent reduction percentage
            tenancy_length_min,                 # Minimum tenancy length (months)
            resolved_tenancy_length_max,        # Maximum tenancy length (months)

            # Down Payment Params
            resolved_hm_downpayment_mu,         # home-mover down-payment distribution mean
            resolved_hm_downpayment_sigma,      # home-mover down-payment distribution sigma
            resolved_btl_downpayment_mu,        # buy-to-let down-payment distribution mean
            resolved_btl_downpayment_sigma,     # buy-to-let down-payment distribution sigma
            downpayment_bank_balance_for_cash_sale,

            resolved_btl_xi,
            btl_annual_to_monthly,
            resolved_btl_probability_adjustment,  # BTL Eq. 6 multiplier (UK 1.76 / Spain 1.6 / kwarg override)
            # Regulatory Policy
            resolved_soft_lti_active,
            resolved_soft_lti_limit_ftb,
            resolved_soft_lti_limit_hm,
            resolved_flow_limit_ftb,
            resolved_flow_limit_hm,
            use_pooled_lti_quota,
            # Interest Rate
            resolved_interest_rate_elasticity_phi
        )



    # --- Create the Bank ---
    # Single representative bank. The rolling regulatory history is held by the Central Bank.
    
    bank = Bank(
        1, # ID
        resolved_bank_ltv_max_ftb, resolved_bank_ltv_max_hm, resolved_bank_ltv_max_btl,
        resolved_bank_lti_max_ftb, resolved_bank_lti_max_hm,
        resolved_bank_lti_max_btl,  # BTL hard LTI limit (used only in Spain mode); UK default 99.0
        resolved_bank_dsti_max_common,
        resolved_bank_dsti_max_ftb,
        resolved_bank_dsti_max_hm_btl,
        resolved_bank_icr_min,
        # The base rate is not stored on the Bank (it queries the CentralBank directly), so only the initial mortgage rate is set here.
        resolved_central_bank_policy_rate + resolved_initial_interest_rate_spread, # Initial Mortgage Rate (policy rate + spread)
        0.0,   # Outstanding Credit
        0.0,    # Provisions
        100_000.0, # Cash Reserves (Initial capital buffer)
        0.0, # cumulative_zombie_recovered
        0.0, # cumulative_inheritance_writeoffs
        resolved_initial_interest_rate_spread,                       # current_spread
        resolved_initial_credit_supply_per_hh * n_households,        # previous_credit_supply
        0.0,  # current_credit_supply
        
        # Operational Counters (per type)
        0, # current_month_total_ftb
        0, # current_month_high_lti_ftb
        0, # current_month_total_hm
        0, # current_month_high_lti_hm

        # Adaptive Policy (initialised to the per-type CB allowance)
        resolved_flow_limit_ftb, # target_prospec_fraction_ftb
        0,              # n_prospec_total_ftb
        0,              # n_prospec_high_ftb
        resolved_flow_limit_hm,  # target_prospec_fraction_hm
        0,              # n_prospec_total_hm
        0,              # n_prospec_high_hm

        # OO LTV Rolling Window (Java: CreditSupply.oo_ltv)
        [Float64[] for _ in 1:Config.ROLLING_WINDOW],  # oo_ltv_window — 6 empty slots
        1,                                             # oo_ltv_index  — starts at slot 1

        # OO LTI Rolling Window (Java: CreditSupply.oo_lti) — shares oo_ltv_index
        [Float64[] for _ in 1:Config.ROLLING_WINDOW],  # oo_lti_window — 6 empty slots

        # Spain-mode bookkeeping: always allocated and zero-initialised; the
        # counters are only written when the corresponding Spain switches are on.
        # Realised monthly counters (the BTL total is shared by the LTV and LTI limits):
        0, # current_month_total_btl           (shared by BTL LTV and BTL LTI limits)
        0, # current_month_high_ltv_ftb
        0, # current_month_high_ltv_hm
        0, # current_month_high_ltv_btl
        0, # current_month_high_lti_btl
        # Prospective monthly counters:
        0, # n_prospec_total_btl               (shared by BTL LTV and BTL LTI limits)
        0, # n_prospec_high_ltv_ftb
        0, # n_prospec_high_ltv_hm
        0, # n_prospec_high_ltv_btl
        0, # n_prospec_high_lti_btl
        # Adaptive prospective targets (initialised to the corresponding Config
        # max-frac-over-soft-max value to match the Bank.maxFrac*ProspecOverSoftMax*
        # initialisation in the Spain Java Bank class):
        resolved_central_bank_ltv_max_frac_over_soft_max_ftb,
        resolved_central_bank_ltv_max_frac_over_soft_max_hm,
        resolved_central_bank_ltv_max_frac_over_soft_max_btl,
        Float64(central_bank_lti_max_frac_over_soft_max_btl), # Initial prospective targets match the allowances assigned to CentralBank.
        0,   # mortgage_id_counter

        Float64(bank_ltv_soft_max_ftb),
        Float64(bank_ltv_soft_max_hm),
        Float64(bank_ltv_soft_max_btl),
        Float64(bank_ltv_frac_over_soft_max_ftb),
        Float64(bank_ltv_frac_over_soft_max_hm),
        Float64(bank_ltv_frac_over_soft_max_btl),
    )


    # --- Create the Central Bank ---
    # The Central Bank holds the system-wide rolling-window history.
    
    # Per-type rolling history — length driven by Config.LTI_WINDOW_MONTHS
    # (Java: CENTRAL_BANK_LTI_MONTHS_TO_CHECK = 12, config.properties line 85)
    cb_history_total_ftb = zeros(Int, Config.LTI_WINDOW_MONTHS)
    cb_history_high_ftb  = zeros(Int, Config.LTI_WINDOW_MONTHS)
    cb_history_total_hm  = zeros(Int, Config.LTI_WINDOW_MONTHS)
    cb_history_high_hm   = zeros(Int, Config.LTI_WINDOW_MONTHS)

    # Additional rolling histories used by the Spain-mode limits (LTV flow limits and the
    # buy-to-let LTI limit). Same window length, zero-initialised.
    cb_history_high_ltv_ftb = zeros(Int, Config.LTI_WINDOW_MONTHS)  # FTB loans above the soft LTV limit
    cb_history_high_ltv_hm  = zeros(Int, Config.LTI_WINDOW_MONTHS)  # HM loans above the soft LTV limit
    cb_history_total_btl    = zeros(Int, Config.LTI_WINDOW_MONTHS)  # BTL loans issued (shared by the BTL LTV and LTI limits)
    cb_history_high_ltv_btl = zeros(Int, Config.LTI_WINDOW_MONTHS)  # BTL loans above the soft LTV limit
    cb_history_high_lti_btl = zeros(Int, Config.LTI_WINDOW_MONTHS)  # BTL loans above the soft LTI limit

    requested_cb_policy = CentralBankRequestedPolicy(
        resolved_limit_ltv_ftb,  # max_ltv_ftb
        resolved_limit_ltv_hm,  # max_ltv_hm
        resolved_limit_ltv_btl,  # max_ltv_btl
        resolved_limit_dsti_common,  # max_dsti
        resolved_limit_dsti_ftb,  # max_dsti_ftb
        resolved_limit_dsti_hm_btl,  # max_dsti_hm_btl
        resolved_soft_lti_limit_ftb,  # soft_lti_limit_ftb
        resolved_soft_lti_limit_hm,  # soft_lti_limit_hm
        resolved_central_bank_lti_soft_max_btl,  # soft_lti_limit_btl
        resolved_central_bank_ltv_soft_max_ftb,  # soft_max_ltv_ftb
        resolved_central_bank_ltv_soft_max_hm,  # soft_max_ltv_hm
        resolved_central_bank_ltv_soft_max_btl,  # soft_max_ltv_btl
        resolved_central_bank_application_income_percentile,  # application_income_percentile
    )

    initial_cb_policy = CentralBankRequestedPolicy(
        resolved_pre_limit_ltv_ftb,
        resolved_pre_limit_ltv_hm,
        resolved_pre_limit_ltv_btl,
        resolved_pre_limit_dsti_common,
        resolved_pre_limit_dsti_ftb,
        resolved_pre_limit_dsti_hm_btl,
        resolved_pre_soft_lti_limit_ftb,
        resolved_pre_soft_lti_limit_hm,
        resolved_pre_central_bank_lti_soft_max_btl,
        resolved_pre_central_bank_ltv_soft_max_ftb,
        resolved_pre_central_bank_ltv_soft_max_hm,
        resolved_pre_central_bank_ltv_soft_max_btl,
        resolved_pre_central_bank_application_income_percentile,
    )

    central_bank = CentralBank(
        resolved_central_bank_policy_rate,
        resolved_limit_ltv_ftb,
        resolved_limit_ltv_hm,
        resolved_limit_ltv_btl,
        resolved_limit_dsti_common,
        resolved_limit_dsti_ftb,
        resolved_limit_dsti_hm_btl,
        resolved_limit_icr,

        resolved_soft_lti_active,    # Controlled by Config.IS_SOFT_LIMIT_ACTIVE
        resolved_soft_lti_limit_ftb, # Java CENTRAL_BANK_LTI_SOFT_MAX_FTB (UK 5.4 / Spain 15.0)
        resolved_soft_lti_limit_hm,  # Java CENTRAL_BANK_LTI_SOFT_MAX_HM  (UK 5.6 / Spain 15.0)
        resolved_flow_limit_ftb,       # Java CENTRAL_BANK_LTI_MAX_FRAC_OVER_SOFT_MAX_FTB (UK 0.15 / Spain 0.0)
        resolved_flow_limit_hm,        # Java CENTRAL_BANK_LTI_MAX_FRAC_OVER_SOFT_MAX_HM  (UK 0.15 / Spain 0.0)
        use_pooled_lti_quota, # Java default: true (FTB == HM allowance → pooled)

        cb_history_total_ftb,
        cb_history_high_ftb,
        cb_history_total_hm,
        cb_history_high_hm,

        # Requested regulatory values. Explicitly scheduled runs receive
        # reference initial thresholds after construction, while requested_policy
        # retains these resolved values for the end-of-month activation.
        resolved_central_bank_ltv_soft_max_ftb,                # soft_max_ltv_ftb
        resolved_central_bank_ltv_max_frac_over_soft_max_ftb,  # max_frac_over_soft_max_ltv_ftb
        resolved_central_bank_ltv_soft_max_hm,                 # soft_max_ltv_hm
        resolved_central_bank_ltv_max_frac_over_soft_max_hm,   # max_frac_over_soft_max_ltv_hm
        resolved_central_bank_ltv_soft_max_btl,                # soft_max_ltv_btl
        resolved_central_bank_ltv_max_frac_over_soft_max_btl,  # max_frac_over_soft_max_ltv_btl
        resolved_central_bank_lti_soft_max_btl,                # soft_lti_limit_btl
        resolved_central_bank_lti_max_frac_over_soft_max_btl,  # soft_lti_allowance_btl
        resolved_central_bank_application_income_percentile,    # application_income_percentile
        0.0,                                          # application_income (refreshed each step by central_bank_step!)
        resolved_central_bank_ltv_application_age,    # application_age_ltv

        cb_history_high_ltv_ftb,    # FTB loans above the soft LTV limit
        cb_history_high_ltv_hm,     # HM loans above the soft LTV limit
        cb_history_total_btl,       # BTL loans issued (shared by the BTL LTV and LTI limits)
        cb_history_high_ltv_btl,    # BTL loans above the soft LTV limit
        cb_history_high_lti_btl,    # BTL loans above the soft LTI limit
        resolved_cb_policy_application_time,
        requested_cb_policy,
    )

    if resolved_cb_policy_application_time !== nothing
        if resolved_cb_policy_application_time == 0
            apply_requested_policy!(central_bank)
        else
            initialize_pre_policy_limits!(central_bank, initial_cb_policy)
        end
    end

    # --- Create the Government ---
    government = Government(
        0.0  # Initial bank balance (tax revenue)
    )

    # --- Create the Construction Sector ---
    # Java Model.java line 82: construction = new Construction(prng)
    # housing_stock_count is set to 0 here and synchronised to
    # length(housing_stock) inline after the housing loop below.
    construction = Construction(
        0,  # housing_stock_count  (Java: housingStock = 0)
        0   # n_new_build          (Java: nNewBuild  = 0)
        # on_market omitted — see Construction struct docstring in Types.jl
    )
    
    
    # -------------------------------------------------------
    # 4. Populate the World
    # -------------------------------------------------------

    # 1. Initialize Housing Stock Container
    # NOTE: In Java, housing stock starts at 0 and is built up in Construction.step().
    # We initialize an empty vector here to pass to ModelProperties, but we will
    # populate it AFTER household creation to match the RNG sequence.
    housing_stock = Vector{House}()

    # House price distribution (UK reference: mu 12.1186, sigma 0.6414). Resolved values (UK Config / Spain / kwarg override).
    price_dist = LogNormal(resolved_price_dist_mu, resolved_price_dist_sigma)

    # Rental price distribution (UK reference: mu 6.2647, sigma 0.6353). Resolved values (UK Config / Spain / kwarg override).
    rent_dist = LogNormal(resolved_rent_dist_mu, resolved_rent_dist_sigma)

    # --- Create Market Oracle ---
    # The housing stock is still empty at this point, and generating prices now would
    # consume random numbers out of the Java order (households first, then houses).
    # MarketStats is therefore created with placeholder values and the reference prices
    # and rents are computed after households and houses have been populated.

    # --- Quality-Segmented Initialization (Placeholders) ---
    # Overwritten after house generation.
    initial_prices_q = [Float64[] for _ in 1:n_qualities]
    initial_rents_q = [Float64[] for _ in 1:n_qualities]
    
    global_mean_price = resolved_price_dist_mu # Temporary fallback
    global_mean_rent = resolved_rent_dist_mu   # Temporary fallback
    
    ref_prices = zeros(n_qualities)
    ref_rents = zeros(n_qualities)
    
    # The price history is seeded with 1.0 (the HPI is a dimensionless ratio,
    # sumSoldPrice/sumSoldReferencePrice), not with absolute prices.
    # Java: HousingMarketStats.java line 134: HPIRecord.addValue(1.0).
    # Buffer length is the resolved HPI record length (UK 27 / Spain 51 / kwarg override),
    # matching Java's `Arrays.fill(HPIRecord, 1.0)` over the dynamically sized window.
    initial_history = fill(1.0, resolved_hpi_record_length)

    # Matches Equations 1, 14, and 16 for market feedback loops
    market_stats = MarketStats(
        1.0,                                                        # hpi: Normalized to 1.0 at T=0
        1.0,                                                        # rental_price_index: Normalized to 1.0
        
        copy(ref_prices),                                           # ema_prices_by_quality
        copy(ref_rents),                                            # ema_rents_by_quality
        ones(n_qualities),                                          # occupancy_rate_by_quality (Full occupancy start)
        
        global_mean_price,                                          # ema_sales_price (Global)
        global_mean_rent,                                           # ema_rent (Global)
        resolved_initial_rental_yield,                              # ema_yield (Global)
        resolved_initial_rental_yield,                              # flow_yield_raw (Java: avFlowYield init)
        
        global_mean_rent,                                           # average_rent (Emergent, Table 6)
        0.30,                                                       # avg_rent_to_income (Emergent, Table 6)

        global_mean_price,                                          # reference_price: The Endogenous P_0
        global_mean_rent,                                           # reference_rent: The Endogenous R_0
        
        copy(ref_prices),                                           # reference_prices_by_quality
        copy(ref_rents),                                            # reference_rents_by_quality
        
        0,                                                          # sales_volume: Starts at zero for Step 0
        0,                                                          # mortgage_approvals: Starts at zero
        0,                                                          # rental_transactions: Starts at zero
        fill(Config.INITIAL_MOM, n_qualities),                      # months_on_market_ema: Typical liquidity baseline (Segmented)
        fill(Config.INITIAL_MOM, n_qualities),                      # months_on_market_ema_rental: Default liquidity baseline (Segmented)

        # Demand/Supply Measures
        0, 0.0, 0, 0.0,                                             # measured_demand/supply fields
        
        initial_history,                                            # price_history: initialised to 1.0 over the HPI record length
        0.0,                                                         # hpa_oracle: Initial growth rate
        
        [Float64[] for _ in 1:n_qualities],                         # current_sales_by_quality
        [Float64[] for _ in 1:n_qualities],                         # current_rents_by_quality
        [Int[] for _ in 1:n_qualities],                             # current_mom_by_quality
        [Int[] for _ in 1:n_qualities],                             # current_rental_mom_by_quality
        
        0,                                                          # mortgage_flow_temp
        0,                                                          # rental_flow_temp
        0.0,                                                        # mortgage_flow_principal_temp (gross new lending accumulator)
        0.0,                                                        # new_lending_flow (published per-tick flow)
        0.0,                                                        # audit_interest_due (published per-tick)
        0.0,                                                        # audit_interest_paid (published per-tick)
        0.0,                                                        # audit_principal_paid (published per-tick)
        0.0,                                                        # audit_interest_due_temp (intra-step accumulator)
        0.0,                                                        # audit_interest_paid_temp (intra-step accumulator)
        0.0,                                                        # audit_principal_paid_temp (intra-step accumulator)
        BitSet(),                                                   # active_sales_listings: Starts empty
        BitSet(),                                                   # active_rental_listings: Starts empty
        
        zeros(Int, n_qualities),                                    # occupied_rentals_by_quality
        zeros(Int, n_qualities),                                    # vacant_rentals_by_quality

        0, 0,                                                       # n_withdrawals, n_bankruptcies
        0, 0, 0,                                                    # n_bankruptcies_ftb, n_bankruptcies_hm, n_bankruptcies_btl
        0, 0,                                                       # n_bids_active, n_offers_active

        Bid[],                                                      # bids_queue
        RentalBid[],                                                # rental_bids_queue
        Float64[],                                                  # sorted_household_incomes (cache; populated by update_market_stats! when :spain_application_income_gate is on)
        # Consumption ledger (5 snapshots + 5 counters; used when :spain_consumption_recording is on)
        0.0, 0.0, 0.0, 0.0, 0.0,                                    # snapshots: rental / interest / principal_repayment / downpayment / non_housing
        0.0, 0.0, 0.0, 0.0, 0.0                                     # within-step counters: same order
    )

    # -------------------------------------------------------
    # Model properties
    # -------------------------------------------------------
    
    # --- Load Empirical Data ---
    # Four switches select the UK or Spain CSV independently for each distribution (age,
    # age-income, income-wealth, buy-to-let), so hybrid combinations such as Spain age
    # with UK income are possible. All default to `false`, which selects the UK files.
    # The mark-up CSVs are always read from the UK directory (the Spain files are copies).
    uk_resource_path    = joinpath(@__DIR__, Config.DATA_DIR_UK...)
    spain_resource_path = joinpath(@__DIR__, Config.DATA_DIR_SPAIN...)

    age_dir,     age_csv     = spain_demographics_dataset        ? (spain_resource_path, Config.DATA_PATH_AGE_SPAIN)           : (uk_resource_path, Config.DATA_PATH_AGE_UK)
    income_dir,  income_csv  = spain_income_age_joint_dataset    ? (spain_resource_path, Config.DATA_PATH_AGE_INCOME_SPAIN)    : (uk_resource_path, Config.DATA_PATH_AGE_INCOME_UK)
    wealth_dir,  wealth_csv  = spain_income_wealth_joint_dataset ? (spain_resource_path, Config.DATA_PATH_INCOME_WEALTH_SPAIN) : (uk_resource_path, Config.DATA_PATH_INCOME_WEALTH_UK)
    btl_dir,     btl_csv     = spain_btl_dataset                 ? (spain_resource_path, Config.DATA_PATH_BTL_SPAIN)           : (uk_resource_path, Config.DATA_PATH_BTL_UK)

    # Soft check (a warning, not an assertion) so that partially switched combinations remain possible:
    if (spain_income_age_joint_dataset || spain_income_wealth_joint_dataset) && !spain_pdf_precision
        @warn "Spain joint-distribution dataset flag(s) ON " *
              "without `:spain_pdf_precision=true`. Inverse-CDF accuracy collapses on Spain bin schema " *
              "(n_samples=100 vs Spain 100_000; INTEGRATION_STEPS=2048 vs Spain 262_144)."
    end

    demographics_raw = load_demographics(joinpath(age_dir, age_csv))

    # Fixed expected households per age bin, computed once at initialisation.
    # Java Parity: data.Demographics.computeExpectedHouseholdsPerAgeBand()
    # This anchors the demographic target to the target population for the whole run.
    expected_per_bin = [round(Int, n_households * p) for p in demographics_raw.monthly_probs]

    # Create final demographics object with anchored targets
    demographics = DemographicsData(
        demographics_raw.age_bins,
        demographics_raw.age_probs,
        demographics_raw.raw_bins,
        demographics_raw.monthly_probs,
        demographics_raw.monthly_bin_width,
        expected_per_bin  # The fixed anchor
    )

    income_dist      = load_income_distribution(joinpath(income_dir, income_csv); spain_pdf_precision=spain_pdf_precision)
    wealth_dist      = load_wealth_distribution(joinpath(wealth_dir, wealth_csv); spain_pdf_precision=spain_pdf_precision)
    btl_prob         = load_btl_distribution(joinpath(btl_dir, btl_csv))
    sale_markup_dist = load_markup_distribution(joinpath(uk_resource_path, "InitialSaleMarkUpDist.csv"); spain_pdf_precision=spain_pdf_precision)
    rent_markup_dist = load_markup_distribution(joinpath(uk_resource_path, "InitialRentMarkUpDist.csv"); spain_pdf_precision=spain_pdf_precision)


    # Create Transaction Log
    transaction_log = Vector{Transaction}()

    # Omitted values use country defaults; explicit numeric values win.
    resolved_btl_alternative_return = Float64(resolve_country_parameter(
        btl_alternative_return, spain_btl_alternative_return,
        Config.BTL_ALTERNATIVE_RETURN, Config.BTL_ALTERNATIVE_RETURN_SPAIN_VALUE))

    resolved_bank_age_limit = Float64(resolve_country_parameter(
        bank_age_limit, spain_bank_age_limits,
        Config.BANK_AGE_LIMIT, Config.BANK_AGE_LIMIT_SPAIN_VALUE))
    resolved_mortgage_duration_years = Int(resolve_country_parameter(
        mortgage_duration_years, spain_bank_age_limits,
        Config.MORTGAGE_DURATION_YEARS, Config.MORTGAGE_DURATION_YEARS_SPAIN_VALUE))
    resolved_bank_min_age_limit = Float64(resolve_country_parameter(
        bank_min_age_limit, spain_bank_min_age,
        Config.BANK_MIN_AGE_LIMIT, Config.BANK_MIN_AGE_LIMIT_SPAIN_VALUE))

    # Resolvers for the buy-to-let down-payment LogNormal. The UK path (normal fraction
    # times price) never reads these values, so the UK default is a NaN sentinel; an
    # `isnan` check distinguishes an untouched keyword from an explicit override.
    #   * switch ON  + keyword NaN (untouched)  -> Spain values 10.2693 / 1.0061.
    #   * switch ON  + keyword numeric          -> the user value wins.
    #   * switch OFF -> keyword value (default NaN) is stored as given; the UK branch of
    #     `calculate_down_payment` never reads these fields.
    # An explicit NaN with the switch ON cannot be told apart from the untouched default
    # and resolves to the Spain values; NaN is not a meaningful setting here.
    resolved_btl_downpayment_scale = (spain_btl_downpayment_distribution && isnan(btl_downpayment_scale)) ?
                                      Config.BTL_DOWNPAYMENT_SCALE_SPAIN_VALUE :
                                      Float64(btl_downpayment_scale)
    resolved_btl_downpayment_shape = (spain_btl_downpayment_distribution && isnan(btl_downpayment_shape)) ?
                                      Config.BTL_DOWNPAYMENT_SHAPE_SPAIN_VALUE :
                                      Float64(btl_downpayment_shape)

    # `resolved_expectations_gamma`, `resolved_expectations_zeta`,
    # `resolved_hpa_years_to_check` and `resolved_hpi_record_length` are computed
    # earlier, before `ModelParameters` is built: gamma and zeta feed the parameters,
    # while the lookback and the derived record length feed `ModelProperties` and the
    # `MarketStats.price_history` buffer.

    # This dictionary holds the global state of the simulation.
    props = ModelProperties(
        params,                 # The immutable rules object
        housing_stock,          # The mutable vector of passive assets
        market_stats,           # The Market Oracle
        bank,                   # The bank institution
        central_bank,           # The Regulatory Authority
        government,             # The government entity
        construction,           # The construction sector (Java: Model.construction)
        demographics,
        income_dist,
        wealth_dist,
        btl_prob,
        sale_markup_dist,
        rent_markup_dist,
        transaction_log,
        d22_use_realized_disposable_income,
        spain_gross_income_flow,
        spain_pdf_precision,
        # Spain-mode switches (each defaults to the UK behaviour):
        spain_soft_ltv_ftb,
        spain_soft_ltv_hm,
        spain_soft_ltv_btl,
        spain_soft_lti_btl,
        spain_application_income_gate,
        spain_application_age_ltv_gate,
        spain_bank_min_age,  # minimum applicant age floor (BANK_MIN_AGE_LIMIT)
        spain_btl_repayment_yield_formula,  # BTL yield-formula switch
        spain_consumption_recording,        # household consumption ledger
        spain_btl_repayment_mode,           # BTL routing (annuity + OO age-ladder + LTV/LTI/DSTI)
        spain_essential_nominal_consumption,# essential nominal consumption 0.0 -> 200.0 (household side)
        spain_dynamic_affordability_ceiling,# Bank DSTI hard-max ceiling
        spain_btl_alternative_return,       # BTL alternative-asset benchmark return switch
        resolved_btl_alternative_return,    # resolved Float64 value (UK 0.0 / Spain 0.040755 / kwarg override)
        spain_bank_age_limits,              # switch bundling BANK_AGE_LIMIT and MORTGAGE_DURATION_YEARS
        resolved_bank_age_limit,            # resolved Float64 (UK 65.0 / Spain 61.0 / kwarg override)
        resolved_mortgage_duration_years,   # resolved Int (UK 25 / Spain 30 / kwarg override)
        resolved_bank_min_age_limit,        # resolved Float64 (UK 0.0 / Spain 24.0 / kwarg override); gated by :spain_bank_min_age
        spain_btl_downpayment_distribution, # BTL down-payment LogNormal switch
        resolved_btl_downpayment_scale,     # resolved LogNormal scale (Spain 10.2693 / kwarg override / NaN sentinel when off)
        resolved_btl_downpayment_shape,     # resolved LogNormal shape (Spain 1.0061 / kwarg override / NaN sentinel when off)
        spain_expectations_naive,           # switch bundling gamma, zeta and the lookback
        resolved_hpa_years_to_check,        # resolved Int (UK 2 / Spain 4 / kwarg override) [Java: HPA_YEARS_TO_CHECK]
        resolved_hpi_record_length,         # derived ring-buffer length = lookback * 12 + 3 (UK 27 / Spain 51)
        spain_bank_calibration_values,      # switch for the bank prudential parameter bundle (18 keys)
        spain_distribution_calibration,     # switch for the distribution parameter bundle (18 keys + N_QUALITIES)
        resolved_uk_households,             # national household aggregate (Java UK_HOUSEHOLDS: UK 26442100 / Spain 18444200)
        resolved_houses_per_household,      # derived target-stock ratio (UK 0.8557 / Spain 0.9051)
        spain_population_scalars,           # switch for the population scalars (2 keys)
        spain_rent_buy_logit,                  # lambda + theta logit coupling switch (model paper Eq. 1)
        spain_btl_probability_multiplier,      # BTL Eq. 6 multiplier switch
        spain_market_avg_price_decay,          # MarketStats EMA decay switch (Java MARKET_AVERAGE_PRICE_DECAY)
        spain_demographics_dataset,            # age marginal dataset switch
        spain_income_age_joint_dataset,        # age x log-income joint dataset switch (use with :spain_pdf_precision)
        spain_income_wealth_joint_dataset,     # log-income x log-wealth joint dataset switch (use with :spain_pdf_precision)
        spain_btl_dataset,                     # BTL probability per income percentile dataset switch
        spain_sell_home_veto_affordability,    # sell-home veto on affordability and age > 35.0
        spain_sell_home_veto_upgrade,          # sell-home veto on upgrade quality and age > 45.0
        spain_btl_hard_rules_off,              # BTL_COMPAT_MODE off-wrapper switch
        spain_record_wealth_aggregates,        # three wealth-aggregate collectors (financial / housing-net / housing-gross)
        spain_btl_paper_maturity,              # BTL flat 25-year term and strict cut-off age (as in the model paper)
        seed
    )

    # -------------------------------------------------------
    # Create the StandardABM
    # -------------------------------------------------------
    # StandardABM with no space, so only the agent type is passed.
    model = StandardABM(
        Household;
        properties = props,
        rng = rng,
        agent_step! = agent_step!,          # Per-agent step function
        model_step! = model_step!       # Pass the function defined in Scheduler.jl
    )

    # -------------------------------------------------------
    # Populate agents
    # -------------------------------------------------------

    # Investor types (Table 12 of the model paper)
    # 1. Income Driven (delta = 0.1, p = 0.4927)
    # 2. Capital Gain Driven (delta = 0.9, p = 0.1458)
    # 3. Mixed (delta = 0.5, p = 0.3615)
    
    # -------------------------------------------------------
    # Populate agents (monthly age-bin loop)
    # -------------------------------------------------------
    # Follows the initialisation logic of Java's "Demographics.step()":
    # iterate through monthly age bins (young to old) using the interpolated distribution.
    
    # A. Calculate Targets per Monthly Bin
    monthly_probs = demographics.monthly_probs
    monthly_width = demographics.monthly_bin_width
    min_age = Float64(demographics.raw_bins[1][1])
    
    n_monthly_bins = length(monthly_probs)
    
    # Target counts are built from the cumulative distribution so that they sum exactly
    # to n_households. Java uses simple rounding `(int)Math.round(N * prob)`, which can give
    # a total different from N; the two approaches can therefore differ in bin counts and
    # the random-number sequence can diverge from Java.
    monthly_cdf = cumsum(monthly_probs)
    # Normalize cdf to ensure last element is exactly 1.0 (though it should be close)
    if monthly_cdf[end] > 0
        monthly_cdf = monthly_cdf ./ monthly_cdf[end]
    end
    
    target_counts = zeros(Int, n_monthly_bins)
    cumulative_target = 0
    
    for i in 1:n_monthly_bins
         target_at_i = round(Int, monthly_cdf[i] * n_households)
         target_counts[i] = target_at_i - cumulative_target
         cumulative_target = target_at_i
    end
    
    for bin_idx in 1:n_monthly_bins
        n_in_bin = target_counts[bin_idx]

        for _ in 1:n_in_bin
            # 1. Sample Age (Restricted to Monthly Bin)
            # Bin j corresponds to [min + (j-1)*w, min + j*w]
            bin_start_age = min_age + (bin_idx - 1) * monthly_width
            
            # Uniform within the month (Java Parity)
            age = bin_start_age + rand(rng) * monthly_width
            
            # 2. Sample Income Percentile - MATCHING JAVA SEQUENCE
            # Java: incomePercentile = prng.nextDouble();
            income_percentile = rand(rng)
            
            # 3. Calculate Income from Percentile
            # Java: annualGrossEmploymentIncome = getAnnualGrossEmploymentIncome(age, incomePercentile);
            annual_income = calculate_income_from_rank(age, income_percentile, income_dist;
                # Spain income floor applied at draw time during initial agent
                # construction. Default false keeps the UK floor.
                spain_essential_nominal_consumption = spain_essential_nominal_consumption,
            )
            
            # 4. Propensity to Save
            # Java: propensityToSave = prng.nextDouble();
            propensity_to_save = rand(rng)

            # 5. Calculate Wealth - MATCHING JAVA DEPENDENCY
            # Java: getDesiredBankBalance(..., propensityToSave);
            wealth = calculate_wealth_from_rank(annual_income, propensity_to_save, wealth_dist)
            
            # 6. Determine BTL status inline - MATCHING JAVA CONSTRUCTOR
            # Logic: if rand() < Prob(percentile) * Adjustment
            is_btl = false
            btl_coeff = 0.0
            
            # Lookup for BTL probability.
            # Bin edges (bin_uppers) map income_percentile to the correct bin, which handles
            # both UK (100 bins, 1%-width) and Spain (20 bins, 5%-width) automatically.
            # searchsortedfirst returns the index of the first bin whose upper edge is >= income_percentile.
            btl_bin_idx = searchsortedfirst(btl_prob.bin_uppers, income_percentile)
            if btl_bin_idx > length(btl_prob.probabilities)
                btl_bin_idx = length(btl_prob.probabilities)
            end
            raw_prob = btl_prob.probabilities[btl_bin_idx] 
            
            if rand(rng) < (raw_prob * resolved_btl_probability_adjustment)
                 is_btl = true
                 
                 # Assign investor type
                 type_roll = rand(rng)
                 
                 if type_roll < Config.BTL_P_INCOME_DRIVEN
                     # Type 1: Rental-Income Driven (delta = 0.1)
                     btl_coeff = Config.BTL_INCOME_DRIVEN_CAP_GAIN_COEFF
                 elseif type_roll < (Config.BTL_P_INCOME_DRIVEN + Config.BTL_P_CAPITAL_DRIVEN)
                     # Type 2: Capital-Gains Driven (delta = 0.9)
                     btl_coeff = Config.BTL_CAPITAL_DRIVEN_CAP_GAIN_COEFF
                 else
                     # Type 3: Mixed (delta = 0.5)
                     btl_coeff = Config.BTL_MIX_DRIVEN_CAP_GAIN_COEFF
                 end
            end

            # Initial State: Born in Social Housing, defined as FTB
            add_agent!(
                    model, 
                    Float64(age),                      # Age
                    income_percentile,                 # Income Percentile
                    wealth,                            # Bank Balance
                    annual_income,                     # Annual Income
                    propensity_to_save,                # Propensity to save
                    is_btl,                            # Is BTL?
                    btl_coeff,                         # BTL Coeff      
                    nothing,                           # Residence (Initial = Social Housing)
                    nothing,                           # Rental Agreement (None)
                    Int[],                             # Properties Owned (Empty)
                    Mortgage[],                        # Mortgages (Empty)
                    ConsumptionObservation(),           # consumption_observation (invalid until the first consumption update)
                    Mortgage[],                        # Zombie Debts (Empty; populated only when JAVA_COMPAT_MODE = true)
                    SocialHousing,                     # Tenure (Enum)
                    0.0,                               # Desired Purchase Price (Initial)
                    FTB,                               # Borrower Logic (Enum)
                    0.0,                               # realized_disposable_income
                    0.0,                               # persistent_lti_limit (frozen at bid-time)
                    0.0                                # persistent_ltv_limit (frozen at bid-time)
                )
        end
    end

    # -----------------------------------------------------------------------
    # Create and distribute the housing stock
    # -----------------------------------------------------------------------
    # The entire housing stock is distributed at random among existing households.
    # Follows Java's interleaved creation and assignment
    # (Construction.java, line 58, while shortFall > 0 loop):
    # create house -> assign quality -> select owner -> inherit -> repeat.
    # Java `Construction.step()` calls `new House` (random draw for quality).
    
    # A. Pre-calculate theoretical reference prices
    # Needed by `inherit_house!` (valuation) before the market is active.
    # Matches Java's use of static distribution parameters for initial valuation.
    
    for q in 1:n_qualities
        percentile = (q - 0.5) / n_qualities
        ref_prices[q] = quantile(price_dist, percentile)
        ref_rents[q] = quantile(rent_dist, percentile)
    end
    
    # Seed the market statistics with these theoretical starting values
    market_stats.ema_prices_by_quality .= ref_prices
    market_stats.ema_rents_by_quality .= ref_rents
    market_stats.reference_prices_by_quality .= ref_prices
    market_stats.reference_rents_by_quality .= ref_rents
    
    # EXACT JAVA PARITY:
    # Java HousingMarketStats.getAvReferencePrice() calculates the SIMPLE MEAN of the quality bands.
    # It strictly ignores the realized distribution (weights) of the actual housing stock.
    # See HousingMarketStats.java: getAvReferencePrice()
    initial_global_reference_price = mean(ref_prices)
    initial_global_reference_rent = mean(ref_rents)
    
    market_stats.ema_sales_price = initial_global_reference_price
    market_stats.ema_rent = initial_global_reference_rent
    market_stats.reference_price = initial_global_reference_price
    market_stats.reference_rent = initial_global_reference_rent
    # price_history is already initialised to 1.0 (dimensionless HPI),
    # as Java fills HPIRecord with 1.0 in init(); no overwrite is needed.

    # B. Main construction and assignment loop
    all_agent_ids = collect(allids(model))
    
    for i in 1:n_houses
        # 1. Assign Quality Uniformly at Random (RNG: Quality)
        # Java Parity: (int)(prng.nextDouble() * config.derivedParams.N_QUALITIES)
        # We must use `rand(rng)` (float) to consume the RNG state identically to Java's nextDouble().
        # Java returns 0-based index [0, N-1]. Julia uses 1-based [1, N].
        quality = Int(floor(rand(rng) * n_qualities)) + 1
        
        # 2. Determine Pricing (Deterministic given Quality)
        percentile = (quality - 0.5) / n_qualities
        base_sale_price = quantile(price_dist, percentile)
        base_rent_price = quantile(rent_dist, percentile)

        # 3. Create House Object
        # Initially off-market. Ownership established below by inherit_house!.
        new_house = House(
            i,                  # id
            quality,            # quality
            nothing,            # owner_id (Pending assignment)
            nothing,            # resident_id
            false,              # is_for_sale (Set by inheritor logic)
            base_sale_price,    # sale_listing_price
            0,                  # months_on_sales_market
            false,              # is_for_rent (Set by inheritor logic)
            base_rent_price,    # rental_listing_price
            0                   # months_on_rental_market
        )
        
        # Add to global stock
        push!(housing_stock, new_house)
        
        # 4. Select Owner (RNG: Selection of Agent)
        # Java: Model.households.get(prng.nextInt(Model.households.size()))
        owner_id = rand(rng, all_agent_ids)
        owner = model[owner_id]
        
        # 5. Execute Inheritance Logic
        inherit_house!(owner, new_house, model)
    end 
    
    # Note: `initial_prices_q` need not be updated and the housing stock need not be
    # iterated again, because the reference prices are derived from the theoretical
    # distribution parameters (step A), matching Java's static "getAvReferencePrice".

    # ------------------------------------------------------------------
    # Post-housing-loop: sync the Construction sector
    # ------------------------------------------------------------------
    # Java divergence: in Java, housingStock starts at 0 and is built up by
    # construction.step() from t = 0.  Here the houses are pre-created above
    # to keep the random-number sequence aligned with Java.  The
    # housing_stock_count counter is therefore synchronised now, before the
    # model loop starts, so that construction_step! sees the correct baseline
    # and does not rebuild the entire stock at t = 0.
    # Java call site: Model.java init() line 171 (construction.init())
    construction.housing_stock_count = length(housing_stock)
    construction.n_new_build         = 0
    # on_market omitted — see Construction struct docstring in Types.jl

    return model
end