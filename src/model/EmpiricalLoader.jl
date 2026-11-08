# src/model/EmpiricalLoader.jl

using CSV
using DataFrames
using Distributions
using Random: AbstractRNG

# -------------------------------------------------------------------------
# LOADING FUNCTIONS
# -------------------------------------------------------------------------

"""
    load_demographics(path::String)
Loads age distribution data and applies a monthly smoothing transformation to match the Java implementation.
Reference: `src/legacy_codebase/java/data/Demographics.java` (Method: `transformAgeDistributionToMonthly`)

The Java model does not use the raw 10-year bins directly for agent creation. Instead, it:
1. Calculates the probability density at the center of each raw bin.
2. Linearly interpolates the density between these centers (Piecewise Linear).
3. Resamples this continuous density into ~900 monthly bins (0 to ~85 years).
This results in a "smooth" age distribution rather than a "blocky" histogram.
"""
function load_demographics(path::String)
    # 1. Load Raw Data
    df = CSV.read(path, DataFrame; comment="#", header=false)
    # Headers: Age (lower edge), Age (upper edge), Probability
    
    # Extract raw columns
    raw_probs = Float64.(df[!, 3])
    # Normalize probabilities to ensure sum is exactly 1.0 (Java `BinnedDataDouble` behavior)
    probs = raw_probs ./ sum(raw_probs)
    cdf = cumsum(probs)
    
    # Store raw bins info (Lower, Upper) used for the coarse structure
    raw_bins = Tuple{Int, Int}[(r[1], r[2]) for r in eachrow(df)]
    upper_bounds = Float64.(df[!, 2])
    
    # -------------------------------------------------------------------------
    # JAVA PARITY: Monthly Smoothing Transformation
    # -------------------------------------------------------------------------
    # Replicates `data.Demographics.transformAgeDistributionToMonthly`
    
    # A. Setup Original Bins
    min_age = Float64(raw_bins[1][1])
    max_age = Float64(raw_bins[end][2])
    n_original_bins = length(probs)
    # Java assumes uniform bin width for the input data in this transformation
    original_bin_width = Float64(raw_bins[1][2] - raw_bins[1][1])
    
    # B. Compute Density at Bin Centers
    # Java: density = probability / width
    original_densities = probs ./ original_bin_width
    
    # Calculate geometric centers of the original coarse bins
    original_centers = [min_age + original_bin_width/2.0 + (i-1)*original_bin_width for i in 1:n_original_bins]
    
    # C. Compute Slopes and Intercepts (Linear Interpolation)
    # Java: `computeSlopesAndIntercepts`
    # We define the line segment between Center(i-1) and Center(i)
    slopes = zeros(Float64, n_original_bins + 1)
    intercepts = zeros(Float64, n_original_bins + 1)
    
    # Iterate through the intervals between bin centers
    for i in 2:n_original_bins
        x1 = original_centers[i-1]
        y1 = original_densities[i-1]
        x2 = original_centers[i]
        y2 = original_densities[i]
        
        # Linear equation: y = mx + c
        m = (y2 - y1) / (x2 - x1)
        c = y1 - m * x1
        
        slopes[i] = m
        intercepts[i] = c
    end
    
    # Extrapolate Edges (Constant slope from nearest segment)
    # Left Tail: Extend the monthly bins before the first center using the first computed slope
    slopes[1] = slopes[2]
    intercepts[1] = intercepts[2]
    
    # Right Tail: Extend the monthly bins after the last center using the last computed slope
    slopes[end] = slopes[end-1]
    intercepts[end] = intercepts[end-1]
    
    # D. Generate Monthly Bins
    # Java constants: MONTHS_IN_YEAR = 12
    months_in_year = 12.0
    monthly_bin_width = 1.0 / months_in_year
    n_monthly_bins = Int(round((max_age - min_age) * months_in_year))
    
    monthly_probs = zeros(Float64, n_monthly_bins)
    
    # Sample the interpolated density at the center of each monthly bin
    for j in 1:n_monthly_bins
        # Bin j corresponds to interval [min + (j-1)*w, min + j*w]
        center = min_age + monthly_bin_width/2.0 + (j-1)*monthly_bin_width
        
        # Find which linear segment this month falls into
        # Java: `computeWhichBin`
        segment_idx = 1
        if center < original_centers[1]
            segment_idx = 1
        elseif center >= original_centers[end]
            segment_idx = n_original_bins + 1 
        else
            # Find i such that center is between original_centers[i] and original_centers[i+1]
            # `searchsortedlast` returns index <= x, so it gives us the left bracket `i`
            # The segment connecting i and i+1 is stored at index i+1 in match with loop above
            idx = searchsortedlast(original_centers, center)
            segment_idx = idx + 1
        end
        
        # Calculate interpolated density
        d = slopes[segment_idx] * center + intercepts[segment_idx]
        monthly_probs[j] = max(0.0, d) # Clamp to zero to avoid negative probability
    end
    
    # E. Renormalize
    # Convert Density -> Probability Mass (Mass = Density * Width)
    monthly_masses = monthly_probs .* monthly_bin_width
    
    # Ensure sum equals exactly 1.0
    final_monthly_probs = monthly_masses ./ sum(monthly_masses)
    
    # NOTE: expected_per_bin will be computed at model initialization in Initialization.jl
    # after TARGET_POPULATION is known. We pass an empty vector here as a placeholder.
    return DemographicsData(upper_bounds, cdf, raw_bins, final_monthly_probs, monthly_bin_width, Int[])
