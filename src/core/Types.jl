# src/core/Types.jl
#
# Domain types of the housing-market model: data declarations only, no behaviour.
#
# Contents: `ModelParameters` (immutable run constants), market records (`Bid`,
# `RentalBid`, `Transaction`), `MarketStats` (market-level indicators and per-step
# accumulators), property and contract types (`House`, `Mortgage`, `RentalAgreement`),
# the `Household` agent, institutions (`CentralBank`, `Government`, `Bank`,
# `Construction`), containers for empirical distributions, and `ModelProperties`
# (the concrete model-level property struct passed to Agents.jl).
#
# Included by `Engine.jl` after `Config.jl` and before every module that operates on
# these types; keeping the declarations in one place avoids circular dependencies.
using Agents

# ============================================================================
# MODEL PARAMETERS
# ============================================================================

"""
    ModelParameters

Immutable configuration struct holding the static simulation constants. It is built
once during model initialisation (`initialize_model`) and never modified afterwards.
Most fields follow Carro et al. (2022); equation and table numbers are given in the
field comments. Values that differ between the UK and Spain parameterisations are
resolved in `Initialization.jl` before construction. Empirical tables live in
`ModelProperties` instead.
"""
struct ModelParameters
    n_households::Int
    n_houses::Int
    n_steps::Int
    
    # Market Physics
    bid_up_factor::Float64        # e.g. 1.05 (Price jumps by 5% during bidding wars)
    months_under_offer::Float64  # Average months a house remains on market before sale (Eq 20) - Days under offer / 30
    smoothing_factor::Float64  # EMA Smoothing Factor (Sigma)
    mix_adjustment_weight::Float64 # Rho (ρ) for Perceived Price/Rent (Eq 21)

    n_qualities::Int               # Number of housing quality segments

    # --- Behavioral Parameters (Carro et al. 2022, Table 10) ---
    pd_alpha::Float64                  # Scale for desired price   
    pd_beta::Float64                   # Exponent for income
    pd_epsilon_mu::Float64             # Noise Mean
    pd_epsilon_sigma::Float64          # Noise Std Dev
    psychological_cost_renting::Float64 # Lambda parameter for renting cost adjustment
    sensitivity_rent_buy::Float64       # Theta parameter for rent vs buy decision
    # Expectations (Eq 2: g = γ·HPA + ζ). `expectations_gamma` corresponds to the Java
    # setting `HPA_EXPECTATION_FACTOR` and `expectations_zeta` to `HPA_EXPECTATION_CONST`.
    expectations_gamma::Float64         # Sensitivity to past growth (UK 0.44 / Spain 1.0) [Java: HPA_EXPECTATION_FACTOR]
    expectations_zeta::Float64          # Sentiment bias (UK -0.007 / Spain 0.0)          [Java: HPA_EXPECTATION_CONST]
    # Rental Bid Parameters (Eq 5, Table 10)
    rental_bid_scale::Float64           # mu
    rental_bid_exponent::Float64        # nu
    rental_bid_noise_mu::Float64        # Log-normal noise mean (DESIRED_RENT_MU)
    rental_bid_noise_sigma::Float64     # Log-normal noise std dev (DESIRED_RENT_SIGMA)
    
    # Financial
    essential_consumption_fraction::Float64  # Essential consumption as a fraction of `min_gov_support`
    min_gov_support::Float64                 # Minimum government income support (per month)
    # Cap on monthly discretionary consumption, as a share of annual gross total income
    # (Java `MAXIMUM_CONSUMPTION_FRACTION`; UK 0.17 / Spain 0.17509309751065444).
    # Read in `process_discretionary_consumption!` (FinancialFlows.jl).
    windfall_cap_share::Float64

    # Supply Side (Table 11)
    holding_period_years::Float64       # Average holding period in years (17.0)
    p_sale_monthly::Float64             # Monthly sale probability (1 / (holding_years * 12))
    sale_price_reduction_prob::Float64  # Monthly probability of reducing the listing price
    sale_price_reduction_mean::Float64  # Mean of price reduction percentage
    sale_price_reduction_std::Float64   # Std Dev of price reduction percentage

    # Rental Side (Table 12)
    rent_price_reduction_prob::Float64        # Monthly probability of reducing the rent
    rent_reduction_mean::Float64        # Mean of rent reduction percentage
    rent_reduction_std::Float64         # Std Dev of rent reduction percentage
    tenancy_length_min::Int             # Minimum tenancy length (months)
    tenancy_length_max::Int             # Maximum tenancy length (months)

    # --- Down Payment Parameters (Carro et al. 2022, Appendix B) ---
    hm_downpayment_mu::Float64         # LogNormal Scale (Table 10: 11.15)
    hm_downpayment_sigma::Float64      # LogNormal Shape (Table 10: 0.958)
    btl_downpayment_mu::Float64        # Normal Mean (Table 12: 0.34)
    btl_downpayment_sigma::Float64     # Normal Std (Table 12: 0.15)
    downpayment_bank_balance_for_cash_sale::Float64 # Multiplier for cash sale threshold (Java parity)

    # --- Supply Side: BTL Divestment Parameters ---
    btl_xi::Float64              # Sensitivity of sell decision to effective yield
    btl_annual_to_monthly::Float64  # Temporal adjustment for Eq. (11)
    
    # BTL Population Correction
    # Multiplier applied to the buy-to-let probability computed in Demographics.jl
    btl_probability_adjustment::Float64 

    # --- Regulatory Policy (Macroprudential) ---
    # Split per borrower type, following Java: CentralBank.getFirstTimeBuyerSoftMaxLTI() /
    # getHomeMoverSoftMaxLTI() and getFirstTimeBuyerMaxFracOverSoftMaxLTI() / getHomeMoverMaxFracOverSoftMaxLTI().
    is_soft_limit_active::Bool       # Toggle for Regulatory Queue
    soft_lti_limit_ftb::Float64      # FTB soft LTI threshold (Java: CENTRAL_BANK_LTI_SOFT_MAX_FTB = 5.4)
    soft_lti_limit_hm::Float64       # HM  soft LTI threshold (Java: CENTRAL_BANK_LTI_SOFT_MAX_HM  = 5.6)
    flow_limit_allowance_ftb::Float64  # Max fraction of FTB mortgages over soft limit (Java: 0.15)
    flow_limit_allowance_hm::Float64   # Max fraction of HM  mortgages over soft limit (Java: 0.15)
    # Quota pooling mode, mirroring the pooled branch of Java's getLoanToIncomeLimit().
    # true  = FTB and HM share one combined quota (Java default).
    # false = independent FTB and HM quotas.
    use_pooled_lti_quota::Bool

    # --- Interest Rate Policy (Section 3.4 / Eq 17) ---
    phi::Float64               # Elasticity of interest rate to credit supply changes
