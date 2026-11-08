# src/post/SpanishMoments.jl
#
# ============================================================================
#
# **Logic**
#   Pure post-processing pipeline for Spanish-calibration moment comparisons.
#   Reads finished simulation trajectories and computes two reference vectors:
#   the 9-moment TargetMoments.py vector and the 13-moment Calibrator.py vector
#   (output-calibration scripts of the upstream Spanish model).
#
#   Both use raw model HPI for its standard deviation and cycle period.
#   Their standard-deviation conventions, rental-yield inputs and spread
#   definitions differ; the vectors are therefore computed separately.
#
#   No behavioural feedback into the engine and no abmrng consumption.

# **Reference definitions**
#
#   TargetMoments.py:
#     • get_period → oecd_period(series).
#     • HP filtering applies to empirical HPI diagnostics.
#       Model HPI standard deviation and period use raw model HPI.
#     • target_moments_9 computes:
#       mean HPI, raw HPI standard deviation (denominator N), HPI period,
#       mean RPI, ownership share, renting share, BTL share,
#       mean flow rental yield, and mean mortgage rate minus a fixed baseline.
#
#   Calibrator.py:
#     • calibrator_moments_13 computes:
#       mean HPI, raw HPI standard deviation (denominator N−1), HPI period,
#       mean RPI, ownership share, renting share, BTL share,
#       transaction mean and standard deviation (denominator N),
#       price-to-income mean and standard deviation (denominator N),
#       mean stock rental yield (%) and mean actual bank spread (%).
#
#   N is the number of retained monthly observations within one run.
#
# **Methodology coexistence**
#
#   The reference model moments use raw HPI. HP filtering remains available
#   for separate diagnostics.
#
#
#   Do not replace raw model HPI with its HP cycle when computing either
#   reference vector.
#
# **RNG discipline**: all functions in this module are pure / idempotent
# (no `abmrng(model)` consumption; safe to invoke any number of times).
#
# **Returns**: see individual function docstrings.
# ============================================================================

module SpanishMoments

using FFTW
using LinearAlgebra
using SparseArrays
using Statistics

export hp_filter, oecd_period, target_moments_9, calibrator_moments_13,
       SpanishMomentVector, SPANISH_TARGET_LABELS_9, CALIBRATOR_TARGET_LABELS_13

