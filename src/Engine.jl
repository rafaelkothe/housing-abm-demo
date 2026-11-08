# src/Engine.jl
module Engine

using Agents
using Random
using CSV
using DataFrames
using Random: Xoshiro # access the RNG object
using Distributions

# ============================================================================
# MODULE STRUCTURE
# ============================================================================
# We use `include()` to stitch split files into this single module.
# Exports are grouped with their corresponding includes for clarity.
# The order is critical: core types must be defined before the logic that uses them.


# ============================================================================
# 1. Core & Configuration
# ============================================================================
include("core/Config.jl")
export Config

# Defines 'Household', 'House', and 'ModelParameters' structs.
include("core/Types.jl")
export Household, House, ModelParameters, MarketStats, Bank, CentralBank, Mortgage, RentalAgreement
export Bid, RentalBid
export ModelProperties, Transaction
export BorrowerType, FTB, HM, BTL
export TenureStatus, SocialHousing, Renter, OwnerOccupier
export Construction, construction_step!

# Load Empirical Data Helper
include("model/EmpiricalLoader.jl")

# ============================================================================
# 2. Institutions & Behavior (The Brains)
# ============================================================================
# 2.0 Government (Taxation) 
include("institutions/Government.jl") 
# Note: calculate_net_income is now available in Engine scope

# 2.0b Central Bank (Regulation)
include("institutions/CentralBank.jl")

# Bank logic first (defines credit limits)
# 2.1 Institutions 
# Defines 'evaluate_credit' for bank lending decisions.
include("institutions/Bank.jl")

# 2.1b Construction Sector
# Replicates Construction.java — dynamic housing supply, called every tick.
# Java: Model.java modelStep() line 187: construction.step()
include("institutions/Construction.jl") 

# 2.2 Agent Behavior Logic (uses Bank limits)
include("model/HouseholdBehavior.jl")   
export submit_market_bids!

# ============================================================================
# 3. Market Mechanisms (The Environment)
# ============================================================================
# Stats (Oracles) first (used by market clearing)
# 3.1 Housing Market
# Defines 'clear_sales_market!' and 'update_for_sale_supply!'. 
# Logic for the double-sided auction and seller pricing.
include("markets/HousingMarket.jl")

# 3.2 Market Statistics 
# Defines 'update_market_stats'. Tracks HPI, EMA prices, and other aggregate stats.
# Used by market clearing to inform agents of current "Going Rates".
include("markets/MarketStats.jl")

# 3.3 Rental Market
# Defines 'clear_rental_market!' and 'update_rental_supply!'. 
# Logic for matching tenants to landlords and dynamic rent adjustment.
include("markets/RentalMarket.jl")

# ============================================================================
# 4. Model Scheduling & Logic
# ============================================================================
include("model/Demographics.jl") # Load Population Dynamics (Stationary Population)
export demographics_step!, create_new_household!, process_death!

# 4.1 Financial Flows
# Handles monthly cash flows (Mortgages, Rent) and debt accumulation.
include("model/FinancialFlows.jl")

# 4.2 Scheduler
# The global stepping function ('model_step!') that orchestrates the phase order.
include("model/Scheduler.jl")

include("model/Initialization.jl")

# ============================================================================
# 5. Analysis
# ============================================================================
# Defines functions for data collection and visualization.
include("analysis/DataCollection.jl")
export build_data_collectors

# ============================================================================
# Post-processing
# Pure post-processing pipeline. Reads finished simulation outputs and emits
# the Spanish 9-moment and 13-moment calibration vectors via OECD HP
# filter (λ=129,600) + FFT period detection. No behavioural feedback into the
# engine, so simulation results are unaffected. See `src/post/SpanishMoments.jl`
# header for the definitions.
include("post/SpanishMoments.jl")
using .SpanishMoments
export SpanishMoments

end