end

"""
    Bid
A buy order submitted by a household to the housing market. Agents push bids into
`MarketStats.bids_queue` and the market clears them in a batch.

# Fields
- `agent_id`: The household ID placing the bid.
- `house_id`: Target house (0 = any).
- `price`: Maximum willingness-to-pay (budget).
- `desired_down_payment`: Down-payment computed at bid time, selected by `Config.D19_MODE`.
  - `:OFF`   → field is NaN; `execute_transaction!` recomputes at clearing for all bidders.
  - `:ON`    → field is finite for all bidders; clearing reuses the stored value.
  - `:PAPER` → field is finite for OO/FTB and NaN for BTL.
  Mirrors Java's `HouseBidderRecord.desiredDownPayment`.
- `p_max`: Maximum affordable price at bid time (result of `calculate_buying_power`);
  recorded in the transaction log as `Transaction.p_max`.
"""
struct Bid
    agent_id::Int
    house_id::Int 
    price::Float64
    desired_down_payment::Float64
    p_max::Float64
end

"""
    RentalBid
A rental application submitted by a household to the rental market.
`house_id` is the target house (0 = any) and `price` the maximum monthly rent offered.
"""
struct RentalBid
    agent_id::Int
    house_id::Int
    price::Float64
end

"""
    MarketStats
Mutable record of aggregate market-level statistics (Eq 1, 14, 16). It serves as the
public information source (the "oracle") that agents read about the state of the housing
and rental markets. Per-step accumulators are filled during the step and the published
indicators are refreshed once per step by `update_market_stats!` (MarketStats.jl).

# Selected fields
- `hpi`: House Price Index, a mix-adjusted ratio of sale prices to reference prices; starts at 1.0. (Eq. 1)
- `ema_sales_price`: Exponential moving average of sale prices (model currency units). (Eq. 14)
- `average_rent`: Mean monthly rent paid by current tenants.
- `ema_yield`: Exponential moving average of the gross rental yield (annual fraction). (Eq. 16)
- `sales_volume`: Number of property sales in the last step.
- `months_on_market_ema`: Per-quality exponential moving average of months on the market before sale.
- `*_by_quality`: Vectors with one entry per quality segment (length `n_qualities`).
"""
mutable struct MarketStats
    # --- Dynamic Indicators (Segmented) ---
    hpi::Float64
    rental_price_index::Float64 # RPI (mix-adjusted rent index; starts at 1.0)
    
    # Vectors length = n_qualities
    ema_prices_by_quality::Vector{Float64}
    ema_rents_by_quality::Vector{Float64}
    occupancy_rate_by_quality::Vector{Float64}  # Expected share of rental time occupied: tenancy / (tenancy + expected vacancy)
    
    # Global scalars (aggregates across all quality segments)
    ema_sales_price::Float64
    ema_rent::Float64
    ema_yield::Float64
    # Raw per-step flow yield. It keeps its last value on steps with no rental transactions,
    # while the EMA above is updated toward it every step. This mirrors Java's two-variable
    # avFlowYield / expAvFlowYield pattern in RentalMarketStats.java.
    flow_yield_raw::Float64
    
    # Emergent Indicators (Table 6)
    average_rent::Float64
    avg_rent_to_income::Float64   # Total rent paid / total monthly income of tenants

    # --- Fixed Anchors (the endogenous P_0 and R_0) ---
    # Set once at initialisation from the initial housing stock.
    reference_price::Float64
    reference_rent::Float64
    
    # Vectors length = n_qualities
    reference_prices_by_quality::Vector{Float64}
    reference_rents_by_quality::Vector{Float64}

    # --- Volume / Liquidity ---
    sales_volume::Int
    mortgage_approvals::Int        # Mortgages issued in the previous step (snapshot of `mortgage_flow_temp`)
    rental_transactions::Int       # Tenancies started in the previous step (snapshot of `rental_flow_temp`)
    months_on_market_ema::Vector{Float64}         # Per quality: months on the market before sale
    months_on_market_ema_rental::Vector{Float64}  # Per quality: months on the market before letting

    # --- Demand & Bidding Stats (Java preClearingRecord) ---
    # Written by `record_pre_clearing_stats!` (MarketStats.jl) before a market clears:
    # number of bids and sum of bid prices, number of listings and sum of their asking
    # prices (sale listing price or rental price).
    measured_demand_buyers::Int
    measured_demand_bids_sum::Float64
    measured_supply_sellers::Int
    measured_supply_offer_sum::Float64
    
    # --- History & Buffers ---
    price_history::Vector{Float64}   # Ring buffer of recent HPI values (length `hpi_record_length`)
    hpa_oracle::Float64              # Annualised house price appreciation over `hpa_years_to_check` years
    
    # --- Internal Accumulators (Binning by Quality) ---
    # Vector of Vectors: Index 1 = Quality 1, etc.
    current_sales_by_quality::Vector{Vector{Float64}}
    current_rents_by_quality::Vector{Vector{Float64}}
    current_mom_by_quality::Vector{Vector{Int}} # Months on Market (Sales)
    current_rental_mom_by_quality::Vector{Vector{Int}} # Months on Market (Rental)
    
    mortgage_flow_temp::Int   # Mortgages issued in the current step (published as `mortgage_approvals`)
    rental_flow_temp::Int     # Tenancies started in the current step (published as `rental_transactions`)

    # --- Gross new lending flow (accumulated agent-side) ---
    # `mortgage_flow_principal_temp` accumulates `final_loan_principal` at each mortgage
    # clearance during the step; `update_market_stats!` publishes it to `new_lending_flow`
    # and resets it to 0. Parallels Java's `CreditSupply.newLendingAmount`. Values are in
    # unscaled model currency units; the collector `get_new_lending_flow` applies the UK scaling.
    mortgage_flow_principal_temp::Float64
    new_lending_flow::Float64

    # --- Debt-service telemetry (observation only; no decision reads these fields) ---
    # The snapshot fields are published once per step in `update_market_stats!`.
    # The `*_temp` fields accumulate within the step from FinancialFlows.jl.
    audit_interest_due::Float64
    audit_interest_paid::Float64
    audit_principal_paid::Float64
    audit_interest_due_temp::Float64
    audit_interest_paid_temp::Float64
    audit_principal_paid_temp::Float64

    # --- Active listings ---
    # Persistent sets of house IDs with an active sale / rental listing, so that listings
    # need not be found by scanning the whole housing stock. BitSet keeps iteration cheap.
    active_sales_listings::BitSet
    active_rental_listings::BitSet
    
    # --- Incremental statistics ---
    # Number of rental properties per quality bin that are occupied / vacant, maintained
    # incrementally to avoid a full scan of the housing stock.
    occupied_rentals_by_quality::Vector{Int}
    vacant_rentals_by_quality::Vector{Int}

    # --- Per-step mechanism counters (reset at the start of each step) ---
    n_withdrawals::Int    # Sale listings withdrawn from the market in this step
    n_bankruptcies::Int   # Households with a negative balance resolved by `resolve_insolvency!`
    # Split of n_bankruptcies into FTB / HM / BTL buckets.
    # Invariant: n_bankruptcies == n_bankruptcies_ftb + n_bankruptcies_hm + n_bankruptcies_btl.
    # BTL investors are classified first, then FTB, then HM (see resolve_insolvency! in
    # FinancialFlows.jl). Java keeps a single bankruptcy flag per household and has no such split.
    n_bankruptcies_ftb::Int
    n_bankruptcies_hm::Int
    n_bankruptcies_btl::Int
    # Snapshots of `measured_demand_buyers` / `measured_supply_sellers` taken in
    # `update_market_stats!`. `record_pre_clearing_stats!` is called by both the sales and the
    # rental market, so the snapshot holds the values recorded last.
    n_bids_active::Int
    n_offers_active::Int

    # --- Market Matching State (bids are pushed here and cleared in batch) ---
    bids_queue::Vector{Bid}
    rental_bids_queue::Vector{RentalBid}

    # Household `annual_income` values sorted in ascending order, rebuilt at the end of
    # `update_market_stats!` before `central_bank_step!` reads it. It backs
    # `income_at_percentile`, the counterpart of Spain Java
    # `HouseholdStats.getIncomeLevelFromPercentile(p)`, so that institutions read income
    # percentiles from a statistics collector rather than iterating over households.
    # Populated only when `model.spain_application_income_gate` is true; otherwise it stays empty.
    sorted_household_incomes::Vector{Float64}    # guarded by :spain_application_income_gate

    # --- Consumption ledger (counterpart of Spain Java `HouseholdStats`) ---
    # Five consumption components: rental housing, interest payments, principal repayments,
    # down payments, and non-housing consumption. Each has a `*_counter` field that
    # accumulates during the step and a snapshot field that `update_market_stats!` fills
    # from the counter before resetting the counter to 0.0 (the same pattern as
    # `mortgage_flow_temp` / `mortgage_approvals`). These fields are only collected for
    # output; no decision reads them. The counters are written only when
    # `model.spain_consumption_recording` is true.
    rental_housing_consumption::Float64                  # guarded by :spain_consumption_recording
    interest_payment_housing_consumption::Float64        # guarded by :spain_consumption_recording
    principal_repayment_housing_consumption::Float64     # guarded by :spain_consumption_recording
    downpayment_housing_consumption::Float64             # guarded by :spain_consumption_recording
    non_housing_consumption::Float64                     # guarded by :spain_consumption_recording
    rental_housing_consumption_counter::Float64                 # guarded by :spain_consumption_recording
    interest_payment_housing_consumption_counter::Float64       # guarded by :spain_consumption_recording
    principal_repayment_housing_consumption_counter::Float64    # guarded by :spain_consumption_recording
    downpayment_housing_consumption_counter::Float64            # guarded by :spain_consumption_recording
    non_housing_consumption_counter::Float64                    # guarded by :spain_consumption_recording
