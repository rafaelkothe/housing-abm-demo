# src/core/Config.jl
#
# Central configuration of the housing-market model: switches, feature flags and
# numerical constants, collected in the module `Config` and read elsewhere as
# `Config.<NAME>`.
#
# Contents, in file order:
#   - switches between the paper's reading of a mechanism and the original Java
#     implementation, each read from an environment variable at load time;
#   - the registry of Spain-specific mechanism flags (`SPAIN_MECHANISMS`,
#     `SPAIN_ALL_ON`);
#   - ordering and diagnostic switches, simulation meta-parameters, behavioural
#     parameters and the constants of the banking and central-bank sector.
#
# Everything is declared `const`, so values are fixed when the module is loaded;
# environment variables must be set before Julia is started.

module Config

    # ---------------------------------------------------------------------------
    # SWITCHES BETWEEN THE PAPER AND THE ORIGINAL JAVA IMPLEMENTATION
    # ---------------------------------------------------------------------------
    # Several mechanisms can be implemented either as described in the model paper
    # (Carro et al., 2022) or as in the original Java code. Each alternative is
    # selected by a `const Bool` below, read from an environment variable when the
    # module is loaded. Being constants, the switches are resolved at compile time
    # and are inferred exactly at every call site.
    #
    # In the descriptions, "Java behaviour" is the behaviour of the Java class and
    # method named in the text; "paper behaviour" follows the equation or section
    # of the paper named in the text. Unless stated otherwise the switches are
    # independent of each other and can be changed one at a time, for example
    #   D1_GAZUMPING_COMPAT=true julia --project=. scripts/run_working_data.jl <OUTPUT_DIR>
    #
    # Spain-specific mechanisms are not controlled by these constants; they are
    # selected per model instance through the `SPAIN_MECHANISMS` flags below.

    # ---------------------------------------------------------------------------
    # BTL_COMPAT_MODE: force-buy and sell floor for buy-to-let investors
    # ---------------------------------------------------------------------------
    # Two rules of the Java model (HouseholdBehaviour.java) that the paper does not
    # describe are controlled together by this flag:
    #   - First investment purchase (decideToBuyInvestmentProperty): an investor who
    #     owns fewer than two properties always decides to buy, bypassing the
    #     yield-based purchase decision (paper Eqs 7-8, Section 3.3.2). The
    #     investor wealth gate still applies.
    #   - Sell floor (decideToSellInvestmentProperty): an investor who owns fewer
    #     than three properties never sells an investment property, so the first
    #     investment property is kept permanently. A maturity-driven forced sale
    #     overrides the floor. The paper (Eqs 10-11) sets no minimum portfolio size.
    #
    #   true  (default): both rules are active, as in the Java model.
    #   false: the logistic, yield-based entry and exit decisions of the paper
    #          govern at every portfolio size.
    #
    # Read in HouseholdBehavior.jl by evaluate_investment_entry (force-buy) and
    # evaluate_investor_exit (sell floor); both guards also test
    # `model.spain_btl_hard_rules_off`.
    # Override: BTL_COMPAT_MODE=false julia ...
    const BTL_COMPAT_MODE  = get(ENV, "BTL_COMPAT_MODE",  "true")  == "true"

    # ---------------------------------------------------------------------------
    # SPAIN MECHANISM FLAGS
    # ---------------------------------------------------------------------------
    # Mechanisms that differ between the UK and the Spanish versions of the Java
    # model are switched on individually: `initialize_model()` takes one plain
    # `Bool` keyword argument per mechanism, default `false` (UK behaviour).
    # Consumer code branches on its own per-mechanism flag only (for example
    # `model.spain_gross_income_flow`); there is no master switch.
    #
    #   SPAIN_MECHANISMS  tuple of all mechanism symbols; the single list from which
    #                     the other definitions are derived or checked.
    #   SPAIN_ALL_ON      NamedTuple setting every mechanism to `true`, derived from
    #                     SPAIN_MECHANISMS.
    #
    # Usage:
    #   UK:               initialize_model()
    #   Spain:            initialize_model(; Config.SPAIN_ALL_ON...)
    #   UK plus one:      initialize_model(; spain_gross_income_flow = true)
    #   Spain minus one:  initialize_model(; Config.SPAIN_ALL_ON..., spain_gross_income_flow = false)
    #
    # Initialization.jl asserts at load time that its list of Spain keyword
    # arguments equals SPAIN_MECHANISMS, so the two cannot drift apart. Where a
    # mechanism changes a parameter default to its Spanish value, an explicitly
    # passed keyword argument for that parameter takes precedence.
    const SPAIN_MECHANISMS = (
        # Income flow is taken gross of tax; ESSENTIAL_NOMINAL_CONSUMPTION is applied.
        :spain_gross_income_flow,
        # Higher precision of the load-time inverse-CDF tables, as in the Spanish
        # Pdf.java: 100 -> 100000 samples and 2048 -> 262144 integration steps, plus
        # a correction of the phantom tail at the support limits (getStart/getEnd).
        # The tables are consumed by D7_INCOME_COMPAT (default false) and
        # D7_WEALTH_COMPAT (default true); the latter affects wealth draws at high
        # percentiles of the low-income groups.
        :spain_pdf_precision,
        # Soft-LTV-cap bookkeeping on CentralBank/Bank for first-time buyers:
        # counters of mortgages above the soft maximum LTV, adaptive target and
        # history vector. Gates struct-field writes and counter updates only.
        :spain_soft_ltv_ftb,
        # Same soft-LTV-cap bookkeeping for home movers.
        :spain_soft_ltv_hm,
        # Same soft-LTV-cap bookkeeping for buy-to-let borrowers, including the
        # realised-counter triple shared with :spain_soft_lti_btl.
        :spain_soft_ltv_btl,
        # Soft-LTI-cap bookkeeping for buy-to-let borrowers (counters, adaptive
        # target, history vector). The UK soft-LTI switch IS_SOFT_LIMIT_ACTIVE is
        # kept for first-time buyers and home movers.
        :spain_soft_lti_btl,
        # Application-income carve-out: `application_income_percentile` and
        # `application_income` scalars on CentralBank, recomputed every step by
        # central_bank_step!.
        :spain_application_income_gate,
        # LTV age carve-out: `application_age_ltv` scalar on CentralBank.
        :spain_application_age_ltv_gate,
        # BANK_MIN_AGE_LIMIT floor on the number of payments (Spanish Bank.java:
        # `if (age < BANK_MIN_AGE_LIMIT) return 0`). Consumers: evaluate_credit and
        # calculate_buying_power. The limit defaults to 0.0 (UK) and to 24.0 under
        # this flag.
        :spain_bank_min_age,
        # Expected equity yield of a buy-to-let purchase or sale is computed as
        # `principal * annual_rate / equity` (forward-looking interest carry) instead
        # of `nextPayment * 12 / equity`. The two are identical for interest-only
        # mortgages and differ once buy-to-let loans amortise
        # (:spain_btl_repayment_mode).
        :spain_btl_repayment_yield_formula,
        # Five per-step consumption counters on MarketStats: rental housing,
        # interest payments, principal repayments, down payments and non-housing
        # consumption. Collector only; no decision reads them.
        :spain_consumption_recording,
        # Buy-to-let applications are routed through the owner-occupier branch
        # (Spanish Bank.java, `isHome = true` when buy-to-let mortgages are not
        # interest-only):
        #   - underwriting uses LTV, LTI and DSTI; the ICR test is not applied;
        #   - monthly payments follow the annuity formula instead of interest-only;
        #   - the mortgage term follows the owner-occupier age ladder (shorter past
        #     age 40, zero past 65) instead of a flat 25 years up to age 65.
        # Under this flag the soft-LTI cap for buy-to-let (:spain_soft_lti_btl) takes
        # effect in evaluate_credit, and :spain_btl_repayment_yield_formula becomes
        # economically meaningful.
        :spain_btl_repayment_mode,
        # ESSENTIAL_NOMINAL_CONSUMPTION changes from 0.0 (UK) to 200.0
        # (ESSENTIAL_NOMINAL_CONSUMPTION_SPAIN_VALUE) at the household-side sites:
        # disposable-income floor, rental-bid cap, non-housing consumption addend
        # and income floor at draw time (ESSENTIAL_NOMINAL_CONSUMPTION * 12).
        :spain_essential_nominal_consumption,
        # Bank DSTI hard-maximum ceiling `1 - ESSENTIAL_NOMINAL_CONSUMPTION /
        # gross_monthly_income` in evaluate_credit and calculate_buying_power. It
        # reads the same ESSENTIAL_NOMINAL_CONSUMPTION_SPAIN_VALUE as the household
        # flag above but is switched separately, so the household and bank effects
        # can be isolated.
        :spain_dynamic_affordability_ceiling,
        # BTL_ALTERNATIVE_RETURN changes from 0.0 (UK) to 0.040755 (about 4.08 % a
        # year, an alternative-asset benchmark). It is subtracted from the weighted
        # return in the buy-to-let buy and sell valuations in HouseholdBehavior.jl.
        :spain_btl_alternative_return,
        # BANK_AGE_LIMIT changes from 65 to 61 and MORTGAGE_DURATION_YEARS from 25 to
        # 30; the two enter together in the owner-occupier payment-count algebra
        # (BANK_AGE_LIMIT - MORTGAGE_DURATION_YEARS). Read as `model.bank_age_limit`
        # and `model.mortgage_duration_years` in Bank.jl, HousingMarket.jl and
        # HouseholdBehavior.jl.
        :spain_bank_age_limits,
        # Buy-to-let down payment is HPI times the quantile of a LogNormal
        # distribution at the household's income percentile (a monetary amount,
        # deterministic, no random draw) instead of a Normal fraction times the
        # price. Applies to the buy-to-let branch of calculate_down_payment only;
        # D16_BTL_DP_NO_UPPER_CLAMP is irrelevant under this flag.
        :spain_btl_downpayment_distribution,
        # Price-expectation parameters change together: expectations_gamma 0.44 -> 1.0,
        # expectations_zeta -0.007 -> 0.0 and HPA_YEARS_TO_CHECK 2 -> 4. The HPI
        # ring-buffer length HPI_RECORD_LENGTH = HPA_YEARS_TO_CHECK * 12 + 3 grows from
        # 27 to 51. Consumed in HouseholdBehavior.jl::calc_expected_growth and
        # MarketStats.jl::update_market_stats!.
        :spain_expectations_naive,
        # Bank and central-bank parameter bundle (18 values): hard caps for LTV, LTI,
        # DSTI and ICR, the policy rate, initial credit supply, interest-rate
        # elasticity, the soft-LTI cap/quota pair for first-time buyers and home
        # movers, and the central-bank affordability and ICR floors. The defaults
        # are replaced by Spanish values in Initialization.jl only when the keyword
        # argument still equals its UK constant.
        :spain_bank_calibration_values,
        # Distribution and behaviour parameter bundle (18 values): house-price and
        # rental-price LogNormal seeds, the home-mover/owner-occupier down-payment
        # LogNormal pair, the buy-to-let Normal-mode mean and epsilon, the
        # desired-purchase-budget Pdf coefficients, the rental-bid coefficients, the
        # maximum tenancy length, the consumption windfall cap share and the average
        # holding period (with the dependent N_QUALITIES value). Replaced in
        # Initialization.jl under the same rule as above.
        :spain_distribution_calibration,
        # National population aggregates UK_HOUSEHOLDS and UK_DWELLINGS (names kept
        # from the Java model). They determine HOUSES_PER_HOUSEHOLD (target stock in
        # Construction.jl) and the scaling factor of reporting indicators in
        # DataCollection.jl.
        :spain_population_scalars,
        # Rent-or-buy logit pair (paper Eq. 1) changes together:
        # PSYCHOLOGICAL_COST_OF_RENTING 0.4 -> 0.8 and
        # SENSITIVITY_RENT_OR_PURCHASE 0.001 -> 0.01.
        :spain_rent_buy_logit,
        # Buy-to-let probability multiplier (paper Eq. 6, field
        # `btl_probability_adjustment`) changes from 1.76 to 1.6.
        :spain_btl_probability_multiplier,
        # Relaxation weight of the average-price exponential moving average in
        # MarketStats (Java MARKET_AVERAGE_PRICE_DECAY, Julia MIX_ADJUSTMENT_WEIGHT,
        # field `mix_adjustment_weight`) changes from 0.5 to 0.7.
        :spain_market_avg_price_decay,
        # Each of the four dataset flags replaces one empirical-distribution CSV by
        # its Spanish counterpart; the path is chosen in
        # Initialization.jl::_init_from_files. The mark-up CSVs are not replaced.
        # Age marginal: Age9-Weighted.csv -> EFF-Age9.csv.
        :spain_demographics_dataset,
        # Age x log-income joint distribution: AgeGrossIncomeJointDist.csv ->
        # EFF-AgeGrossIncomeJointDist-NoHouseSaleProfits-MI.csv.
        :spain_income_age_joint_dataset,
        # Log-income x log-wealth joint distribution:
        # GrossIncomeNetWealthJointDist.csv -> EFF-GrossIncomeNetWealthJointDist.csv.
        :spain_income_wealth_joint_dataset,
        # Buy-to-let probability per income-percentile bin:
        # BTLProbabilityPerIncomePercentileBin.csv ->
        # EFF-BTLProbabilityPerIncomePercentileBin.csv.
        :spain_btl_dataset,
        # Two owner-occupier vetoes from the Spanish HouseholdBehaviour.java, checked
        # in decision_owner_occupier_sell! between the buy-to-let early exit and the
        # exogenous-moving draw. The UK decideToSellHome has no such vetoes.
        # This one blocks listing when the desired purchase price exceeds the maximum
        # mortgage price and the agent is older than 35.
        :spain_sell_home_veto_affordability,
        # Blocks listing when the highest quality affordable with net wealth is no
        # better than the current home's quality and the agent is older than 45.
        :spain_sell_home_veto_upgrade,
        # Adds a `!model.spain_btl_hard_rules_off` condition to the two existing
        # BTL_COMPAT_MODE guards in HouseholdBehavior.jl (force-buy and sell floor),
        # disabling both rules for Spain. The Spanish Java code has them commented out.
        :spain_btl_hard_rules_off,
        # Enables three wealth aggregate collectors (financial, net housing, gross
        # housing wealth) in DataCollection.jl. Observational only; when off, each
        # collector returns 0.0 without iterating over agents.
        :spain_record_wealth_aggregates,
        # Only has an effect together with :spain_btl_repayment_mode. Buy-to-let
        # keeps annuity payments and LTV + LTI + DSTI underwriting but uses the flat
        # 25-year term with a strict age cut-off instead of the owner-occupier age
        # ladder, as described in the paper (Section 3.4).
        :spain_btl_paper_maturity,
    )
    const SPAIN_ALL_ON = NamedTuple{SPAIN_MECHANISMS}(ntuple(_ -> true, length(SPAIN_MECHANISMS)))

    # ---------------------------------------------------------------------------
    # PAPER VERSUS JAVA SWITCHES
    # ---------------------------------------------------------------------------
    # Each flag below has its own default and can be overridden through the
    # environment variable of the same name to run isolation experiments, e.g.
    #   D1_GAZUMPING_COMPAT=true julia --project=. scripts/run_working_data.jl <OUTPUT_DIR>
    #   D7_MARKUP_COMPAT=true   julia --project=. scripts/run_working_data.jl <OUTPUT_DIR>
    #   D7_WEALTH_COMPAT=true D1_GAZUMPING_COMPAT=true julia --project=. scripts/run_working_data.jl <OUTPUT_DIR>
    #
    # The three D7_* flags concern the sampling of empirical distributions in
    # EmpiricalLoader.jl. The Java class `utilities.Pdf` builds a 100-point
    # inverse-CDF lookup table by numerical integration and samples it by linear
    # interpolation. Its last table entry is pinned to the upper edge of the last
    # bin even when that bin has zero probability, so draws at extreme percentiles
    # are extrapolated beyond the support of the data.
    #   true:  sample from the 100-point Java table (java_inverse_cdf_lookup).
    #   false: exact inverse CDF on the empirical bin probabilities.
    # The accuracy of the tables is set by `:spain_pdf_precision`.

    # D7_MARKUP_COMPAT: sale and rent mark-up distributions (sample_markup).
    # Default false. The exact path draws twice (bin selection, then a uniform draw
    # within the bin); the Java path draws once. The difference is largest at the
    # extreme percentiles and affects the listing-price distribution there.
    const D7_MARKUP_COMPAT = get(ENV, "D7_MARKUP_COMPAT", "false") == "true"

    # D7_WEALTH_COMPAT: wealth target drawn given income (calculate_wealth_from_rank).
    # Default true: the Java table is used. At extreme percentiles it extrapolates
    # into zero-probability bins and strongly inflates the wealth draw, which raises
    # savings targets and buying power for the agents drawn there.
    const D7_WEALTH_COMPAT = get(ENV, "D7_WEALTH_COMPAT", "true") == "true"

    # D7_INCOME_COMPAT: income drawn given age (calculate_income_from_rank).
    # Default false. The income tables have no zero-probability tail bins, so the
    # Java table differs from the exact path only marginally at the top percentiles.
    # Provided so that each of the three distribution switches can be set alone.
    const D7_INCOME_COMPAT = get(ENV, "D7_INCOME_COMPAT", "false") == "true"

    # D1_GAZUMPING_COMPAT: outcome of competitive bidding on a listing when the
    # raised price exceeds every bidder's budget (HousingMarket.jl). The seller raises
    # the price a geometrically distributed number of times; if no bidder survives:
    #   true  (default, Java behaviour, HousingMarket.clearMatches): the highest
    #         bidder wins and pays their own submitted bid, so the seller captures
    #         the surplus over the listing price.
    #   false (paper behaviour): the sale falls back to the listing price and the
    #         winner is drawn uniformly at random among all bidders, since the seller
    #         cannot observe maximum budgets (Carro et al. 2022, Footnote 21).
    const D1_GAZUMPING_COMPAT = get(ENV, "D1_GAZUMPING_COMPAT", "true") == "true"

    # D1_RENTAL_COMPAT: the same fallback in rental clearing (RentalMarket.jl). If no
    # applicant survives the bid-up: true means the highest applicant wins at their
    # own submitted budget; false means the original asking rent applies and the
    # winner is drawn at random.
    # Defaults to the value of D1_GAZUMPING_COMPAT, so sales and rentals behave
    # alike unless this variable is set explicitly. Examples:
    #   D1_GAZUMPING_COMPAT=true                             sales and rentals
    #   D1_GAZUMPING_COMPAT=true D1_RENTAL_COMPAT=false      sales only
    #   D1_GAZUMPING_COMPAT=false D1_RENTAL_COMPAT=true      rentals only
    const D1_RENTAL_COMPAT = haskey(ENV, "D1_RENTAL_COMPAT") ?
        (ENV["D1_RENTAL_COMPAT"] == "true") : D1_GAZUMPING_COMPAT

    # D5_DOWN_PAYMENT_COMPAT: price on which the down payment is computed in
    # decide_rent_or_buy (HouseholdBehavior.jl). It matters only for buyers whose
    # target quality is the top quality band, where the prime-capped price
    # p'_d = min(p_d, p_Qmax) (paper Eq. 2) is below the bank-capped budget; for
    # all other agents purchase_price equals budget.
    #   false (default, paper behaviour): down payment, mortgage principal and cost
    #         comparison all use the prime-capped purchase price.
    #   true  (Java behaviour, Household.bidForAHome): decideDownPayment is evaluated
    #         on the bank-capped budget before the prime cap is applied, while the
    #         mortgage is still evaluated on the capped price.
    # The bank approves the loan against the actual transaction price in both modes.
    const D5_DOWN_PAYMENT_COMPAT = get(ENV, "D5_DOWN_PAYMENT_COMPAT", "false") == "true"

    # Further paper-versus-Java switches, all defaulting to false (paper behaviour).
    #
    # D3_ZOMBIE_DEBT: mortgage not covered by the sale proceeds when a house is sold
    #   (execute_transaction!, HousingMarket.jl). Java's MortgageAgreement.payoff(amount)
    #   repays at most the available balance and leaves the rest as a residual loan.
    #   true  (Java behaviour): the seller pays min(post-sale balance, remaining
    #         principal) into the bank's cash reserves. Any residual stays in
    #         `seller.zombie_debts` with its monthly payment scaled down and is
    #         serviced monthly in process_income_and_obligations! until repaid. The
    #         bank's outstanding credit falls by the full principal at sale in both
    #         modes. Residual loans of a deceased agent are discharged in full in
    #         Demographics.jl, crediting only the bank's cash reserves.
    #   false (paper behaviour): full discharge at sale; cash reserves rise by the
    #         whole remaining principal and the mortgage record is removed. Negative
    #         seller equity is resolved by the insolvency bailout.
    #
    # D2_SELF_OWNERSHIP_GUARD: candidate houses owned by the bidder in
    #   select_best_house (HousingMarket.jl).
    #   true  (Java behaviour, HousingMarket.matchBidsWithOffers): the best candidate
    #         is taken without an ownership filter and the whole bid is dropped if the
    #         bidder owns it; the agent bids again next month. For buy-to-let bidders
    #         the cheapest house of each tier is the tier candidate and the check is
    #         made on the globally best candidate; for owner-occupier bidders the
    #         first affordable house is the candidate.
    #   false (paper behaviour): self-owned houses are skipped and the next valid
    #         candidate is used in the same round, since "available" in the matching
    #         rule excludes self-owned houses (Section 3.5).
    #
    # D4_INHERITANCE_OVERPAY: payment of a deceased agent's mortgages from their bank
    #   balance (Demographics.jl). In both modes the bank's outstanding credit falls
    #   by the full principal.
    #   false (paper behaviour, Appendix A.2): payment = min(balance, outstanding
    #         principal); any shortfall is written off and the balance stays
    #         non-negative.
    #   true  (Java behaviour, Household.transferAllWealthTo calling payoff() without
    #         argument): payment = full outstanding principal, so the balance can go
    #         negative; the heir receives max(0, balance).
    #
    # D6_BIDUP_FLOOR: factor b in the bid-up probability for n bidders (paper Eq. 20,
    #   Footnote 45), used in resolve_price_bidding! (HousingMarket.jl) and
    #   resolve_rental_bidding! (RentalMarket.jl).
    #   false (paper behaviour): b = max(log10(n), 1.0), continuous.
    #   true  (Java behaviour, integer cast in HousingMarket.clearMatches):
    #         b = max(floor(Int, log10(n)), 1), a step function.
    #   The two differ only for n >= 11 bidders.
    const D3_ZOMBIE_DEBT          = get(ENV, "D3_ZOMBIE_DEBT",          "false") == "true"
    const D2_SELF_OWNERSHIP_GUARD = get(ENV, "D2_SELF_OWNERSHIP_GUARD", "false") == "true"
    const D4_INHERITANCE_OVERPAY  = get(ENV, "D4_INHERITANCE_OVERPAY",  "false") == "true"
    const D6_BIDUP_FLOOR          = get(ENV, "D6_BIDUP_FLOOR",          "false") == "true"

    # D11_RENTAL_CONTRACTED_RENT: rent counted as a landlord's rental income when
    # calc_rental_budget (HouseholdBehavior.jl) reconstructs it from owned, occupied
    # properties.
    #   false (default, paper behaviour): the house's current asking rent
    #         (`house.rental_price`).
    #   true  (Java behaviour, Household.getMonthlyGrossRentalIncome): the tenant's
    #         contracted rent (`rental_agreement.monthly_rent`), fixed at lease signing.
    # The two values coincide while a house is occupied, because the asking rent of a
    # tenanted house is not revised.
    const D11_RENTAL_CONTRACTED_RENT = get(ENV, "D11_RENTAL_CONTRACTED_RENT", "false") == "true"

    # D13_BTL_INTEREST_FULL_GUARD: which buy-to-let loans contribute interest to the
    # tax-relief reconstruction in process_discretionary_consumption!
    # (FinancialFlows.jl). Java (Household.getAnnualFinanceCosts) applies the same
    # conditions as the income-and-obligations step; the UK paper (Footnote 6) grants
    # relief only for rented-out properties.
    #   true  (default, Java behaviour): the loan must be on a property other than the
    #         agent's residence, have an active mortgage (term and payment positive),
    #         and be on an occupied property whose tenant pays rent (positive rent and
    #         months remaining).
    #   false: any loan on a property other than the residence counts, so vacant
    #         properties also receive tax relief, which raises disposable income in
    #         the consumption formula.
    const D13_BTL_INTEREST_FULL_GUARD = get(ENV, "D13_BTL_INTEREST_FULL_GUARD", "true") == "true"

    # D16_BTL_DP_NO_UPPER_CLAMP: bound on the buy-to-let down-payment fraction drawn
    # from Normal(btl_downpayment_mu, btl_downpayment_sigma) in calculate_down_payment
    # (HouseholdBehavior.jl).
    #   false (default): the fraction is clamped to [0, 1].
    #   true  (Java behaviour, HouseholdBehaviour.java): it is floored at zero only,
    #         so it can exceed 1 in principle.
    # The two differ only for draws above 1, which is extremely unlikely for the
    # default mean and standard deviation.
    const D16_BTL_DP_NO_UPPER_CLAMP = get(ENV, "D16_BTL_DP_NO_UPPER_CLAMP", "false") == "true"

    # D17_RENTAL_BID_NO_FLOOR: lower bound on the maximum affordable rent
    # r_max = net income - essential consumption in calc_rental_budget
    # (HouseholdBehavior.jl).
    #   false (default): r_max = max(0, r_max), so rental bids are never negative.
    #   true  (Java behaviour, HouseholdBehaviour.getDesiredRentPrice): no floor; a
    #         negative r_max can become the bid through min(desired, r_max).
    # Only agents whose net income is below essential consumption are affected.
    const D17_RENTAL_BID_NO_FLOOR = get(ENV, "D17_RENTAL_BID_NO_FLOOR", "false") == "true"

    # D18_PRE_INCOME_BEHAVIORAL: timing of update_behavioral_state! within the step
    # (Scheduler.jl, model_step!).
    #   false (default, paper behaviour, Section 3.1 Steps 2a/2b): the update runs
    #         after income and obligations, discretionary consumption and insolvency
    #         resolution, so decisions use end-of-month wealth.
    #   true  (Java behaviour, Household.step): the desired purchase price is updated
    #         first, before income is credited, so decisions use wealth that is one
    #         month's income lower. The later update is then skipped.
    const D18_PRE_INCOME_BEHAVIORAL = get(ENV, "D18_PRE_INCOME_BEHAVIORAL", "false") == "true"

    # ND31_DIAGNOSTIC: optional instrumentation of the housing-stock state.
    # When true, nd31_log_phase! (Scheduler.jl), called after each sub-phase of
    # model_step!, appends one CSV row to ND31_LOG_PATH with the columns
    # step, phase_id, n_total, n_vacant, n_unlisted, n_for_sale, n_for_rent.
    # "Unlisted" means vacant and neither for sale nor for rent.
    # Default false. The logging is read-only and consumes no random numbers.
    const ND31_DIAGNOSTIC = get(ENV, "ND31_DIAGNOSTIC", "false") == "true"
    const ND31_LOG_PATH   = get(ENV, "ND31_LOG_PATH", "output/ND31_phase_trace.csv")

    #
    # MODES:
    #   :OFF   — Down-payment computed at CLEARING TIME for ALL bidders.
    #            Paper-faithful for BTL; paper-divergent for OO/FTB.
    #   :ON    — Down-payment computed at BID TIME for ALL bidders (Java parity).
    #            Paper-faithful for OO/FTB; paper-divergent for BTL.
    #   :PAPER — Path-asymmetric: BID TIME for OO/FTB, CLEARING TIME for BTL.
    #            Paper-faithful on BOTH legs (Carro 2022 §3 compliant).
    #
    # ISOLATION:  D19_MODE=PAPER julia --project=. scripts/run_working_data.jl <OUTPUT_DIR>    # production default
    #             D19_MODE=ON    julia --project=. scripts/run_working_data.jl <OUTPUT_DIR>    # Java behaviour
    #             D19_MODE=OFF   julia --project=. scripts/run_working_data.jl <OUTPUT_DIR>    # clearing-time down payment
    #
    # OLDER ENV VARIABLE NAMES (still accepted):
    #   D19_BID_TIME_DOWN_PAYMENT=true   → D19_MODE=:ON       (overrides default)
    #   D19_SPLIT_PAPER=false            → D19_MODE=:OFF      (only if D19_MODE unset
    #                                                          and D19_BID_TIME unset)
    #   When both legacy vars set with conflicting intent, D19_BID_TIME_DOWN_PAYMENT
    #   wins (matches the legacy precedence rule).
    const D19_MODE = let
        explicit = get(ENV, "D19_MODE", "")
        legacy_bid = get(ENV, "D19_BID_TIME_DOWN_PAYMENT", "")
        legacy_split = get(ENV, "D19_SPLIT_PAPER", "")
        mode = if !isempty(explicit)
            sym = Symbol(uppercase(explicit))
            sym in (:OFF, :ON, :PAPER) || error("Invalid D19_MODE=$(explicit); expected one of OFF, ON, PAPER")
            sym
        elseif legacy_bid == "true"
            @warn "D19_BID_TIME_DOWN_PAYMENT is deprecated; use D19_MODE=ON"
            :ON
        elseif legacy_split == "false" && legacy_bid != "true"
            @warn "D19_SPLIT_PAPER=false is deprecated; use D19_MODE=OFF"
            :OFF
        elseif legacy_split == "true"
            # Explicit legacy SPLIT=true equals new default — silent passthrough.
            :PAPER
        else
            :PAPER  # production default
        end
        mode
    end

    # ── D25c: BTL FINANCIAL-HEALTH WEALTH GATE (Java Paper-Code Divergence) ─────────────
    #

    #   Java (default, gate active): `evaluate_investment_entry` blocks BTL market entry
    #     when `agent.bank_balance < desired_wealth(income, propensity, dist)`
    #     (HouseholdBehaviour.java:349-351). The paper does not describe such a gate.
    #   Paper-faithful (gate DISABLED): all BTL investors with positive yield V_buy can
    #     enter the market regardless of bank balance.
    #
    # IMPACT: When D25C_DISABLE_BTL_WEALTH_GATE=true the wealth gate at
    #   HouseholdBehavior.jl:414-416 is bypassed; otherwise default Java-parity behavior.
    #
    # SCOPE: One code location:
    #   1. HouseholdBehavior.jl::evaluate_investment_entry — Financial Health Gate skip
    # DEPENDENCY: Independent of D18 / D19. Compatible with default D25b.
    # ISOLATION:  D25C_DISABLE_BTL_WEALTH_GATE=true julia --project=. scripts/run_working_data.jl <OUTPUT_DIR>
    const D25C_DISABLE_BTL_WEALTH_GATE = get(ENV, "D25C_DISABLE_BTL_WEALTH_GATE", "false") == "true"

    # ── D25b: FTB→HM Classification Clear on Purchase (Java Parity) ──────────────────────
    #
    const D25B_CLEAR_FTB_ON_PURCHASE = get(ENV, "D25B_CLEAR_FTB_ON_PURCHASE", "true") == "true"

    # ──────────────────────────────────────────────────────────────────────────
    #
    const ND31_RELIST_ON_TENANT_EXIT =
        get(ENV, "ND31_RELIST_ON_TENANT_EXIT", "true") == "true"

    # ── D26 — Evict sitting tenant on sale of tenanted property (Java parity) ────────
    #
    # PURPOSE: Mirror Java's UNCONDITIONAL `getEvicted()` call inside
    # `Household.java:339-363 completeHouseSale()`. Java evicts the sitting tenant
    # whenever ANY tenanted property changes hands, regardless of buyer type.
    # With the flag off, the eviction runs only in the buy-to-let purchase branch, so a
    # renter's owner-occupier purchase of a tenanted property keeps the sitting tenant.
    #
    const D26_EVICT_ON_NONBTL_SALE =
        get(ENV, "D26_EVICT_ON_NONBTL_SALE", "true") == "true"

    #
    # MECHANISM: Java's `Household.java::manageHouse` (L252-L268) wraps BOTH
    # the price-cut RNG AND the negative-equity withdrawal in a single
    # `if (Model.getTime() > forSale.gettInitialListing())` gate.
    #
    # STATUS: HousingMarket.jl always follows the Java behaviour; this flag
    # has no effect.
    const ND35_FULL_GRACE_GATE =
        get(ENV, "ND35_FULL_GRACE_GATE", "false") == "true"

    #
    # MECHANISM: Julia's `update_for_sale_supply!` Section C re-lists owned,
    # vacant, non-residence, non-BTL surplus properties unconditionally every
    # tick. Java's `Household.java::manageHouse` routes non-residence properties
    # through `decideToSellInvestmentProperty` (HouseholdBehaviour.java:295) —
    # dispatch is `h == home`, NOT `isPropertyInvestor`. Net Java behaviour:
    # nProperties < 3 → deterministic false (never re-listed); >= 3 → BTL yield
    # calc. Likely an accidental cross-routing in Java. Carro et al. (2022)
    # A.1/A.2 are silent on post-withdrawal continuation — both engines
    # extrapolate beyond the paper, in opposite directions.
    #
    # MODES:
    #   :STATUS_QUO — re-list every month (default).
    #   :JAVA       — nprops<3 hold OR evaluate_investor_exit==false → skip.
    #   :PAPER      — re-list with p_sale_monthly = 1/204 (Table 11 OO rate).
    #
    const ND36_MODE = Symbol(get(ENV, "ND36_MODE", "STATUS_QUO"))

    #
    # MECHANISM: Julia's Scheduler.jl Phase 2d loops at L146 (D18 pre-income)
    # and L214 (D18 post-income) iterate `for id in allids(model)` (Dict
    # hash-bucket order). Java iterates `Model.households` (ArrayList in
    # id-asc by construction). `update_behavioral_state!` consumes one iid
    # `randn(abmrng(model))` ε draw per agent; body is self-mutation only.
    # ANALYTIC EXPECTATION: permutation-invariant in expectation; finite-MC
    # drift only via downstream non-linear operators. ON ≡ sort!(collect(...)).
    #
    const ND37_SORTED_BEHAVIORAL_UPDATE =
        get(ENV, "ND37_SORTED_BEHAVIORAL_UPDATE", "true") == "true"

    #
    # MECHANISM: Julia's Demographics.jl L121 iterates `collect(allids(model))`
    # (Dict hash-bucket order). Java's Demographics.java:115 traverses
    # `Model.households.iterator()` (ArrayList, id-asc). Heir-selection
    # `random_agent(model)` is distribution-identical to Java's
    # `prng.nextInt(households.size())`; per-bin dynamic kill_targets makes
    # expected total deaths invariant to within-bin permutation. Only
    # theoretical leak path: inheritance-cascade `inherit_house!` portfolio
    # branching.
    #
    const ND38_SORTED_DEATH_LOOP =
        get(ENV, "ND38_SORTED_DEATH_LOOP", "false") == "true"

    #
    # MECHANISM: Julia's Demographics.jl L613 iterates `for house_id in
    # dead_agent.properties_owned` (Vector{Int} push order = acquisition order).
    # Java's Household.java:634 iterates `housePayments.keySet()` of a
    # `TreeMap<House, PaymentAgreement>` (id-asc). The first house visited
    # becomes the heir's residence (Scenario 1 of `inherit_house!`); subsequent
    # houses take a different branch (Scenario 2 — listed for sale/rent).
    # Iteration order is therefore body-path-dependent AND RNG-coupled
    # (`draw_rental_markup`, `put_on_market!` sale-markup draws).
    #
    # NECESSARY CONDITION for any divergence: dead agent owns ≥ 2 houses with
    # non-monotonic acquisition→id mapping (recursive inheritance, mid-life BTL
    # divestiture-and-reacquisition). In a no-migration UK calibration the
    # incidence per death is small.
    #
    const ND39_SORTED_PROPERTY_DISPOSITION =
        get(ENV, "ND39_SORTED_PROPERTY_DISPOSITION", "true") == "true"

