# src/institutions/Bank.jl
#
# Mortgage underwriting and credit-supply bookkeeping for the single Bank agent.
# Contents:
#   - annuity helpers (monthly payment and its inverse, the maximum loan);
#   - regulatory soft-limit quota machinery (high-LTI / high-LTV approval-in-principle
#     counters and the monthly adaptive targets derived from the rolling history held by
#     the central bank);
#   - loan-to-value and loan-to-income limits offered at bid time;
#   - `evaluate_credit` (maximum loan at clearing) and `calculate_buying_power`
#     (maximum affordable price at bid time);
#   - registration of newly originated mortgages, the monthly reporting/reset step and
#     the mortgage interest-rate update.
# The Bank is driven by the scheduler and by the household and housing-market code.

"""
    annuity_payment(principal, annual_rate, years)

Calculates the monthly mortgage payment using the standard annuity formula.
Math equivalent: P * r / (1 - (1+r)^-n)
"""
function annuity_payment(principal, annual_rate, years)
    r = annual_rate / 12.0
    n = years * 12
    if r == 0
        return principal / n
    end
    # P * (r(1+r)^n) / ((1+r)^n - 1), identical to P * r / (1 - (1+r)^-n)
    return principal * (r * (1+r)^n) / ((1+r)^n - 1)
end

"""
    max_loan_from_payment(max_payment, annual_rate, years)

Inverts the annuity formula to find the maximum Principal for a given monthly payment.
Matches the fraction in Eq 14 of the original model paper: (1 - (1+r)^-n) / r
"""
function max_loan_from_payment(max_payment, annual_rate, years)
    r = annual_rate / 12.0
    n = years * 12
    if r == 0
        return max_payment * n
    end
    # Inverted Formula: M * ((1+r)^n - 1) / (r(1+r)^n)
    return max_payment * ((1+r)^n - 1) / (r * (1+r)^n)
end

"""
    _is_ftb_dsti_bucket(applicant, is_buying_btl) -> Bool

True when the applicant is a first-time buyer purchasing a home to live in
(not buy-to-let), i.e. falls in the first-time-buyer DSTI segment.
"""
@inline function _is_ftb_dsti_bucket(applicant::Household, is_buying_btl::Bool)
    return (applicant.borrower_type == FTB) && !is_buying_btl
end

"""
    _bank_dsti_cap_for(applicant, bank, is_buying_btl)

Bank-level (soft) DSTI cap for the applicant's segment: `bank.dsti_max_ftb` for
first-time buyers, `bank.dsti_max_hm_btl` for home-movers and buy-to-let.
"""
@inline function _bank_dsti_cap_for(applicant::Household, bank::Bank, is_buying_btl::Bool)
    return _is_ftb_dsti_bucket(applicant, is_buying_btl) ? bank.dsti_max_ftb : bank.dsti_max_hm_btl
end

"""
    _reg_dsti_cap_for(applicant, cb, is_buying_btl)

Regulatory DSTI cap for the applicant's segment: `cb.max_dsti_ftb` for first-time
buyers, `cb.max_dsti_hm_btl` for home-movers and buy-to-let.
"""
@inline function _reg_dsti_cap_for(applicant::Household, cb::CentralBank, is_buying_btl::Bool)
    return _is_ftb_dsti_bucket(applicant, is_buying_btl) ? cb.max_dsti_ftb : cb.max_dsti_hm_btl
end

"""
    update_adaptive_soft_limit!(model)

Update prospective soft-limit targets using stored realised-mortgage
histories, then reset prospective counters for the incoming month.
Called monthly after clearing (see `report_and_reset_activity!`).

Each updated target equals:
    max(0, exemption_allowance - realised_high_fraction)

The realised fraction is zero when the relevant history contains
no mortgages. The calculation does not depend on the previous target.

FTB/HM LTI:
- cb.use_pooled_lti_quota selects pooled or separate targets.

Spanish LTV:
- Equal FTB/HM/BTL exemption allowances select a pooled target.
- The pooled realised fraction uses all three segment histories.
- bank.target_prospec_fraction_ftb_ltv stores the shared target
  consumed by the pooled checks in get_loan_to_value_limit.
- Unequal allowances retain separate targets for active segments.
- No LTV target is updated when all Spain soft-LTV flags are off.
- Existing history and counter activation guards are retained.

The additional BTL LTI target remains separately flag-gated.

The pooled FTB+HM quota follows the Java model's pooled path (the single pooled
quota of the original model paper); `use_pooled_lti_quota = false` keeps independent
FTB and HM targets, as in the Java split path. The target has no gain or smoothing term: it is the
remaining distance between the allowance and the realised fraction.
"""
function update_adaptive_soft_limit!(model)
    bank = model.bank
    cb   = model.central_bank
    if cb.use_pooled_lti_quota
        # --- POOLED PATH: FTB + HM share one combined quota (Java default) ---
        # Java: resetMonthlyCounters() lines 144–148.
        # Java uses getHomeMoverMaxFracOverSoftMaxLTI() as the shared limit in the pooled case.
        total_combined = sum(cb.history_total_ftb) + sum(cb.history_total_hm)
        high_combined  = sum(cb.history_high_lti_ftb) + sum(cb.history_high_lti_hm)
        realized = total_combined > 0 ? (high_combined / total_combined) : 0.0
        # Java (Bank.java lines 205–209): the target is the remaining distance between
        # the limit and the realised fraction. It uses no gain and does not depend on
        # the previous target (memoryless).
        shared_target = realized > cb.soft_lti_allowance_hm ? 0.0 : cb.soft_lti_allowance_hm - realized
        # Java only sets maxFracFTBProspecOverSoftMaxLTI in the pooled path (used for both types).
        bank.target_prospec_fraction_ftb = shared_target
        bank.target_prospec_fraction_hm  = shared_target
    else
        # --- SPLIT PATH: Independent FTB and HM queues ---
        # Java: resetMonthlyCounters() lines 150–155.
        # Used when FTB and HM flow allowances differ.

        # FTB Queue
        total_ftb = sum(cb.history_total_ftb)
        high_ftb  = sum(cb.history_high_lti_ftb)
        realized_ftb = total_ftb > 0 ? (high_ftb / total_ftb) : 0.0
        bank.target_prospec_fraction_ftb = realized_ftb > cb.soft_lti_allowance_ftb ?
            0.0 : cb.soft_lti_allowance_ftb - realized_ftb

        # HM Queue
        total_hm = sum(cb.history_total_hm)
        high_hm  = sum(cb.history_high_lti_hm)
        realized_hm = total_hm > 0 ? (high_hm / total_hm) : 0.0
        bank.target_prospec_fraction_hm = realized_hm > cb.soft_lti_allowance_hm ?
            0.0 : cb.soft_lti_allowance_hm - realized_hm
    end

    # --- Spain LTV adaptive targets ---
    # Use the same pooling rule as get_loan_to_value_limit:
    # equal FTB/HM/BTL exemption allowances -> one pooled quota;
    # otherwise -> independent segment targets.
    # In pooled mode the FTB-named field stores the shared target.
    # Histories and counters retain their existing activation guards.
    ltv_targets_active =
        model.spain_soft_ltv_ftb ||
        model.spain_soft_ltv_hm ||
        model.spain_soft_ltv_btl

    pooled_ltv = (
        cb.max_frac_over_soft_max_ltv_ftb == cb.max_frac_over_soft_max_ltv_hm &&
        cb.max_frac_over_soft_max_ltv_hm == cb.max_frac_over_soft_max_ltv_btl
    )

    if ltv_targets_active
        if pooled_ltv
            total_ltv =
                sum(cb.history_total_ftb) +
                sum(cb.history_total_hm) +
                sum(cb.history_total_btl)
            high_ltv =
                sum(cb.history_high_ltv_ftb) +
                sum(cb.history_high_ltv_hm) +
                sum(cb.history_high_ltv_btl)
            realised_ltv = total_ltv > 0 ? high_ltv / total_ltv : 0.0

            bank.target_prospec_fraction_ftb_ltv = max(
                0.0,
                cb.max_frac_over_soft_max_ltv_ftb - realised_ltv
            )
        else
            if model.spain_soft_ltv_ftb
                total_ftb_l = sum(cb.history_total_ftb)
                high_ftb_l = sum(cb.history_high_ltv_ftb)
                realised_ftb_ltv =
                    total_ftb_l > 0 ? high_ftb_l / total_ftb_l : 0.0
                bank.target_prospec_fraction_ftb_ltv = max(
                    0.0,
                    cb.max_frac_over_soft_max_ltv_ftb - realised_ftb_ltv
                )
            end
            if model.spain_soft_ltv_hm
                total_hm_l = sum(cb.history_total_hm)
                high_hm_l = sum(cb.history_high_ltv_hm)
                realised_hm_ltv =
                    total_hm_l > 0 ? high_hm_l / total_hm_l : 0.0
                bank.target_prospec_fraction_hm_ltv = max(
                    0.0,
                    cb.max_frac_over_soft_max_ltv_hm - realised_hm_ltv
                )
            end
            if model.spain_soft_ltv_btl
                total_btl_l = sum(cb.history_total_btl)
                high_btl_l = sum(cb.history_high_ltv_btl)
                realised_btl_ltv =
                    total_btl_l > 0 ? high_btl_l / total_btl_l : 0.0
                bank.target_prospec_fraction_btl_ltv = max(
                    0.0,
                    cb.max_frac_over_soft_max_ltv_btl - realised_btl_ltv
                )
            end
        end
    end

    # Additional BTL LTI target: retain the existing calculation.
    if model.spain_soft_lti_btl
        total_btl_i = sum(cb.history_total_btl)
        high_btl_i  = sum(cb.history_high_lti_btl)
        realised_btl_lti = total_btl_i > 0 ? (high_btl_i / total_btl_i) : 0.0
        bank.target_prospec_fraction_btl_lti = realised_btl_lti > cb.soft_lti_allowance_btl ?
            0.0 : cb.soft_lti_allowance_btl - realised_btl_lti
    end

    # Reset all prospective counters for the incoming month
    bank.n_prospec_total_ftb = 0
    bank.n_prospec_high_ftb  = 0
    bank.n_prospec_total_hm  = 0
    bank.n_prospec_high_hm   = 0
    # Spain per-segment counters are reset unconditionally. Their writers are
    # guarded by the corresponding Spain flags, so in UK mode the counters stay at
    # zero and the reset is idempotent.
    bank.n_prospec_high_ltv_ftb = 0
    bank.n_prospec_high_ltv_hm  = 0
    bank.n_prospec_total_btl    = 0
    bank.n_prospec_high_ltv_btl = 0
    bank.n_prospec_high_lti_btl = 0