end



"""
    House
A passive asset structure representing a single residential unit.
It acts as a container for state, not an active agent.

# Fields
- `id`: Unique ID
- `quality`: Integer (1, 2, or 3) representing the segment (High, Medium, Low)
- `owner_id`: ID of the household who owns this title (or nothing if initial/bank owned)
- `resident_id`: ID of the household living here (or nothing if vacant)
- `is_for_sale`: Bool flag (true if currently listed on the market)
- `listing_price`: Current ask price (if for sale) or last valuation
- `months_on_market`: Counter for how long it has been unsold (drives price reductions)
"""
mutable struct House
    id::Int
    const quality::Int
    
    # Ownership Linkage (We use IDs to decouple memory)
    owner_id::Union{Int, Nothing}
    resident_id::Union{Int, Nothing}
    
    # Market State
    is_for_sale::Bool
    listing_price::Float64
    months_on_market::Int

    # Rental Market State
    is_for_rent::Bool
    rental_price::Float64
    months_on_rental_market::Int
end


"""
    Mortgage
A fixed-rate annuity loan secured against a property. It is mutable because the
remaining principal and remaining term are updated every month by the payment loop
in FinancialFlows.jl.

# Fields
- `mortgage_id`: Unique contract identifier from a global sequential counter.
- `house_id`: ID of the property securing the loan.
- `principal`: Loan amount at origination (not reduced by repayments).
- `remaining_principal`: Outstanding balance.
- `monthly_payment`: Constant monthly annuity payment.
- `origination_rate`: Annual mortgage rate fixed at contract signing; the monthly interest
  charge is `remaining_principal * origination_rate / 12`.
- `term_months`: Remaining term in months; decremented each month. A value of 0 or less
  marks a discharged contract.
- `start_date`: Model time (step) at which the loan was taken out.
- `is_high_lti`: True if the loan counted as above the soft LTI cap while the soft limit
  was active (set by the Bank at origination).
- `is_buy_to_let`: True for buy-to-let loans (Java: `MortgageAgreement.isBuyToLet`); splits
  the credit stock into owner-occupier and BTL loans.
- `is_first_time_buyer`: Borrower classification at origination, used to split owner-occupier
  credit; it stays fixed when the household's `borrower_type` later changes.
"""
mutable struct Mortgage
    mortgage_id::Int
    house_id::Int
    principal::Float64
    remaining_principal::Float64
    monthly_payment::Float64
    origination_rate::Float64
    term_months::Int
    start_date::Int
    is_high_lti::Bool
    is_buy_to_let::Bool
    is_first_time_buyer::Bool
end

"""
    RentalAgreement
A tenancy contract between a landlord and the household renting `house_id`.
`monthly_rent` is the agreed rent per month, `contract_duration_months` the length of the
lease and `months_remaining` the time left on the contract.
"""
mutable struct RentalAgreement
    house_id::Int
    monthly_rent::Float64
    contract_duration_months::Int
    months_remaining::Int
end

# ============================================================================
# ENUMS
# ============================================================================
# Mutually exclusive household states and roles (Carro et al. 2022), used instead of
# loose boolean flags.

"""
    BorrowerType
Regulatory classification of a household as a mortgage borrower: first-time buyer (`FTB`),
home mover (`HM`) or buy-to-let investor (`BTL`).
"""
@enum BorrowerType begin
    FTB  # First-Time Buyer
    HM   # Home Mover (Previous Owner)
    BTL  # Buy-to-Let Investor