# --- Simulation Meta-Params ---
    # Scaled down from UK total (26.4m) for simulation. Source: ONS 2011 Census.
    const N_HOUSEHOLDS = 10000    
    # Derivation: ONS Table 101 dwelling stock (22.6m) / ONS Census households (26.4m)
    # Source: ONS 2011 Census / ONS Table 101
    # Exact ratio required for empirical identity
    const UK_DWELLINGS = 22626000
    const UK_HOUSEHOLDS = 26442100
    const HOUSES_PER_HOUSEHOLD = UK_DWELLINGS / UK_HOUSEHOLDS
    const UK_HOUSEHOLDS_SPAIN_VALUE      = 18444200
    const UK_DWELLINGS_SPAIN_VALUE       = 16694333
    const HOUSES_PER_HOUSEHOLD_SPAIN_VALUE = UK_DWELLINGS_SPAIN_VALUE / UK_HOUSEHOLDS_SPAIN_VALUE

    # Legacy explicit stock constants are retained for backward compatibility,
    # but runtime initialization now derives geometry from the resolved ratio and
    # target population when `n_houses` / `n_qualities` are omitted.
    const N_HOUSES = Int(round(0.8560 * N_HOUSEHOLDS))
    const N_HOUSES_SPAIN = Int(round(HOUSES_PER_HOUSEHOLD_SPAIN_VALUE * N_HOUSEHOLDS))
    const N_STEPS = 360               # 30 years in months
    const MONTHS_IN_YEAR = 12
    
    # --- Rolling Window Logic (Boundary Condition) ---
    const ROLLING_WINDOW = 6
    const HPA_YEARS_TO_CHECK = 2
    const HPI_RECORD_LENGTH = HPA_YEARS_TO_CHECK * MONTHS_IN_YEAR + 3
    
    # Source: English Housing Survey (EHS) 2011
    const HOLDING_PERIOD_YEARS = 17.0            # Average holding period in years (for sale probability calc)
    # Spain value (Java config.properties):
    # `HOLD_PERIOD = 13.298630137`. Drives `P_SALE_MONTHLY` and (via that) `N_QUALITIES`.
    # The const-freeze of N_QUALITIES at Config.jl load means a runtime Symbol flip
    # cannot retroactively change array sizes; the resolver in Initialization.jl
    # recomputes `resolved_p_sale_monthly` and `resolved_n_qualities` and threads
    # them through ModelParameters + downstream array allocations.
    const HOLDING_PERIOD_YEARS_SPAIN_VALUE = 13.298630137

    # 1. Calculate optimal segments per Manuscript Appendix A.1.1
    # Monthly sale prob = 1 / (17 years * 12 months) ≈ 0.0049
    const P_SALE_MONTHLY = 1.0 / (HOLDING_PERIOD_YEARS * 12.0)  # Monthly sale probability

    # Calculation: N_QUALITIES = N_HOUSES / (HOLD_PERIOD_YEARS * 12)
    # This formula determines the number of quality bands such that, on average, there is exactly 
    # one house sale per quality band per month. This ensures sufficient liquidity in each 
    # segment for price discovery while maximizing the resolution of the quality hierarchy.
    # For a standard run (10k households), this results in ~42 quality bands.
    
    # Ensure at least 1 quality, otherwise roughly 1 segment per expected monthly sale
    # We enforce a minimum of 1 to avoid division-by-zero errors in extremely small simulations.
    const N_QUALITIES = max(1, round(Int, N_HOUSES * P_SALE_MONTHLY))            # Number of quality tiers for houses
    
    # --- Housing Market Mechanism Parameters (Carro et al. 2022) ---
    const BID_UP_FACTOR = 1.074637358  # Chi (χ) - Source: Zoopla (2003-2015 data). Java: BIDUP = 1.074637358 (line 324)
    const DAYS_UNDER_OFFER = 3.0       # Postulated (Design decision). Java: DAYS_UNDER_OFFER = 3.0 (line 321)
    # Replaced by SALE_PRICE_REDUCTION_PROB below for consistency
    # const PROB_PRICE_REDUCE = 0.0703  # Alpha (α) - Source: Zoopla (2003-2015 data)

    # Market Smoothing Factor (α) — EMA decay constant for per-quality prices,
    # months-on-market, and rental yield.
    #
    #   VALUE A — Footnote 46 (p. 46) + Java config.properties (line 27):
    #     "cumulative weight of 1/4 to events older than a year"
    #     w = 0.25  →  α = 1 − 0.25^(1/12) ≈ 0.1091
    #     Java source: CUMULATIVE_WEIGHT_BEYOND_YEAR = 0.25 (config.properties)
    #     Derivation: 1.0 - Math.pow(0.25, 1.0/12.0)  (Config.java line 361)
    #     This is the AUTHORITATIVE value: confirmed by both the manuscript
    #     footnote and the Java implementation used for calibration.
    #
    #   VALUE B — Table 16 ("User set parameters"):
    #     "Cumulative weight for events beyond 12 months = 0.14"
    #     w = 0.14  →  α = 1 − 0.14^(1/12) ≈ 0.1500
    #     This value is NOT present anywhere in the Java source code.
    #     It is an EDITORIAL ERROR in the paper's parameter summary table.
    #
    #   CONCLUSION: Table 16 contains a typo. The correct value is 0.25
    #   (Footnote 46 / Java). The toggle below allows both to be exercised.
    #
    # TOGGLE: EMA_SMOOTHING_TABLE16
    #   false (default, Java-faithful): w=0.25, α≈0.1091  — Footnote 46 + Java
    #   true  (table variant):          w=0.14, α≈0.1500  — Table 16 typo
    #
    # Override: EMA_SMOOTHING_TABLE16=true julia ...
    const EMA_SMOOTHING_TABLE16    = get(ENV, "EMA_SMOOTHING_TABLE16", "false") == "true"
    const MARKET_SMOOTHING_FACTOR  = EMA_SMOOTHING_TABLE16 ?
        (1.0 - 0.14^(1.0/12.0)) :   # w=0.14 → α≈0.1500  (Table 16, editorial error)
        (1.0 - 0.25^(1.0/12.0))     # w=0.25 → α≈0.1091  (Footnote 46 + Java — DEFAULT)

    # Mix-Adjustment Weight (ρ):
    # Source: Appendix C.3.3 (Page 56) and Equation 21 (Page 47).
    # "Weight on market vs segment house prices... value selected... was 0.5"
    # Matches Java: MARKET_AVERAGE_PRICE_DECAY
    const MIX_ADJUSTMENT_WEIGHT = 0.5
    const MIX_ADJUSTMENT_WEIGHT_SPAIN_VALUE = 0.7

    const DATA_PATH_AGE_UK              = "Age9-Weighted.csv"                                    # 9-bin smoothed (transformAgeDistributionToMonthly applied at load)
    const DATA_PATH_AGE_SPAIN           = "EFF-Age9.csv"
    const DATA_PATH_AGE_INCOME_UK       = "AgeGrossIncomeJointDist.csv"                           # 153-bin (9 × 17)
    const DATA_PATH_AGE_INCOME_SPAIN    = "EFF-AgeGrossIncomeJointDist-NoHouseSaleProfits-MI.csv" # 153-bin (CG-stripped, MI-pooled)
    const DATA_PATH_INCOME_WEALTH_UK    = "GrossIncomeNetWealthJointDist.csv"                     # 666-bin
    const DATA_PATH_INCOME_WEALTH_SPAIN = "EFF-GrossIncomeNetWealthJointDist.csv"                 # 666-bin
    const DATA_PATH_BTL_UK              = "BTLProbabilityPerIncomePercentileBin.csv"              # ~100-bin
    const DATA_PATH_BTL_SPAIN           = "EFF-BTLProbabilityPerIncomePercentileBin.csv"          # 21-bin (5×-coarsened)
    const DATA_DIR_UK    = ("..", "..", "data", "uk")                # = repo-root/data/uk/   
    const DATA_DIR_SPAIN = ("..", "..", "data", "spain")              # = repo-root/data/spain/

    # --- Initial Market States (Baseline for MarketStats) ---
    const INITIAL_AVG_PRICE = 171_800.0   # Baseline mean house price (Affordability Bar)
    
    # Parameters for house price distribution: Scale (mu) and Shape (sigma)
    # Source: Land Registry Price Paid Data 2011
    # Java: HOUSE_PRICES_SCALE = 12.1186367865, HOUSE_PRICES_SHAPE = 0.641448422215 (lines 327-330)
    const PRICE_DIST_MU = 12.1186367865
    const PRICE_DIST_SIGMA = 0.641448422215
    # Spain values (Java config.properties):
    #   L530 HOUSE_PRICES_SCALE = 11.892880027998135
    #   L537 HOUSE_PRICES_SHAPE = 0.6365612836749334
    const PRICE_DIST_MU_SPAIN_VALUE    = 11.892880027998135
    const PRICE_DIST_SIGMA_SPAIN_VALUE = 0.6365612836749334

    # Derived: Mean of the log-normal house price distribution
    # Java: Config.java line 362: Math.exp(HOUSE_PRICES_SCALE + HOUSE_PRICES_SHAPE*HOUSE_PRICES_SHAPE/2.0)
    # Used ONLY in CoreIndicators.getPriceToIncome() for mix-adjusted price-to-income ratio.
    # Value ≈ exp(12.1186 + 0.6414²/2) ≈ 224,647
    const HOUSE_PRICES_MEAN = exp(PRICE_DIST_MU + PRICE_DIST_SIGMA^2 / 2.0)

    # Parameters for rental price distribution: Scale (mu) and Shape (sigma)
    # Source: BoE NMG Survey 2016
    # Java: RENTAL_PRICES_SCALE = 6.26469, RENTAL_PRICES_SHAPE = 0.6352749 (lines 331-334)
    const RENT_DIST_MU = 6.26469
    const RENT_DIST_SIGMA = 0.6352749
    # Spain values (Java config.properties):
    #   L545 RENTAL_PRICES_SCALE = 5.997404326045835
    #   L551 RENTAL_PRICES_SHAPE = 0.5904675189223733
    const RENT_DIST_MU_SPAIN_VALUE    = 5.997404326045835
    const RENT_DIST_SIGMA_SPAIN_VALUE = 0.5904675189223733

    # --- Down Payment Parameters (Carro et al. 2022, Appendix B, Table 10 & 12) ---
    const HM_DOWNPAYMENT_MU = 11.15
    const HM_DOWNPAYMENT_SIGMA = 0.958
    const BTL_DOWNPAYMENT_MU = 0.34
    const BTL_DOWNPAYMENT_SIGMA = 0.15
    const HM_DOWNPAYMENT_MU_SPAIN_VALUE     = 10.18035189423329
    const HM_DOWNPAYMENT_SIGMA_SPAIN_VALUE  = 1.1138288425479512
    const BTL_DOWNPAYMENT_MU_SPAIN_VALUE    = 0.3241886613388506
    const BTL_DOWNPAYMENT_SIGMA_SPAIN_VALUE = 0.15123867379476058

    const BTL_DOWNPAYMENT_SCALE = NaN                          # UK-default sentinel: path never fires under Symbol OFF
    const BTL_DOWNPAYMENT_SHAPE = NaN                          # UK-default sentinel: path never fires under Symbol OFF
    const BTL_DOWNPAYMENT_SCALE_SPAIN_VALUE = 10.2693319885064 # Spain Java config.properties:381 (CIR+CdR principal/price calibration)
    const BTL_DOWNPAYMENT_SHAPE_SPAIN_VALUE = 1.0060917629154864 # Spain Java config.properties:383

    const INITIAL_RENTAL_YIELD = 0.05    # Initial gross rental yield (5%). Source: Zoopla / Land Registry analysis & ARLA Report 2013.
    # Spain values (Java config.properties):
    #   L557 RENT_GROSS_YIELD = 0.044175
    # Residual non-flipping fallback: `Config.INITIAL_RENTAL_YIELD` at
    # `src/markets/MarketStats.jl:301` (rare per-quality p_q==0 seed) is left
    # as-is; threading it through would require an additional model-level field.
    const INITIAL_RENTAL_YIELD_SPAIN_VALUE = 0.044175

    # Derived: Annual Rent / 12 months
    const INITIAL_AVG_RENT = (INITIAL_AVG_PRICE * INITIAL_RENTAL_YIELD) / 12 # (Profitability Bar)

    #
    # DIVERGENCE IDENTIFIED: Previous value of 6.0 caused step-1 occupancy recomputation
    # (MarketStats.jl L180: tenancy_avg / (tenancy_avg + months_on_market_ema_rental[q]))
    # to drop below 1.0 immediately, making Julia's BTL ICR constraint more restrictive
    # than Java's in months 1-6. Java sustains full occupancy (1.0) until actual rental
    # vacancy data accumulates. With 0.0, Julia replicates this exactly.
    #
    # SAFETY: denom = tenancy_avg + 0.0 = tenancy_avg > 0 — no division-by-zero risk.
    # The guard in MarketStats.jl L180 (`denom > 0.0 ? ... : 1.0`) is not triggered.
    const INITIAL_MOM = 0.0             # Initial Months on Market (EMA baseline). Java: 0.0 (HousingMarketStats.java L115)
    