end

"""
    check_soft_limit_capacity(bank::Bank, cb::CentralBank, is_ftb::Bool) -> Bool

Internal helper. Returns `true` if the Bank has space in the regulatory queue to issue
a high-LTI Approval in Principle letter to this borrower type right now.

# Adaptive prospect check
Checks whether adding one more high-LTI approval would breach the adaptive target (not the
regulatory limit directly). Not every prospective approval letter converts into an actual
mortgage, so the bank can issue more letters than the regulatory quota would allow if every
letter converted; the headroom is set by `target_prospec_fraction`.

    F_proj = (high_prospec + 1) / (total_prospec + 1)  <=  target_adaptive

The `+1` in both numerator and denominator matches Java's prospective fraction formula
(Bank.java lines 534, 557, 571).

# Pooled vs Split (Java: Bank.java getLoanToIncomeLimit lines 533–579)
When `cb.use_pooled_lti_quota` is true, FTB and HM prospective counts are combined
(Java pooled path, lines 533–550). When false, each type is checked independently
(Java split path, lines 552–579).
"""
function check_soft_limit_capacity(bank::Bank, cb::CentralBank, is_ftb::Bool)
    if cb.use_pooled_lti_quota
        # POOLED PATH: combined FTB + HM counter (Java lines 533–550)
        # Java uses maxFracFTBProspecOverSoftMaxLTI for both types in the pooled path.
        proj_high  = bank.n_prospec_high_ftb  + bank.n_prospec_high_hm  + 1
        proj_total = bank.n_prospec_total_ftb + bank.n_prospec_total_hm + 1
        limit      = bank.target_prospec_fraction_ftb  # equals HM in pooled mode
    else
        # SPLIT PATH: per-type check (Java lines 552–579)
        if is_ftb
            proj_high  = bank.n_prospec_high_ftb  + 1
            proj_total = bank.n_prospec_total_ftb + 1
            limit      = bank.target_prospec_fraction_ftb
        else
            proj_high  = bank.n_prospec_high_hm  + 1
            proj_total = bank.n_prospec_total_hm + 1
            limit      = bank.target_prospec_fraction_hm
        end
    end
    return (proj_high / proj_total) <= limit
end

"""
    register_approval_in_principle!(model, max_downpayment, price, applicant_income, is_ftb, is_home)

Increments the bank's prospective (approval-in-principle) counters when a household
decides to bid on the sales market, consuming quota capacity in the corresponding
segment. Mutates `model.bank` counters only.

Arguments: `max_downpayment` is the household's liquid wealth at bid time, `price` the bid
budget, `applicant_income` the annual gross income; `is_ftb` / `is_home` select the
FTB / home-mover / buy-to-let segment (`is_home = false` is buy-to-let).

Must be called AFTER `agent.persistent_lti_limit` and `agent.persistent_ltv_limit`
have been set (both limits are frozen at bid time), so that the quota state the agent
observed is captured before this call updates it for subsequent agents.

Java parity:
  - UK Bank.acceptApprovalInPrincipleLetter (Bank.java:564–572) — LTI counters only.
  - Spain Bank.acceptApprovalInPrincipleLetter (Bank.java:991–1026) — 3-segment dispatch
    (FTB / HM / BTL) writing both intended-LTV high counters and intended-LTI high
    counters, plus per-segment totals.

# Spain semantics (intended LTV at approval time)
The intended LTV is `(price - max_downpayment) / price`. This is distinct from realised
LTV (post-clearing principal/value), which is written by `register_mortgage!` at clearing
time. Both flow into the same `n_prospec_high_ltv_*` counter triple (Java parity: Spain
Bank uses prospective counters at approval time and realised counters at
endMonthlyAccounting).

# Flag guards
All Spain-specific writes (high-LTV counters; BTL total; BTL high-LTI) are guarded by the
corresponding `model.spain_soft_ltv_*` / `model.spain_soft_lti_btl` flag. With all flags off:
  - FTB/HM total and high-LTI increments are the only writes (UK behaviour).
  - The BTL path performs no writes (the UK model has no BTL prospective counters).
"""
function register_approval_in_principle!(model, max_downpayment::Float64, price::Float64,
                                         applicant_income::Float64,
                                         is_ftb::Bool, is_home::Bool)
    bank = model.bank
    cb   = model.central_bank

    # Intended LTV at approval time (Spain Bank.java:996 / 1004 / 1018).
    # When price <= 0 (degenerate bid) the intended LTV is undefined; use 0.0.
    intended_ltv = price > 0.0 ? (price - max_downpayment) / price : 0.0

    if is_home
        if is_ftb
            # --- FTB segment (UK + Spain shared LTI counters; Spain-only LTV counter) ---
            bank.n_prospec_total_ftb += 1
            # Unconditional high-LTI counter (matches Spain Java approval handling,
            # Bank.java:1005, which also writes unconditionally). The cb.soft_lti_*
            # threshold is the approval-time high-water mark regardless of whether the
            # soft-limit adaptive quota is currently active.
            if price > max_downpayment + applicant_income * cb.soft_lti_limit_ftb
                bank.n_prospec_high_ftb += 1
            end
            if model.spain_soft_ltv_ftb && intended_ltv > cb.soft_max_ltv_ftb
                bank.n_prospec_high_ltv_ftb += 1
            end
        else
            # --- HM segment ---
            bank.n_prospec_total_hm += 1
            if price > max_downpayment + applicant_income * cb.soft_lti_limit_hm
                bank.n_prospec_high_hm += 1
            end
            if model.spain_soft_ltv_hm && intended_ltv > cb.soft_max_ltv_hm
                bank.n_prospec_high_ltv_hm += 1
            end
        end
    else
        # --- BTL segment (Spain only; the UK configuration has no BTL approval-in-principle counters) ---
        # Total, high-LTV and high-LTI counters are all kept per segment.
        # The BTL total is incremented when EITHER the LTV or the LTI soft-limit flag is
        # on (shared denominator).
        if model.spain_soft_ltv_btl || model.spain_soft_lti_btl
            bank.n_prospec_total_btl += 1
        end
        if model.spain_soft_ltv_btl && intended_ltv > cb.soft_max_ltv_btl
            bank.n_prospec_high_ltv_btl += 1
        end
        if model.spain_soft_lti_btl &&
           price > max_downpayment + applicant_income * cb.soft_lti_limit_btl
            bank.n_prospec_high_lti_btl += 1
        end
    end