end

# ─────────────────────────────────────────────────────────────────────────────

"""
    build_java_inverse_cdf(lows, highs, probs; n_samples=100, integration_steps=2048,
                           skip_zero_tails=false)

Replicates Java `Pdf.initInverseCDF()` (utilities/Pdf.java:107–140).
Builds an `n_samples`-point (default 100) lookup table by numerically integrating the
piecewise-uniform PDF over `integration_steps` (default 2048) sub-steps.

  `inv_cdf[n_samples]` is hard-pinned to the UPPER EDGE OF THE LAST CSV BIN
  (`getSupportUpperBound()`), regardless of whether that bin has non-zero probability.
  For distributions with zero-probability tail bins (wealth CSV: last 5–6 bins per
  income group are zero), this extrapolates the inverse CDF linearly from the true
  support maximum out to `end_val`, inflating extreme-percentile draws by up to 37×.
  Example: wealth p=0.999 low-income cohort → £162,701 (Julia exact) vs £6,047,194 (Java).

  * Spain uses `nSamples = 100_000`, `INTEGRATION_STEPS = 262_144` (vs UK 100 / 2048).
  * Spain adds `getStart()` / `getEnd()` helpers that skip leading/trailing zero-prob
    bins when locating the support edges — this REMOVES the phantom-tail artefact.
  When `skip_zero_tails=true` (mechanism `:spain_pdf_precision`), this routine uses
  the first lower-bound with `probs[i] > 0` as `start_val` and the last upper-bound
  with `probs[i] > 0` as `end_val`.
"""
function build_java_inverse_cdf(lows::Vector{Float64}, highs::Vector{Float64},
                                probs::Vector{Float64};
                                n_samples::Int=100, integration_steps::Int=2048,
                                skip_zero_tails::Bool=false)
    total     = sum(probs)
    norm_probs = total > 0.0 ? probs ./ total : probs
    if skip_zero_tails
        # Spain Pdf.java::getStart / getEnd — skip leading/trailing zero-prob bins.
        first_nz = findfirst(>(0.0), norm_probs)
        last_nz  = findlast(>(0.0),  norm_probs)
        if first_nz === nothing || last_nz === nothing
            start_val = lows[1]
            end_val   = highs[end]
        else
            start_val = lows[first_nz]
            end_val   = highs[last_nz]
        end
    else
        start_val = lows[1]
        end_val   = highs[end]   # Java UK: getSupportUpperBound() — last bin edge, not last non-zero edge
    end

    function density(x::Float64)
        for i in 1:length(lows)
            if x >= lows[i] && x < highs[i]
                bw = highs[i] - lows[i]
                return bw > 0.0 ? norm_probs[i] / bw : 0.0
            end
        end
        return 0.0
    end

    dx      = (end_val - start_val) / integration_steps
    inv_cdf = zeros(Float64, n_samples)
    inv_cdf[1]         = start_val
    inv_cdf[n_samples] = end_val      # Java hard-pin (Pdf.java:121)
    x   = start_val + dx / 2.0
    cp  = 0.0
    dcp = 0.0
    for i in 2:(n_samples - 1)
        target_cp = (i - 1) / (n_samples - 1.0)
        while cp < target_cp && x < end_val
            dcp  = density(x)
            cp  += dcp * dx
            x   += dx
        end
        if x < end_val
            x  += (target_cp - cp) / max(dcp, 1e-15)
            cp  = target_cp
        else
            x = end_val
        end
        inv_cdf[i] = x
    end
    return inv_cdf