end

"""
    TenureStatus
Housing state of a household: `SocialHousing`, `Renter` or `OwnerOccupier`.
"""
@enum TenureStatus begin
    SocialHousing  # Free, transitionary state
    Renter         # Renting private accommodation
    OwnerOccupier  # Owns their residence
end

"""
    ConsumptionObservation

Per-household record written where discretionary consumption is executed
(`process_discretionary_consumption!`, FinancialFlows.jl). It is read only by the
consumption collectors in DataCollection.jl and does not feed back into behaviour.
`valid` is false until the first record has been written; the unset fields then hold NaN
(or -1 for `model_time`). All amounts are per month.

# Fields
- `model_time`: Model time at which the record was written.
- `age`: Household age.
- `tenure`: Tenure status at that time.
- `essential`: Essential consumption.
- `discretionary`: Capped discretionary consumption.
- `non_housing`: `essential + discretionary`.
- `employment_income_monthly`: Monthly wage income.
- `rental_income_monthly`: Approximate monthly rental income.
- `gross_income_monthly`: Estimated gross monthly income used for the consumption cap.
"""
struct ConsumptionObservation
    valid::Bool
    model_time::Int
    age::Float64
    tenure::TenureStatus
    essential::Float64
    discretionary::Float64
    non_housing::Float64
    employment_income_monthly::Float64
    rental_income_monthly::Float64
    gross_income_monthly::Float64
end

ConsumptionObservation() = ConsumptionObservation(
    false,
    -1,
    NaN,
    SocialHousing,
    NaN,
    NaN,
    NaN,
    NaN,
    NaN,
    NaN,
)

"""
    Household
The primary agent type representing a family unit.

## Economic State
- `bank_balance::Float64`: **Financial Wealth**. Total liquid assets available for consumption smoothing, down-payments, and mortgage servicing.
- `annual_income::Float64`: Gross annual income. Derived dynamically from `age` and `income_percentile` using empirical curves.

## Behavioral Traits
- `propensity_to_save::Float64`: Permanent parameter (0.0 - 1.0) determining the target financial wealth and consumption smoothing speed.
- `is_btl_investor::Bool`: Flag indicating if the household has the capacity/willingness to enter the Buy-to-Let market.
- `btl_cap_gain_coeff::Float64`: The weighting parameter \$\\delta_i\$ (0.0 - 1.0) used in yield calculations. 
    - Represents the investor's preference for Capital Gains vs. Rental Yield.
    - Mapped from investor types: Rental-Income-Driven (~0.1), Mixed (~0.5), Capital-Gain-Driven (~0.9).

## Housing Status
- `residence_id::Union{Int, Nothing}`: ID of the property currently occupied by the household. 
    - If `nothing`, the household is in **Social Housing** (homeless/temporary accommodation).
- `mortgages_held::Vector{Int}`: IDs of properties against which this household holds a mortgage liability. 

## Explicit State Tracking (New)
- `tenure_status::TenureStatus`: Explicit enum for current housing state (SocialHousing / Renter / OwnerOccupier).
- `borrower_type::BorrowerType`: Explicit enum for regulatory classification (FTB / HM / BTL).
"""


"""
    Transaction
Struct to record micro-data for every completed sale.
Used for distributional validation (V&V Protocol Figure 2 & 9).
"""
struct Transaction
    step::Int
    house_id::Int
    buyer_id::Int
    seller_id::Union{Int, Nothing} # Nothing if initialized ownership
    mortgage_id::Int              # NEW: unique contract identifier
    price::Float64
    
    # Financials
    loan_amount::Float64
    down_payment::Float64
    annual_income::Float64
    income_percentile::Float64
    permanent_income_quintile::Int
    wealth_before::Float64
    
    # Ratios
    ltv::Float64
    lti::Float64
    
    # Classification
    buyer_type::BorrowerType # FTB, HM, BTL
    buyer_age::Int
    is_buy_to_let::Bool # Explicit flag for the loan purpose
    
    # For Quintile Analysis
    house_quality::Int

    # Seller-side debt on this property at time of sale.
    # Structural guarantee: price >= seller_remaining_principal always.
    # Equity margin = (price - seller_remaining_principal) / price.
    seller_remaining_principal::Float64

    # C.1: Monthly debt service flow (0.0 for cash purchases)
    monthly_payment::Float64
    # C.5: Time-to-sale in months (captured before reset)
    months_on_market::Int
    # C.2: Annual origination rate frozen at contract signing (0.0 for cash)
    mortgage_rate::Float64
    # C.3: Age-adjusted mortgage term at origination, in months (0 for cash)
    origination_term_months::Int
    # C.4: Seller classification at sale ("BTL", "OO", "OTHER", "NONE")
    seller_type::String
    # Exact borrower-type classification of the seller at sale time.
    seller_borrower_type::BorrowerType
    # Affordability constraint fields: buyer's unconstrained desire vs financial capacity at bid time
    p_fundamental::Float64  # agent.desired_purchase_price at bid submission
    p_max::Float64          # calculate_buying_power result at bid submission
end