end

"""
    get_loan_to_value_limit(model, applicant, is_ftb::Bool, is_home::Bool) -> Float64

Returns the LTV the Bank is willing to offer this household at AIPL time. Mirrors
Spain Java `Bank.getLoanToValueLimit(isFirstTimeBuyer, isHome, age, annualGrossEmpIncome)`
(Bank.java:660–800). UK Java has NO equivalent function — UK LTV is the simple
`min(bank.ltv_max_*, cb.max_ltv_*)`.

Called ONCE per agent per step in `submit_market_bids!`, immediately before the
tenure/budget decision. The result is stored as `agent.persistent_ltv_limit` and held
fixed for the entire clearing cycle (the LTI limit is frozen in the same way).

# Segment guard and random-number use
When this segment's Spain soft-LTV flag is OFF, this function returns
`min(bank.ltv_max_*, cb.max_ltv_*)` WITHOUT advancing the RNG, so the random-number
stream is identical to the UK configuration.

# When the segment's soft-LTV mechanism is enabled
1. Sample the private-bank LTV offer using the bank's own settings.
2. If the offer is at or below the regulatory soft cap, return it.
3. If the income exemption applies, return the private-bank offer.
4. Otherwise, if the age exemption applies, return the minimum
   of the private-bank offer and the regulatory hard cap.
5. Otherwise apply the existing pooled or segment-specific quota:
   return the regulatory soft cap when quota is exhausted,
   or the private-bank offer when quota is available.

Checks stop at the first applicable return. The regulatory hard
cap is not a universal clamp in this Java reference routine.
"""
function get_loan_to_value_limit(model, applicant::Household, is_ftb::Bool, is_home::Bool)
    bank = model.bank
    cb   = model.central_bank

    # ── Outermost segment guard: UK pattern, no RNG advance when the flag is off ──
    segment_active = if is_home
        is_ftb ? model.spain_soft_ltv_ftb : model.spain_soft_ltv_hm
    else
        model.spain_soft_ltv_btl
    end
    if !segment_active
        # UK pattern: pure min, no RNG consumed.
        if is_home
            return is_ftb ? min(bank.ltv_max_ftb, cb.max_ltv_ftb) :
                            min(bank.ltv_max_hm,  cb.max_ltv_hm)
        else
            return min(bank.ltv_max_btl, cb.max_ltv_btl)
        end
    end

    # ── Spain path: segment flag is ON; proceed with stochastic internal-LTV draw ──
    rng = abmrng(model)

    # Segment-specific bank caps + bypass-probability (Spain Bank.java:663–688).
    soft_int, hard_int, frac_over = if is_home
        is_ftb ? (
            bank.ltv_soft_max_ftb,
            bank.ltv_max_ftb,
            bank.ltv_frac_over_soft_max_ftb,
        ) : (
            bank.ltv_soft_max_hm,
            bank.ltv_max_hm,
            bank.ltv_frac_over_soft_max_hm,
        )
    else
        (
            bank.ltv_soft_max_btl,
            bank.ltv_max_btl,
            bank.ltv_frac_over_soft_max_btl,
        )
    end

    # 1. Stochastic internal-LTV draw (Spain Bank.java:665–684): the first draw decides
    #    whether the offer lies above the bank's soft maximum, the second (only in that
    #    case) places it within the band. abmrng(model) is used for thread safety.
    internal_ltv = if rand(rng) < frac_over
        soft_int + (hard_int - soft_int) * rand(rng)
    else
        soft_int
    end
    # Preserve the private-bank offer before regulatory branch checks.
    # This guard is inert when the bank's soft maximum does not
    # exceed its hard maximum.
    internal_ltv = min(internal_ltv, hard_int)

    # 2. Offer at or below the regulatory soft cap:
    # return the private-bank offer.
    cb_soft = if is_home
        is_ftb ? cb.soft_max_ltv_ftb : cb.soft_max_ltv_hm
    else
        cb.soft_max_ltv_btl
    end
    if internal_ltv <= cb_soft
        return internal_ltv
    end

    # 3. Income exemption precedes the age exemption.
    # Java returns the private-bank offer without a regulatory
    # hard-LTV clamp in this branch.
    if model.spain_application_income_gate &&
       applicant.annual_income < cb.application_income

        return internal_ltv
    end

    # 4. Age exemption: retain the applicable regulatory hard cap.
    # Reached only if neither earlier branch returned.
    if model.spain_application_age_ltv_gate &&
       applicant.age < cb.application_age_ltv

        regulatory_hard_ltv = if is_home
            is_ftb ? cb.max_ltv_ftb : cb.max_ltv_hm
        else
            cb.max_ltv_btl
        end

        return min(internal_ltv, regulatory_hard_ltv)
    end

    # 5. Pool-flag check — Spain Bank.java:724-728.
    pooled = cb.max_frac_over_soft_max_ltv_ftb == cb.max_frac_over_soft_max_ltv_hm &&
             cb.max_frac_over_soft_max_ltv_hm  == cb.max_frac_over_soft_max_ltv_btl

    if pooled
        # Combined FTB+HM+BTL quota check (Spain Bank.java:730-744).
        proj_high  = bank.n_prospec_high_ltv_ftb + bank.n_prospec_high_ltv_hm +
                     bank.n_prospec_high_ltv_btl + 1
        proj_total = bank.n_prospec_total_ftb + bank.n_prospec_total_hm +
                     bank.n_prospec_total_btl + 1
        if proj_high / proj_total > bank.target_prospec_fraction_ftb_ltv
            return cb_soft  # quota exhausted → CB soft cap binds
        else
            return internal_ltv
        end
    else
        # Per-segment quota check (Spain Bank.java:745-797).
        if is_home
            if is_ftb
                proj_high  = bank.n_prospec_high_ltv_ftb + 1
                proj_total = bank.n_prospec_total_ftb + 1
                target     = bank.target_prospec_fraction_ftb_ltv
            else
                proj_high  = bank.n_prospec_high_ltv_hm + 1
                proj_total = bank.n_prospec_total_hm + 1
                target     = bank.target_prospec_fraction_hm_ltv
            end
        else
            proj_high  = bank.n_prospec_high_ltv_btl + 1
            proj_total = bank.n_prospec_total_btl + 1
            target     = bank.target_prospec_fraction_btl_ltv
        end
        if proj_high / proj_total > target
            return cb_soft
        else
            return internal_ltv
        end
    end