end

"""
    java_inverse_cdf_lookup(p, inv_cdf)

Replicates Java `Pdf.inverseCumulativeProbability(p)` (Pdf.java:93–99).
Linear interpolation on a pre-computed 100-point table.
"""
function java_inverse_cdf_lookup(p::Float64, inv_cdf::Vector{Float64})
    n = length(inv_cdf)
    # floor matches Java's (int) cast; +1 for 1-based Julia indexing
    i         = clamp(Int(floor(p * (n - 1))) + 1, 1, n - 1)
    remainder = p * (n - 1) - (i - 1)
    return (1.0 - remainder) * inv_cdf[i] + remainder * inv_cdf[i + 1]
end

# ─────────────────────────────────────────────────────────────────────────────
function load_income_distribution(path::String; spain_pdf_precision::Bool=false)
    df = CSV.read(path, DataFrame; comment="#", header=false)
    # Headers: Age (lower), Age (upper), LogGross(lower), LogGross(upper), Prob
    
    # We need to group by Age Bin to create conditional distributions
    # Unique age bins
    unique_ages = unique(df[!, 1:2])
    
    cdf_dict          = Dict{Int, Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}}}()
    java_inv_cdf_dict = Dict{Int, Vector{Float64}}()  # [D7] Java 100-pt inverse CDF tables

    for (i, age_row) in enumerate(eachrow(unique_ages))
        age_l, age_u = age_row[1], age_row[2]
        
        # Filter for this age bin
        sub_df = filter(row -> row[1] == age_l && row[2] == age_u, df)
        
        # Sort by lower bound of income to ensure correct cumulative sum
        sort!(sub_df, 3) # Sort by LogGross(lower)

        # Apply trimming to mimic original Python preprocessing (removing top 1% and bottom 1%)
        # Note: Original code filtered on raw data, here we filter the histogram bins.
        # We assume the "Probability" column reflects the frequency in that bin.
        
        # Calculate raw cumulative sum
        raw_probs = sub_df[!, 5]
        total_prob = sum(raw_probs)
        
        # The CSV is used as-is without discarding tails, as in the Java code.
        
        # Normalize probs
        if total_prob > 0
            probs = raw_probs ./ total_prob
        else
            probs = raw_probs # Should be empty or zeros
        end

        cdf = cumsum(probs)
        
        # Store Log Income Bins
        lower_bounds = Float64.(sub_df[!, 3])
        upper_bounds = Float64.(sub_df[!, 4])
        
        cdf_dict[i] = (lower_bounds, upper_bounds, cdf)
        java_inv_cdf_dict[i] = spain_pdf_precision ?
            build_java_inverse_cdf(lower_bounds, upper_bounds, Float64.(raw_probs);
                n_samples=100_000, integration_steps=262_144, skip_zero_tails=true) :
            build_java_inverse_cdf(lower_bounds, upper_bounds, Float64.(raw_probs))
    end
    
    # Store the age structure to map Agent Age -> Age Bin Index
    return IncomeData(unique_ages[!, 1], unique_ages[!, 2], cdf_dict, java_inv_cdf_dict)
end

