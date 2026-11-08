# src/institutions/CentralBank.jl

"""
    update_central_bank_history!(cb, ftb_total, ftb_high, hm_total, hm_high)

Appends one month of realised lending data to the Central Bank's per-type rolling
12-month history and removes the oldest entry to maintain window length.
Called post-clearing each step by `report_and_reset_activity!` (Scheduler.jl Phase 5b).

# Arguments
- `ftb_total`  : New FTB  mortgages issued this month.
- `ftb_high`   : FTB  mortgages above the FTB  soft LTI threshold this month.
- `hm_total`   : New HM   mortgages issued this month.
- `hm_high`    : HM   mortgages above the HM   soft LTI threshold this month.

# Java reference
Equivalent to the rolling-list bookkeeping in `Bank.resetMonthlyCounters()`:
  `nFTBMortgages_List`, `nFTBMortOverSoftMaxLTI_List` (and HM counterparts),
which are shifted left by one slot each month (Java: `List.remove(0)` / `List.add(...)`).
"""
function update_central_bank_history!(cb::CentralBank,
                                      ftb_total::Int, ftb_high::Int,
                                      hm_total::Int,  hm_high::Int)

    push!(cb.history_total_ftb,    ftb_total)
    push!(cb.history_high_lti_ftb, ftb_high)
    push!(cb.history_total_hm,     hm_total)
    push!(cb.history_high_lti_hm,  hm_high)

    # Maintain exactly LTI_WINDOW_MONTHS window (Java: CENTRAL_BANK_LTI_MONTHS_TO_CHECK = 12)
    if length(cb.history_total_ftb) > Config.LTI_WINDOW_MONTHS
        popfirst!(cb.history_total_ftb)
        popfirst!(cb.history_high_lti_ftb)
        popfirst!(cb.history_total_hm)
        popfirst!(cb.history_high_lti_hm)
    end
end

"""
    is_soft_limit_breached(cb::CentralBank)

Diagnostic helper. Returns `true` if the rolling 12-month realised lending fraction
exceeds the regulatory allowance for **either** FTB or HM borrower type.
Reference: Carro et al. (2022) Section 3.4 / Java `Bank.getLoanToIncomeLimit`.

Note: This function is not called in the main simulation loop; it is available
for post-hoc policy diagnostics.
"""
function is_soft_limit_breached(cb::CentralBank)
    if !cb.soft_limit_active
        return false
    end

    total_ftb = sum(cb.history_total_ftb)
    ftb_breached = total_ftb > 0 &&
        (sum(cb.history_high_lti_ftb) / total_ftb) > cb.soft_lti_allowance_ftb

    total_hm = sum(cb.history_total_hm)
    hm_breached  = total_hm  > 0 &&
        (sum(cb.history_high_lti_hm)  / total_hm)  > cb.soft_lti_allowance_hm

    return ftb_breached || hm_breached
end

# ────────────────────────────────────────────────────────────────────────────────

"""
    update_central_bank_history!(cb,
        ftb_total, ftb_high_lti, hm_total, hm_high_lti,
        ftb_high_ltv, hm_high_ltv,
        btl_total, btl_high_ltv, btl_high_lti)

per-segment rolling history queues (4 UK + 5 Spain) and trims to
`Config.LTI_WINDOW_MONTHS`. Called from Bank.jl once the
arguments arrive as literal zeros because the upstream Bank write sites
no consumer reads them, so baseline results are unchanged.

[Alignment Note] Mirrors Spain `Bank.resetMonthlyCounters()` rolling-list

# RNG discipline
Idempotent. Does not consume RNG.
"""
function update_central_bank_history!(cb::CentralBank,
                                      ftb_total::Int, ftb_high_lti::Int,
                                      hm_total::Int,  hm_high_lti::Int,
                                      ftb_high_ltv::Int, hm_high_ltv::Int,
                                      btl_total::Int, btl_high_ltv::Int, btl_high_lti::Int)
    # UK queues (unchanged from 4-arg path).
    push!(cb.history_total_ftb,    ftb_total)
    push!(cb.history_high_lti_ftb, ftb_high_lti)
    push!(cb.history_total_hm,     hm_total)
    push!(cb.history_high_lti_hm,  hm_high_lti)

    push!(cb.history_high_ltv_ftb, ftb_high_ltv)  # guarded by :spain_soft_ltv_ftb (upstream)
    push!(cb.history_high_ltv_hm,  hm_high_ltv)   # guarded by :spain_soft_ltv_hm  (upstream)
    push!(cb.history_total_btl,    btl_total)     # guarded by :spain_soft_ltv_btl || :spain_soft_lti_btl (upstream)
    push!(cb.history_high_ltv_btl, btl_high_ltv)  # guarded by :spain_soft_ltv_btl (upstream)
    push!(cb.history_high_lti_btl, btl_high_lti)  # guarded by :spain_soft_lti_btl (upstream)

    # Maintain exactly LTI_WINDOW_MONTHS window. All nine queues are trimmed
    # in lockstep so a single length-check on the FTB total suffices.
    if length(cb.history_total_ftb) > Config.LTI_WINDOW_MONTHS
        popfirst!(cb.history_total_ftb)
        popfirst!(cb.history_high_lti_ftb)
        popfirst!(cb.history_total_hm)
        popfirst!(cb.history_high_lti_hm)
        popfirst!(cb.history_high_ltv_ftb)
        popfirst!(cb.history_high_ltv_hm)
        popfirst!(cb.history_total_btl)
        popfirst!(cb.history_high_ltv_btl)
        popfirst!(cb.history_high_lti_btl)
    end