end

"""
    get_loan_to_income_limit(model, is_ftb::Bool, is_home::Bool, applicant_income::Float64) -> Float64

Returns the LTI multiple the Bank is willing to offer this household in an
Approval in Principle letter. Mirrors:
  - UK Bank.getLoanToIncomeLimit(boolean isFirstTimeBuyer) — FTB/HM only.
  - Spain Bank.getLoanToIncomeLimit(isFirstTimeBuyer, isHome, annualGrossEmpIncome)
    (Bank.java:863–957) — adds a BTL branch, the application-income bypass and a
    three-way pool-flag dispatch.

Takes `model` as a single argument (reads `model.bank` and `model.central_bank` internally).

Called ONCE per agent per step (in `submit_market_bids!`), immediately before the
tenure/budget decision. The result is stored as `agent.persistent_lti_limit` and held
fixed for the entire clearing cycle (Java: Household.persistentLTILimit set in
bidForAHome l.445 OO / l.156 BTL).

# Logic
  - Application-income carve-out (guarded by `model.spain_application_income_gate`):
    if income < CB application_income, return the bank hard maximum (regulatory bypass).
  - FTB/HM path (`is_home=true`): soft-LTI quota check via `check_soft_limit_capacity`.
  - BTL path (`is_home=false`): only meaningful when `model.spain_soft_lti_btl` is on.
    When off: returns `bank.lti_max_btl` (99.0 by default, never binds).
    When on: applies pool-flag dispatch over CB LTI allowances and BTL prospective
    counters (mirror of Spain Bank.java:868-957).

With `is_home=false` and `model.spain_soft_lti_btl=false` the returned 99.0 is a hard cap
that the BTL `evaluate_credit` path does not consume (it uses only LTV and ICR).
"""
function get_loan_to_income_limit(model, is_ftb::Bool, is_home::Bool,
                                  applicant_income::Float64)
    bank = model.bank
    cb   = model.central_bank

    # Segment-specific bank hard caps + CB soft caps.
    hard_internal, cb_soft = if is_home
        is_ftb ? (bank.lti_max_ftb, cb.soft_lti_limit_ftb) :
                 (bank.lti_max_hm,  cb.soft_lti_limit_hm)
    else
        (bank.lti_max_btl, cb.soft_lti_limit_btl)
    end

    # Application-income bypass (Spain Bank.java:865), guarded by its flag.
    # The default `cb.application_income == 0.0` keeps this inert.
    if model.spain_application_income_gate && applicant_income < cb.application_income
        return hard_internal
    end

    if is_home
        # ── FTB/HM path: soft-LTI quota machinery ──
        if !cb.soft_limit_active
            return hard_internal
        end
        if check_soft_limit_capacity(bank, cb, is_ftb)
            return hard_internal
        else
            return min(hard_internal, cb_soft)
        end
    else
        # ── BTL path: meaningful only when `model.spain_soft_lti_btl` is on ──
        if !model.spain_soft_lti_btl
            return hard_internal  # 99.0 placeholder; never binds
        end

        # Pool-flag check — Spain Bank.java:880.
        pooled = cb.soft_lti_allowance_ftb == cb.soft_lti_allowance_hm &&
                 cb.soft_lti_allowance_hm  == cb.soft_lti_allowance_btl
        if pooled
            # Spain Bank.java:885-886 uses `maxFracFTBProspecOverSoftMaxLTI` (the FTB
            # adaptive target) as the SHARED target in the pooled branch, not BTL's.
            # `bank.target_prospec_fraction_ftb` corresponds to that field.
            proj_high  = bank.n_prospec_high_ftb + bank.n_prospec_high_hm +
                         bank.n_prospec_high_lti_btl + 1
            proj_total = bank.n_prospec_total_ftb + bank.n_prospec_total_hm +
                         bank.n_prospec_total_btl + 1
            if proj_high / proj_total > bank.target_prospec_fraction_ftb
                return min(hard_internal, cb_soft)
            else
                return hard_internal
            end
        else
            proj_high  = bank.n_prospec_high_lti_btl + 1
            proj_total = bank.n_prospec_total_btl + 1
            if proj_high / proj_total > bank.target_prospec_fraction_btl_lti
                return min(hard_internal, cb_soft)
            else
                return hard_internal
            end
        end
    end
end


