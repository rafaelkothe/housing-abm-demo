#!/usr/bin/env julia
# ============================================================================
# WORKING DATA RUN — N_MC × N_STEPS Steps
# Experiments filtered via WD_EXPERIMENTS env var (default: all).
# Saves output to the directory passed as the first CLI argument.
# ============================================================================

using Pkg
if isfile(joinpath(@__DIR__, "..", "Project.toml"))
    Pkg.activate(joinpath(@__DIR__, ".."))
elseif isfile("Project.toml")
    Pkg.activate(".")
end

using Agents
using DataFrames
using CSV
using Statistics
using Dates
using Printf
using Random

include(joinpath(@__DIR__, "..", "src", "Engine.jl"))
using .Engine

# ============================================================================
# CONFIGURATION
# ============================================================================
const WD_N_HOUSEHOLDS   = parse(Int, get(ENV, "WD_N_HOUSEHOLDS", string(Config.N_HOUSEHOLDS)))
const WD_N_STEPS        = parse(Int, get(ENV, "WD_N_STEPS",        "10000"))  # override: WD_N_STEPS=3500 julia ...
const WD_RECORD_START   = parse(Int, get(ENV, "WD_RECORD_START",   "2000"))   # override: WD_RECORD_START=500 julia ... (MSM: 500)
const WD_N_MC_RUNS      = parse(Int, get(ENV, "WD_N_MC_RUNS",      "30"))     # override: WD_N_MC_RUNS=2 julia ...

# Output directory: first command-line argument, or default
const WD_RESULTS_DIR = length(ARGS) >= 1 ? abspath(ARGS[1]) : joinpath(@__DIR__, "working_data")
mkpath(WD_RESULTS_DIR)

# ── Thread-count guard ────────────────────────────────────────────────────────
# Parallelism requires julia --threads=N (or --threads=auto).
# Serial fallback is silent and correct but extremely slow at WD_N_MC_RUNS >= 10.
if Threads.nthreads() == 1
    @warn """
    Running with 1 thread — MC loop will execute serially.
    For full parallelism launch with:
        julia --threads=$(WD_N_MC_RUNS) scripts/run_working_data.jl
    or: julia --threads=auto scripts/run_working_data.jl
    """
end

let _alpha_desc = Config.EMA_SMOOTHING_TABLE16 ?
        @sprintf("TABLE16 w=0.14 → α≈%.4f (editorial error)", Config.MARKET_SMOOTHING_FACTOR) :
        @sprintf("Footnote46+Java w=0.25 → α≈%.4f (DEFAULT)", Config.MARKET_SMOOTHING_FACTOR)
    global _WD_ALPHA_DESC = _alpha_desc
end

println("=" ^ 80)
let _exp_label = get(ENV, "WD_EXPERIMENTS", "all")
    println(" WORKING DATA RUN ($(WD_N_MC_RUNS) MC × $(WD_N_STEPS) Steps | Experiments: $(_exp_label))")
end
# --- Reproducibility Header ---
let _git_commit = try strip(read(`git rev-parse --short HEAD`, String)) catch; "unknown" end
    _git_branch = try strip(read(`git branch --show-current`, String)) catch; "unknown" end
    _run_date = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    _julia_ver = string(VERSION)
    _n_threads = Threads.nthreads()
    println(" Date: $(_run_date) | Julia: $(_julia_ver) | Threads: $(_n_threads)")
    println(" Git: $(_git_commit) @ $(_git_branch)")
    global _WD_GIT_COMMIT = _git_commit
    global _WD_GIT_BRANCH = _git_branch
    global _WD_RUN_DATE = _run_date
    global _WD_JULIA_VER = _julia_ver
    global _WD_N_THREADS = _n_threads
end
println(" N_HOUSEHOLDS=$(WD_N_HOUSEHOLDS) | N_STEPS=$(WD_N_STEPS) | RECORD_START=$(WD_RECORD_START) | MC=$(WD_N_MC_RUNS)")
println(" BTL_COMPAT_MODE=$(Config.BTL_COMPAT_MODE)")
println(" D1_GAZUMPING=$(Config.D1_GAZUMPING_COMPAT) | D1_RENTAL=$(Config.D1_RENTAL_COMPAT)")
println(" D2_SELF=$(Config.D2_SELF_OWNERSHIP_GUARD) | D3_ZOMBIE=$(Config.D3_ZOMBIE_DEBT) | D4_INHERIT=$(Config.D4_INHERITANCE_OVERPAY)")
println(" D5_DOWN_PMT=$(Config.D5_DOWN_PAYMENT_COMPAT) | D6_BIDUP=$(Config.D6_BIDUP_FLOOR)")
println(" D7_WEALTH=$(Config.D7_WEALTH_COMPAT) | D7_MARKUP=$(Config.D7_MARKUP_COMPAT) | D7_INCOME=$(Config.D7_INCOME_COMPAT)")
println(" D11_RENTAL_CONTRACTED=$(Config.D11_RENTAL_CONTRACTED_RENT) | D13_BTL_INT=$(Config.D13_BTL_INTEREST_FULL_GUARD)")
println(" D15_BTL_REPAY=RETIRED-PHASE8A (use :spain_btl_repayment_mode Symbol)")
println(" D16_BTL_DP=$(Config.D16_BTL_DP_NO_UPPER_CLAMP) | D17_RENT_FLOOR=$(Config.D17_RENTAL_BID_NO_FLOOR) | D18_PRE_BEH=$(Config.D18_PRE_INCOME_BEHAVIORAL) | D19_MODE=$(Config.D19_MODE)")
println(" EMA_TABLE16=$(Config.EMA_SMOOTHING_TABLE16) | EMA: $(_WD_ALPHA_DESC)")
let _dsti_ov = get(ENV, "WD_LIMIT_DSTI", "-"), _icr_ov = get(ENV, "WD_LIMIT_ICR", "-"),
    _dsti_ftb_ov = get(ENV, "WD_LIMIT_DSTI_FTB", "-"), _dsti_hmbtl_ov = get(ENV, "WD_LIMIT_DSTI_HM_BTL", "-"),
    _bdsti_ov = get(ENV, "WD_BANK_DSTI_MAX", "-"),
    _bdsti_ftb_ov = get(ENV, "WD_BANK_DSTI_MAX_FTB", "-"), _bdsti_hmbtl_ov = get(ENV, "WD_BANK_DSTI_MAX_HM_BTL", "-"),
    _ltv_f = get(ENV, "WD_LIMIT_LTV_FTB", "-"), _ltv_h = get(ENV, "WD_LIMIT_LTV_HM", "-"),
    _ltv_b = get(ENV, "WD_LIMIT_LTV_BTL", "-")
    println(" Env overrides: DSTI=$(_dsti_ov) DSTI_FTB=$(_dsti_ftb_ov) DSTI_HM_BTL=$(_dsti_hmbtl_ov) ICR=$(_icr_ov) BankDSTI=$(_bdsti_ov) BankDSTI_FTB=$(_bdsti_ftb_ov) BankDSTI_HM_BTL=$(_bdsti_hmbtl_ov) LTV_FTB=$(_ltv_f) LTV_HM=$(_ltv_h) LTV_BTL=$(_ltv_b)")
end
let _slti_act = get(ENV, "WD_SOFT_LTI_ACTIVE", "-"),
    _slti_ftb = get(ENV, "WD_SOFT_LTI_LIMIT_FTB", "-"), _slti_hm = get(ENV, "WD_SOFT_LTI_LIMIT_HM", "-"),
    _flow_ftb = get(ENV, "WD_FLOW_LIMIT_FTB", "-"), _flow_hm = get(ENV, "WD_FLOW_LIMIT_HM", "-"),
    _pooled = get(ENV, "WD_USE_POOLED_LTI_QUOTA", "-")
    println(" LTI overrides: soft_active=$(_slti_act) soft_ftb=$(_slti_ftb) soft_hm=$(_slti_hm) flow_ftb=$(_flow_ftb) flow_hm=$(_flow_hm) pooled=$(_pooled)")
end
# Spain port: mechanism toggle audit. Echoes every `WD_SPAIN_*` env override
# detected for the Symbols listed in `Config.SPAIN_MECHANISMS`.
let _spain_echo = String[]
    for _mech in Config.SPAIN_MECHANISMS
        _envname = "WD_" * uppercase(string(_mech))
        push!(_spain_echo, "$(_envname)=$(get(ENV, _envname, "-"))")
    end
    println(" Spain mechanisms: " * join(_spain_echo, " "))
end
println(" Output: $(WD_RESULTS_DIR)")
println("=" ^ 80)

# ============================================================================
# EXPERIMENT DEFINITIONS
# ============================================================================

struct WDExperimentConfig
    name::String
    reg_ltv_ftb::Float64
    reg_ltv_hm::Float64
    reg_ltv_btl::Float64
    soft_lti_active::Bool
    soft_lti_limit_ftb::Float64
    soft_lti_limit_hm::Float64
    flow_limit_ftb::Float64
    flow_limit_hm::Float64
    use_pooled_lti_quota::Bool
    desc::String
end

