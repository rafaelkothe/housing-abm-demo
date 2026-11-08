import argparse
import os
import pandas as pd
import numpy as np
import statsmodels.api as sm
from scipy.fftpack import fft

# ============================================================================
# CONFIGURATION BLOCK
# ============================================================================
BASE_DIR = os.path.dirname(os.path.abspath(__file__)) if '__file__' in locals() else '.'
MODEL_FILE_PATH = os.path.join(BASE_DIR, "E1_Baseline_model_data.csv")

# Discard steps <= 2000 to match get_burn_in() fallback in Julia script
BURN_IN_STEPS = 2000 

# ============================================================================
# METHODOLOGY: FFT CYCLE PERIOD ESTIMATION (SAME METHOD AS THE JULIA CODE)
# ============================================================================
def estimate_cycle_period_julia(series):
    """
    Python implementation matching the Julia estimate_cycle_period(series) function.
    Evaluates frequencies for an independent run without pre-filtering.
    """
    series_f = np.array(series, dtype=float)
    n = len(series_f)
    if n < 50:
        return np.nan

    half_n = n // 2
    if half_n < 2:
        return np.nan

    # Julia FFTW.fft returns n values. 2:div(n,2) maps to 1:half_n in Python
    fft_vals = fft(series_f)
    magnitudes = (1.0 / n) * np.abs(fft_vals[1:half_n])

    # Reconstruct frequency domain spacing: k / (n - 1)
    frequency_domain = np.array([k / (n - 1) for k in range(1, half_n)])

    if len(magnitudes) == 0:
        return np.nan
        
    k_max = np.argmax(magnitudes)
    return 1.0 / frequency_domain[k_max]

# ============================================================================
# ENSEMBLE AGGREGATION HELPERS
# ============================================================================
def per_run_mean(df, metric_func):
    """Group data by run_id, compute metric per run, return mean and std of metric."""
    grouped = df.groupby('run_id') if 'run_id' in df.columns else [('all', df)]
    vals = []
    for _, g in grouped:
        v = metric_func(g)
        if np.isfinite(v):
            vals.append(v)
    if not vals:
        return np.nan, np.nan
    return np.mean(vals), np.std(vals)

def per_run_ensemble_quantile(df, target_col, p):
    """Computes the specified quantile within each run, then returns the ensemble average."""
    grouped = df.groupby('run_id') if 'run_id' in df.columns else [('all', df)]
    qvals = []
    for _, g in grouped:
        vals = g[target_col].dropna().values
        if len(vals) > 0:
            qvals.append(np.percentile(vals, p * 100))
    if not qvals:
        return np.nan
    return np.mean(qvals)

# ============================================================================
# MAIN ANALYSIS ENTRY POINT
# ============================================================================
def parse_args():
    parser = argparse.ArgumentParser(description="Summary moments of a simulated model_data file")
    parser.add_argument("--model-file", default=MODEL_FILE_PATH,
                        help="Path to a *_model_data.csv file (default: %(default)s)")
    parser.add_argument("--burn-in", type=int, default=BURN_IN_STEPS,
                        help="Discard rows with step <= this value (default: %(default)s)")
    return parser.parse_args()