"""
    evaluate_credit(bank, applicant, house_price, model) -> Float64

Maximum mortgage principal the bank will lend to `applicant` for a property priced at
`house_price`, evaluated at clearing time. Returns 0.0 when the applicant is ineligible
(below the bank minimum age, above the age limit, or with no remaining term).

Two underwriting paths:
- Investment purchase (buy-to-let): the minimum of the LTV and interest-coverage-ratio
  (ICR) limits. With `model.spain_btl_repayment_mode` on, investment purchases use the
  home-buyer path instead.
- Home purchase (first-time buyers and home-movers): the minimum of the LTV, LTI and
  DSTI limits, where the DSTI limit inverts the annuity formula over the remaining term.

The LTV and LTI limits are the values frozen on the applicant at bid time
(`persistent_ltv_limit`, `persistent_lti_limit`). Each bank limit is combined with the
corresponding central-bank limit by taking the stricter of the two.
"""
function evaluate_credit(bank::Bank, applicant::Household, house_price::Float64, model)
    cb = model.central_bank

    # ── Bank minimum age floor (Spain only) ──
    # Spain Bank.java:402 `if (age < BANK_MIN_AGE_LIMIT) return 0`.
    # Enabled by `model.spain_bank_min_age`; the threshold is `model.bank_min_age_limit`.
    if model.spain_bank_min_age && applicant.age < model.bank_min_age_limit
        return 0.0
    end

    # --- Purchase Purpose and BTL Repayment Routing ---
    # An investment purchase requires the investor flag AND an
    # existing owner-occupied home. Investor identity alone does
    # not make an own-home purchase a BTL purchase.
    is_buying_btl_outer =
        applicant.is_btl_investor && applicant.tenure_status == OwnerOccupier
    route_btl_as_home =
        is_buying_btl_outer && model.spain_btl_repayment_mode

    # Repayment routing and maturity selection are separate.
    # Actual repayment BTL purchases use:
    # - full configured maturity when spain_btl_paper_maturity=true;
    # - the owner-occupier age ladder when the flag is false.
    # Actual interest-only BTL purchases retain full maturity.
    # Own-home purchases always use the owner-occupier age ladder.
    btl_term_uses_age_ladder =
        route_btl_as_home && !model.spain_btl_paper_maturity

    # --- 0. Age and Maturity Constraint ---
    term_years = model.mortgage_duration_years
    max_age_entry = model.bank_age_limit

    if is_buying_btl_outer && !btl_term_uses_age_ladder
        # Full-maturity investment loan: application-age cutoff.
        if applicant.age > max_age_entry
            return 0.0
        end
    else
        # Own-home purchase, or repayment BTL with Java maturity:
        # shorten the term to finish by the configured age limit.
        # Use the same integer-month calculation as the budget.
        time_to_retire_raw = max_age_entry - applicant.age
        time_to_retire_months = floor(Int, time_to_retire_raw * 12)
        time_to_retire_years = time_to_retire_months / 12.0
        term_years = min(term_years, time_to_retire_years)

        if term_years <= 0
            return 0.0
        end
    end

    # =========================================================
    # PATH A: INVESTORS (Buy-to-Let)
    # Rules: LTV + ICR (Eq 15)
    # If an agent with the BTL flag is already an OwnerOccupier,
    # any new purchase is treated as an investment (BTL loan).
    #
    # Double veto: the stricter of the bank and central-bank limits applies.
    #
    # When `model.spain_btl_repayment_mode` is on, this branch is unreachable for
    # investment buys: they fall through to the owner-occupier checks (LTV + LTI + DSTI, as in Spain).
    # Purchase purpose, not borrower label, governs this path selection.
    # =========================================================
    is_buying_btl = is_buying_btl_outer

    if is_buying_btl && !model.spain_btl_repayment_mode
        # --- 1. LTV Constraint (Collateral) ---
        # Read the frozen LTV (set at bid time by get_loan_to_value_limit).
        # With the Spain soft-LTV flags off, persistent_ltv_limit equals
        # min(bank.ltv_max_btl, cb.max_ltv_btl).
        # Spain parity: Bank.requestApproval (Bank.java:504) reads h.getPersistentLTVLimit().
        effective_ltv_limit = applicant.persistent_ltv_limit
        max_ltv = house_price * effective_ltv_limit
        
        # --- 2. ICR Constraint (Profitability) ---
        # Strictest Limit
        effective_icr_limit = max(bank.icr_min, cb.min_icr)

        # Expected Rent = Price * s_bar
        # Java: Bank.requestApproval() (line 373) uses expAvFlowYield directly with no
        # zero-guard. When ema_yield == 0: expected_rent = 0, so max_icr = 0 and
        # min(max_ltv, 0) = 0: the loan is rejected.
        market_yield = model.market_stats.ema_yield
        expected_rent = house_price * market_yield

        # NaN guard (same pattern as in the household bid logic). When the effective ICR
        # floor is zero, `expected_rent / effective_icr_limit` would give +Inf (positive
        # yield) or 0/0 = NaN (zero yield). The guard collapses both cases to "ICR does
        # not bind, only LTV constrains". It is inert whenever effective_icr_limit >= 1e-9.
        if effective_icr_limit > 1e-9 && bank.current_mortgage_rate > 1e-9
            max_interest = expected_rent / effective_icr_limit
            max_icr = max_interest / bank.current_mortgage_rate
        else
            max_icr = max_ltv  # ICR inert ⇒ LTV is the only binding constraint
        end

        # Result: lowest of LTV and ICR limits (Spain parity).
        # BTL has no LTI constraint. Spain Bank.java:530-534 (`requestApproval` BTL
        # branch) applies LTV + ICR only, and the `getMaxMortgagePrice` BTL branch (L645)
        # is the same. The Spain BTL hard maximum LTI (config.properties:683) is stored on
        # `Household.persistentLTILimit` via `getLoanToIncomeLimit(false,false,income)`
        # and used only for approval-in-principle soft-quota counters
        # (`acceptApprovalInPrincipleLetter`, Spain Bank.java:991-1024); it never binds the
        # BTL loan principal or price.
        return min(max_ltv, max_icr)
    end

    # =========================================================
    # PATH B: HOME BUYERS (FTB & Home Movers)
    # Rules: LTV + LTI (Eq 13) + DSTI (Eq 14)
    # Regulatory queue: soft LTI limit
    # =========================================================

    # 1. Determine internal limits (FTB vs HM)
    if applicant.borrower_type == FTB
        internal_lti = bank.lti_max_ftb
    else
        internal_lti = bank.lti_max_hm
    end

    # Read the frozen LTV (set at bid time by get_loan_to_value_limit).
    # With the Spain soft-LTV flags off, persistent_ltv_limit equals
    # min(bank.ltv_max_*, cb.max_ltv_*).
    # Spain parity: Bank.requestApproval (Bank.java:504) reads h.getPersistentLTVLimit().
    effective_ltv_limit = applicant.persistent_ltv_limit
    
    # --- 2. LTV Constraint (Collateral) ---
    max_ltv = house_price * effective_ltv_limit
    
    # --- 3. LTI Constraint (Eq 13 - Gross Income) ---
    # Java parity: Bank.requestApproval() (l.346) uses h.getPersistentLTILimit() rather than
    # re-querying getLoanToIncomeLimit(). The limit was frozen on the applicant at bid time by
    # get_loan_to_income_limit() so that quota changes during market clearing cannot
    # retroactively shrink a loan that was already priced into the agent's bid decision.
    # When the soft limit is inactive, `get_loan_to_income_limit` returns `internal_lti`,
    # so `persistent_lti_limit == internal_lti`.
    max_lti = applicant.annual_income * applicant.persistent_lti_limit

    # --- 4. DSTI Constraint (Eq 14 - Affordability) ---
    # Double Veto: Strictest DSTI
    bank_dsti_cap = _bank_dsti_cap_for(applicant, bank, is_buying_btl_outer)
    reg_dsti_cap  = _reg_dsti_cap_for(applicant, cb, is_buying_btl_outer)
    effective_dsti_limit = min(bank_dsti_cap, reg_dsti_cap)

    gross_monthly = applicant.annual_income / 12.0

    # ── Dynamic affordability ceiling (DSTI hard maximum) ──
    # Spain Java `Bank.java::getHardMaxAffordability` (L965-L974) has three clauses:
    #   (1) application-income bypass: if applicantIncome < centralBank.applicationIncome
    #       the regulatory limit does not apply;
    #   (2) essential-consumption ceiling: limit = 1.0 − ENC / monthlyGrossEmploymentIncome;
    #   (3) the result is folded in via min() into effective_dsti_limit.
    # Enabled by `model.spain_dynamic_affordability_ceiling`, which is independent of the
    # household-side essential-consumption flag because the ceiling is applied by the bank.
    # The bypass applies only when `model.spain_application_income_gate` is on AND
    # applicant.annual_income is below `cb.application_income` (recomputed each step in
    # `central_bank_step!` via `income_at_percentile`). With a percentile of 0.0 the
    # nearest-rank threshold is the minimum income in a non-empty cache (0.0 only in the
    # empty-cache start-up fallback), so activation depends on the realised threshold and
    # the strict `<` comparison.
    # The ceiling reads `Config.ESSENTIAL_NOMINAL_CONSUMPTION_SPAIN_VALUE`, the single
    # source of the essential-consumption amount shared with the household side.
    if model.spain_dynamic_affordability_ceiling
        limit_given_by_essential =
            1.0 -
            Config.ESSENTIAL_NOMINAL_CONSUMPTION_SPAIN_VALUE / gross_monthly

        income_exempt =
            model.spain_application_income_gate &&
            applicant.annual_income < cb.application_income

        effective_dsti_limit = if income_exempt
            min(bank_dsti_cap, limit_given_by_essential)
        else
            min(bank_dsti_cap, reg_dsti_cap, limit_given_by_essential)
        end
    end

    max_payment = gross_monthly * effective_dsti_limit
    
    # Invert annuity to find Max Loan
    max_dsti = max_loan_from_payment(
        max_payment, 
        bank.current_mortgage_rate, 
        term_years 
    )

    # Result: lowest of LTV, LTI, DSTI
    max_loan_borrower_constraints = min(max_ltv, max_lti, max_dsti)

    # The bank imposes no supply-side (liquidity or capital) constraint on lending (Java parity).
    return max_loan_borrower_constraints
end