# E1: Baseline (2011 Benchmark)
# Regulatory: None (banks use internal limits only).
# "None" in code = Regulatory Limit set to 1.0 (high enough never to bind).
# Carro text says "Regulatory Limits (None)"; Config.jl defaults are 1.0 (inactive).
# Bank internal LTV maps: Max 0.9 (FTB/HM), 0.75 (BTL) — these are what bind in E1.
# Explicit loose limits (1.0) are set below to ensure reg limits never interfere.
const WD_E1 = WDExperimentConfig(
    "E1_Baseline",
    1.0, 1.0, 1.0,           # LTV = 1.0: bank internal limits (0.90/0.75) will bind instead
    false, 0.0, 0.0, 0.0, 0.0, # No Soft LTI (use_pooled_lti_quota irrelevant when inactive)
    false,                   # use_pooled_lti_quota (irrelevant: soft_lti_active=false)
    "Baseline: No Regulatory Intervention"
)

# E2: Policy Shock A (Hard LTV)
# Hard Max LTV = 0.85 for Owner-Occupiers (FTB + HM).
# Bank internal limits are the same as E1 (reg limit supersedes where stricter).
# BTL is unaffected: bank's own hard limit of 0.75 is already stricter than 0.85.
const WD_E2 = WDExperimentConfig(
    "E2_LTV_Shock",
    0.85, 0.85, 1.0,         # 85% for FTB/HM; BTL loose (bank's 0.75 binds instead)
    false, 0.0, 0.0, 0.0, 0.0, # No Soft LTI (use_pooled_lti_quota irrelevant when inactive)
    false,                   # use_pooled_lti_quota (irrelevant: soft_lti_active=false)
    "Hard LTV Cap at 0.85 for Owner-Occupiers"
)

# E3: Policy Shock B (Soft LTI) — Carro et al. (2022) Figure 2 / Section 5.3 experiment
#
# PAPER vs CODE DIVERGENCE NOTE:
#
#   Limit Type                | Value  | Source
#   --------------------------|--------|--------------------------------------------------
#   E3 Soft Limit (FTB & HM)  | 3.35x  | Carro et al., footnote 30
#   Real-world BoE 2014 limit | 4.5x   | Carro et al., footnote 31
#   Bank Hard Limit (FTB)     | 5.4x   | Java: BANK_LTI_HARD_MAX_FTB (config.properties:371)
#   Bank Hard Limit (HM)      | 5.6x   | Java: BANK_LTI_HARD_MAX_HM  (config.properties:374)
#   CB Soft Max calibration   | 5.4/5.6| Java: CENTRAL_BANK_LTI_SOFT_MAX_FTB/HM (lines 73,76)
#
# WHY 3.35?
# Authors deliberately chose a value LOWER than the real-world 4.5x because the model is
# calibrated to 2011 data; at 2011 income levels, 4.5x would not constrain enough borrowers
# to generate significant effects. 3.35x was chosen so the LTI experiment affects ~20% of
# borrowers, comparable to the LTV experiment. (Carro et al., footnote 30)
#
# HOW IT WORKS:
# 3.35 overrides BOTH cb.soft_lti_limit_ftb AND cb.soft_lti_limit_hm (the classification
# thresholds). Bank hard limits (lti_max_ftb=5.4, lti_max_hm=5.6) are UNCHANGED.
# A borrower's LTI is compared to 3.35 in register_mortgage!() to determine high-LTI status.
# When the prospective queue is full, get_loan_to_income_limit() returns min(5.4, 3.35)=3.35
# for FTB and min(5.6, 3.35)=3.35 for HM.
#
# POOLING:
# Both flow allowances are 0.15 (equal) → Java ALWAYS uses the pooled path for this
# experiment. FTBs and HMs compete for the SAME 15% slot. use_pooled_lti_quota=true.
const WD_E3 = WDExperimentConfig(
    "E3_LTI_Shock",
    1.0, 1.0, 1.0,           # LTV loose (not binding)
    true,                    # Soft LTI active
    3.35, 3.35,              # CB soft cap: 3.35x FTB and HM (Carro et al., footnote 30; NOT 5.4/5.6)
    0.15, 0.15,              # Flow allowance: 15% for both types (Java lines 79, 82)
    true,                    # use_pooled_lti_quota=true (Java default: 0.15==0.15 → pooled)
    "Soft LTI 3.35x, 15% flow allowance, pooled FTB+HM quota (Carro et al. 2022 Fig 2/Sec 5.3)"
)

# Filter via WD_EXPERIMENTS env var: comma-separated name prefixes, or "all" (default).
# Example: WD_EXPERIMENTS=E1_Baseline julia ... scripts/run_working_data.jl output/dir
const WD_EXPERIMENTS = let
    _all = [WD_E1, WD_E2, WD_E3]
    _sel = get(ENV, "WD_EXPERIMENTS", "all")
    _sel == "all" ? _all : filter(e -> any(startswith(e.name, s) for s in split(_sel, ",")), _all)
end

# ============================================================================
# PERIODIC AGENT SNAPSHOT INTERVAL
# Panels (g) and (h) compare against cross-sectional surveys (WAS, EPLS).
# A single end-of-run snapshot is vulnerable to the BTL maturity-cliff:
# investors whose 25-year mortgages mature near step 10,000 are forced to sell,
# artificially deflating the portfolio distribution.  Sampling every
# AGENT_SNAPSHOT_INTERVAL months (post-burn-in) captures the time-averaged
# steady-state distribution that the cross-sectional surveys represent.
# ============================================================================
const AGENT_SNAPSHOT_INTERVAL = 600   # every 50 simulated years (~13 cross-sections per run)
                                       # Sufficient to dilute the BTL maturity-cliff effect while
                                       # keeping the _agents.csv row count ≈ the original single-
                                       # snapshot footprint (50 runs × 13 × ~800 BTL ≈ 520k rows).

# ============================================================================
# PERIODIC FULL-POPULATION SNAPSHOT INTERVAL (Multi-snapshot extension)
# Java's MicroDataRecorder records ALL agents every 12 steps from step 996
# (84 snapshots/run over N_STEPS=2000).  Scaled to our N_STEPS=10,000:
#   freq=12 → 666 snapshots × 10k agents × 30 MC = 200M rows (too large)
#   freq=1200 → ~6 snapshots × 10k agents × 30 MC = 1.8M rows (manageable)
# These periodic full-population snapshots enable time-averaged distributional
# validation (income, wealth, tenure shares) and reduce single-draw bias from
# using only the final-step snapshot. Analysis code can average over all
# full-population snapshots for smoother estimates; the final snapshot is
# still written at the last step.
# ============================================================================
const FULL_SNAPSHOT_INTERVAL = 1200   # every 100 simulated years (~6 full-pop snapshots post-burn-in)

@inline function permanent_income_quintile_from_percentile(percentile::Real)::Int
    return clamp(ceil(Int, Float64(percentile) * 5.0), 1, 5)
end