@agent struct Household(NoSpaceAgent)
    age::Float64
    income_percentile::Float64
    # --- Economic State ---
    bank_balance::Float64
    annual_income::Float64
    
    # --- Behavioral Traits ---
    const propensity_to_save::Float64
    is_btl_investor::Bool
    btl_cap_gain_coeff::Float64 # delta_i (Weight on Capital Gains)

    # --- Housing Status ---
    residence_id::Union{Int, Nothing} = nothing 
    # Track their rental contract (if they are a renter)
    rental_agreement::Union{RentalAgreement, Nothing} = nothing
    # Track their owned properties (Assets)
    properties_owned::Vector{Int} = Int[]
    # Track their debt (if they are an owner)
    mortgages_held::Vector{Mortgage} = Mortgage[]
    
    # --- NEW: Dynamic Loan-Level Ratios (for cross-sectional PD binning) ---
    consumption_observation::ConsumptionObservation = ConsumptionObservation()

    # --- Zombie Debt Container (Java-Parity Path Only) ---
    #
    # Java reference: Household.java:339-348 (completeHouseSale, partial payoff)
    #                 Household.java:124-134 (step, monthly zombie servicing loop)
    # Java behaviour: payoff(bankBalance) books min(bankBalance, principal); residual stays in
    #   housePayments and is serviced each step until fully cleared.
    #
    # Julia lifecycle of a zombie Mortgage object:
    #   ENTRY:  execute_transaction! (HousingMarket.jl) — when JAVA_COMPAT_MODE = true and
    #           residual = remaining_principal - min(post_sale_balance, remaining_principal) > 0.
    #           monthly_payment is scaled to residual/original_principal. The Mortgage object
    #           is moved here via push!(seller.zombie_debts, mortgage) + deleteat! from
    #           mortgages_held. house_id still points to the sold house (identifier only;
    #           the seller no longer owns it).
    #   SERVICE: process_income_and_obligations! (FinancialFlows.jl) — each month, min(
    #           max(0, bank_balance), remaining_principal) is deducted from agent and credited
    #           to bank.cash_reserves. monthly_payment is rescaled. When remaining_principal
    #           reaches 0, the entry is marked for deletion.
    #   EXIT:  deleteat!(agent.zombie_debts, ...) in FinancialFlows.jl — once fully cleared.
    #   DEATH: dead_agent.zombie_debts is abandoned (not transferred to beneficiary);
    #          gc'd with the agent, matching Java's zombie-killer behaviour in transferAllWealthTo.
    #
    # Julia baseline (JAVA_COMPAT_MODE = false, DEFAULT): always empty — mortgages are fully
    #   discharged unconditionally on sale (see the paper's Appendix A.4).
    # Julia Java-parity (JAVA_COMPAT_MODE = true): residual Mortgage objects accumulate here and
    #   are serviced each month by the zombie loop in process_income_and_obligations!
    #   (FinancialFlows.jl) until remaining_principal reaches 0.0.
    zombie_debts::Vector{Mortgage} = Mortgage[]

    # --- Explicit Flags (Compliance Upgrade) ---
    tenure_status::TenureStatus = SocialHousing
    desired_purchase_price::Float64 = 0.0
    borrower_type::BorrowerType = FTB # Default birth state
    # Realized net disposable income after mandatory inflows/outflows.
    # Optional carry-through source for discretionary-consumption logic (D22).
    realized_disposable_income::Float64 = 0.0
    # LTI limit offered by the bank in the Approval in Principle letter.
    # Frozen at bid-time (Java: Household.persistentLTILimit, set in bidForAHome() l.445,
    # used in Bank.requestApproval() via h.getPersistentLTILimit() l.688).
    # Must be set before calculate_buying_power() or evaluate_credit() are called.
    persistent_lti_limit::Float64 = 0.0
    persistent_ltv_limit::Float64 = 0.0
end


"""
    CentralBankRequestedPolicy

Requested thresholds applied at the scheduled policy month. Active thresholds
remain on CentralBank; this immutable snapshot contains no lending histories.
"""
struct CentralBankRequestedPolicy
    max_ltv_ftb::Float64
    max_ltv_hm::Float64
    max_ltv_btl::Float64
    max_dsti::Float64
    max_dsti_ftb::Float64
    max_dsti_hm_btl::Float64
    soft_lti_limit_ftb::Float64
    soft_lti_limit_hm::Float64
    soft_lti_limit_btl::Float64
    soft_max_ltv_ftb::Float64
    soft_max_ltv_hm::Float64
    soft_max_ltv_btl::Float64
    application_income_percentile::Float64
end

"""
    CentralBank
The Regulatory Authority.
Sets the base interest rate (Monetary Policy) and lending limits (Macroprudential Policy).
Based on Carro et al. (2022) Section 3.4 and Section 5.
"""
mutable struct CentralBank
    # --- Monetary Policy ---
    base_rate::Float64 

    # --- Hard Limits (Regulation) ---
    max_ltv_ftb::Float64
    max_ltv_hm::Float64
    max_ltv_btl::Float64
    
    # Legacy/common regulatory DSTI cap (pooled). Kept for back-compat metadata.
    max_dsti::Float64
    # Borrower-split regulatory DSTI caps (effective underwriting caps).
    max_dsti_ftb::Float64
    max_dsti_hm_btl::Float64
    min_icr::Float64

    # --- Soft Limit State ---
    soft_limit_active::Bool
    # Per-type soft LTI thresholds (Java: CentralBank.firstTimeBuyerSoftMaxLTI / homeMoverSoftMaxLTI).
    # Used for high-LTI classification in register_mortgage!() and for prospective
    # queue capacity decisions in get_loan_to_income_limit().
    soft_lti_limit_ftb::Float64      # e.g., 5.4 (Java: CENTRAL_BANK_LTI_SOFT_MAX_FTB)
    soft_lti_limit_hm::Float64       # e.g., 5.6 (Java: CENTRAL_BANK_LTI_SOFT_MAX_HM)
    # Per-type flow allowances (Java: firstTimeBuyerMaxFracOverSoftMaxLTI / homeMoverMaxFracOverSoftMaxLTI).
    soft_lti_allowance_ftb::Float64  # e.g., 0.15 (Java: CENTRAL_BANK_LTI_MAX_FRAC_OVER_SOFT_MAX_FTB)
    soft_lti_allowance_hm::Float64   # e.g., 0.15 (Java: CENTRAL_BANK_LTI_MAX_FRAC_OVER_SOFT_MAX_HM)
    # Pooling mode — mirrors Java resetMonthlyCounters() / getLoanToIncomeLimit() branch.
    # true  = FTB+HM share one combined quota (Java default when FTB == HM allowance).
    # false = independent FTB and HM quotas (never used in published experiments).
    use_pooled_lti_quota::Bool
    # --- History Queues (Rolling 12-month Window, Java: CENTRAL_BANK_LTI_MONTHS_TO_CHECK = 12) ---
    # Per-type 12-month rolling history for adaptive target computation.
    # Java equivalents: nFTBMortgages_List / nFTBMortOverSoftMaxLTI_List (and HM counterparts).
    # Separate histories allow fully independent quota tracking; required for correct
    # operation when FTB and HM allowances diverge.
    history_total_ftb::Vector{Int}       # Monthly count of new FTB mortgages issued
    history_high_lti_ftb::Vector{Int}    # Monthly count of FTB mortgages above the FTB soft LTI
    history_total_hm::Vector{Int}        # Monthly count of new HM mortgages issued
    history_high_lti_hm::Vector{Int}     # Monthly count of HM mortgages above the HM soft LTI


    # --- L1/L2/L3 LTV soft caps (Spain CentralBank.{firstTimeBuyer,homeMover,buyToLet}SoftMaxLTV) ---
    soft_max_ltv_ftb::Float64                # L1: e.g. 0.85 (Spain) / 0.9999 placeholder (UK-default, non-binding)
    max_frac_over_soft_max_ltv_ftb::Float64  # L1: e.g. 0.15 / 0.0 placeholder
    soft_max_ltv_hm::Float64                 # L2
    max_frac_over_soft_max_ltv_hm::Float64   # L2
    soft_max_ltv_btl::Float64                # L3
    max_frac_over_soft_max_ltv_btl::Float64  # L3
    # --- L4 BTL LTI soft cap (Spain CentralBank.buyToLetSoftMaxLTI) ---
    # UK FTB+HM LTI soft caps remain in soft_lti_limit_{ftb,hm} / soft_lti_allowance_{ftb,hm}
    # above, gated by Config.IS_SOFT_LIMIT_ACTIVE — NOT by any Spain Symbol.
    soft_lti_limit_btl::Float64              # L4: Spain target e.g. 5.0 / non-binding placeholder
    soft_lti_allowance_btl::Float64          # L4
    # --- L5 application-income carve-out (Spain CentralBank.applicationIncome{Percentile}) ---
    application_income_percentile::Float64   # L5: e.g. 0.30 — bottom-percentile income carve-out threshold
    application_income::Float64              # L5: recomputed each step via central_bank_step!
                                             #     = income_at_percentile(market_stats, application_income_percentile)
                                             #     (mirror of Spain Java HouseholdStats.getIncomeLevelFromPercentile)
    # --- L6 LTV age carve-out (Spain CentralBank.applicationAgeLTV) ---
    application_age_ltv::Float64             # L6: e.g. 35.0 — LTV cap only binds above this age

    history_high_ltv_ftb::Vector{Int}    # L1: monthly FTB mortgages with LTV > soft_max_ltv_ftb
    history_high_ltv_hm::Vector{Int}     # L2: monthly HM  mortgages with LTV > soft_max_ltv_hm
    history_total_btl::Vector{Int}       # L3+L4 shared: monthly BTL mortgages issued
    history_high_ltv_btl::Vector{Int}    # L3: monthly BTL mortgages with LTV > soft_max_ltv_btl
    history_high_lti_btl::Vector{Int}    # L4: monthly BTL mortgages with LTI > soft_lti_limit_btl

    # nothing: limits apply from initialization; integer: end-of-month activation.
    policy_application_time::Union{Nothing,Int}
    requested_policy::CentralBankRequestedPolicy