"""
    calculate_buying_power(bank, agent, model) -> Float64

Maximum house price P_max ("the backpack") the agent can afford at bid time: the hard
budget constraint in the desired-price calculation (Eq 1).

# Encapsulation
The logic lives in the Bank module so that agents do not access private bank variables
(LTV/LTI limits, mortgage rate, DSTI and ICR caps) directly: the agent asks for its
limit and the bank solves its own constraints.

# Constraints
P_max is the minimum of an income-based and a wealth-based price limit.

1. Income constraint:
   - Home buyers (and Spain investment buys routed through the home-buyer path):
     P_max_income = min(Income * LTI_limit, DSTI-implied loan) + Cash
   - Buy-to-let investors: ICR-implied price, Cash / (1 - Yield / (ICR * r)),
     with no LTI bound.

2. Wealth constraint (LTV-driven):
   - The bank requires a minimum downpayment fraction (1 - LTV_limit).
   - Even with high income, a borrower is limited by the cash available for the downpayment.
   - P_max_wealth = Cash / (1 - LTV_limit)

If the applicant is ineligible for a loan (age rules), P_max is the available cash only.

# Returns
- `Float64`: The maximum purchase price (P_max).
"""
function calculate_buying_power(bank::Bank, agent::Household, model)    
    cb = model.central_bank

    # ── Bank minimum age floor (Spain only) ──
    # Spain Bank.java:402 `if (age < BANK_MIN_AGE_LIMIT) return 0`.
    # When the floor binds, loan principal is 0 and buying power collapses to cash only.
    # The threshold is `model.bank_min_age_limit`.
    if model.spain_bank_min_age && agent.age < model.bank_min_age_limit
        liquid_wealth_floor = agent.bank_balance - 0.01
        return liquid_wealth_floor < 0.0 ? 0.0 : liquid_wealth_floor
    end

    # --- 0. Determine liquid wealth (Java replication) ---
    # Matches Bank.java: getMaxMortgagePrice
    # Java maximises leverage using all liquid wealth minus 1 cent to avoid rounding errors:
    # max_downpayment = h.getBankBalance() - 0.01
    liquid_wealth = agent.bank_balance - 0.01
    if liquid_wealth < 0.0
        liquid_wealth = 0.0
    end

    # --- 1. Check Eligibility (Age & Term) ---
    # Matches Java "getNPayments" check at start of getMaxMortgagePrice.
    # If age limit reached, loan amount is 0, so Buying Power = Cash.
    
    # ── Bank age limit ──
    # Reads `model.bank_age_limit` (the resolved age limit for the active configuration).
    max_age_entry = model.bank_age_limit
    is_investing = agent.is_btl_investor && agent.tenure_status == OwnerOccupier

    # ── BTL routing ──
    # Spain Java Bank.java#L598 (getMaxMortgagePrice): when `!interestOnlyMortgagesForBTL`,
    # `isHome` is forced to `true` BEFORE the eligibility check, LTI selection, and
    # the LTI-vs-ICR affordability branch. Mirrored here: when
    # `model.spain_btl_repayment_mode` is on AND `is_investing`, the agent is treated as an
    # owner-occupier for eligibility, LTI selection (reads agent.persistent_lti_limit,
    # which is stamped for BTL at bid time) and the DSTI affordability branch.
    # Primary-residence buys by BTL-gene tenants are not affected (is_investing
    # is already false for them).
    route_btl_as_home = is_investing && model.spain_btl_repayment_mode
    effective_is_investing = is_investing && !route_btl_as_home

    # ── BTL maturity selection ──
    # Term resolution and age eligibility are decoupled from the master
    # `model.spain_btl_repayment_mode` flag. `effective_is_investing` above is the
    # underwriting-routing gate (LTI selection, DSTI vs ICR affordability dispatch).
    # `btl_uses_btl_eligibility` selects both age eligibility and the term used in the
    # DSTI annuity calculation below. With Spain repayment mode on:
    # - paper-maturity on: application-age cutoff and full configured term;
    # - paper-maturity off: owner-occupier age ladder for eligibility and term.
    # The full-term BTL convention comes from the original model paper.
    # With repayment mode off, `btl_term_uses_age_ladder` is false and
    # `btl_uses_btl_eligibility` equals `effective_is_investing`.
    btl_term_uses_age_ladder = route_btl_as_home && !model.spain_btl_paper_maturity
    btl_uses_btl_eligibility = is_investing && !btl_term_uses_age_ladder

    eligible_for_loan = true

    if btl_uses_btl_eligibility
        # Strict application-age cutoff for full-maturity BTL loans (Bank.java:271)
        if agent.age > max_age_entry
            eligible_for_loan = false
        end
    else
        # Owner-occupiers (and repayment BTL with Java maturity) must have time left to the
        # age limit (Bank.java:260). Quantise to integer months.
        time_to_retire_raw = max_age_entry - agent.age
        time_to_retire_months = floor(Int, time_to_retire_raw * 12)
        if time_to_retire_months <= 0
            eligible_for_loan = false
        end
    end

    if !eligible_for_loan
        # Cash Buyer Only (No Loan)
        return liquid_wealth
    end

    # --- 2. Determine Applicable Limits (Double Veto) ---
    # Legend: Double Veto means Stricter of (Bank Policy, Regulatory Policy)
    #
    # Read the frozen LTV (set at bid time by get_loan_to_value_limit).
    # With the Spain soft-LTV flags off, persistent_ltv_limit equals
    # min(bank.ltv_max_*, cb.max_ltv_*).
    # Spain parity: Bank.getMaxMortgagePrice (Bank.java:614) reads h.getPersistentLTVLimit().
    effective_ltv_limit = agent.persistent_ltv_limit

    if effective_is_investing
        # Buy-to-let: ICR-bound (no LTI in the budget); the home-mover LTI only seeds
        # max_loan_lti, which the BTL branch below ignores.
        current_lti_limit = bank.lti_max_hm 
    elseif agent.borrower_type == FTB
        current_lti_limit = bank.lti_max_ftb
    else
        current_lti_limit = bank.lti_max_hm
    end

    # --- 3. Solve Income Constraint (LTI) ---
    # Java parity: getMaxMortgagePrice() (Bank.java ~l.385) uses h.getPersistentLTILimit(),
    # the limit frozen at bid time. A live queue check here would diverge from the LTI
    # limit already embedded in the agent's tenure decision (decide_rent_or_buy calls this
    # function, and its output drives the buy/rent branch). Both paths must see the same
    # limit, so `persistent_lti_limit` (snapshot taken by `get_loan_to_income_limit()` with
    # the queue state at bid time) is read, keeping the budget computation consistent with
    # the bid decision regardless of subsequent queue motion.
    #
    # With `model.spain_btl_repayment_mode` on, Spain investment buys also read
    # `agent.persistent_lti_limit` (stamped for BTL at bid time). Mirrors Spain Java
    # Bank.java#L631 reading `h.getPersistentLTILimit()` after the L598 force.
    if !effective_is_investing
        current_lti_limit = agent.persistent_lti_limit
    end

    # Max Loan = Income * LTI_Limit
    max_loan_lti = agent.annual_income * current_lti_limit
    
    # --- 4. Solve Affordability Constraint (DSTI or ICR) ---
    # Double Veto: Strictest DSTI/ICR applies.
    bank_dsti_cap = _bank_dsti_cap_for(agent, bank, is_investing)
    reg_dsti_cap  = _reg_dsti_cap_for(agent, cb, is_investing)
    effective_dsti_limit = min(bank_dsti_cap, reg_dsti_cap)

    max_loan_dsti = Inf
    buying_power_income = 0.0

    if !effective_is_investing 
        # --- Owner-occupier (or Spain investment routed as a home purchase): DSTI ---
        # 1. Maximum monthly payment allowed (DSTI limit * gross monthly income)
        gross_monthly = agent.annual_income / 12.0

        # ── Dynamic affordability ceiling (DSTI hard maximum) ──
        # Same adjustment as in the `evaluate_credit` home-buyer path, including the
        # application-income bypass of Spain Java `Bank.java::getHardMaxAffordability`
        # (L965-L974). Enabled by `model.spain_dynamic_affordability_ceiling`. The bypass
        # needs `model.spain_application_income_gate` on AND
        # `agent.annual_income < cb.application_income` (the threshold defaults to 0.0).
        if model.spain_dynamic_affordability_ceiling
            limit_given_by_essential =
                1.0 -
                Config.ESSENTIAL_NOMINAL_CONSUMPTION_SPAIN_VALUE / gross_monthly

            income_exempt =
                model.spain_application_income_gate &&
                agent.annual_income < cb.application_income

            effective_dsti_limit = if income_exempt
                min(bank_dsti_cap, limit_given_by_essential)
            else
                min(bank_dsti_cap, reg_dsti_cap, limit_given_by_essential)
            end
        end

        max_payment = gross_monthly * effective_dsti_limit
        
        # Term resolution must mirror evaluate_credit for internal consistency:
        # - OO (and Spain routed-BTL when paper-maturity is OFF): age-ladder term
        # - Spain routed-BTL with paper-maturity ON: full configured term
        term_years = if btl_uses_btl_eligibility
            model.mortgage_duration_years
        else
            # Re-use the Java-style integer-month truncation from the OO age ladder.
            time_to_retire_raw = max_age_entry - agent.age
            time_to_retire_months = floor(Int, time_to_retire_raw * 12)
            time_to_retire_years = time_to_retire_months / 12.0
            min(model.mortgage_duration_years, time_to_retire_years)
        end

        # 2. Invert annuity to find Max Loan Principal
        max_loan_dsti = max_loan_from_payment(
            max_payment, 
            bank.current_mortgage_rate, 
            term_years
        )
        
        # The actual Max Loan is the stricter of LTI or DSTI
        max_loan_income_based = min(max_loan_lti, max_loan_dsti)
    
        # Buying Power = Allowable Loan + Cash (using liquid_wealth)
        buying_power_income = max_loan_income_based + liquid_wealth
        
    else
        # --- BTL: Interest Coverage Ratio (ICR) ---
        # BTL investors are constrained by the property's self-generated income (Rent), not salary.
        # The Bank requires: Expected Rent >= Interest Payment * ICR_Limit
        # Rearranging for Price (assuming Max Limit):
        # P_max = Cash / (1 - Yield / (ICR * r))
        
        yield = model.market_stats.ema_yield
        interest_rate = bank.current_mortgage_rate
        
        # The regulatory constraint is a MINIMUM Ratio (Rent/Interest >= Target).
        # We must satisfy the stricter of the two targets (the higher value).
        effective_icr_min = max(bank.icr_min, cb.min_icr)
        
        # Solve for the denominator (1 - Term)
        # Term = Yield / (ICR * Rate)
        if interest_rate > 1e-9 && effective_icr_min > 1e-9
             term = yield / (effective_icr_min * interest_rate)
             denominator = 1.0 - term
             
             # If denominator <= 0, the Yield is high enough to cover interest fully without equity pressure.
             # In this case, Leverage is fundamentally unconstrained by ICR (limited only by LTV).
             if denominator <= 0.0001
                 buying_power_income = Inf 
             else
                 # Max Price based on ICR constraint
                 buying_power_income = liquid_wealth / denominator
             end
        else
             # If interest is 0, ICR acts as no constraint
             buying_power_income = Inf
        end

        # BTL has no LTI cap on buying power: Spain Java `getMaxMortgagePrice` BTL branch
        # (Bank.java:645) applies LTV and ICR only.
    end

    # --- 5. Solve Wealth Constraint (LTV) ---
    # Max Price = Cash / Downpayment%
    min_downpayment_fraction = 1.0 - effective_ltv_limit
    
    # Corner Case: If downpayment requirement is truly zero (100%+ LTV), wealth
    # constraint is infinite. A merely tiny but positive down-payment fraction
    # must still bind; otherwise bid-time buying power can admit near-zero-cash
    # buyers that clearing-time `evaluate_credit` later rejects when it applies
    # the exact LTV gap.
    if min_downpayment_fraction <= 0.0
        max_price_ltv = Inf
    else
        # Use liquid_wealth (already checked for < 0)
        # Avoid division by zero if cash simplifies to 0 (though liquid_wealth >= 0)
        if liquid_wealth < 1e-9
            return 0.0
        end
        max_price_ltv = liquid_wealth / min_downpayment_fraction
    end

    # --- 6. The Backpack Limit ---
    # The true constraint is the "tightest" of the two.
    p_max = min(buying_power_income, max_price_ltv)

    return p_max