"""
    wd_agent_snapshot(agents_vec, model, mc_id, step_id)

Builds a per-agent DataFrame for one snapshot step.

Key field — `rental_income_annual`:
  Summed from each tenant's active `RentalAgreement.monthly_rent × 12` for
  every tenanted investment property owned by the investor.  This is the
  endogenous contracted income, NOT a 5% static proxy.  The paper notes
  that the 5% initial gross yield \"disappears soon after the model starts
  running\", so only the contracted rent is the correct income measure for
  comparing against the WAS Wave 3 distribution (Figure 2g).
"""
function wd_agent_snapshot(agents_vec, model, mc_id::Int, step_id::Int; btl_only::Bool = true)
    target_vec = btl_only ? filter(a -> a.is_btl_investor && length(a.properties_owned) > 1, agents_vec) : agents_vec
    n      = length(target_vec)
    houses = model.housing_stock

    ids             = Vector{Int}(undef, n)
    ages            = Vector{Float64}(undef, n)
    incomes         = Vector{Float64}(undef, n)
    income_percentiles = Vector{Float64}(undef, n)
    permanent_income_quintiles = Vector{Int}(undef, n)
    bank_bals       = Vector{Float64}(undef, n)
    mortgage_debts  = Vector{Float64}(undef, n)
    housing_equity  = Vector{Float64}(undef, n)
    total_wealth    = Vector{Float64}(undef, n)
    is_btls         = Vector{Bool}(undef, n)
    has_res_morts   = Vector{Bool}(undef, n)
    tenures         = Vector{String}(undef, n)
    n_props         = Vector{Int}(undef, n)
    rental_incomes  = Vector{Float64}(undef, n)
    consumption_record_valid = Vector{Bool}(undef, n)
    consumption_model_time = Vector{Int}(undef, n)
    consumption_age = Vector{Float64}(undef, n)
    consumption_tenure = Vector{String}(undef, n)
    consumption_essential_monthly = Vector{Float64}(undef, n)
    consumption_discretionary_monthly = Vector{Float64}(undef, n)
    consumption_non_housing_monthly = Vector{Float64}(undef, n)
    consumption_employment_income_monthly = Vector{Float64}(undef, n)
    consumption_rental_income_monthly = Vector{Float64}(undef, n)
    consumption_gross_income_monthly = Vector{Float64}(undef, n)

    @inbounds for (i, a) in enumerate(target_vec)
        ids[i]       = a.id
        ages[i]      = a.age
        incomes[i]   = a.annual_income
        income_percentiles[i] = a.income_percentile
        permanent_income_quintiles[i] = permanent_income_quintile_from_percentile(a.income_percentile)
        bank_bals[i] = a.bank_balance
        is_btls[i]   = a.is_btl_investor
        tenures[i]   = String(Symbol(a.tenure_status))
        # Per-agent debt + mark-to-market net housing equity (Java-parity valuation basis):
        #   mortgage_debt_i  = Σ_h Debt(h)
        #   housing_equity_i = Σ_h [EMAPrice(h) - Debt(h)]
        #   total_wealth_i   = bank_balance_i + housing_equity_i
        debt_by_property = Dict{Int,Float64}()
        for m in a.mortgages_held
            debt_by_property[m.house_id] = get(debt_by_property, m.house_id, 0.0) + m.remaining_principal
        end
        debt_i = 0.0
        equity_i = 0.0
        for pid in a.properties_owned
            d = get(debt_by_property, pid, 0.0)
            debt_i += d
            h = houses[pid]
            gross = model.market_stats.ema_prices_by_quality[h.quality]
            equity_i += gross - d
        end
        mortgage_debts[i] = debt_i
        housing_equity[i] = equity_i
        total_wealth[i]   = a.bank_balance + equity_i

        obs = a.consumption_observation
        consumption_record_valid[i] = obs.valid
        consumption_model_time[i] = obs.model_time
        consumption_age[i] = obs.age
        consumption_tenure[i] = String(Symbol(obs.tenure))
        consumption_essential_monthly[i] = obs.essential
        consumption_discretionary_monthly[i] = obs.discretionary
        consumption_non_housing_monthly[i] = obs.non_housing
        consumption_employment_income_monthly[i] = obs.employment_income_monthly
        consumption_rental_income_monthly[i] = obs.rental_income_monthly
        consumption_gross_income_monthly[i] = obs.gross_income_monthly

        # Exact residence-mortgage discriminator (same logic as the data collectors).
        has_res_morts[i] = a.residence_id !== nothing &&
                           any(m -> m.house_id == a.residence_id, a.mortgages_held)

        # Investment-property count: total owned minus the owner-occupied home.
        # Uses residence_id (not tenure_status) to handle the edge case where a
        # BTL investor is temporarily in social housing or renting.
        n_props[i]   = a.is_btl_investor ?
                       length(a.properties_owned) - (a.residence_id !== nothing ? 1 : 0) : 0

        # Actual contracted annual rental income.
        # Walk each owned property; if a tenant has an active lease on that
        # property, accumulate their contracted monthly_rent × 12.
        rental = 0.0
        if a.is_btl_investor && !isempty(a.properties_owned)
            for pid in a.properties_owned
                h = houses[pid]
                if h.resident_id !== nothing && h.resident_id != a.id &&
                        Agents.hasid(model, h.resident_id)
                    tenant = model[h.resident_id]
                    if tenant.rental_agreement !== nothing &&
                            tenant.rental_agreement.house_id == pid
                        rental += tenant.rental_agreement.monthly_rent * 12.0
                    end
                end
            end
        end
        rental_incomes[i] = rental
    end

    return DataFrame(
        run_id               = mc_id,
        step                 = step_id,
        snapshot_scope       = fill(btl_only ? "btl_only" : "full_population", n),
        id                   = ids,
        age                  = ages,
        income               = incomes,
        income_percentile    = income_percentiles,
        permanent_income_quintile = permanent_income_quintiles,
        bank_balance         = bank_bals,
        mortgage_debt        = mortgage_debts,
        housing_equity       = housing_equity,
        total_wealth         = total_wealth,
        is_btl               = is_btls,
        has_residence_mortgage = has_res_morts,
        tenure               = tenures,
        n_properties         = n_props,
        rental_income_annual = rental_incomes
        ,consumption_record_valid = consumption_record_valid
        ,consumption_model_time = consumption_model_time
        ,consumption_age = consumption_age
        ,consumption_tenure = consumption_tenure
        ,consumption_essential_monthly = consumption_essential_monthly
        ,consumption_discretionary_monthly = consumption_discretionary_monthly
        ,consumption_non_housing_monthly = consumption_non_housing_monthly
        ,consumption_employment_income_monthly = consumption_employment_income_monthly
        ,consumption_rental_income_monthly = consumption_rental_income_monthly
        ,consumption_gross_income_monthly = consumption_gross_income_monthly
    )
end

"""
    wd_mortgage_stock_snapshot(agents_vec, mc_id, step_id)

Builds an exact mortgage-contract stock snapshot by permanent-income quintile
and mortgage purpose.
"""
function wd_mortgage_stock_snapshot(agents_vec, mc_id::Int, step_id::Int)
    counts = Dict{Tuple{Int,Bool,Union{Missing,Bool}},Int}()

    @inbounds for a in agents_vec
        q = permanent_income_quintile_from_percentile(a.income_percentile)
        for m in a.mortgages_held
            oo_origination_ftb = m.is_buy_to_let ? missing : m.is_first_time_buyer
            key = (q, m.is_buy_to_let, oo_origination_ftb)
            counts[key] = get(counts, key, 0) + 1
        end
    end

    n = length(counts)
    qs = Vector{Int}(undef, n)
    is_btl_mortgages = Vector{Bool}(undef, n)
    is_first_time_buyer_originations = Vector{Union{Missing,Bool}}(undef, n)
    active_counts = Vector{Int}(undef, n)

    i = 0
    for ((q, is_btl_mortgage, is_first_time_buyer_origination), active_count) in
            sort(collect(counts); by = x -> (
                x[1][1],
                x[1][2],
                ismissing(x[1][3]) ? 2 : (x[1][3] ? 1 : 0),
            ))
        i += 1
        qs[i] = q
        is_btl_mortgages[i] = is_btl_mortgage
        is_first_time_buyer_originations[i] = is_first_time_buyer_origination
        active_counts[i] = active_count
    end

    return DataFrame(
        run_id = fill(mc_id, n),
        step = fill(step_id, n),
        permanent_income_quintile = qs,
        is_btl_mortgage = is_btl_mortgages,
        is_first_time_buyer_origination = is_first_time_buyer_originations,
        active_mortgage_count = active_counts,
    )
end

# ============================================================================
# COLUMN RENAME MAP
# Maps custom step-loop column names (Symbol of each mdata function) to the
# short output column names.
# ============================================================================
const MD_RENAME = Dict(
    :time                       => :step,
    :get_sales_volume           => :sales_volume,
    :get_mortgage_approvals     => :mortgage_approvals,
    :get_mean_house_price       => :avg_price,
    :get_mean_rent              => :avg_rent,
    :get_market_hpi             => :hpi,
    :get_rpi                    => :rpi,
    :get_market_yield           => :avg_yield,       # stock yield (kept for back-compat)
    :get_flow_yield             => :flow_yield,       # EMA flow yield — use for calibration
    :get_price_to_income_ratio  => :price_to_income,
    :get_price_to_income_gross  => :price_to_income_gross,
    :get_price_to_income_ratio_oo  => :price_to_income_oo,
    :get_price_to_income_ratio_btl => :price_to_income_btl,
    :get_price_to_income_gross_oo  => :price_to_income_gross_oo,
    :get_price_to_income_gross_btl => :price_to_income_gross_btl,
    :get_ownership_rate         => :owner_occupier_share,
    :get_rental_rate            => :private_renting_share,
    :get_btl_population_share   => :investor_share,
    :get_n_btl_investors        => :n_btl_investors,
    :get_total_btl_properties   => :total_btl_properties,
    :get_avg_ltv_stock          => :avg_ltv_stock,
    :get_avg_ltv_owner_occupier => :oo_ltv_flow,
    :get_avg_lti                => :avg_lti,
    :get_avg_dti_stock          => :avg_dti_stock,
    :get_interest_rate_spread   => :mortgage_spread,
    :get_n_withdrawals          => :n_withdrawals,
    :get_n_bankruptcies         => :n_bankruptcies,
    :get_n_bankruptcies_ftb     => :n_bankruptcies_ftb,
    :get_n_bankruptcies_hm      => :n_bankruptcies_hm,
    :get_n_bankruptcies_btl     => :n_bankruptcies_btl,
    :get_n_bids                 => :n_bids,
    :get_n_offers               => :n_offers,
    :get_total_housing_wealth   => :total_housing_wealth,
    :get_mean_bank_balance      => :mean_bank_balance,
    :get_total_debt             => :total_debt,
    :get_n_active_mortgages     => :n_active_mortgages,
    :get_n_oo_mortgages         => :n_oo_mortgages,
    :get_n_btl_mortgages        => :n_btl_mortgages,
    :get_avg_dsti_stock          => :avg_dsti_stock,
    :get_avg_dsti_stock_btl      => :avg_dsti_stock_btl,
    :get_avg_dsti_flow           => :avg_dsti_flow,
    :get_avg_dsti_flow_btl       => :avg_dsti_flow_btl,
    :get_oo_with_mortgage_rate   => :oo_with_mortgage_rate,
    :get_oo_outright_rate        => :oo_outright_rate,
    :get_vacancy_rate            => :vacancy_rate,
    :get_vacant_for_sale         => :vacant_for_sale,
    :get_vacant_for_rent         => :vacant_for_rent,
    :get_vacant_unlisted         => :vacant_unlisted,
    :get_mean_mortgage_age       => :mean_mortgage_age,
    :get_p75_mortgage_age        => :p75_mortgage_age,
    :get_interest_due_this_step              => :interest_due_this_step,
    :get_interest_paid_this_step             => :interest_paid_this_step,
    :get_principal_paid_this_step            => :principal_paid_this_step,
    :get_ead_weighted_mortgage_rate          => :ead_weighted_mortgage_rate,
    :get_ead_weighted_mortgage_rate_oo       => :ead_weighted_mortgage_rate_oo,
    :get_ead_weighted_mortgage_rate_btl      => :ead_weighted_mortgage_rate_btl,
    :get_ead_weighted_mortgage_spread        => :ead_weighted_mortgage_spread,
    :get_ead_weighted_mortgage_spread_oo     => :ead_weighted_mortgage_spread_oo,
    :get_ead_weighted_mortgage_spread_btl    => :ead_weighted_mortgage_spread_btl,
    :get_n_households           => :n_households,
    :get_n_consumption_observations => :n_consumption_observations,
    :get_essential_consumption  => :essential_consumption,
    :get_discretionary_consumption => :discretionary_consumption,
    :get_non_housing_consumption => :non_housing_consumption,
    :get_non_housing_consumption_per_household => :non_housing_consumption_per_household,
    :get_consumption_gross_income_monthly => :consumption_gross_income_monthly,

)