end

"""
    Government
A simple entity to accumulate fiscal revenue.
"""

mutable struct Government
    bank_balance::Float64  # Total tax revenue collected
end


"""
    Bank
The Institutional Agent. 
Manages credit supply, evaluates loan requests, and tracks risk.
"""
mutable struct Bank
    id::Int
    
    # --- Risk Policy (Heterogeneous in Phase B) ---
    ltv_max_ftb::Float64  # First-Time Buyer LTV
    ltv_max_hm::Float64   # Home Mover LTV
    ltv_max_btl::Float64  # Buy-to-Let LTV
    
    lti_max_ftb::Float64  # Loan-to-Income
    lti_max_hm::Float64   
    # Mirrors Spain Bank.buyToLetHardMaxLTI (config.properties:683, value 13.8266).
    # UK Java has no BTL LTI surface; UK-default value = Config.LTI_MAX_BTL (99.0,
    # vacuously high → never binds). Consumed in evaluate_credit BTL path only when
    # `model.spain_soft_lti_btl == true`; otherwise BTL retains UK LTV+ICR semantics.
    lti_max_btl::Float64
    
    # Legacy/common bank DSTI cap (pooled). Kept for back-compat metadata.
    dsti_max::Float64
    # Borrower-split bank-internal DSTI caps (effective underwriting caps).
    dsti_max_ftb::Float64
    dsti_max_hm_btl::Float64
    icr_min::Float64      # Interest Coverage Ratio
    
    # --- State ---
    # base_rate: Bank must query CentralBank agent (Source of Truth)
    current_mortgage_rate::Float64
    
    # --- Accounting (For Phase C: Risk Engine) ---
    outstanding_credit::Float64
    bad_debt_provisions::Float64
    cash_reserves::Float64

    # --- D3/D4 Cumulative Audit Counters ---
    # Reset to 0.0 at model initialisation. Monotonically increasing during a run.
    # Used by get_cumulative_zombie_recovered / get_cumulative_inheritance_writeoffs
    # in DataCollection.jl for live simulation comparison between JAVA_COMPAT_MODE modes.
    cumulative_zombie_recovered::Float64        # D3: total cash credited to cash_reserves via zombie servicing
    cumulative_inheritance_writeoffs::Float64   # D4 (false path): total shortfall absorbed as bank write-offs at agent death


    # When modeling detailed banking sector health, add:
    # - capital_adequacy_ratio::Float64  # Tier 1 capital / Risk-Weighted Assets
    # - liquidity_coverage_ratio::Float64 # High-quality liquid assets / Net cash outflows
    # - max_credit_quota::Float64        # Absolute monthly lending limit
    # - risk_weighted_assets::Float64    # RWA calculation for Basel III compliance
    # This would enable rejection logic: "if new_loan would breach CAR → reject"

    # --- Interest Rate Mechanism ---
    current_spread::Float64
    previous_credit_supply::Float64
    current_credit_supply::Float64
    
    # --- Operational Counters (Reporting to CB per borrower type) ---
    # Java equivalents: nFTBMortgages_New / nFTBMortOverSoftMaxLTI_New (and HM counterparts).
    # Reset each step in report_and_reset_activity!(). BTL mortgages are excluded (Java parity:
    # Bank.requestLoan() only increments these counters inside the `if (isHome)` block).
    current_month_total_ftb::Int           # FTB mortgages issued this month
    current_month_high_lti_ftb::Int        # FTB mortgages above the FTB soft LTI this month
    current_month_total_hm::Int            # HM mortgages issued this month
    current_month_high_lti_hm::Int         # HM mortgages above the HM soft LTI this month

    # --- Adaptive Policy (LTI Soft Limit, per borrower type) ---
    # Tracks prospective "Approvals in Principle" (Bidding Stage) per type.
    # Java equivalents: maxFracFTBProspecOverSoftMaxLTI, nFTBMortgages_Prospec,
    # nFTBMortOverSoftMaxLTI_Prospec (and HM counterparts).
    # Reset in update_adaptive_soft_limit!() each step.
    target_prospec_fraction_ftb::Float64   # Adaptive prospective target for FTB queue
    n_prospec_total_ftb::Int               # Prospective FTB mortgages this month (bids placed)
    n_prospec_high_ftb::Int                # Prospective FTB mortgages above soft LTI
    target_prospec_fraction_hm::Float64    # Adaptive prospective target for HM queue
    n_prospec_total_hm::Int                # Prospective HM mortgages this month (bids placed)
    n_prospec_high_hm::Int                 # Prospective HM mortgages above soft LTI

    # --- OO LTV Rolling Window (Java: CreditSupply.oo_ltv) ---
    # Records LTV at origination for new Owner-Occupier mortgages (FTB + HM) over a
    # rolling window of ROLLING_WINDOW months.  Used ONLY for reporting
    # (CoreIndicators.getOwnerOccupierLTVMeanAboveMedian); does NOT feed back into
    # model logic (lending decisions, regulatory checks, or agent behavior).
    # Java: ArrayList<ArrayList<Double>> oo_ltv, indexed by (time % rollingWindow).
    # LTV formula: principal / (principal + downPayment).
    oo_ltv_window::Vector{Vector{Float64}}  # Length = ROLLING_WINDOW; each slot collects one month
    oo_ltv_index::Int                       # Current active slot = (time % ROLLING_WINDOW) + 1 (1-based)

    # --- OO LTI Rolling Window (Java: CreditSupply.oo_lti) ---
    # Records LTI at origination (principal / annual_income) for new OO (FTB + HM) mortgages
    # over a rolling window of ROLLING_WINDOW months. Shares oo_ltv_index — both windows
    # rotate simultaneously in Scheduler.jl Phase 1c. Used ONLY for reporting
    # (CoreIndicators.getOwnerOccupierLTIMeanAboveMedian via get_avg_lti in DataCollection.jl).
    oo_lti_window::Vector{Vector{Float64}}  # Length = ROLLING_WINDOW; each slot collects one month


    # --- Realised monthly counters (mirror Spain Bank.{n*MortOverSoftMax*,n*Mortgages}_New) ---
    # BTL totals are SHARED between L3 and L4: increment when either
    # :spain_soft_ltv_btl OR :spain_soft_lti_btl is on. The total is the denominator for
    # BOTH BTL-LTV-over and BTL-LTI-over adaptive targets.
    current_month_total_btl::Int               # L3+L4 shared
    current_month_high_ltv_ftb::Int            # L1
    current_month_high_ltv_hm::Int             # L2
    current_month_high_ltv_btl::Int            # L3
    current_month_high_lti_btl::Int            # L4

    # --- Prospective counters (mirror Spain Bank.{n*MortOverSoftMax*,n*Mortgages}_Prospec) ---
    # Reset each step in update_adaptive_soft_limit!. Track bids-placed at the
    # approval-in-principle stage (NOT closed mortgages).
    n_prospec_total_btl::Int                   # L3+L4 shared
    n_prospec_high_ltv_ftb::Int                # L1
    n_prospec_high_ltv_hm::Int                 # L2
    n_prospec_high_ltv_btl::Int                # L3
    n_prospec_high_lti_btl::Int                # L4

    # --- Adaptive prospective targets (mirror Spain Bank.maxFrac{FTB,HM,BTL}ProspecOverSoftMax{LTV,LTI}) ---
    target_prospec_fraction_ftb_ltv::Float64   # L1
    target_prospec_fraction_hm_ltv::Float64    # L2
    target_prospec_fraction_btl_ltv::Float64   # L3
    target_prospec_fraction_btl_lti::Float64   # L4

    # --- Data Relational IDs ---
    mortgage_id_counter::Int                # Global sequential mortgage contract ID source

    # Private-bank soft-LTV thresholds.
    ltv_soft_max_ftb::Float64
    ltv_soft_max_hm::Float64
    ltv_soft_max_btl::Float64

    # Probabilities of drawing an internal ceiling above those thresholds.
    ltv_frac_over_soft_max_ftb::Float64
    ltv_frac_over_soft_max_hm::Float64
    ltv_frac_over_soft_max_btl::Float64