end

"""
    report_and_reset_activity!(model)

Called post-clearing each step — after all market transactions have settled and
post-clearing statistics have been collected, but before the interest rate is updated
(see the scheduler's post-clearing step).

Performs three sub-operations, all of which require finalised flow data from the
completed clearing phase:

1. **Commit to rolling LTI history** — pushes this month's per-type realised lending
   counts (`current_month_total_ftb`, `current_month_high_lti_ftb`, and HM counterparts)
   into the Central Bank's 12-month rolling history
   (`cb.history_total_ftb / history_high_lti_ftb`, and HM equivalents).

2. **Recompute adaptive prospective targets** — calls `update_adaptive_soft_limit!` to
   derive next month's approval-in-principle quota
   (`target_prospec_fraction_ftb / target_prospec_fraction_hm`) from the now-complete
   rolling window. The `n_prospec_*` counters are also zeroed internally by that call.

3. **Reset monthly flow counters** — zeros `current_month_total_ftb` etc. so they
   accumulate cleanly from zero across the next step's mortgage recording.

Rotation of the `oo_ltv_window` / `oo_lti_window` slot is deliberately not done here:

The slot advance and `empty!` are performed in the scheduler's pre-clearing step. The
reason is a timing constraint:

  • The slot must be advanced and emptied BEFORE clearing so that `register_mortgage!`,
    called during clearing, writes this month's LTV values into the fresh slot.
  • Advancing the slot here (post-clearing) would happen after clearing has already filled
    it, so DataCollection would always encounter one empty slot in the ROLLING_WINDOW-slot
    array and the effective window would shrink from ROLLING_WINDOW to ROLLING_WINDOW-1.

The rotation must therefore stay in the pre-clearing step.

Reference (cross-check only): `bank.step()` / `resetMonthlyCounters()` in Bank.java.
"""
function report_and_reset_activity!(model)
    bank = model.bank
    cb   = model.central_bank
    # 1. Commit this month's realised flow to the Central Bank's rolling history.
    #    The nine-argument overload also carries the per-segment realised counters
    #    (FTB-LTV, HM-LTV, BTL total, BTL-LTV, BTL-LTI). Their writers in
    #    `register_mortgage!` are flag-gated, so in the UK configuration these arguments
    #    are zero.
    update_central_bank_history!(
        cb,
        bank.current_month_total_ftb, bank.current_month_high_lti_ftb,
        bank.current_month_total_hm,  bank.current_month_high_lti_hm,
        bank.current_month_high_ltv_ftb,
        bank.current_month_high_ltv_hm,
        bank.current_month_total_btl,
        bank.current_month_high_ltv_btl,
        bank.current_month_high_lti_btl
    )

    # 2. Recompute adaptive prospective targets for the coming month.
    #    (update_adaptive_soft_limit! also resets n_prospec_* counters internally.)
    update_adaptive_soft_limit!(model)

    # 3. Reset this month's realised flow counters for the next step.
    bank.current_month_total_ftb     = 0
    bank.current_month_high_lti_ftb  = 0
    bank.current_month_total_hm      = 0
    bank.current_month_high_lti_hm   = 0
    # The five per-segment realised counters are reset unconditionally. Their writers
    # are flag-gated; in UK mode they are already zero, so the reset is idempotent.
    bank.current_month_high_ltv_ftb  = 0
    bank.current_month_high_ltv_hm   = 0
    bank.current_month_total_btl     = 0
    bank.current_month_high_ltv_btl  = 0
    bank.current_month_high_lti_btl  = 0