def main():
    args = parse_args()
    print("=" * 80)
    print("SIMULATED MOMENTS")
    print("=" * 80)
    
    if not os.path.exists(args.model_file):
        print(f"[Error] Missing model data file: {args.model_file}")
        return

    # Load simulated records
    df = pd.read_csv(args.model_file)
    
    # Filter using your strict steady-state timeline constraint (> 2000 steps)
    df_clean = df[df['step'] > args.burn_in].copy()
    print(f"[Data Loaded] Raw records: {len(df)} | Clean steady-state records: {len(df_clean)}")

    if df_clean.empty:
        print(f"[Error] No records left after applying the {args.burn_in}-step burn-in filter.")
        return

    # --- SECTION 1: PRICE & CYCLE MOMENTS (SLIDE 1) ---
    print("\n--- TABLE 1 MOMENTS (ENSEMBLE AVERAGES ACROSS MONTE CARLO RUNS) ---")

    # 1. HPI Level Statistics (True endogenous emergent values, no forced 1.000 rebasing)
    hpi_mean_val, _ = per_run_mean(df_clean, lambda g: np.mean(g['hpi']))
    hpi_std_val, _  = per_run_mean(df_clean, lambda g: np.std(g['hpi'], ddof=1)) # matches calc_hpi_std raw track
    hpi_p25_val     = per_run_ensemble_quantile(df_clean, 'hpi', 0.25)
    hpi_p75_val     = per_run_ensemble_quantile(df_clean, 'hpi', 0.75)
    
    # 2. HPI Cyclical Volatility (Isolated via HP Filter per run)
    def calc_hp_vol(g):
        vals = g['hpi'].dropna().values
        if len(vals) < 3: return np.nan
        # Rebase individual run for HP input stability if necessary
        vals_norm = vals / np.mean(vals)
        cycle, _ = sm.tsa.filters.hpfilter(vals_norm, lamb=129600)
        return np.std(cycle, ddof=1)
        
    hpi_hp_vol, _ = per_run_mean(df_clean, calc_hp_vol)
    hpi_cycle_len, _ = per_run_mean(df_clean, lambda g: estimate_cycle_period_julia(g['hpi']))

    # 3. RPI Level Statistics
    rpi_mean_val, _ = per_run_mean(df_clean, lambda g: np.mean(g['rpi']))
    rpi_std_val, _  = per_run_mean(df_clean, lambda g: np.std(g['rpi'], ddof=1))
    rpi_p25_val     = per_run_ensemble_quantile(df_clean, 'rpi', 0.25)
    rpi_p75_val     = per_run_ensemble_quantile(df_clean, 'rpi', 0.75)

    # 4. Gross Rental Yield Mapping
    # Resolves flow_yield preference falling back to stock yield (avg_yield)
    yield_col = 'flow_yield' if 'flow_yield' in df_clean.columns else 'avg_yield'
    yield_mean_val, _ = per_run_mean(df_clean, lambda g: np.mean(g[yield_col]))

    print(f"HPI Emergent Mean          : {hpi_mean_val:.4f}")
    print(f"HPI Raw Standard Deviation : {hpi_std_val:.4f}")
    print(f"HPI 25th Percentile (p25)  : {hpi_p25_val:.4f}")
    print(f"HPI 75th Percentile (p75)  : {hpi_p75_val:.4f}")
    print(f"HPI Cyclical Volatility    : {hpi_hp_vol:.4f}")
    print(f"HPI Dominant Cycle Period  : {hpi_cycle_len:.2f} months")
    print(f"RPI Emergent Mean          : {rpi_mean_val:.4f}")
    print(f"RPI Raw Standard Deviation : {rpi_std_val:.4f}")
    print(f"RPI 25th Percentile (p25)  : {rpi_p25_val:.4f}")
    print(f"RPI 75th Percentile (p75)  : {rpi_p75_val:.4f}")
    print(f"Mean Gross Rental Yield    : {yield_mean_val * 100:.2f}%" if yield_mean_val < 1.0 else f"{yield_mean_val:.2f}%")

    # --- SECTION 2: STRUCTURAL TENURE SHARES (SLIDE 2) ---
    print("\n--- TABLE 2 MOMENTS (STRUCTURAL ENSEMBLE COHORT SHARES) ---")
    
    own_share, _  = per_run_mean(df_clean, lambda g: np.mean(g['owner_occupier_share']))
    rent_share, _ = per_run_mean(df_clean, lambda g: np.mean(g['private_renting_share']))
    btl_share, _  = per_run_mean(df_clean, lambda g: np.mean(g['investor_share']))

    print(f"Share of Households Owning    : {own_share * 100:.2f}%" if own_share <= 1.0 else f"{own_share:.2f}%")
    print(f"Share of Households Renting   : {rent_share * 100:.2f}%" if rent_share <= 1.0 else f"{rent_share:.2f}%")
    print(f"Share of Active BTL Investors : {btl_share * 100:.2f}%" if btl_share <= 1.0 else f"{btl_share:.2f}%")
    print("=" * 80)

if __name__ == "__main__":
    main()