end


# ============================================================================
# CONSTRUCTION SECTOR
# ============================================================================
"""
    Construction

Replicates the `Construction` class from the Java codebase
(`src/legacy_codebase/java/housing/Construction.java`).

## Execution timing
**DYNAMIC** — `construction_step!` is called unconditionally every tick from
`model_step!` in Scheduler.jl, mirroring Java `modelStep()` at
Model.java line 187: `construction.step()`.

## Fields
- `housing_stock_count`: Running total of houses ever created.  Mirrors Java
  field `housingStock` (Construction.java line 13).  Synchronised to
  `length(model.housing_stock)` after the pre-build loop in `initialize_model`
  and incremented by `construction_step!` whenever new houses are delivered.
- `n_new_build`: Number of houses built this tick.  Mirrors Java field
  `nNewBuild` (Construction.java line 15).  Reset to 0 at the start of every
  `construction_step!` call and set to the shortfall when positive.

## Fields intentionally omitted
Java also declares `HashSet<House> onMarket` (Construction.java line 19) and
iterates it in `step()` to apply a 5 % monthly price cut (lines 44–46).
That set is **never populated** in the current Java codebase (see
Construction.jl file-header comment for the full trace), making the price-cut
loop dead code.  The field and its associated callbacks (`completeHouseSale`,
`endOfLettingAgreement`, `completeHouseLet`) are therefore omitted from the
Julia struct.  Price reductions for all sale listings — including
construction-originated ones — are handled by `update_for_sale_supply!`
(HousingMarket.jl).

## Java source references
| Symbol                      | Java location                           |
|-----------------------------|-----------------------------------------|
| `housing_stock_count` field | `Construction.java` line 13             |
| `n_new_build` field         | `Construction.java` line 15             |
| `construction_step!`        | `Construction.java` `step()` lines 41–70|
| Model field declaration     | `Model.java` line 45                    |
| Model instantiation         | `Model.java` constructor line 82        |
| Init sync (Julia)           | `Model.java` `init()` line 171          |
"""
mutable struct Construction
    housing_stock_count::Int   # Java: housingStock (Construction.java:13)
    n_new_build::Int           # Java: nNewBuild     (Construction.java:15)
    # Note: Java also declares `HashSet<House> onMarket` (Construction.java:19) and
    # iterates it in step() to apply a 5 % monthly price cut.  However, onMarket is
    # NEVER populated in the current Java codebase: all new houses are transferred
    # immediately to households via inheritHouse() (Construction.java:67), so
    # h.owner becomes the Household, not Construction.  completeHouseSale() is
    # therefore never triggered and onMarket stays permanently empty.  The 5 % cut
    # loop is dead code in Java; the general price-reduction mechanism for all sale
    # listings is handled by update_for_sale_supply! (HousingMarket.jl).
    # This field is intentionally omitted from the Julia struct.
end

# ============================================================================
# EMPIRICAL DATA STRUCTURES (Loaded from CSVs)
# ============================================================================

struct DemographicsData
    age_bins::Vector{Float64}         # Cumulative Upper bounds
    age_probs::Vector{Float64}        # Cumulative probabilities (CDF) of original bins
    raw_bins::Vector{Tuple{Int, Int}} # For specific integer sampling (Lower, Upper)
    
    # New Field: Monthly Smoothing (Java Parity)
    monthly_probs::Vector{Float64}    # PDF of monthly bins (size ~ 100 * 12)
    monthly_bin_width::Float64        # 1/12
    
    expected_per_bin::Vector{Int}     # Fixed integer targets per monthly bin