end

"""
    register_mortgage!(bank, mortgage, annual_income, borrower_type, is_home, model; down_payment=0.0)

Records a newly issued mortgage against the Bank's regulatory
and interest-rate accounting. Called by `execute_transaction!` in HousingMarket.jl.

# Arguments
- `mortgage`       : The `Mortgage` object just created.
- `annual_income`  : Buyer's annual gross employment income (denominator for LTI).
- `borrower_type`  : `FTB`, `HM`, or `BTL`.
- `is_home`        : `true` for Owner-Occupier purchases; `false` for BTL.
                     Mirrors Java's `isHome` flag in `Bank.requestLoan`.
- `down_payment`   : Cash paid at purchase; used with the principal to record the
                     origination LTV.

# Operations
1. **Origination history** (OO only) — pushes the origination LTV and LTI into the
   current slot of the rolling `oo_ltv_window` / `oo_lti_window`.
2. **High-LTI classification** (OO only) — compares realised LTI against the
   type-specific Central Bank soft threshold (only while the soft-limit regime is active)
   and sets `mortgage.is_high_lti`. BTL mortgages are excluded from OO soft-limit
   tracking (Java `if (isHome)` gate, Bank.java:303).
3. **Per-type monthly counter update** — increments `current_month_total_ftb/hm`
   and `current_month_high_lti_ftb/hm` (Java: `nFTBMortgages_New` etc.), plus the Spain
   per-segment high-LTV / BTL counters when the corresponding flags are on.
4. **Credit supply accumulation** — adds the principal to `current_credit_supply`
   for the interest-rate feedback mechanism (Eq 17).
"""
function register_mortgage!(bank::Bank, mortgage::Mortgage, annual_income::Float64,
                             borrower_type::BorrowerType, is_home::Bool, model;
                             down_payment::Float64=0.0)
    cb = model.central_bank

    if is_home
        # --- OO LTV Recording (Java: CreditSupply.recordLoan) ---
        # Record LTV at origination = principal / (principal + downPayment)
        # into the current slot of the rolling window (FTB + HM only, not BTL).
        if mortgage.principal > 0.0
            ltv_at_origination = mortgage.principal / (mortgage.principal + down_payment)
            push!(bank.oo_ltv_window[bank.oo_ltv_index], ltv_at_origination)
        end
        # 1. Classify high-LTI using the type-specific soft threshold.
        # Java: Bank.requestLoan lines 305–314.
        soft_cap    = (borrower_type == FTB) ? cb.soft_lti_limit_ftb : cb.soft_lti_limit_hm
        lti         = mortgage.principal / annual_income
        # --- OO LTI Recording (Java: CreditSupply.recordLoan) ---
        # Push LTI-at-origination into the current slot of the rolling window.
        # lti is already computed above; oo_ltv_index is shared with the LTV window.
        push!(bank.oo_lti_window[bank.oo_ltv_index], lti)
        # Guard: only classify as high-LTI when the soft-limit regime is active.
        # Without it, a soft LTI limit of 0.0 (no policy) would flag every
        # positive-principal mortgage as high-LTI and inflate the monthly counters
        # even though the quota is inert.
        is_high_lti = cb.soft_limit_active && (lti > soft_cap)
        mortgage.is_high_lti = is_high_lti

        # 2. Update per-type realised monthly counters.
        if borrower_type == FTB
            bank.current_month_total_ftb += 1
            if is_high_lti; bank.current_month_high_lti_ftb += 1; end
            # Per-segment realised high-LTV counter (Spain flag).
            # `ltv_at_origination` is defined above when mortgage.principal > 0.
            if model.spain_soft_ltv_ftb && mortgage.principal > 0.0 && ltv_at_origination > cb.soft_max_ltv_ftb
                bank.current_month_high_ltv_ftb += 1
            end
        else  # HM (home-movers and edge-case OO BTL-gene buyers)
            bank.current_month_total_hm += 1
            if is_high_lti; bank.current_month_high_lti_hm += 1; end
            if model.spain_soft_ltv_hm && mortgage.principal > 0.0 && ltv_at_origination > cb.soft_max_ltv_hm
                bank.current_month_high_ltv_hm += 1
            end
        end
    else
        # BTL purchase: the UK configuration does not track these counters; the Spain
        # configuration keeps per-segment realised counters under the BTL soft-limit
        # flags. Counters stay at zero when the flags are off.
        mortgage.is_high_lti = false
        if (model.spain_soft_ltv_btl || model.spain_soft_lti_btl) && mortgage.principal > 0.0
            ltv_btl_o = mortgage.principal / (mortgage.principal + down_payment)
            lti_btl_o = annual_income > 0.0 ? mortgage.principal / annual_income : 0.0
            bank.current_month_total_btl += 1
            if model.spain_soft_ltv_btl && ltv_btl_o > cb.soft_max_ltv_btl
                bank.current_month_high_ltv_btl += 1
            end
            if model.spain_soft_lti_btl && lti_btl_o > cb.soft_lti_limit_btl
                bank.current_month_high_lti_btl += 1
            end
        end
    end

    # 3. Accumulate credit supply for the interest-rate mechanism (Eq 17).
    bank.current_credit_supply += mortgage.principal
end

"""
    update_interest_rate!(bank, model)

Updates the mortgage interest rate at the end of the simulation step
(Eq 17 and the credit-supply feedback of the original model paper).

Equation 17:
    i_{t+1} = i_t + phi * (C_t - C_{t-1}) / N
    r_{mortgage} = r_{policy} + i_{t+1}

The bank acts as a counter-cyclical stabiliser: if credit supply increases, it raises
rates to cool demand. Mutates `bank.current_spread`, `bank.current_mortgage_rate`,
`bank.previous_credit_supply` and resets `bank.current_credit_supply`.
"""
function update_interest_rate!(bank::Bank, model)
    # 1. Calculate change in credit per household
    # delta_C: change in total flow of credit compared to last month
    delta_C = bank.current_credit_supply - bank.previous_credit_supply

    # Per capita change
    # Uses the current active population (nagents) rather than the static target
    n_agents = nagents(model)
    per_capita_delta = n_agents > 0 ? delta_C / n_agents : 0.0
    
    # 2. Update spread (Eq 17)
    # phi is the elasticity parameter (`model.params.phi`)
    # New spread = old spread + adjustment
    adjustment = model.params.phi * per_capita_delta
    
    bank.current_spread += adjustment
    
    # 3. Enforce Zero Lower Bound restriction
    # The spread cannot be negative (Mortgage Rate cannot fall below Base Rate)
    if bank.current_spread < 0.0
        bank.current_spread = 0.0
    end
    
    # 4. Update Final Mortgage Rate
    # Rate = Base + Spread
    # Use Central Bank's live base rate (Source of Truth), not local copy
    bank.current_mortgage_rate = model.central_bank.base_rate + bank.current_spread
    
    # 5. Rotate Counters
    # Store current as previous for next step
    bank.previous_credit_supply = bank.current_credit_supply
    # Reset counter for the new month
    bank.current_credit_supply = 0.0
end