function load_wealth_distribution(path::String; spain_pdf_precision::Bool=false)
    df = CSV.read(path, DataFrame; comment="#", header=false)
    # Headers: LogGross(lower), LogGross(upper), LogWealth(lower), LogWealth(upper), Prob
    
    # The authors' script filters to keep W > 0, so Log W can be calculated.
    
    unique_incomes = unique(df[!, 1:2])
    
    cdf_dict                  = Dict{Int, Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}}}()
    wealth_java_inv_cdf_dict  = Dict{Int, Vector{Float64}}()  # [D7] Java 100-pt inverse CDF tables

    for (i, inc_row) in enumerate(eachrow(unique_incomes))
        inc_l, inc_u = inc_row[1], inc_row[2]
        
        # Filter for this income bin
        sub_df = filter(row -> row[1] == inc_l && row[2] == inc_u, df)
        
        # Sort by lower bound of wealth
        sort!(sub_df, 3) 

        # --- TRIM LOGIC for Wealth ---
        # The authors' script filters out zeros/negatives when modifying the raw data.
        
        raw_probs = Float64.(sub_df[!, 5])
        probs     = sum(raw_probs) > 0 ? raw_probs ./ sum(raw_probs) : raw_probs
        cdf = cumsum(probs)
        
        lower_bounds = Float64.(sub_df[!, 3])
        upper_bounds = Float64.(sub_df[!, 4])
        
        cdf_dict[i] = (lower_bounds, upper_bounds, cdf)
        wealth_java_inv_cdf_dict[i] = spain_pdf_precision ?
            build_java_inverse_cdf(lower_bounds, upper_bounds, raw_probs;
                n_samples=100_000, integration_steps=262_144, skip_zero_tails=true) :
            build_java_inverse_cdf(lower_bounds, upper_bounds, raw_probs)
    end
    
    return WealthData(unique_incomes[!, 1], unique_incomes[!, 2], cdf_dict, wealth_java_inv_cdf_dict)
end

function load_btl_distribution(path::String)
    df = CSV.read(path, DataFrame; comment="#", header=false)
    # Headers: Pctl_Low, Pctl_High, Probability
    bin_lowers = Float64.(df[!, 1])
    bin_uppers = Float64.(df[!, 2])
    probs = Float64.(df[!, 3])
    return BTLData(probs, bin_lowers, bin_uppers)
end

function load_markup_distribution(path::String; spain_pdf_precision::Bool=false)
    df = CSV.read(path, DataFrame; comment="#", header=false)
    # Headers: Markup_Low, Markup_High, Probability
    lower = Float64.(df[!, 1])
    upper = Float64.(df[!, 2])
    probs = Float64.(df[!, 3])
    java_inv_cdf = spain_pdf_precision ?
        build_java_inverse_cdf(lower, upper, probs;
            n_samples=100_000, integration_steps=262_144, skip_zero_tails=true) :
        build_java_inverse_cdf(lower, upper, probs)
    return MarkupData(lower, upper, probs, java_inv_cdf)
end

# -------------------------------------------------------------------------
# SAMPLING FUNCTIONS
# -------------------------------------------------------------------------

"""
    sample_age(rng, demo_data::DemographicsData)
Returns a specific age sampled from the distribution.
"""
function sample_age(rng::AbstractRNG, data::DemographicsData)
    r = rand(rng)
    
    # Find bin where CDF_prev < r <= CDF_i
    # searchsortedfirst returns the index of the first element >= r
    idx = searchsortedfirst(data.age_probs, r)
    
    # Safety Check
    if idx > length(data.age_probs)
        idx = length(data.age_probs)
    end
    
    # Uniform Smoothing within the bin
    (bin_low, bin_high) = data.raw_bins[idx]
    
    # Sample continuous value uniformly: [Low, High)
    return bin_low + rand(rng) * (bin_high - bin_low)
end

"""
    sample_age_in_bin(rng, bin_idx::Int, data::DemographicsData)
Returns a specific age strictly within the specified bin index.
Used for Structural Births (Targeted Replenishment).
"""
function sample_age_in_bin(rng::AbstractRNG, bin_idx::Int, data::DemographicsData)
    # Validation
    if bin_idx < 1 || bin_idx > length(data.raw_bins)
        bin_idx = 1 # Fallback
    end

    (bin_low, bin_high) = data.raw_bins[bin_idx]
    
    # Sample continuous value uniformly: [Low, High)
    return bin_low + rand(rng) * (bin_high - bin_low)