end

"""
    initialize_pre_policy_limits!(cb::CentralBank, initial_policy::CentralBankRequestedPolicy)

Apply the configurable pre-activation regulatory state for scheduled runs.
If callers omit pre-policy kwargs, Initialization.jl supplies the historical
placeholder defaults (0.9999 / 15.0 / percentile 0.0).
"""
function initialize_pre_policy_limits!(cb::CentralBank,
                                       initial_policy::CentralBankRequestedPolicy)
    for name in fieldnames(CentralBankRequestedPolicy)
        setfield!(cb, name, getfield(initial_policy, name))
    end
    cb.application_income = 0.0
    return nothing
end

function apply_requested_policy!(cb::CentralBank)
    policy = cb.requested_policy
    for name in fieldnames(CentralBankRequestedPolicy)
        setfield!(cb, name, getfield(policy, name))
    end
    return nothing
end

"""
    central_bank_step!(model)

Called after the month's lending and quota accounting. With an integer schedule,
activate requested thresholds when abmtime(model) + 1 >= policy_application_time.
This yields beginning-of-month activation semantics for decision month t while
keeping the scheduler call position unchanged. With an integer schedule, the
startup regime is whatever pre-policy limits were configured at initialization
(legacy placeholders when not supplied). With nothing, retain immediate
startup requested limits. Income thresholds refresh every month when the
income mechanism is enabled, using the currently active percentile.

Base rate, ICR, allowances, age threshold and lending histories are not changed
by this activation, matching the selected static Spanish Java configuration.
"""
function central_bank_step!(model)
    cb = model.central_bank
    policy_time = cb.policy_application_time

    if policy_time !== nothing && (abmtime(model) + 1) >= policy_time
        apply_requested_policy!(cb)
    end

    if model.spain_application_income_gate
        cb.application_income = income_at_percentile(
            model.market_stats, cb.application_income_percentile)
    end
    return nothing
end

"""
    check_central_bank_hard_limits(cb::CentralBank, borrower_type::BorrowerType, ltv::Float64, dsti::Float64, icr::Float64)

Returns true if the loan application passes all Central Bank Hard Limits.
These are absolute caps (e.g. Max LTV, Max DSTI).
"""
function check_central_bank_hard_limits(cb::CentralBank, borrower_type::BorrowerType, ltv::Float64, dsti::Float64, icr::Float64)
    # 1. Check DSTI (Affordability)
    if borrower_type == FTB
        if dsti > cb.max_dsti_ftb; return false; end
    else
        if dsti > cb.max_dsti_hm_btl; return false; end
    end

    # 2. Check LTV by Borrower Type
    if borrower_type == FTB
        if ltv > cb.max_ltv_ftb; return false; end
    elseif borrower_type == HM
        if ltv > cb.max_ltv_hm; return false; end
    elseif borrower_type == BTL
        if ltv > cb.max_ltv_btl; return false; end
        
        # 3. Check ICR (BTL Only)
        # Note: We assume ICR is provided. If 0.0 for non-BTL, strict check might fail if min_icr > 0.
        # But this block is only for BTL.
        if icr < cb.min_icr; return false; end
    end
    
    return true
end