# ============================================================================
# EXECUTION
# ============================================================================

#

function _rm_retry(path::AbstractString; recursive::Bool = false, max_attempts::Int = 6)
    for attempt in 1:max_attempts
        try
            rm(path; force = true, recursive = recursive)
            return true
        catch e
            if !(e isa Base.IOError) || attempt == max_attempts
                @warn "Giving up removing path after $attempt attempt(s) (leaving it for the OS to reap later — does not affect result correctness)" path exception = e
                return false
            end
            GC.gc()  # Encourage release of any lingering mmap'd CSV.read handles.
            sleep(0.25 * attempt)  # Backoff: 0.25s, 0.5s, 0.75s, ...
        end
    end
    return false
end

function _stream_concat_write(paths::Vector{Union{String,Nothing}}, out_path::String)
    wrote_any = false
    for p in paths
        p === nothing && continue
        df = CSV.read(p, DataFrame)
        CSV.write(out_path, df; append = wrote_any, writeheader = !wrote_any)
        df = nothing
        wrote_any = true
        _rm_retry(p)
    end
    return wrote_any
end

function wd_run_experiment(exp::WDExperimentConfig)
    println("\n" * "-" ^ 66)
    println(" Starting Experiment: $(exp.name)")
    println(" Description: $(exp.desc)")
    println("-" ^ 66)

    all_runs_mdf    = Vector{Union{String,Nothing}}(undef, WD_N_MC_RUNS)
    all_runs_tx     = Vector{Union{String,Nothing}}(undef, WD_N_MC_RUNS)
    all_runs_agents = Vector{Union{String,Nothing}}(undef, WD_N_MC_RUNS)
    all_runs_mortgage_stock = Vector{Union{String,Nothing}}(undef, WD_N_MC_RUNS)
    _mc_tmp_dir = mkpath(joinpath(WD_RESULTS_DIR, ".mc_scratch_$(exp.name)"))

    # Build collectors once — DataCollection.jl is the single source of truth.
    # mdata is a read-only Vector{Function}; safe to share across threads.
    _, mdata = Engine.build_data_collectors()

    # Lock for interleaved progress output (correctness does not require it — cosmetic).
    print_lock = ReentrantLock()

    Threads.@threads for mc in 1:WD_N_MC_RUNS
        t0 = time()
        lock(print_lock) do; println("  MC $mc / $(WD_N_MC_RUNS) starting..."); end

        _bank_underwriting_profile = get(ENV, "WD_BANK_UNDERWRITING_PROFILE", "")
        _central_bank_profile = get(ENV, "WD_CENTRAL_BANK_PROFILE", "")
        _cb_profile_selected = !isempty(_central_bank_profile)
        _cb_policy_application_time = haskey(ENV, "WD_CB_POLICY_APPLICATION_TIME") ?
            parse(Int, ENV["WD_CB_POLICY_APPLICATION_TIME"]) :
            Config.CENTRAL_BANK_POLICY_APPLICATION_TIME

        # Parameter overrides via ENV.
        # Presence semantics for calibration knobs: when env is absent we pass
        # `nothing` so initialize_model can apply UK/Spain preset defaults.
        _exp_gamma = haskey(ENV, "EXPECTATIONS_GAMMA") ?
            parse(Float64, ENV["EXPECTATIONS_GAMMA"]) : nothing
        _exp_zeta  = haskey(ENV, "EXPECTATIONS_ZETA") ?
            parse(Float64, ENV["EXPECTATIONS_ZETA"])  : nothing
        # Further behavioural parameter overrides.
        _psych_rent = haskey(ENV, "PSYCHOLOGICAL_COST_RENTING") ?
            parse(Float64, ENV["PSYCHOLOGICAL_COST_RENTING"]) : nothing
        _sens_rent_buy = haskey(ENV, "SENSITIVITY_RENT_BUY") ?
            parse(Float64, ENV["SENSITIVITY_RENT_BUY"]) : nothing
        _btl_prob   = haskey(ENV, "BTL_PROBABILITY_ADJUSTMENT") ?
            parse(Float64, ENV["BTL_PROBABILITY_ADJUSTMENT"]) : nothing
        _phi        = haskey(ENV, "INTEREST_RATE_ELASTICITY_PHI") ?
            parse(Float64, ENV["INTEREST_RATE_ELASTICITY_PHI"]) : nothing
        _hpa_years_to_check = haskey(ENV, "HPA_YEARS_TO_CHECK") ?
            parse(Int, ENV["HPA_YEARS_TO_CHECK"]) : nothing
        _mix_adjustment_weight = haskey(ENV, "MIX_ADJUSTMENT_WEIGHT") ?
            parse(Float64, ENV["MIX_ADJUSTMENT_WEIGHT"]) : nothing
        _btl_xi = haskey(ENV, "BTL_XI") ?
            parse(Float64, ENV["BTL_XI"]) : nothing
        _bank_dsti  = haskey(ENV, "WD_BANK_DSTI_MAX") ?
            parse(Float64, ENV["WD_BANK_DSTI_MAX"]) : nothing
        _bank_dsti_ftb = haskey(ENV, "WD_BANK_DSTI_MAX_FTB") ?
            parse(Float64, ENV["WD_BANK_DSTI_MAX_FTB"]) : _bank_dsti
        _bank_dsti_hm_btl = haskey(ENV, "WD_BANK_DSTI_MAX_HM_BTL") ?
            parse(Float64, ENV["WD_BANK_DSTI_MAX_HM_BTL"]) : _bank_dsti
        # Regulatory DSTI / ICR / LTV overrides via env (override experiment struct).
        _limit_dsti = haskey(ENV, "WD_LIMIT_DSTI") ?
            parse(Float64, ENV["WD_LIMIT_DSTI"]) : nothing
        _limit_dsti_ftb = haskey(ENV, "WD_LIMIT_DSTI_FTB") ?
            parse(Float64, ENV["WD_LIMIT_DSTI_FTB"]) : _limit_dsti
        _limit_dsti_hm_btl = haskey(ENV, "WD_LIMIT_DSTI_HM_BTL") ?
            parse(Float64, ENV["WD_LIMIT_DSTI_HM_BTL"]) : _limit_dsti
        _pre_limit_dsti = haskey(ENV, "WD_PRE_LIMIT_DSTI") ?
            parse(Float64, ENV["WD_PRE_LIMIT_DSTI"]) : nothing
        _pre_limit_dsti_ftb = haskey(ENV, "WD_PRE_LIMIT_DSTI_FTB") ?
            parse(Float64, ENV["WD_PRE_LIMIT_DSTI_FTB"]) : _pre_limit_dsti
        _pre_limit_dsti_hm_btl = haskey(ENV, "WD_PRE_LIMIT_DSTI_HM_BTL") ?
            parse(Float64, ENV["WD_PRE_LIMIT_DSTI_HM_BTL"]) : _pre_limit_dsti
        _limit_icr  = haskey(ENV, "WD_LIMIT_ICR") ?
            parse(Float64, ENV["WD_LIMIT_ICR"])  : nothing
        _ltv_ftb = haskey(ENV, "WD_LIMIT_LTV_FTB") ?
            parse(Float64, ENV["WD_LIMIT_LTV_FTB"]) : (_cb_profile_selected ? nothing : exp.reg_ltv_ftb)
        _ltv_hm  = haskey(ENV, "WD_LIMIT_LTV_HM") ?
            parse(Float64, ENV["WD_LIMIT_LTV_HM"])  : (_cb_profile_selected ? nothing : exp.reg_ltv_hm)
        _ltv_btl = haskey(ENV, "WD_LIMIT_LTV_BTL") ?
            parse(Float64, ENV["WD_LIMIT_LTV_BTL"]) : (_cb_profile_selected ? nothing : exp.reg_ltv_btl)
        _pre_ltv_ftb = haskey(ENV, "WD_PRE_LIMIT_LTV_FTB") ?
            parse(Float64, ENV["WD_PRE_LIMIT_LTV_FTB"]) : nothing
        _pre_ltv_hm = haskey(ENV, "WD_PRE_LIMIT_LTV_HM") ?
            parse(Float64, ENV["WD_PRE_LIMIT_LTV_HM"]) : nothing
        _pre_ltv_btl = haskey(ENV, "WD_PRE_LIMIT_LTV_BTL") ?
            parse(Float64, ENV["WD_PRE_LIMIT_LTV_BTL"]) : nothing
        _soft_lti_active = haskey(ENV, "WD_SOFT_LTI_ACTIVE") ?
            (ENV["WD_SOFT_LTI_ACTIVE"] == "true") : (_cb_profile_selected ? nothing : exp.soft_lti_active)
        _soft_lti_limit_ftb = haskey(ENV, "WD_SOFT_LTI_LIMIT_FTB") ?
            parse(Float64, ENV["WD_SOFT_LTI_LIMIT_FTB"]) : (_cb_profile_selected ? nothing : exp.soft_lti_limit_ftb)
        _soft_lti_limit_hm = haskey(ENV, "WD_SOFT_LTI_LIMIT_HM") ?
            parse(Float64, ENV["WD_SOFT_LTI_LIMIT_HM"]) : (_cb_profile_selected ? nothing : exp.soft_lti_limit_hm)
        _pre_soft_lti_limit_ftb = haskey(ENV, "WD_PRE_SOFT_LTI_LIMIT_FTB") ?
            parse(Float64, ENV["WD_PRE_SOFT_LTI_LIMIT_FTB"]) : nothing
        _pre_soft_lti_limit_hm = haskey(ENV, "WD_PRE_SOFT_LTI_LIMIT_HM") ?
            parse(Float64, ENV["WD_PRE_SOFT_LTI_LIMIT_HM"]) : nothing
        _flow_limit_ftb = haskey(ENV, "WD_FLOW_LIMIT_FTB") ?
            parse(Float64, ENV["WD_FLOW_LIMIT_FTB"]) : (_cb_profile_selected ? nothing : exp.flow_limit_ftb)
        _flow_limit_hm = haskey(ENV, "WD_FLOW_LIMIT_HM") ?
            parse(Float64, ENV["WD_FLOW_LIMIT_HM"]) : (_cb_profile_selected ? nothing : exp.flow_limit_hm)
        _use_pooled_lti_quota = haskey(ENV, "WD_USE_POOLED_LTI_QUOTA") ?
            (ENV["WD_USE_POOLED_LTI_QUOTA"] == "true") : exp.use_pooled_lti_quota

        # Optional bank-internal LTV/LTI/ICR hard-cap overrides (WD_BANK_* variables).
        # Defaults to Config.jl bank-side caps (LTV 0.9/0.9/0.75, LTI 5.4/5.6, ICR 1.2)
        # which is what every standard (policy-on) run uses.
        _bank_ltv_ftb = haskey(ENV, "WD_BANK_LTV_FTB") ?
            parse(Float64, ENV["WD_BANK_LTV_FTB"]) : nothing
        _bank_ltv_hm  = haskey(ENV, "WD_BANK_LTV_HM") ?
            parse(Float64, ENV["WD_BANK_LTV_HM"])  : nothing
        _bank_ltv_btl = haskey(ENV, "WD_BANK_LTV_BTL") ?
            parse(Float64, ENV["WD_BANK_LTV_BTL"]) : nothing
        _bank_lti_ftb = haskey(ENV, "WD_BANK_LTI_FTB") ?
            parse(Float64, ENV["WD_BANK_LTI_FTB"]) : nothing
        _bank_lti_hm  = haskey(ENV, "WD_BANK_LTI_HM") ?
            parse(Float64, ENV["WD_BANK_LTI_HM"])  : nothing
        _bank_lti_btl = haskey(ENV, "WD_BANK_LTI_BTL") ?
            parse(Float64, ENV["WD_BANK_LTI_BTL"]) : nothing
        _bank_icr_min = haskey(ENV, "WD_BANK_ICR_MIN") ?
            parse(Float64, ENV["WD_BANK_ICR_MIN"]) : nothing
        _central_bank_policy_rate = haskey(ENV, "WD_CENTRAL_BANK_POLICY_RATE") ?
            parse(Float64, ENV["WD_CENTRAL_BANK_POLICY_RATE"]) : nothing

        _holding_period = haskey(ENV, "WD_HOLDING_PERIOD_YEARS") ?
            parse(Float64, ENV["WD_HOLDING_PERIOD_YEARS"]) : nothing
        # initialize_model derives p_sale_monthly from the resolved holding period.

        # Spanish mechanism switches from environment variables.
        # Generic loop over `Config.SPAIN_MECHANISMS`. Each Symbol `:spain_<name>`
        # is read from env var `WD_SPAIN_<NAME>` (uppercase, leading `WD_` prefix
        # over the full symbol). Missing vars default to `false` — Java-UK parity.
        # Add a Symbol to `Config.SPAIN_MECHANISMS` and the runner picks it up
        # automatically; no further edits needed in this file.
        # Example:  WD_SPAIN_GROSS_INCOME_FLOW=true julia scripts/run_working_data.jl
        _spain_kwargs = NamedTuple()
        for _mech in Config.SPAIN_MECHANISMS
            _envname = "WD_" * uppercase(string(_mech))
            _val = haskey(ENV, _envname) ? (lowercase(ENV[_envname]) in ("true","1","yes")) : false
            _spain_kwargs = merge(_spain_kwargs, NamedTuple{(_mech,)}((_val,)))
        end

        # Private-bank soft-LTV overrides.
        # Missing values retain the initializer's Config defaults.
        _bank_soft_kwarg_pairs = (
            (:bank_ltv_soft_max_ftb,
             "WD_BANK_LTV_SOFT_MAX_FTB"),
            (:bank_ltv_soft_max_hm,
             "WD_BANK_LTV_SOFT_MAX_HM"),
            (:bank_ltv_soft_max_btl,
             "WD_BANK_LTV_SOFT_MAX_BTL"),
            (:bank_ltv_frac_over_soft_max_ftb,
             "WD_BANK_LTV_FRAC_OVER_SOFT_MAX_FTB"),
            (:bank_ltv_frac_over_soft_max_hm,
             "WD_BANK_LTV_FRAC_OVER_SOFT_MAX_HM"),
            (:bank_ltv_frac_over_soft_max_btl,
             "WD_BANK_LTV_FRAC_OVER_SOFT_MAX_BTL"),
        )

        _bank_soft_kwargs = NamedTuple()

        for (_k, _env) in _bank_soft_kwarg_pairs
            if haskey(ENV, _env)
                _bank_soft_kwargs = merge(
                    _bank_soft_kwargs,
                    NamedTuple{(_k,)}((parse(Float64, ENV[_env]),)),
                )
            end
        end

        # Central-bank calibration overrides.
        # Per-experiment overrides of the CB-side soft caps. Defaults to
        # `Config.CENTRAL_BANK_*` (Spain calibration mild experiment values).
        # Missing vars: kwarg unset → Initialization.jl falls back to Config default.
        # Mapping: `WD_CB_<NAME>` (uppercase) → `central_bank_<name>` kwarg.
        # Example:  WD_CB_LTV_SOFT_MAX_FTB=0.80 julia scripts/run_working_data.jl
        _cb_kwarg_pairs = (
            (:central_bank_ltv_soft_max_ftb,                "WD_CB_LTV_SOFT_MAX_FTB"),
            (:central_bank_ltv_soft_max_hm,                 "WD_CB_LTV_SOFT_MAX_HM"),
            (:central_bank_ltv_soft_max_btl,                "WD_CB_LTV_SOFT_MAX_BTL"),
            (:central_bank_ltv_max_frac_over_soft_max_ftb,  "WD_CB_LTV_MAX_FRAC_OVER_SOFT_MAX_FTB"),
            (:central_bank_ltv_max_frac_over_soft_max_hm,   "WD_CB_LTV_MAX_FRAC_OVER_SOFT_MAX_HM"),
            (:central_bank_ltv_max_frac_over_soft_max_btl,  "WD_CB_LTV_MAX_FRAC_OVER_SOFT_MAX_BTL"),
            (:central_bank_lti_soft_max_btl,                "WD_CB_LTI_SOFT_MAX_BTL"),
            (:central_bank_lti_max_frac_over_soft_max_btl,  "WD_CB_LTI_MAX_FRAC_OVER_SOFT_MAX_BTL"),
            (:central_bank_application_income_percentile,   "WD_CB_APPLICATION_INCOME_PERCENTILE"),
            (:central_bank_ltv_application_age,             "WD_CB_LTV_APPLICATION_AGE"),
        )
        _cb_kwargs = NamedTuple()
        for (_k, _env) in _cb_kwarg_pairs
            if haskey(ENV, _env)
                _cb_kwargs = merge(_cb_kwargs, NamedTuple{(_k,)}((parse(Float64, ENV[_env]),)))
            end
        end

        _cb_pre_kwarg_pairs = (
            (:central_bank_pre_ltv_soft_max_ftb,             "WD_CB_PRE_LTV_SOFT_MAX_FTB"),
            (:central_bank_pre_ltv_soft_max_hm,              "WD_CB_PRE_LTV_SOFT_MAX_HM"),
            (:central_bank_pre_ltv_soft_max_btl,             "WD_CB_PRE_LTV_SOFT_MAX_BTL"),
            (:central_bank_pre_lti_soft_max_btl,             "WD_CB_PRE_LTI_SOFT_MAX_BTL"),
            (:central_bank_pre_application_income_percentile, "WD_CB_PRE_APPLICATION_INCOME_PERCENTILE"),
        )
        _cb_pre_kwargs = NamedTuple()
        for (_k, _env) in _cb_pre_kwarg_pairs
            if haskey(ENV, _env)
                _cb_pre_kwargs = merge(_cb_pre_kwargs, NamedTuple{(_k,)}((parse(Float64, ENV[_env]),)))
            end
        end

        # Optional explicit geometry; otherwise initialization derives both values.
        _n_houses = haskey(ENV, "WD_N_HOUSES") ?
            parse(Int, ENV["WD_N_HOUSES"]) : nothing
        _n_qualities = haskey(ENV, "WD_N_QUALITIES") ?
            parse(Int, ENV["WD_N_QUALITIES"]) : nothing

        model = Engine.initialize_model(
            n_households         = WD_N_HOUSEHOLDS,
            n_houses             = _n_houses,
            n_qualities          = _n_qualities,
            n_steps              = WD_N_STEPS,
            seed                 = mc,
            limit_ltv_ftb        = _ltv_ftb,
            limit_ltv_hm         = _ltv_hm,
            limit_ltv_btl        = _ltv_btl,
            soft_lti_active      = _soft_lti_active,
            soft_lti_limit_ftb   = _soft_lti_limit_ftb,
            soft_lti_limit_hm    = _soft_lti_limit_hm,
            flow_limit_ftb       = _flow_limit_ftb,
            flow_limit_hm        = _flow_limit_hm,
            use_pooled_lti_quota = _use_pooled_lti_quota,
            limit_dsti           = _limit_dsti,
            limit_dsti_ftb       = _limit_dsti_ftb,
            limit_dsti_hm_btl    = _limit_dsti_hm_btl,
            limit_icr            = _limit_icr,
            pre_limit_ltv_ftb    = _pre_ltv_ftb,
            pre_limit_ltv_hm     = _pre_ltv_hm,
            pre_limit_ltv_btl    = _pre_ltv_btl,
            pre_limit_dsti       = _pre_limit_dsti,
            pre_limit_dsti_ftb   = _pre_limit_dsti_ftb,
            pre_limit_dsti_hm_btl = _pre_limit_dsti_hm_btl,
            pre_soft_lti_limit_ftb = _pre_soft_lti_limit_ftb,
            pre_soft_lti_limit_hm = _pre_soft_lti_limit_hm,
            expectations_gamma   = _exp_gamma,
            expectations_zeta    = _exp_zeta,
            psychological_cost_renting    = _psych_rent,
            sensitivity_rent_buy          = _sens_rent_buy,
            btl_probability_adjustment   = _btl_prob,
            interest_rate_elasticity_phi  = _phi,
            hpa_years_to_check            = _hpa_years_to_check,
            mix_adjustment_weight         = _mix_adjustment_weight,
            btl_xi                        = _btl_xi,
            bank_dsti_max                = _bank_dsti,
            bank_dsti_max_ftb            = _bank_dsti_ftb,
            bank_dsti_max_hm_btl         = _bank_dsti_hm_btl,
            bank_ltv_max_ftb             = _bank_ltv_ftb,
            bank_ltv_max_hm              = _bank_ltv_hm,
            bank_ltv_max_btl             = _bank_ltv_btl,
            bank_lti_max_ftb             = _bank_lti_ftb,
            bank_lti_max_hm              = _bank_lti_hm,
            bank_lti_max_btl             = _bank_lti_btl,
            bank_icr_min                 = _bank_icr_min,
            bank_underwriting_profile    = _bank_underwriting_profile,
            central_bank_profile         = _central_bank_profile,
            central_bank_policy_application_time = _cb_policy_application_time,
            central_bank_policy_rate     = _central_bank_policy_rate,
            holding_period_years         = _holding_period;

            _spain_kwargs...,
            _bank_soft_kwargs...,
            _cb_kwargs...,
            _cb_pre_kwargs...
        )

        println(" Resolved credit profiles: bank_underwriting_profile=$(_bank_underwriting_profile == "" ? "<default>" : _bank_underwriting_profile) central_bank_profile=$(_central_bank_profile == "" ? "<default>" : _central_bank_profile)")
        println(" Resolved bank limits: LTV(ftb/hm/btl)=($(model.bank.ltv_max_ftb),$(model.bank.ltv_max_hm),$(model.bank.ltv_max_btl)) LTI(ftb/hm/btl)=($(model.bank.lti_max_ftb),$(model.bank.lti_max_hm),$(model.bank.lti_max_btl)) DSTI(ftb/hm_btl)=($(model.bank.dsti_max_ftb),$(model.bank.dsti_max_hm_btl))")
        println(" Active CB limits at startup: LTV(ftb/hm/btl)=($(model.central_bank.max_ltv_ftb),$(model.central_bank.max_ltv_hm),$(model.central_bank.max_ltv_btl)) DSTI(ftb/hm_btl)=($(model.central_bank.max_dsti_ftb),$(model.central_bank.max_dsti_hm_btl)) soft_lti_active=$(model.central_bank.soft_limit_active) soft_lti(ftb/hm)=($(model.central_bank.soft_lti_limit_ftb),$(model.central_bank.soft_lti_limit_hm)) policy_rate=$(model.central_bank.base_rate)")
        _cb_startup_timing = model.central_bank.policy_application_time === nothing ?
            "from initialization" :
            "after model month $(model.central_bank.policy_application_time)"
        println(" CB policy timing: ", _cb_startup_timing)
        _requested_cb = model.central_bank.requested_policy
        println(" Requested CB LTV(ftb/hm/btl)=",
            (_requested_cb.max_ltv_ftb, _requested_cb.max_ltv_hm,
             _requested_cb.max_ltv_btl),
            "; DSTI(ftb/hm_btl)=",
            (_requested_cb.max_dsti_ftb, _requested_cb.max_dsti_hm_btl))

        println(" Bank soft-LTV thresholds: ",
            (model.bank.ltv_soft_max_ftb,
             model.bank.ltv_soft_max_hm,
             model.bank.ltv_soft_max_btl),
            "; above-threshold probabilities: ",
            (model.bank.ltv_frac_over_soft_max_ftb,
             model.bank.ltv_frac_over_soft_max_hm,
             model.bank.ltv_frac_over_soft_max_btl))

        println(" Regulatory soft-LTV thresholds: ",
            (model.central_bank.soft_max_ltv_ftb,
             model.central_bank.soft_max_ltv_hm,
             model.central_bank.soft_max_ltv_btl),
            "; allowances: ",
            (model.central_bank.max_frac_over_soft_max_ltv_ftb,
             model.central_bank.max_frac_over_soft_max_ltv_hm,
             model.central_bank.max_frac_over_soft_max_ltv_btl))

        println(" Initial quota targets (FTB/HM/BTL LTV; BTL LTI): ",
            (model.bank.target_prospec_fraction_ftb_ltv,
             model.bank.target_prospec_fraction_hm_ltv,
             model.bank.target_prospec_fraction_btl_ltv,
             model.bank.target_prospec_fraction_btl_lti))

        # ── Custom step loop: model data + periodic agent snapshots ─────────────
        # Replaces Agents.run! so we can take agent snapshots at regular intervals
        # and record actual rental income on each snapshot.
        # Model data is collected identically to run!(when_model = s > WD_RECORD_START).
        n_record = WD_N_STEPS - WD_RECORD_START   # number of steps to record
        mdf_time = Vector{Int}(undef, n_record)
        mdf_vals = [Vector{Float64}(undef, n_record) for _ in mdata]
        mdf_idx  = 0
        snap_frames = DataFrame[]
        mortgage_stock_frames = DataFrame[]

        for step_idx in 1:WD_N_STEPS
            Agents.step!(model)
            if step_idx > WD_RECORD_START
                mdf_idx += 1
                mdf_time[mdf_idx] = step_idx
                for (j, f) in enumerate(mdata)
                    mdf_vals[j][mdf_idx] = Float64(f(model))
                end
                # Branch A — Periodic BTL-only snapshots (Panel b time-averaging).
                # Skips the final step so it is not also captured as BTL-only.
                # WD_N_STEPS (10,000) % AGENT_SNAPSHOT_INTERVAL (600) = 400 ≠ 0,
                # so the two branches never fire on the same step in standard config.
                if step_idx % AGENT_SNAPSHOT_INTERVAL == 0 && step_idx != WD_N_STEPS
                    avecs = collect(allagents(model))
                    push!(snap_frames, wd_agent_snapshot(avecs, model, mc, step_idx;
                                                         btl_only = true))
                end
                # Branch C — Periodic full-population snapshots (multi-snapshot extension).
                # Java's MicroDataRecorder records ALL agents every 12 steps from step 996.
                # This is the Julia equivalent, scaled to freq=1200 (~6 snapshots/run).
                # Enables time-averaged distributional validation (income, wealth, tenure)
                # reducing single-draw bias.  Skips final step (Branch B handles it).
                # NOTE: FULL_SNAPSHOT_INTERVAL (1200) is a multiple of AGENT_SNAPSHOT_INTERVAL
                # (600), so at steps 3600, 4800, 6000, 7200, 8400, 9600 BOTH Branch A
                # (BTL-only) and Branch C (full-pop) fire — this is correct.  Branch A
                # captures BTL-only rows and Branch C captures all-agent rows at the same
                # timestep.  Consumers distinguish by per-step row count.
                if step_idx % FULL_SNAPSHOT_INTERVAL == 0 && step_idx != WD_N_STEPS
                    avecs_full = collect(allagents(model))
                    push!(snap_frames, wd_agent_snapshot(avecs_full, model, mc, step_idx;
                                                         btl_only = false))
                    push!(mortgage_stock_frames, wd_mortgage_stock_snapshot(avecs_full, mc, step_idx))
                end
                # Branch B — Full-population final snapshot (Panel a denominator).
                # Captures all ~10,000 agents at the final equilibrium step so that
                # end-state shares use the full population as denominator.
                if step_idx == WD_N_STEPS
                    avecs = collect(allagents(model))
                    push!(snap_frames, wd_agent_snapshot(avecs, model, mc, step_idx;
                                                         btl_only = false))
                    push!(mortgage_stock_frames, wd_mortgage_stock_snapshot(avecs, mc, step_idx))
                end
            end
        end

        # Build model DataFrame (same column structure as Agents.run! output)
        mdf = DataFrame(time = mdf_time[1:mdf_idx])
        for (j, f) in enumerate(mdata)
            mdf[!, Symbol(f)] = mdf_vals[j][1:mdf_idx]
        end

        # Tag with MC run id and rename columns to the short output names.
        mdf[!, :run_id] .= mc
        rename!(mdf, MD_RENAME)
        _mdf_path = joinpath(_mc_tmp_dir, "mdf_mc$(mc).csv")
        CSV.write(_mdf_path, mdf)
        all_runs_mdf[mc] = _mdf_path

        # ── Transaction log (post burn-in) ────────────────────────────────────
        tx_log = filter(x -> x.step > WD_RECORD_START, model.transaction_log)
        all_runs_tx[mc] = nothing  # default; overwritten below if non-empty
        if isempty(tx_log)
            lock(print_lock) do
                println("\n  WARNING: No transactions after burn-in for MC $mc.")
            end
        else
            tx_df = DataFrame(
                step          = [x.step                     for x in tx_log],
                house_id      = [x.house_id                  for x in tx_log],
                buyer_id      = [x.buyer_id                  for x in tx_log],
                seller_id     = [x.seller_id === nothing ? missing : x.seller_id for x in tx_log],
                mortgage_id   = [x.mortgage_id               for x in tx_log],
                price         = [x.price                     for x in tx_log],
                ltv           = [x.ltv                       for x in tx_log],
                lti           = [x.lti                       for x in tx_log],
                buyer_type    = [String(Symbol(x.buyer_type)) for x in tx_log],
                house_quality = [x.house_quality             for x in tx_log],
                is_btl        = [x.is_buy_to_let             for x in tx_log],
                loan_amount   = [x.loan_amount               for x in tx_log],
                income        = [x.annual_income             for x in tx_log],
                income_percentile = [hasproperty(x, :income_percentile) ? x.income_percentile : NaN for x in tx_log],
                permanent_income_quintile = [hasproperty(x, :permanent_income_quintile) ? x.permanent_income_quintile : missing for x in tx_log],
                wealth_before = [x.wealth_before             for x in tx_log],
                buyer_age     = [x.buyer_age                 for x in tx_log],
                down_payment  = [x.down_payment              for x in tx_log],
                p_fundamental = [x.p_fundamental             for x in tx_log],
                p_max         = [x.p_max                     for x in tx_log],
                p_ratio       = [x.p_max > 0.0 ? (x.price / x.p_max) : NaN for x in tx_log],
                seller_debt   = [x.seller_remaining_principal for x in tx_log],
                monthly_payment = [x.monthly_payment           for x in tx_log],
                months_on_market = [x.months_on_market         for x in tx_log],
                mortgage_rate   = [x.mortgage_rate              for x in tx_log],
                origination_term = [x.origination_term_months   for x in tx_log],
                seller_type   = [x.seller_type                for x in tx_log],
                seller_borrower_type = [String(Symbol(x.seller_borrower_type)) for x in tx_log],
                run_id        = mc
            )
            _tx_path = joinpath(_mc_tmp_dir, "tx_mc$(mc).csv")
            CSV.write(_tx_path, tx_df)
            all_runs_tx[mc] = _tx_path
        end

        if !isempty(snap_frames)
            _agents_df = vcat(snap_frames...)
            _agents_path = joinpath(_mc_tmp_dir, "agents_mc$(mc).csv")
            CSV.write(_agents_path, _agents_df)
            all_runs_agents[mc] = _agents_path
        else
            all_runs_agents[mc] = nothing
        end
        if !isempty(mortgage_stock_frames)
            _ms_df = vcat(mortgage_stock_frames...)
            _ms_path = joinpath(_mc_tmp_dir, "mortgage_stock_mc$(mc).csv")
            CSV.write(_ms_path, _ms_df)
            all_runs_mortgage_stock[mc] = _ms_path
        else
            all_runs_mortgage_stock[mc] = nothing
        end

        elapsed = time() - t0
        lock(print_lock) do
            @printf("  [%s] MC %d done (%.1fs)\n", exp.name, mc, elapsed)
        end
    end
    GC.gc()  # Frees any remaining transients after all threads complete.

    # ── Save (serial — after all threads complete) ────────────────────────────
    _stream_concat_write(all_runs_mdf, joinpath(WD_RESULTS_DIR, "$(exp.name)_model_data.csv"))
    _stream_concat_write(all_runs_tx, joinpath(WD_RESULTS_DIR, "$(exp.name)_transactions.csv"))
    _stream_concat_write(all_runs_agents, joinpath(WD_RESULTS_DIR, "$(exp.name)_agents.csv"))
    _stream_concat_write(all_runs_mortgage_stock, joinpath(WD_RESULTS_DIR, "$(exp.name)_mortgage_stock_quintiles.csv"))
    _rm_retry(_mc_tmp_dir; recursive = true)
    println("  Saved $(exp.name) to $(WD_RESULTS_DIR)")