end

"""
    sample_income(rng, age, inc_data::IncomeData)
Returns Gross Income (Annual).
Phase 2A: Conditional on Age.

# DEPRECATED — do not call.
# Replaced by `calculate_income_from_rank`, which performs exact analytical inverse-CDF
# sampling directly on the full empirical CDF vector. This function consumes two `rand(rng)`
# calls per invocation and performs an unconstrained stochastic intra-bin draw, replicating
# the distributional blurring of the Java 100-point quantile table and corrupting the RNG
# sequence relative to the canonical D1/D2 draw order established in `create_new_household!`.
"""
function sample_income(rng::AbstractRNG, age::Float64, data::IncomeData)
    # 1. Find the Age Bin index for this agent
    # We iterate through the bins structure
    bin_idx = 0
    age_int = floor(Int, age)
    
    for i in 1:length(data.age_lower)
        if age_int >= data.age_lower[i] && age_int <= data.age_upper[i]
            bin_idx = i
            break
        end
    end
    
    if bin_idx == 0
        bin_idx = 1 
    end
    
    (lows, highs, cdf) = data.income_cdf_by_age[bin_idx]
    
    # 2. Sample Log Income Bin
    r = rand(rng)
    idx = searchsortedfirst(cdf, r)
    if idx > length(cdf); idx = length(cdf); end
    
    # 3. Log-Linear Transformation
    l_bound = lows[idx]
    u_bound = highs[idx]
    
    # Draw uniform value v between LogBounds
    v = l_bound + rand(rng) * (u_bound - l_bound)
    
    # Convert back to monetary value and apply scaling
    return exp(v)
end

"""
    get_income_percentile(age, annual_income, data::IncomeData)
Reverse lookup: Given an income val, find its percentile rank within the age cohort.
Used to correlate BTL status for new agents.
"""
function get_income_percentile(age::Float64, annual_income::Float64, data::IncomeData)
    # 1. Find Age Bin
    bin_idx = 0
    age_int = floor(Int, age)
    
    for i in 1:length(data.age_lower)
        if age_int >= data.age_lower[i] && age_int <= data.age_upper[i]
            bin_idx = i
            break
        end
    end
    
    if bin_idx == 0; bin_idx = 1; end
    
    (lows, highs, cdf) = data.income_cdf_by_age[bin_idx]
    
    log_val = log(max(annual_income, 1.0))
    
    # 2. Find Income Bin
    # We need to find i such that low[i] <= log_val < high[i]
    # Since bin searching is fast, we can loop or binary search.
    # Arrays are sorted.
    
    idx = 0
    for i in 1:length(lows)
        if log_val >= lows[i] && log_val < highs[i]
            idx = i
            break
        end
    end
    
    # Handle Out of Bounds
    if idx == 0
        if log_val < lows[1]
             return 0.0 # Poorest
        else
             return 1.0 # Richest
        end
    end
    
    # 3. Interpolate
    l_bound = lows[idx]
    u_bound = highs[idx]
    
    fraction = (log_val - l_bound) / (u_bound - l_bound)
    fraction = clamp(fraction, 0.0, 1.0)
    
    prob_curr = cdf[idx]
    prob_prev = idx > 1 ? cdf[idx-1] : 0.0
    
    percentile = prob_prev + fraction * (prob_curr - prob_prev)
    return percentile
end