# --- Behavioral Parameters (Carro et al. 2022, Table 10) ---
    # Desired Purchase Price Parameters (Eq. 3)
    # Java: BUY_SCALE = 42.90361, BUY_EXPONENT = 0.7891695, BUY_MU = -0.0176871, BUY_SIGMA = 0.4103773
    const PD_ALPHA = 42.90361            # Scale for desired price (alpha). Source: FCA Product Sales Data (PSD) & Land Registry 2011
    const PD_BETA = 0.7891695            # Exponent for income (beta). Source: FCA Product Sales Data (PSD) & Land Registry 2011
    const PD_EPSILON_MU = -0.0176871     # Noise Mean. Source: Calibration
    const PD_EPSILON_SIGMA = 0.4103773   # Noise Std Dev. Source: Calibration
    # Spain values (Java config.properties):
    #   L272 BUY_SCALE    = 511.322240967      (Pdf budget eq. α; ~12× UK)
    #   L287 BUY_EXPONENT = 0.5559
    #   L306 BUY_MU       = 0.0
    #   L320 BUY_SIGMA    = 0.3975000514662877
    const PD_ALPHA_SPAIN_VALUE         = 511.322240967
    const PD_BETA_SPAIN_VALUE          = 0.5559
    const PD_EPSILON_MU_SPAIN_VALUE    = 0.0
    const PD_EPSILON_SIGMA_SPAIN_VALUE = 0.3975000514662877

    const PSYCHOLOGICAL_COST_RENTING = 0.4   # lambda. Carro Table 10 (Java-UK parity).

    const SENSITIVITY_RENT_BUY = 0.001       # theta. Source: Calibrated (Method of Simulated Moments)
    # Spain Java config.properties L714 (`PSYCHOLOGICAL_COST_OF_RENTING = 0.8`)
    # and L717 (`SENSITIVITY_RENT_OR_PURCHASE = 0.01`). Co-bundled under the
    # `:spain_rent_buy_logit` Symbol (Carro Eq. 1 bias × temperature pair).
    const PSYCHOLOGICAL_COST_RENTING_SPAIN_VALUE = 0.8
    const SENSITIVITY_RENT_BUY_SPAIN_VALUE       = 0.01
    # ─── Carro et al. (2022) Eq. 2 expectations parameters (Java-UK parity defaults) ──────
    const EXPECTATIONS_GAMMA = 0.44          # gamma. Carro Table 10 (Java-UK parity). [Java: HPA_EXPECTATION_FACTOR]
    const EXPECTATIONS_ZETA = -0.007         # zeta.  Carro Table 10 (Java-UK parity). [Java: HPA_EXPECTATION_CONST]
    const EXPECTATIONS_GAMMA_SPAIN_VALUE   = 1.0      # Spain: pure naive extrapolation
    const EXPECTATIONS_ZETA_SPAIN_VALUE    = 0.0      # Spain: zero autonomous sentiment
    const HPA_YEARS_TO_CHECK_SPAIN_VALUE   = 4        # Spain: 4-year lookback (vs UK 2)

    # --- Rental Affordability (Table 10) ---
    # Java: DESIRED_RENT_SCALE = 17.21657, DESIRED_RENT_EXPONENT = 0.3463723 (lines 264-267)
    const RENTAL_BID_SCALE = 17.21657      # mu (Eq 5). Source: BoE NMG Survey 2016
    const RENTAL_BID_EXPONENT = 0.3463723  # nu (Eq 5). Source: BoE NMG Survey 2016
    # Spain values (Java config.properties):
    #   L465 DESIRED_RENT_SCALE    = 8.435930297
    #   L475 DESIRED_RENT_EXPONENT = 0.4098
    const RENTAL_BID_SCALE_SPAIN_VALUE    = 8.435930297
    const RENTAL_BID_EXPONENT_SPAIN_VALUE = 0.4098
    # Stochastic noise for rental budget (Java: DESIRED_RENT_MU, DESIRED_RENT_SIGMA)
    # Set to 0.0 in calibration, but MUST be included for RNG synchronization
    const RENTAL_BID_NOISE_MU = 0.0        # Mean of log-normal noise multiplier
    const RENTAL_BID_NOISE_SIGMA = 0.0     # Std dev of log-normal noise multiplier

    # --- Down Payment Parameters (Table 10 & 12) ---
    const DESIRED_DOWN_PAYMENT_FTB_SCALE = 10.35
    const DESIRED_DOWN_PAYMENT_FTB_SHAPE = 0.898
    const DESIRED_DOWN_PAYMENT_HM_SCALE = 11.15
    const DESIRED_DOWN_PAYMENT_HM_SHAPE = 0.958
    
    const BTL_DOWN_PAYMENT_MEAN = 0.34
    const BTL_DOWN_PAYMENT_STD = 0.15

    # --- Supply Side (Table 11: Owner-Occupier Decisions) ---
    # Monthly probability of reducing the listing price. Source: Zoopla (2003-2015 data)
    # Matches Java: config.P_SALE_PRICE_REDUCE
    const SALE_PRICE_REDUCTION_PROB = 0.070261549

    # Magnitude of price reduction (Log-Normal parameters). Source: Zoopla (2003-2015 data)
    # Drawn from Normal Distribution (epsilon): Mean = 1.4531, Std = 0.7070
    # Logic: price_new = price_old * (1 - exp(epsilon)/100)
    # Matches Java: config.REDUCTION_MU and REDUCTION_SIGMA
    const SALE_PRICE_REDUCTION_MEAN = 1.4531616527146942
    const SALE_PRICE_REDUCTION_STD = 0.7069519537251404


    # --- Rental Market (Table 12: BTL Decisions) ---
    # Monthly probability of reducing the rent. Source: Zoopla (2003-2015 data)
    # Matches Java: config.P_RENT_PRICE_REDUCE
    const RENT_PRICE_REDUCTION_PROB = 0.105704443

    # Magnitude of rent reduction (Log-Normal parameters). Source: Zoopla (2003-2015 data)
    # Drawn from Normal Distribution (epsilon): Mean = 1.6558, Std = 0.7855
    # Logic: rent_new = rent_old * (1 - exp(epsilon)/100)
    # Matches Java: config.RENT_REDUCTION_MU (1.6558...) and RENT_REDUCTION_SIGMA (0.7855...)
    const RENT_REDUCTION_MEAN = 1.65587341743     
    const RENT_REDUCTION_STD = 0.785541663134

    # Tenancy Length (Months). Source: ARLA Members Survey 2013 Q4
    const TENANCY_LENGTH_MIN = 12
    const TENANCY_LENGTH_MAX = 24
    # Spain values (Java config.properties):
    #   L489 TENANCY_LENGTH_MAX = 36
    const TENANCY_LENGTH_MAX_SPAIN_VALUE = 36

    # --- Supply Side: BTL Divestment Parameters ---
    const BTL_XI             = 100.0      # Sensitivity of sell decision (xi). Source: Calibrated (Method of Simulated Moments)
    
    const BTL_ANNUAL_TO_MONTHLY = 1.0/12.0  # Temporal adjustment for Eq. (11)
    
    # Correction for BTL Population Share (Source: Carro et al. 2022)
    # Value 1.76 scales the income-based probability to match the ~7.9% target
    # Source: Calibrated (to match total investors in WAS)
    const BTL_PROBABILITY_ADJUSTMENT = 1.76
    const BTL_PROBABILITY_ADJUSTMENT_SPAIN_VALUE = 1.6

    # Alternative return for BTL entry/exit value calculation (Eq 7, Carro 2022)
    # UK Java: no explicit alternative return term → effective value is 0.0.
    # With 0.0, V_buy = leverage × weighted_return − mortgage_cost (unchanged).
    const BTL_ALTERNATIVE_RETURN = 0.0


    const BTL_ALTERNATIVE_RETURN_SPAIN_VALUE = 0.040755

    const INTEREST_ONLY_MORTGAGES_FOR_BTL = true

    # --- BTL Investor Strategy Types (Section 3.3.4, Table 12) ---
    # Source: BoE NMG Survey 2014 / Java config.properties lines 235-255
    # Three investor types with different capital-gains weights (delta_i):
    #   Type 1: Rental-Income Driven (delta = 0.1, p = 0.4927)
    #   Type 2: Capital-Gains Driven (delta = 0.9, p = 0.1458)
    #   Type 3: Mixed             (delta = 0.5, p = 1 - 0.4927 - 0.1458 = 0.3615)
    const BTL_P_INCOME_DRIVEN = 0.4927              # Java: BTL_P_INCOME_DRIVEN = 0.4927
    const BTL_P_CAPITAL_DRIVEN = 0.1458             # Java: BTL_P_CAPITAL_DRIVEN = 0.1458
    const BTL_INCOME_DRIVEN_CAP_GAIN_COEFF = 0.1    # Java: BTL_INCOME_DRIVEN_CAP_GAIN_COEFF = 0.1
    const BTL_CAPITAL_DRIVEN_CAP_GAIN_COEFF = 0.9   # Java: BTL_CAPITAL_DRIVEN_CAP_GAIN_COEFF = 0.9
    const BTL_MIX_DRIVEN_CAP_GAIN_COEFF = 0.5       # Java: BTL_MIX_DRIVEN_CAP_GAIN_COEFF = 0.5

    # --- Bank Rules (Table 13) ---
    const MORTGAGE_DURATION_YEARS = 25      # UK-faithful default. Source: UK config.properties:341.

    # Spain value (Java config.properties:567). An explicit keyword argument always wins.
    const MORTGAGE_DURATION_YEARS_SPAIN_VALUE = 30

    const BANK_AGE_LIMIT = 65               # UK-faithful default. Source: UK config.properties:344.
    const BANK_AGE_LIMIT_SPAIN_VALUE = 61.0

    const BANK_MIN_AGE_LIMIT = 0            # UK-faithful default (no min-age check).
    const BANK_MIN_AGE_LIMIT_SPAIN_VALUE = 24.0

    const LTV_MAX_FTB = 0.9               # Gamma_FTB. Java: BANK_LTV_HARD_MAX_FTB = 0.9 (line 363)
    const LTV_MAX_HM = 0.90               # Gamma_HM. Java: BANK_LTV_HARD_MAX_HM = 0.9 (line 365)
    const LTV_MAX_BTL = 0.75              # Gamma_BTL. Java: BANK_LTV_HARD_MAX_BTL = 0.75 (line 367)

    const LTI_MAX_FTB = 5.4               # Phi_FTB (Hard Limit) - Per Carro et al. (2022) Table 13 & Java line 347
    const LTI_MAX_HM = 5.6                # Phi_HM (Hard Limit) - Per Carro et al. (2022) Table 13 & Java line 349

    const LTV_MAX_FTB_SPAIN_VALUE = 1.0
    const LTV_MAX_HM_SPAIN_VALUE  = 1.0
    const LTV_MAX_BTL_SPAIN_VALUE = 0.95
    const LTI_MAX_FTB_SPAIN_VALUE = 13.8266
    const LTI_MAX_HM_SPAIN_VALUE  = 13.8266

    const LTI_MAX_BTL = 99.0
    # Spain config.properties:683 BANK_LTI_HARD_MAX_BTL = 13.8266. With the Spanish
    # parameters active this resolves into `model.bank_lti_max_btl`; the consumer in Bank.evaluate_credit
    # remains gated by `:spain_soft_lti_btl` so the value only binds when that
    # flag is also on.
    const LTI_MAX_BTL_SPAIN_VALUE = 13.8266

    const BANK_LTV_SOFT_MAX_FTB           = 0.80    # Spain config.properties:622
    const BANK_LTV_SOFT_MAX_HM            = 0.80    # Spain config.properties:636
    const BANK_LTV_SOFT_MAX_BTL           = 0.70    # Spain config.properties:650
    const BANK_LTV_FRAC_OVER_SOFT_MAX_FTB = 0.4699  # Spain config.properties:630
    const BANK_LTV_FRAC_OVER_SOFT_MAX_HM  = 0.4699  # Spain config.properties:644
    const BANK_LTV_FRAC_OVER_SOFT_MAX_BTL = 0.4646  # Spain config.properties:657

    const DSTI_MAX = 0.40001                 # Psi. Java: BANK_AFFORDABILITY_HARD_MAX = 0.4 (line 351)

    # The paper reports 1.25, but the Java config.properties (line 90) sets
    # BANK_ICR_HARD_MIN = 1.2; the Java value is used here.
    const ICR_MIN = 1.2                   # Omega. Java: BANK_ICR_HARD_MIN = 1.2 (line 355)
    # Spain config.properties:692 BANK_AFFORDABILITY_HARD_MAX = 0.897381937 (very loose).
    # Spain config.properties:703 BANK_ICR_HARD_MIN          = 0.0          (ICR floor off).
    const DSTI_MAX_SPAIN_VALUE = 0.897381937
    const ICR_MIN_SPAIN_VALUE  = 0.0


    # =========================================================================
    # GOVERNMENT & FISCAL POLICY (2011 Calibration)
    # Reference: Carro et al. (2022) Appendix C.2.9 / HMRC 2011 Data
    # =========================================================================
    #
    # 11 UK-only keys replaced by Julia constants:
    #   1.  data_tax_rates                                → TAX_RATE_BASIC / HIGHER / ADDITIONAL + TAX_BAND_*
    #   2.  data_national_insurance_rates                 → NI_RATE_MAIN / ADDITIONAL + NI_*_THRESHOLD
    #   3.  government_general_personal_allowance         → TAX_PERSONAL_ALLOWANCE
    #   4.  government_income_limit_for_personal_allowance→ TAX_INCOME_LIMIT
    #   5.  government_monthly_income_support             → MINIMUM_GOVT_SUPPORT
    #   6.  essential_consumption_fraction                → ESSENTIAL_CONSUMPTION_FRACTION
    #   7.  central_bank_lti_months_to_check              → LTI_WINDOW_MONTHS (elsewhere)
    #   8.  central_bank_ltv_hard_max_ftb                 → REGULATORY_LTV_FTB (elsewhere)
    #   9.  central_bank_ltv_hard_max_hm                  → REGULATORY_LTV_HM  (elsewhere)
    #   10. central_bank_ltv_hard_max_btl                 → REGULATORY_LTV_BTL (elsewhere)
    #   11. record_housing_wealth                         → not a Config key (Java MicroDataRecorder option)
    #
    # =========================================================================

    # --- Income Tax ---
    const TAX_PERSONAL_ALLOWANCE = 7475.0
    const TAX_INCOME_LIMIT = 100000.0

    # Tax Bands (Applied to *Taxable* Income, i.e., Gross - Allowance)
    const TAX_BAND_BASIC_LIMIT = 35000.0
    const TAX_BAND_HIGHER_LIMIT = 150000.0
    # Note: 50% Additional rate applies above £150k (2011 specific)

    const TAX_RATE_BASIC = 0.20
    const TAX_RATE_HIGHER = 0.40
    const TAX_RATE_ADDITIONAL = 0.50

    # --- National Insurance (Class 1) ---
    # Annualized thresholds (Matches Java/CSV Source exactly)
    const NI_PRIMARY_THRESHOLD = 7228.0
    const NI_UPPER_EARNINGS_LIMIT = 42484.0

    const NI_RATE_MAIN = 0.12
    const NI_RATE_ADDITIONAL = 0.02

    # Java Parity: Cash Buyer Threshold
    const DOWNPAYMENT_BANK_BALANCE_FOR_CASH_SALE = 1.0 

    # --- Capital Taxes (Excluded in 2011 Calibration) ---
    const CAPITAL_GAINS_TAX = 0.0
    
    # --- Consumption Logic (Section 3.2) ---
    # Essential Consumption Parameters (Table 9)
    const MINIMUM_GOVT_SUPPORT = 445.80
    const ESSENTIAL_CONSUMPTION_FRACTION = 0.66

    # Essential Consumption (66% of JSA ~£294) calculated from primitives
    const ESSENTIAL_CONSUMPTION_MONTHLY = MINIMUM_GOVT_SUPPORT * ESSENTIAL_CONSUMPTION_FRACTION

    const ESSENTIAL_NOMINAL_CONSUMPTION = 0.0

    const ESSENTIAL_NOMINAL_CONSUMPTION_SPAIN_VALUE = 200.0

    # Target Wealth Parameters
    # Target Wealth is NO LONGER linear function of Disposable (See feedback)
    # Determined by empirical lookup (GrossIncomeNetWealthJointDist.csv)

    const CONSUMPTION_GAMMA = 0.5     # Speed of adjustment to target (Set to 0.5 per Eq 16)
    const WINDFALL_CAP_SHARE = 0.17   # C_max = 0.17 * Gross Income
    # Spain values (Java config.properties):
    #   L227 MAXIMUM_CONSUMPTION_FRACTION = 0.17509309751065444 (Julia name `WINDFALL_CAP_SHARE`)
    # Consumer at FinancialFlows.jl::process_discretionary_consumption!; stored in the
    # `ModelParameters.windfall_cap_share` field.
    const WINDFALL_CAP_SHARE_SPAIN_VALUE = 0.17509309751065444

    # --- Interest Rate Mechanism (Section 3.4 / Eq 17) ---
    const INTEREST_RATE_ELASTICITY_PHI = 1.33e-5  # phi. Carro Sec 3.4 (Java-UK parity).
    const CENTRAL_BANK_POLICY_RATE = 0.005       # Base Rate (0.5% - Fixed Policy Rate). Source: Bank of England (2009-2016 average).
    const INITIAL_INTEREST_RATE_SPREAD = 0.03    # Initial spread (~3.0% per calibration).
    const INITIAL_CREDIT_SUPPLY_PER_HH = 244.0   # Initial credit supply per household (Appendix B). Source: FCA PSD 2011 & BoE BTL Data 2018.
    # Spain config.properties:
    #   L611 BANK_D_INTEREST_D_DEMAND      = 1.783936e-05  (Carro Sec 3.4 φ, Spain calibration)
    #   L585 BANK_INITIAL_RATE             = 0.023536      (composite spread+rate; Spain decomposes
    #                                                       to CB policy rate = 0.0 + spread = 0.023536)
    #   L600 BANK_INITIAL_CREDIT_SUPPLY    = 140.229133    (per-household, Spain calibration)
    # CB policy rate flip from 0.005 → 0.0 is reporting-only when soft-rate adaptive
    # path is OFF (Spain disables the regulatory ρ-policy).
    const INTEREST_RATE_ELASTICITY_PHI_SPAIN_VALUE = 1.783936e-5
    const CENTRAL_BANK_POLICY_RATE_SPAIN_VALUE     = 0.0
    const INITIAL_INTEREST_RATE_SPREAD_SPAIN_VALUE = 0.023536
    const INITIAL_CREDIT_SUPPLY_PER_HH_SPAIN_VALUE = 140.229133

    # --- Legacy Parameters (Present in Java but Unused) ---
    # These parameters exist in Java config.properties but are marked as LEGACY or have zero values
    # Included here for completeness and to maintain parameter parity
    const BUY_WEIGHT_HPA = 0.4644683          # Java line 437 (LEGACY parameter, unused in current model)
    const DESIRED_RENT_MU = 0.0               # Java line 454 (Set to zero as design decision)
    const DESIRED_RENT_SIGMA = 0.0            # Java line 459 (Set to zero as design decision)

    # --- Regulatory Defaults (Section 3.4) ---
    const IS_SOFT_LIMIT_ACTIVE = true
    # Per-type soft LTI thresholds — Java: config.properties
    #   CENTRAL_BANK_LTI_SOFT_MAX_FTB = 5.4  (line 73)
    #   CENTRAL_BANK_LTI_SOFT_MAX_HM  = 5.6  (line 76)
    # The value 3.35 is used only in the policy experiment of Carro et al. (Fig. 2; E3 in
    # scripts/run_working_data.jl); it is not the calibration default.
    const SOFT_LTI_LIMIT_FTB = 5.4
    const SOFT_LTI_LIMIT_HM  = 5.6
    # Per-type flow allowances — Java: config.properties
    #   CENTRAL_BANK_LTI_MAX_FRAC_OVER_SOFT_MAX_FTB = 0.15  (line 79)
    #   CENTRAL_BANK_LTI_MAX_FRAC_OVER_SOFT_MAX_HM  = 0.15  (line 82)
    # Both 0.15 in baseline calibration; stored separately to enable independent
    # type-specific policy experiments without code changes.
    const FLOW_LIMIT_ALLOWANCE_FTB = 0.15
    const FLOW_LIMIT_ALLOWANCE_HM  = 0.15
    # Spain config.properties:
    #   L118 CENTRAL_BANK_LTI_SOFT_MAX_FTB                = 15.0  (effectively non-binding)
    #   L124 CENTRAL_BANK_LTI_SOFT_MAX_HM                 = 15.0  (effectively non-binding)
    #   L136 CENTRAL_BANK_LTI_MAX_FRAC_OVER_SOFT_MAX_FTB  = 0.0   (Spain disables flow allowance)
    #   L140 CENTRAL_BANK_LTI_MAX_FRAC_OVER_SOFT_MAX_HM   = 0.0
    const SOFT_LTI_LIMIT_FTB_SPAIN_VALUE      = 15.0
    const SOFT_LTI_LIMIT_HM_SPAIN_VALUE       = 15.0
    const FLOW_LIMIT_ALLOWANCE_FTB_SPAIN_VALUE = 0.0
    const FLOW_LIMIT_ALLOWANCE_HM_SPAIN_VALUE  = 0.0
    # Rolling window length for the LTI soft-limit fraction check.
    # Java: config.properties CENTRAL_BANK_LTI_MONTHS_TO_CHECK = 12 (line 85)
    const LTI_WINDOW_MONTHS = 12
    # Quota pooling mode — mirrors Java's runtime branch in Bank.resetMonthlyCounters() /
    # getLoanToIncomeLimit(): when FTB and HM flow allowances are equal, Java uses ONE combined
    # FTB+HM counter instead of independent queues.
    # Java condition: getFirstTimeBuyerMaxFracOverSoftMaxLTI() == getHomeMoverMaxFracOverSoftMaxLTI()
    # Since both default to 0.15, the POOLED path is ALWAYS active in Java's calibration.
    # Set false only for experiments with divergent FTB/HM allowances (no published precedent).

    # The split-quota path is not used in any published experiment, so results with
    # USE_POOLED_LTI_QUOTA = false cannot be compared with published figures.
    const USE_POOLED_LTI_QUOTA = true

    # --- Regulatory Hard Limits (Central Bank Mandatory Policy) ---
    # Source: Java config.properties lines 61-69 (Central Bank policy section)
    # These default to match internal bank limits (non-binding) in baseline calibration
    const REGULATORY_LTV_FTB = 0.95
    const REGULATORY_LTV_HM = 0.90
    const REGULATORY_LTV_BTL = 0.80

    # Java: CENTRAL_BANK_AFFORDABILITY_HARD_MAX = 0.4 (config.properties L88)
    # NOTE: In the baseline calibration this equals bank.dsti_max (Config.DSTI_MAX = 0.4), so
    # min(bank.dsti_max, cb.max_dsti) = min(0.4, 0.4) = 0.4 — the CB cap is non-binding but
    # PRESENT. In policy experiments where bank.dsti_max is relaxed above 0.4, this regulatory
    # floor correctly clamps the effective limit back to 0.4, matching Java behaviour.
    # Setting this to 1.0 would silently disable the CB floor in all such experiments.
    const REGULATORY_DSTI_MAX = 0.4001  # Java: CENTRAL_BANK_AFFORDABILITY_HARD_MAX = 0.4 (config.properties L88)
    # NOTE: Java config.properties L91 sets CENTRAL_BANK_ICR_HARD_MIN = 1.2 (NOT 0.0).
    # In the baseline calibration this equals bank.icr_min (Config.ICR_MIN = 1.2), so
    # max(bank.icr_min, cb.min_icr) = max(1.2, 1.2) = 1.2 — the CB floor is non-binding
    # but PRESENT, matching the Java data state exactly. This change from 0.0 to 1.2 is
    # behaviourally neutral (max(1.2, 0.0) was already 1.2) but ensures data-state parity
    # with Java for any future introspection or policy experiments that read cb.min_icr.
    const REGULATORY_ICR_MIN = 1.2   # Java: CENTRAL_BANK_ICR_HARD_MIN = 1.2 (config.properties L91)
    # Spain config.properties:
    #   L148 CENTRAL_BANK_AFFORDABILITY_HARD_MAX = 0.9999  (DSTI hard cap, effectively off)
    #   L159 CENTRAL_BANK_ICR_HARD_MIN          = 0.0     (CB ICR floor disabled)
    const REGULATORY_DSTI_MAX_SPAIN_VALUE = 0.9999
    const REGULATORY_ICR_MIN_SPAIN_VALUE  = 0.0


    # Policy activation convention:
    # nothing -> limits apply from initialization (UK Java and legacy startup).
    # 0       -> Spanish Java activation at the end of model month t=0.
    # n >= 0  -> Spanish Java activation at the end of model month t=n.
    # The public Spanish reference configuration uses 500; select it explicitly.
    const CENTRAL_BANK_POLICY_APPLICATION_TIME = nothing

    # ──────────────────────────────────────────────────────────────────────────
    #
    # Internal bank limits (`bank_ltv_max_*`, `bank_lti_max_*`, etc.) remain
    # UK non-binding defaults — deliberately decoupled from CB-side calibration
    # per Carro et al. (2022) §4-§5 layered design.
    # ──────────────────────────────────────────────────────────────────────────

    # (2-4) LTV soft maxima per borrower type — Spain mild experiment.
    const CENTRAL_BANK_LTV_SOFT_MAX_FTB = 0.94
    const CENTRAL_BANK_LTV_SOFT_MAX_HM  = 0.94
    const CENTRAL_BANK_LTV_SOFT_MAX_BTL = 0.80

    # (5-7) Max flow-fraction over LTV soft cap per borrower type — Spain mild.
    const CENTRAL_BANK_LTV_MAX_FRAC_OVER_SOFT_MAX_FTB = 0.10
    const CENTRAL_BANK_LTV_MAX_FRAC_OVER_SOFT_MAX_HM  = 0.10
    const CENTRAL_BANK_LTV_MAX_FRAC_OVER_SOFT_MAX_BTL = 0.05

    # (8) LTV-policy application age cutoff — Spain mild experiment.
    const CENTRAL_BANK_LTV_APPLICATION_AGE = 35.0

    # (9) LTI soft maximum for BTL — Spain mild experiment.
    const CENTRAL_BANK_LTI_SOFT_MAX_BTL = 5.0

    # (10) Max flow-fraction over LTI soft cap for BTL — Spain mild experiment.
    const CENTRAL_BANK_LTI_MAX_FRAC_OVER_SOFT_MAX_BTL = 0.05

    # (11) Income-percentile cutoff for policy application — Spain mild experiment.
    const CENTRAL_BANK_APPLICATION_INCOME_PERCENTILE = 0.6
end