end

# ============================================================================
# MAIN
# ============================================================================

function wd_main()
    t0 = time()

    _consumption_legacy_ledger_enabled = haskey(ENV, "WD_SPAIN_CONSUMPTION_RECORDING") ?
        (lowercase(ENV["WD_SPAIN_CONSUMPTION_RECORDING"]) in ("true", "1", "yes")) : false

    for exp in WD_EXPERIMENTS
        wd_run_experiment(exp)
    end

    _spain_params = String[]
    _spain_values = Any[]
    for _mech in Config.SPAIN_MECHANISMS
        _envname = "WD_" * uppercase(string(_mech))
        push!(_spain_params, lowercase(_envname))
        push!(_spain_values, haskey(ENV, _envname) ?
              string(lowercase(ENV[_envname]) in ("true","1","yes")) : "false")
    end

    CSV.write(joinpath(WD_RESULTS_DIR, "run_config.csv"),
        DataFrame(
            Parameter=[
                "run_date", "git_commit", "git_branch", "julia_version", "n_threads",
                "n_households", "n_steps", "n_mc_runs", "record_start", "house_prices_mean",
                "btl_compat_mode",
                "d1_gazumping_compat", "d1_rental_compat",
                "d2_self_ownership_guard", "d3_zombie_debt",
                "d4_inheritance_overpay", "d5_down_payment_compat",
                "d6_bidup_floor", "d7_wealth_compat", "d7_markup_compat", "d7_income_compat",
                "d11_rental_contracted_rent", "d13_btl_interest_full_guard",
                "d15_btl_repayment_mortgage", "d16_btl_dp_no_upper_clamp",
                "d17_rental_bid_no_floor", "d18_pre_income_behavioral",
                "d19_mode",
                "d25b_clear_ftb_on_purchase", "d25c_disable_btl_wealth_gate",
                "nd31_relist_on_tenant_exit",
                "ema_smoothing_table16",
                "expectations_gamma", "expectations_zeta", "hpa_years_to_check",
                "psychological_cost_renting", "btl_probability_adjustment", "interest_rate_elasticity_phi",
                "sensitivity_rent_buy", "mix_adjustment_weight", "btl_xi",
                "wd_limit_ltv_ftb", "wd_limit_ltv_hm", "wd_limit_ltv_btl",
                "wd_limit_lti_ftb", "wd_limit_lti_hm",
                "wd_limit_dsti", "wd_limit_dsti_ftb", "wd_limit_dsti_hm_btl",
                "wd_bank_dsti_max", "wd_bank_dsti_max_ftb", "wd_bank_dsti_max_hm_btl", "wd_limit_icr",
                "wd_bank_ltv_ftb", "wd_bank_ltv_hm", "wd_bank_ltv_btl",
                "wd_bank_lti_ftb", "wd_bank_lti_hm",
                "wd_bank_icr_min",
                "wd_bank_underwriting_profile", "wd_central_bank_profile",
                "wd_central_bank_policy_rate",
                "wd_soft_lti_active",
                "wd_soft_lti_limit_ftb", "wd_soft_lti_limit_hm",
                "wd_flow_limit_ftb", "wd_flow_limit_hm",
                "wd_use_pooled_lti_quota",
                "wd_holding_period_years",
                "consumption_schema_version",
                "consumption_observation_enabled",
                "consumption_definition",
                "consumption_unit",
                "consumption_capture_phase",
                "consumption_income_basis",
                "consumption_tenure_basis",
                "wealth_state_basis",
                "consumption_aggregate_source",
                "consumption_legacy_ledger_enabled",
                "agent_snapshot_scope_column",
                "agent_snapshot_interval",
                "full_population_snapshot_interval",
                "consumption_seed_scheme",
                _spain_params...,
            ],
            Value=[
                _WD_RUN_DATE, _WD_GIT_COMMIT, _WD_GIT_BRANCH, _WD_JULIA_VER, _WD_N_THREADS,
                WD_N_HOUSEHOLDS, WD_N_STEPS, WD_N_MC_RUNS, WD_RECORD_START, Config.HOUSE_PRICES_MEAN,
                Config.BTL_COMPAT_MODE,
                Config.D1_GAZUMPING_COMPAT, Config.D1_RENTAL_COMPAT,
                Config.D2_SELF_OWNERSHIP_GUARD, Config.D3_ZOMBIE_DEBT,
                Config.D4_INHERITANCE_OVERPAY, Config.D5_DOWN_PAYMENT_COMPAT,
                Config.D6_BIDUP_FLOOR, Config.D7_WEALTH_COMPAT, Config.D7_MARKUP_COMPAT, Config.D7_INCOME_COMPAT,
                Config.D11_RENTAL_CONTRACTED_RENT, Config.D13_BTL_INTEREST_FULL_GUARD,
                "RETIRED-PHASE8A", Config.D16_BTL_DP_NO_UPPER_CLAMP,
                Config.D17_RENTAL_BID_NO_FLOOR, Config.D18_PRE_INCOME_BEHAVIORAL,
                string(Config.D19_MODE),
                Config.D25B_CLEAR_FTB_ON_PURCHASE, Config.D25C_DISABLE_BTL_WEALTH_GATE,
                Config.ND31_RELIST_ON_TENANT_EXIT,
                Config.EMA_SMOOTHING_TABLE16,
                haskey(ENV,"EXPECTATIONS_GAMMA") ? ENV["EXPECTATIONS_GAMMA"] : string(Config.EXPECTATIONS_GAMMA),
                haskey(ENV,"EXPECTATIONS_ZETA")  ? ENV["EXPECTATIONS_ZETA"]  : string(Config.EXPECTATIONS_ZETA),
                haskey(ENV,"HPA_YEARS_TO_CHECK") ? ENV["HPA_YEARS_TO_CHECK"] : string(Config.HPA_YEARS_TO_CHECK),
                haskey(ENV,"PSYCHOLOGICAL_COST_RENTING") ? ENV["PSYCHOLOGICAL_COST_RENTING"] : string(Config.PSYCHOLOGICAL_COST_RENTING),
                haskey(ENV,"BTL_PROBABILITY_ADJUSTMENT") ? ENV["BTL_PROBABILITY_ADJUSTMENT"] : string(Config.BTL_PROBABILITY_ADJUSTMENT),
                haskey(ENV,"INTEREST_RATE_ELASTICITY_PHI") ? ENV["INTEREST_RATE_ELASTICITY_PHI"] : string(Config.INTEREST_RATE_ELASTICITY_PHI),
                haskey(ENV,"SENSITIVITY_RENT_BUY") ? ENV["SENSITIVITY_RENT_BUY"] : string(Config.SENSITIVITY_RENT_BUY),
                haskey(ENV,"MIX_ADJUSTMENT_WEIGHT") ? ENV["MIX_ADJUSTMENT_WEIGHT"] : string(Config.MIX_ADJUSTMENT_WEIGHT),
                haskey(ENV,"BTL_XI") ? ENV["BTL_XI"] : string(Config.BTL_XI),
                get(ENV,"WD_LIMIT_LTV_FTB","-"), get(ENV,"WD_LIMIT_LTV_HM","-"), get(ENV,"WD_LIMIT_LTV_BTL","-"),
                get(ENV,"WD_LIMIT_LTI_FTB","-"), get(ENV,"WD_LIMIT_LTI_HM","-"),
                get(ENV,"WD_LIMIT_DSTI","-"), get(ENV,"WD_LIMIT_DSTI_FTB","-"), get(ENV,"WD_LIMIT_DSTI_HM_BTL","-"),
                get(ENV,"WD_BANK_DSTI_MAX","-"), get(ENV,"WD_BANK_DSTI_MAX_FTB","-"), get(ENV,"WD_BANK_DSTI_MAX_HM_BTL","-"), get(ENV,"WD_LIMIT_ICR","-"),
                # Bank-side hard-caps — effective value (ENV override OR Config default).
                # Silent fallback = Config.jl default, so the recorded value is what the
                # run actually used, NOT just the ENV var presence.
                haskey(ENV,"WD_BANK_LTV_FTB") ? ENV["WD_BANK_LTV_FTB"] : string(Config.LTV_MAX_FTB),
                haskey(ENV,"WD_BANK_LTV_HM")  ? ENV["WD_BANK_LTV_HM"]  : string(Config.LTV_MAX_HM),
                haskey(ENV,"WD_BANK_LTV_BTL") ? ENV["WD_BANK_LTV_BTL"] : string(Config.LTV_MAX_BTL),
                haskey(ENV,"WD_BANK_LTI_FTB") ? ENV["WD_BANK_LTI_FTB"] : string(Config.LTI_MAX_FTB),
                haskey(ENV,"WD_BANK_LTI_HM")  ? ENV["WD_BANK_LTI_HM"]  : string(Config.LTI_MAX_HM),
                haskey(ENV,"WD_BANK_ICR_MIN") ? ENV["WD_BANK_ICR_MIN"] : string(Config.ICR_MIN),
                get(ENV,"WD_BANK_UNDERWRITING_PROFILE",""), get(ENV,"WD_CENTRAL_BANK_PROFILE",""),
                haskey(ENV,"WD_CENTRAL_BANK_POLICY_RATE") ? ENV["WD_CENTRAL_BANK_POLICY_RATE"] : string(Config.CENTRAL_BANK_POLICY_RATE),
                haskey(ENV,"WD_SOFT_LTI_ACTIVE") ? ENV["WD_SOFT_LTI_ACTIVE"] : string(Config.IS_SOFT_LIMIT_ACTIVE),
                haskey(ENV,"WD_SOFT_LTI_LIMIT_FTB") ? ENV["WD_SOFT_LTI_LIMIT_FTB"] : string(Config.SOFT_LTI_LIMIT_FTB),
                haskey(ENV,"WD_SOFT_LTI_LIMIT_HM")  ? ENV["WD_SOFT_LTI_LIMIT_HM"]  : string(Config.SOFT_LTI_LIMIT_HM),
                haskey(ENV,"WD_FLOW_LIMIT_FTB") ? ENV["WD_FLOW_LIMIT_FTB"] : string(Config.FLOW_LIMIT_ALLOWANCE_FTB),
                haskey(ENV,"WD_FLOW_LIMIT_HM")  ? ENV["WD_FLOW_LIMIT_HM"]  : string(Config.FLOW_LIMIT_ALLOWANCE_HM),
                haskey(ENV,"WD_USE_POOLED_LTI_QUOTA") ? ENV["WD_USE_POOLED_LTI_QUOTA"] : string(Config.USE_POOLED_LTI_QUOTA),
                haskey(ENV,"WD_HOLDING_PERIOD_YEARS") ? ENV["WD_HOLDING_PERIOD_YEARS"] : string(Config.HOLDING_PERIOD_YEARS),
                "1",
                "true",
                "essential_plus_executed_discretionary_non_housing",
                "model_currency_per_month",
                "phase2b_after_discretionary_deduction",
                "phase2b_gross_income_estimate",
                "phase2b",
                "end_of_month_snapshot",
                "legacy_spain_ledger_or_household_observations",
                string(_consumption_legacy_ledger_enabled),
                "snapshot_scope",
                string(AGENT_SNAPSHOT_INTERVAL),
                string(FULL_SNAPSHOT_INTERVAL),
                "seed_equals_mc_run_id",
                _spain_values...,
            ]
        ))

    elapsed = time() - t0
    println("\n" * "=" ^ 80)
    @printf(" WORKING DATA RUN COMPLETE: %.1f seconds (%.1f minutes)\n", elapsed, elapsed/60)
    println(" Output: $(WD_RESULTS_DIR)")
    println("=" ^ 80)

    # -------------------------------------------------------------------------
    # Global runs manifest — one-row-per-run append to `output/runs_manifest.csv`.
    # Lets analysis code collect runs across output folders without re-reading
    # each folder's metadata.
    # Safe append: creates the file with header on first call; otherwise appends.
    # -------------------------------------------------------------------------
    try
        manifest_path = joinpath(dirname(WD_RESULTS_DIR), "runs_manifest.csv")
        manifest_row = DataFrame(
            run_date        = [_WD_RUN_DATE],
            config_label    = [get(ENV, "CONFIG_LABEL", basename(WD_RESULTS_DIR))],
            result_dir      = [WD_RESULTS_DIR],
            build_commit    = [_WD_GIT_COMMIT],
            git_branch      = [_WD_GIT_BRANCH],
            julia_version   = [_WD_JULIA_VER],
            n_mc            = [WD_N_MC_RUNS],
            n_households    = [WD_N_HOUSEHOLDS],
            n_steps         = [WD_N_STEPS],
            record_start    = [WD_RECORD_START],
            elapsed_seconds = [round(elapsed; digits=1)],
        )
        if isfile(manifest_path)
            CSV.write(manifest_path, manifest_row; append=true, writeheader=false)
        else
            CSV.write(manifest_path, manifest_row)
        end
        println(" Manifest appended: $manifest_path")
    catch e
        println(" ⚠️  Manifest append failed: $e")
    end
end

wd_main()