"""
    calculate_income_from_rank(age, percentile, data::IncomeData)
Deterministically calculates Gross Annual Income based on Age and Income Percentile.
This implements the Inverse CDF method required by Carro et al. (2022).

# Difference from the Java implementation:
# Java (utilities.Pdf): 100-point numerical inverse-CDF table (2048-step integration, DEFAULT_CDF_SAMPLES=100).
#   Body p∈[1%,99%]: ≤0.016% divergence. Tail p=0.999: ≤2.74% (income CSV has no zero-prob tail bins).
#   Toggle: JAVA_COMPAT_MODE = true → uses pre-computed 100-pt table via java_inverse_cdf_lookup.
# Julia (default): exact linear interpolation on empirical bin CDF — no truncation artefact.
"""
function calculate_income_from_rank(age::Real, percentile::Float64, data::IncomeData;
                                    spain_essential_nominal_consumption::Bool=false)
    # 1. Find the Age Bin index (Java: getBinAt logic)
    # The bins are continuous ranges [lower, upper).
    bin_idx = 0
    for i in 1:length(data.age_lower)
        # Check if age falls strictly within the bin range
        # Note: Java is strictly < upper bound for intermediate bins, but handles boundaries carefully
        if age >= data.age_lower[i] && age < data.age_upper[i]
            bin_idx = i
            break
        end
    end
    
    # Validation/Fallback (Java: clamps to bounds)
    if bin_idx == 0
        if age >= data.age_upper[end]
             # Java: boundAge = supportUpperBound - 1e-7;
            bin_idx = length(data.age_lower)
        elseif age < data.age_lower[1]
             # Java: boundAge = supportLowerBound;
            bin_idx = 1
        end
    end
    
    (lows, highs, cdf) = data.income_cdf_by_age[bin_idx]

    local log_val::Float64
    if Config.D7_INCOME_COMPAT
        # Java path: Pdf.inverseCumulativeProbability — linear interp on 100-pt table (Pdf.java:93-99).
        # Max divergence from exact: ≤0.016% (p∈[1%,99%]); ≤2.74% (p=0.999).
        # Toggle: D7_INCOME_COMPAT (granular).
        log_val = java_inverse_cdf_lookup(percentile, data.income_java_inv_cdf_by_age[bin_idx])
    else
        # Julia exact path: direct inverse-CDF on empirical bin probabilities.
        idx       = searchsortedfirst(cdf, percentile)
        if idx > length(cdf); idx = length(cdf); end
        prob_curr = cdf[idx]
        prob_prev = idx > 1 ? cdf[idx-1] : 0.0
        denom     = prob_curr - prob_prev
        fraction  = denom > 1e-9 ? clamp((percentile - prob_prev) / denom, 0.0, 1.0) : 0.5
        log_val   = lows[idx] + fraction * (highs[idx] - lows[idx])
    end

    gross_income = exp(log_val)
    # UK Java imposes no explicit ENC*12 floor here; instead Julia
    # applied `MINIMUM_GOVT_SUPPORT*12` as a defensive floor. Spain Java
    # `EmploymentIncome.java#L119-120` swaps this for `ENC*12` (= 2400).
    # Symbol-gated; UK floor preserved when `:spain_essential_nominal_consumption`
    # is false. Note: the Spain floor (2400) is materially lower than the
    # legacy UK floor (~5349.60) so under Symbol ON some agents at p<0.01
    # may draw lower incomes than under UK semantics \u2014 this is the canonical
    # Spain envelope.
    if spain_essential_nominal_consumption
        min_income = Config.ESSENTIAL_NOMINAL_CONSUMPTION_SPAIN_VALUE * 12.0
    else
        min_income = Config.MINIMUM_GOVT_SUPPORT * 12.0
    end
    return max(gross_income, min_income)
end