end

struct IncomeData
    age_lower::Vector{Int}
    age_upper::Vector{Int}
    income_cdf_by_age::Dict{Int, Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}}} 
    # Key: Index of Age Bin. Value: (LogIncome Lower Bounds, LogIncome Upper Bounds, CDF)
    # [D7] Java-compat 100-point inverse CDF tables (pre-computed by build_java_inverse_cdf at load time)
    income_java_inv_cdf_by_age::Dict{Int, Vector{Float64}}
end

struct WealthData
    income_lower::Vector{Float64}
    income_upper::Vector{Float64}
    wealth_cdf_by_income::Dict{Int, Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}}}
    # Key: Index of Income Bin. Value: (LogWealth Lower Bounds, LogWealth Upper Bounds, CDF)
    # [D7] Java-compat 100-point inverse CDF tables (pre-computed by build_java_inverse_cdf at load time)
    wealth_java_inv_cdf_by_income::Dict{Int, Vector{Float64}}
end

struct BTLData
    probabilities::Vector{Float64}  # N values for income-percentile bins (100 for UK, 20 for Spain)
    bin_lowers::Vector{Float64}     # Lower edge of each bin (e.g., 0.0, 0.01, 0.02, ... for UK; 0.0, 0.05, 0.1, ... for Spain)
    bin_uppers::Vector{Float64}     # Upper edge of each bin (e.g., 0.01, 0.02, 0.03, ... for UK; 0.05, 0.1, 0.15, ... for Spain)
end

struct MarkupData
    markup_bins_lower::Vector{Float64}
    markup_bins_upper::Vector{Float64}
    probs::Vector{Float64}            # Weights for categorical sampling
    # [D7] Java-compat 100-point inverse CDF table (pre-computed by build_java_inverse_cdf at load time)
    java_inv_cdf::Vector{Float64}
end

# ============================================================================
# MODEL PROPERTIES (Concrete Struct for Agents.jl)
# ============================================================================
"""
    ModelProperties
Concrete struct for model-level properties to ensure type stability.
Replaces the Dict{Symbol, Any} used in initialization.
"""
mutable struct ModelProperties
    params::ModelParameters
    housing_stock::Vector{House}
    market_stats::MarketStats
    bank::Bank
    central_bank::CentralBank
    government::Government
    # Java: Model.java field `public static Construction construction` (line 45).
    # Instantiated in Model constructor (line 82); init() called per-simulation (line 171);
    # step() called every tick (line 187).
    construction::Construction

    # Empirical Distributions
    demographics::DemographicsData
    income_dist::IncomeData
    wealth_dist::WealthData
    btl_prob::BTLData
    sale_markup_dist::MarkupData
    rent_markup_dist::MarkupData
    
    # --- Logging ---
    transaction_log::Vector{Transaction}
    # --- Divergence Experiment Switches (runtime, per model instance) ---
    d22_use_realized_disposable_income::Bool

    # --- Spanish mechanism flags ---
    # One Bool per mechanism. Consumers read `model.spain_<mechanism>` directly.
    # See Config.jl `SPAIN_MECHANISMS` for the registry and the @assert that
    # keeps these fields in sync with Config + Initialization kwargs.
    spain_gross_income_flow::Bool
    spain_pdf_precision::Bool
    spain_soft_ltv_ftb::Bool              # L1
    spain_soft_ltv_hm::Bool               # L2
    spain_soft_ltv_btl::Bool              # L3
    spain_soft_lti_btl::Bool              # L4
    spain_application_income_gate::Bool   # L5
    spain_application_age_ltv_gate::Bool  # L6
    spain_bank_min_age::Bool
    spain_btl_repayment_yield_formula::Bool  # BTL expected-equity-yield: principal * annual_rate / equity
    spain_consumption_recording::Bool  # 5-counter consumption ledger on MarketStats (rental/interest/principal/downpayment/non-housing)
    # When true: BTL re-routes through OO branch in Bank.evaluate_credit + calculate_buying_power
    # (LTV+LTI+DSTI, ICR dropped); BTL monthly_payment uses annuity formula; BTL term inherits
    # OO age-ladder. Replaces the former Config.D15_BTL_REPAYMENT_MORTGAGE flag.
    spain_btl_repayment_mode::Bool
    spain_essential_nominal_consumption::Bool
    spain_dynamic_affordability_ceiling::Bool
    spain_btl_alternative_return::Bool
    btl_alternative_return::Float64
    spain_bank_age_limits::Bool
    bank_age_limit::Float64
    mortgage_duration_years::Int
    bank_min_age_limit::Float64
    spain_btl_downpayment_distribution::Bool
    btl_downpayment_scale::Float64
    btl_downpayment_shape::Float64
    spain_expectations_naive::Bool
    hpa_years_to_check::Int
    hpi_record_length::Int
    spain_bank_calibration_values::Bool
    spain_distribution_calibration::Bool
    uk_households::Int
    houses_per_household::Float64
    spain_population_scalars::Bool
    # Three diagnostic-only Boolean gates. Numeric values are threaded directly
    # onto `ModelParameters` (psychological_cost_renting, sensitivity_rent_buy,
    # btl_probability_adjustment, mix_adjustment_weight) — already-existing fields.
    # Booleans retained on ModelProperties as introspection handles, mirroring
    # Phases 8c/8d/8e/8f/8g pattern.
    spain_rent_buy_logit::Bool
    spain_btl_probability_multiplier::Bool
    spain_market_avg_price_decay::Bool
    # Boolean introspection handles for the per-CSV path resolver in
    # `Initialization.jl::_init_from_files`. Numeric data flows directly into
    # the loader-returned distribution objects (no `ModelParameters` field).
    spain_demographics_dataset::Bool
    spain_income_age_joint_dataset::Bool
    spain_income_wealth_joint_dataset::Bool
    spain_btl_dataset::Bool
    # Boolean introspection handles for the consumer-site guards in
    # HouseholdBehavior.jl. Vetoes 2 + 3 fire inside `decision_owner_occupier_sell!`
    # before the exogenous-moving roll. `:spain_btl_hard_rules_off` neutralises the
    # existing `Config.BTL_COMPAT_MODE` gates at force-buy (#L459) + sell-floor (#L680).
    spain_sell_home_veto_affordability::Bool
    spain_sell_home_veto_upgrade::Bool
    spain_btl_hard_rules_off::Bool
    spain_record_wealth_aggregates::Bool
    spain_btl_paper_maturity::Bool

    # --- Reproducibility ---
    seed::Int
end