# ----------------------------------------------------------------------------
# Hodrick-Prescott filter — available for separate trend/cycle diagnostics
# ----------------------------------------------------------------------------
"""
    hp_filter(y::AbstractVector, λ::Real=129_600.0) -> (trend, cycle)

Two-sided HP filter. Java/Python parity: `statsmodels.tsa.filters.hpfilter`.
Returns `(trend, cycle)` with `cycle = y - trend`. For series shorter than 3
samples, returns `(y, zero(y))`.


**Logic**
1. Build the second-difference matrix `D` (size `(n-2) × n`).
2. Solve `(I + λ·DᵀD) · trend = y` for the smoothed trend.
3. Cycle = y − trend.

**Conventions**

- λ=129,600: monthly smoothing convention; used for empirical HPI
  diagnostics in TargetMoments.py.
- λ=1,600: conventional quarterly smoothing parameter.
- λ=100,000: used by the separate Carro-style boom/bust classifier.

Neither reference moment function applies this filter to model HPI.

**Returns**
- `(Vector{Float64}, Vector{Float64})`: trend and cycle component, same length
  as `y`. Both are `Float64` regardless of input element type.
"""
function hp_filter(y::AbstractVector, λ::Real=129_600.0)
    n = length(y)
    if n < 3
        return Vector{Float64}(y), zeros(Float64, n)
    end
    D = spzeros(n - 2, n)
    @inbounds for i in 1:(n - 2)
        D[i, i]     =  1.0
        D[i, i + 1] = -2.0
        D[i, i + 2] =  1.0
    end
    A = I + λ * (D' * D)
    trend = Vector{Float64}(A \ Vector{Float64}(y))
    cycle = Vector{Float64}(y) .- trend
    return trend, cycle
end

# ----------------------------------------------------------------------------
# OECD HP+FFT cycle period (Spain TargetMoments.py::get_period)
# ----------------------------------------------------------------------------
"""
    oecd_period(series::AbstractVector) -> Float64

FFT-based dominant-period estimator following the frequency convention
in TargetMoments.py::get_period.

Operates directly on the supplied series. Both reference moment functions
pass raw model HPI. The empirical calculation in TargetMoments.py instead
uses its HP-filtered HPI cyclical component.

**Logic**
1. FFT magnitudes: `|FFT(y)[k]| / n` for `k = 1 .. n/2 − 1`.
2. Frequency axis: `freq[k] = k / (n − 1)` (numpy `linspace(0, 1, n)` spacing).
3. Dominant period = `1 / freq[argmax(magnitudes)] = (n − 1) / k_max`.

**Constraints**
- Returns `NaN` for series shorter than 50 samples (insufficient resolution).
- Idempotent / no RNG consumption.


**Returns**
- `Float64`: dominant period in sample intervals, or `NaN` when fewer
  than 50 observations are supplied. Monthly input gives a period in months.
"""
function oecd_period(series::AbstractVector)
    sf = Float64.(series)
    n = length(sf)
    n < 50 && return NaN
    half_n = div(n, 2)
    half_n < 2 && return NaN
    fft_vals   = FFTW.fft(sf)
    magnitudes = (1.0 / n) .* abs.(fft_vals[2:half_n])
    frequency_domain = [(k / (n - 1)) for k in 1:(half_n - 1)]
    k_max = argmax(magnitudes)
    return 1.0 / frequency_domain[k_max]
end

# ----------------------------------------------------------------------------
# Spanish 9-moment headline vector (TargetMoments.py L80-L100)
# ----------------------------------------------------------------------------
const SPANISH_TARGET_LABELS_9 = (
    :hpi_mean,
    :hpi_std_raw,
    :hpi_period,
    :rpi_mean,
    :share_owning,
    :share_renting,
    :share_btl,
    :rental_yield_mean,
    :spread_mean,
)

"""
    target_moments_9(; hpi, rpi, n_owner_occ, n_active_btl, n_renting,
                       total_population, rental_yield, interest_rate,
                       interest_rate_baseline=0.000102459)
        -> NamedTuple{SPANISH_TARGET_LABELS_9, NTuple{9, Float64}}

Computes the 9 Spanish headline moments (TargetMoments.py L80-L100).

**Inputs** (each a per-step series, same length, post-burn-in):
- `hpi`                  : Recorded sale HPI series. Preserve its original
                           index normalization; do not rebase to the first
                           retained post-burn-in observation.
- `rpi`                  : Recorded rental price index series.
- `n_owner_occ`          : Number of owner-occupiers per step.
- `n_active_btl`         : Number of active BTL investors per step.
- `n_renting`            : Number of renters per step.
- `total_population`     : Total population per step.
- `rental_yield`         : Flow rental yield from new rental contracts
                           (`flow_yield`), expressed as a fraction.
- `interest_rate`        : All-in mortgage interest rate, expressed as
                           a fraction.
- `interest_rate_baseline`: Fixed reference rate subtracted from the mean
                            mortgage rate. Must use the same units and
                            time basis as `interest_rate`.

**Logic**
1. `hpi_mean`          = `mean(hpi)`.
2. `hpi_std_raw`       = `std(hpi; corrected=false)`:
                        raw HPI standard deviation, denominator N.
3. `hpi_period`        = `oecd_period(hpi)`, using raw HPI.
4. `rpi_mean`          = `mean(rpi)`.
5. `share_owning`      = `mean((n_owner_occ .+ n_active_btl) ./ total_population)`.
6. `share_renting`     = `mean(n_renting ./ total_population)`.
7. `share_btl`         = `mean(n_active_btl ./ total_population)`.
8. `rental_yield_mean` = `mean(rental_yield)`, using flow rental yield.
9. `spread_mean`       = `mean(interest_rate) - interest_rate_baseline`.

The final statistic reproduces the reference script's fixed-baseline
subtraction. It does not generally equal the bank's actual spread.

**Returns**
- `NamedTuple{SPANISH_TARGET_LABELS_9, NTuple{9, Float64}}` — fixed-order
  9-tuple in the order of the calibration targets.
"""
function target_moments_9(; hpi::AbstractVector,
                            rpi::AbstractVector,
                            n_owner_occ::AbstractVector,
                            n_active_btl::AbstractVector,
                            n_renting::AbstractVector,
                            total_population::AbstractVector,
                            rental_yield::AbstractVector,
                            interest_rate::AbstractVector,
                            interest_rate_baseline::Real=0.000102459)
    hpi_f          = Float64.(hpi)
    rpi_f          = Float64.(rpi)
    pop_f          = Float64.(total_population)
    return NamedTuple{SPANISH_TARGET_LABELS_9}((
        mean(hpi_f),
        std(hpi_f; corrected=false),
        oecd_period(hpi_f),
        mean(rpi_f),
        mean((Float64.(n_owner_occ) .+ Float64.(n_active_btl)) ./ pop_f),
        mean(Float64.(n_renting) ./ pop_f),
        mean(Float64.(n_active_btl) ./ pop_f),
        mean(Float64.(rental_yield)),
        mean(Float64.(interest_rate)) - Float64(interest_rate_baseline),
    ))
end

# ----------------------------------------------------------------------------
# Calibrator 13-moment vector (Calibrator.py L117-L129)
# ----------------------------------------------------------------------------
const CALIBRATOR_TARGET_LABELS_13 = (
    :hpi_mean,
    :hpi_std_raw,
    :hpi_period,
    :rpi_mean,
    :share_owning,
    :share_renting,
    :share_btl,
    :housing_transactions_mean,
    :housing_transactions_std,
    :pti_mean,
    :pti_std,
    :rental_yield_mean_pct,
    :spread_mean_pct,
)

"""
    calibrator_moments_13(; hpi, rpi, n_owner_occ, n_active_btl,
                           n_renting, total_population,
                           stock_rental_yield, bank_spread,
                           housing_transactions, pti)
        -> NamedTuple{CALIBRATOR_TARGET_LABELS_13, NTuple{13, Float64}}

Computes the 13-moment Calibrator.py reference vector.

All inputs are monthly series from the same run, covering the same
post-burn-in observations. Preserve the recorded HPI normalization.

**Definitions**

- HPI mean, standard deviation and dominant period use raw model HPI.
- HPI standard deviation uses denominator N−1 (`corrected=true`).
- Transaction and price-to-income standard deviations use denominator N
  (`corrected=false`).
- Ownership, renting and BTL shares are averaged across monthly observations.
- `stock_rental_yield` is yield from existing occupied rental properties
  (`avg_yield`).
- `bank_spread` is the actual recorded bank spread (`mortgage_spread`).

**Units**

Yield and spread inputs must be fractions: 0.04 means 4%.
Outputs 12 and 13 multiply their respective means by 100, giving
`rental_yield_mean_pct` and `spread_mean_pct`.

This function computes its moments separately from `target_moments_9`
because their HPI standard-deviation conventions, rental-yield inputs
and spread definitions differ.

**Returns**

- NamedTuple containing 13 Float64 values in CALIBRATOR_TARGET_LABELS_13 order.
"""
function calibrator_moments_13(; hpi::AbstractVector,
                                 rpi::AbstractVector,
                                 n_owner_occ::AbstractVector,
                                 n_active_btl::AbstractVector,
                                 n_renting::AbstractVector,
                                 total_population::AbstractVector,
                                 rental_yield::AbstractVector,
                                 interest_rate::AbstractVector,
                                 housing_transactions::AbstractVector,
                                 pti::AbstractVector,
                                 interest_rate_baseline::Real=0.000102459)
    m9 = target_moments_9(; hpi=hpi, rpi=rpi, n_owner_occ=n_owner_occ,
                            n_active_btl=n_active_btl, n_renting=n_renting,
                            total_population=total_population,
                            rental_yield=rental_yield,
                            interest_rate=interest_rate,
                            interest_rate_baseline=interest_rate_baseline)
    txn_f = Float64.(housing_transactions)
    pti_f = Float64.(pti)
    return NamedTuple{CALIBRATOR_TARGET_LABELS_13}((
        m9.hpi_mean,
        m9.hpi_std_cyclical,
        m9.hpi_period,
        m9.rpi_mean,
        m9.share_owning,
        m9.share_renting,
        m9.share_btl,
        mean(txn_f),
        std(txn_f),
        mean(pti_f),
        std(pti_f),
        100.0 * m9.rental_yield_mean,        # convert fraction → %
        100.0 * m9.spread_mean,              # convert fraction → %
    ))
end

# ----------------------------------------------------------------------------
# Convenience type — pre-built moment-vector container for downstream callers
# ----------------------------------------------------------------------------
"""
    SpanishMomentVector

Container holding both reference moment vectors:
- `nine`: TargetMoments.py definitions.
- `thirteen`: Calibrator.py definitions.

The keyword constructor computes both vectors separately from monthly
series covering the same post-burn-in observations.

Required yield and rate inputs:
- `rental_yield`: flow rental yield (`flow_yield`).
- `stock_rental_yield`: stock rental yield (`avg_yield`).
- `interest_rate`: all-in mortgage interest rate.
- `bank_spread`: actual bank spread (`mortgage_spread`).
- `interest_rate_baseline`: fixed reference rate used only by the nine-vector.

All yield and rate inputs are fractions: 0.04 means 4%.
Mortgage rate and its baseline must use the same time basis.
"""
struct SpanishMomentVector
    nine::NamedTuple{SPANISH_TARGET_LABELS_9, NTuple{9, Float64}}
    thirteen::NamedTuple{CALIBRATOR_TARGET_LABELS_13, NTuple{13, Float64}}
end

function SpanishMomentVector(;
    hpi::AbstractVector,
    rpi::AbstractVector,
    n_owner_occ::AbstractVector,
    n_active_btl::AbstractVector,
    n_renting::AbstractVector,
    total_population::AbstractVector,
    rental_yield::AbstractVector,
    stock_rental_yield::AbstractVector,
    interest_rate::AbstractVector,
    bank_spread::AbstractVector,
    housing_transactions::AbstractVector,
    pti::AbstractVector,
    interest_rate_baseline::Real=0.000102459,
)
    common = (
        hpi=hpi,
        rpi=rpi,
        n_owner_occ=n_owner_occ,
        n_active_btl=n_active_btl,
        n_renting=n_renting,
        total_population=total_population,
    )

    nine = target_moments_9(;
        common...,
        rental_yield=rental_yield,
        interest_rate=interest_rate,
        interest_rate_baseline=interest_rate_baseline,
    )

    thirteen = calibrator_moments_13(;
        common...,
        stock_rental_yield=stock_rental_yield,
        bank_spread=bank_spread,
        housing_transactions=housing_transactions,
        pti=pti,
    )

    return SpanishMomentVector(nine, thirteen)
end

end # module SpanishMoments