"""
    calculate_wealth_from_rank(annual_income::Float64, percentile::Float64, data::WealthData)
Deterministically calculates Target Financial Wealth based on Gross Annual Income and Propensity to Save (Percentile).
This implements the Inverse CDF method required by Carro et al. (2022).

# Difference from the Java implementation:
# Java (utilities.Pdf): 100-point numerical inverse-CDF table. Critical tail hazard:
#   inverseCDF[100] hard-pinned to last bin edge (~log 16.1) even though CDF reaches 1.0
#   at ~log 12.0 for most income cohorts (5–6 zero-probability tail bins in wealth CSV).
#   Max divergence: ≤0.06% (p∈[1%,99%]); 30.1% at p=0.999 → up to 37× wealth inflation
#   (e.g. £162,701 exact → £6,047,194 Java for low-income cohort at p=0.999).
# Julia (default): exact — no extrapolation beyond actual non-zero support.
# TOGGLE: JAVA_COMPAT_MODE = true to replicate Java phantom-tail artefact.
"""
function calculate_wealth_from_rank(annual_income::Float64, percentile::Float64, data::WealthData)
    log_income = log(max(annual_income, 1.0)) # Avoid log(0) or negative
    
    # 1. Find the Income Bin index
    bin_idx = 0
    for i in 1:length(data.income_lower)
        if log_income >= data.income_lower[i] && log_income < data.income_upper[i]
            bin_idx = i
            break
        end
    end
    
    # Handle edge cases (e.g. extremely high income outside bins)
    if bin_idx == 0
        if log_income < data.income_lower[1]
            bin_idx = 1
        else
            bin_idx = length(data.income_lower)
        end
    end
    
    (lows, highs, cdf) = data.wealth_cdf_by_income[bin_idx]

    local log_val::Float64
    if Config.D7_WEALTH_COMPAT
        # Java path: 100-pt table lookup. Phantom-tail: extrapolates into zero-prob bins.
        # Max divergence: ≤0.06% (p∈[1%,99%]); 30.1% at p=0.999 (37× inflation at extremes).
        # Toggle: D7_WEALTH_COMPAT (granular) or JAVA_COMPAT_MODE (all-in-one).
        log_val = java_inverse_cdf_lookup(percentile, data.wealth_java_inv_cdf_by_income[bin_idx])
    else
        # Julia exact path: direct inverse-CDF on empirical bin probabilities.
        idx       = searchsortedfirst(cdf, percentile)
        if idx > length(cdf); idx = length(cdf); end
        prob_curr = cdf[idx]
        prob_prev = idx > 1 ? cdf[idx-1] : 0.0
        denom     = prob_curr - prob_prev
        fraction  = denom > 1e-9 ? clamp((percentile - prob_prev) / denom, 0.0, 1.0) : 0.5
        log_val   = lows[idx] + fraction * (highs[idx] - lows[idx])
    end

    return exp(log_val)
end

"""
    sample_financial_wealth(rng, income, wealth_data::WealthData)
Returns Net Financial Wealth.
Phase 2B: Conditional on Gross Income.

# DEPRECATED — do not call.
# Replaced by `calculate_wealth_from_rank`, which performs exact analytical inverse-CDF
# sampling directly on the full empirical CDF vector. This function ignores `propensity_to_save`
# entirely (breaking the empirical wealth-savings correlation), consumes two `rand(rng)` calls,
# and replicates the Java tail-truncation artifact. See Wealth.java:117 vs EmpiricalLoader.jl
# `calculate_wealth_from_rank` for the authoritative divergence record.
"""
function sample_financial_wealth(rng::AbstractRNG, income::Float64, data::WealthData)
    log_income = log(max(income, 1.0)) # Avoid log(0) or negative
    
    # 1. Find the Income Bin index
    bin_idx = 0
    # The wealth data bins are defined by Log Income edges
    for i in 1:length(data.income_lower)
        if log_income >= data.income_lower[i] && log_income < data.income_upper[i]
            bin_idx = i
            break
        end
    end
    
    # Handle edge cases (e.g. extremely high income outside bins)
    if bin_idx == 0
        if log_income < data.income_lower[1]
            bin_idx = 1
        else
            bin_idx = length(data.income_lower)
        end
    end
    
    (lows, highs, cdf) = data.wealth_cdf_by_income[bin_idx]
    
    # 2. Sample Log Wealth Bin
    r = rand(rng)
    idx = searchsortedfirst(cdf, r)
    if idx > length(cdf); idx = length(cdf); end
    
    # 3. Log-Linear Transformation
    l_bound = lows[idx]
    u_bound = highs[idx]
    
    v = l_bound + rand(rng) * (u_bound - l_bound)
    
    return exp(v)
end

"""
    assign_btl_flags!(rng, agents, btl_data::BTLData, adjustment_scalar::Float64)
This operates on the whole population of agents after income assignment.
"""
function assign_btl_flags!(rng::AbstractRNG, agents, btl_data::BTLData, adjustment_scalar::Float64=1.76)
    # 1. Sort agents by income to determine percentiles
    
    # `agents` must be an indexable collection (for example a Vector) of households.
    
    
    
    n = length(agents)
    
    # Create permutation
    sorted_indices = sortperm(collect(agents), by = x -> x.annual_income)
    
    for (rank, agent_idx) in enumerate(sorted_indices)
        # Percentile 0 to 1
        percentile = rank / n
        
        # 2. Lookup Raw Probability
        # The BTL data has 100 bins 0.0-0.01, ..., 0.99-1.0
        # Check actual size of data to avoid BoundsError
        max_idx = length(btl_data.probabilities)
        
        bin_idx = Int(ceil(percentile * 100))
        if bin_idx <= 0; bin_idx = 1; end
        if bin_idx > max_idx; bin_idx = max_idx; end
        
        raw_prob = btl_data.probabilities[bin_idx]
        
        # 3. Calibration Adjustment
        effective_prob = raw_prob * adjustment_scalar
        
        # 4. Assignment & Type Heterogeneity
        if rand(rng) < effective_prob
            # A. Assign BTL Status
            agents[agent_idx].is_btl_investor = true 
            
            # B. Assign Investor Type
            # Implements the 3-type heterogeneity required for Equation 7/10 yields.
            # Probabilities: [BTL_P_INCOME_DRIVEN, BTL_P_CAPITAL_DRIVEN, remainder]
            # Weights (delta): [0.1, 0.9, 0.5]
            
            type_roll = rand(rng)
            
            if type_roll < Config.BTL_P_INCOME_DRIVEN
                # Type 1: Rental-Income Driven (delta = 0.1)
                agents[agent_idx].btl_cap_gain_coeff = Config.BTL_INCOME_DRIVEN_CAP_GAIN_COEFF
                
            elseif type_roll < (Config.BTL_P_INCOME_DRIVEN + Config.BTL_P_CAPITAL_DRIVEN)
                # Type 2: Capital-Gains Driven (delta = 0.9)
                agents[agent_idx].btl_cap_gain_coeff = Config.BTL_CAPITAL_DRIVEN_CAP_GAIN_COEFF
                
            else
                # Type 3: Mixed (delta = 0.5)
                agents[agent_idx].btl_cap_gain_coeff = Config.BTL_MIX_DRIVEN_CAP_GAIN_COEFF
            end
            
        else
            agents[agent_idx].is_btl_investor = false 
            agents[agent_idx].btl_cap_gain_coeff = 0.0
        end
    end
end


"""
    sample_markup(rng, data::MarkupData)
Returns a level-space markup ratio ∈ [0.5, 2.0] (e.g. 1.03 = 3% above EMA).
This is exp(η_paper) from Eq 6/9 — multiply directly by p_Q or r_Q; no exponentiation needed.

# Difference from the Java implementation:
# Java (Pdf.nextDouble): exactly 1 rand() call → inverseCumulativeProbability(p) → 100-pt grid.
#   Max divergence: ≤0.81% (p∈[1%,99%]); ≤16.8–28.1% at tail percentiles (p≈0.001 or p≈0.999).
#   RNG draw count: Java = 1 draw. Julia exact path = 2 draws (bin selection + intra-bin uniform).
#   JAVA_COMPAT_MODE = true restores 1-draw parity AND the 100-pt table artefact.
"""
function sample_markup(rng::AbstractRNG, data::MarkupData)
    if Config.D7_MARKUP_COMPAT
        # Java path: Pdf.nextDouble — 1 rand() draw → 100-pt table lookup (Pdf.java:143-144).
        # Replicates HouseholdBehaviour.java:155 (saleMarkUpPdf) and :167 (rentMarkUpPdf).
        # Toggle: D7_MARKUP_COMPAT (granular, D7 sub-component) or JAVA_COMPAT_MODE (all-in-one).
        p = rand(rng)
        return java_inverse_cdf_lookup(p, data.java_inv_cdf)
    else
        # Julia exact path: 2 rand() draws — categorical bin selection + uniform intra-bin smoothing.
        r   = rand(rng) * sum(data.probs)
        cum = 0.0
        idx = length(data.probs)
        for i in 1:length(data.probs)
            cum += data.probs[i]
            if r <= cum
                idx = i
                break
            end
        end
        l_bound = data.markup_bins_lower[idx]
        u_bound = data.markup_bins_upper[idx]
        return l_bound + rand(rng) * (u_bound - l_bound)
    end
end
