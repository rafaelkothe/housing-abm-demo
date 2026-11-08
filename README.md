# Housing ABM: demonstration snapshot

> **Status.** This repository is a demonstration snapshot of the core of a Julia
> (Agents.jl) agent-based model of the housing market. It is published to show
> the code base, its architecture and its workflows. Model extensions used in
> ongoing research, research calibration data and research results are not
> included; the extensions and results are under revision. Outputs produced
> with this snapshot are illustrative only and are not research results.

## What this is

The model is a Julia port of the agent-based model of the UK housing market
developed at INET Oxford and the Bank of England (Baptista et al., 2016;
Carro et al., 2023) and of its Spanish adaptation (Carro, 2022). Both upstream
models are written in Java. This code base re-implements them as a modular
Julia package on [Agents.jl](https://juliadynamics.github.io/Agents.jl/),
with a Monte Carlo experiment framework and a Python script for summary
moments of simulated runs.

The port follows the upstream Java models closely; comments in the source
point to the corresponding Java classes and to the sections of the papers
where a mechanism is defined. Deliberate departures from the Java behaviour
are documented in the source; many of them can be switched with the `D*`
flags in `src/core/Config.jl`, which are set as environment variables.

## Model overview

One model step is one month. Each step runs, in order:

- **Demographics:** birth, ageing and death of households, with inheritance.
- **Household decisions:** consumption and saving, the rent-or-buy decision,
  bids and listings, and buy-to-let investment entry and exit.
- **Credit:** bank underwriting with loan-to-value (LTV), loan-to-income
  (LTI), debt-service-to-income (DSTI) and interest-cover (ICR) limits,
  separately for first-time buyers, home movers and buy-to-let investors.
- **Macroprudential policy:** central-bank hard limits and soft limits with
  quotas, which can be switched on at a chosen month.
- **Markets:** a sales market cleared by a multi-round double auction, and a
  rental market.
- **Institutions:** government (income tax and National Insurance) and a
  construction sector.
- **Data collection:** model-level time series, transactions and
  agent-level snapshots.

The UK and Spanish calibrations share one code path. The Spanish mechanisms
and data sets are selected by flags in the model configuration.

## Repository layout

```
src/
  Engine.jl                 module entry point (includes all components)
  core/                     configuration (Config.jl) and types (Types.jl)
  model/                    initialisation, scheduler, household behaviour,
                            financial flows, demographics, empirical loaders
  institutions/             bank, central bank, government, construction
  markets/                  sales market, rental market, market statistics
  analysis/                 data collectors
  post/                     post-processing of simulated moments
scripts/
  run_working_data.jl       Monte Carlo runner for a set of experiments
  run_experiment.sh         batch runner for series of runs ("waves")
data/
  uk/, spain/               input distributions from the upstream models
  euroarea/                 simulated_metrics.py (summary moments, no data)
```

## Installation

Julia 1.12 or later (tested with Julia 1.13.1; `Manifest.toml` was resolved
with Julia 1.12.3):

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Python 3 for the moments script:

```bash
pip install -r requirements.txt
```

## Running the model

`scripts/run_working_data.jl` runs the three policy experiments of
Carro et al. (2023): a baseline without regulatory limits (`E1_Baseline`), a
hard LTV cap of 0.85 for owner-occupiers (`E2_LTV_Shock`) and a soft LTI limit
of 3.35 (`E3_LTI_Shock`). Each experiment runs as several Monte Carlo
replications in parallel threads, and writes CSV output to the given
directory. A small run:

```bash
WD_EXPERIMENTS=E1_Baseline WD_N_MC_RUNS=2 WD_N_STEPS=1000 WD_RECORD_START=500 \
  julia --project=. --threads=2 scripts/run_working_data.jl "$PWD/output/demo"
```

| Variable          | Meaning                                          | Default |
|-------------------|--------------------------------------------------|---------|
| `WD_EXPERIMENTS`  | comma-separated experiment name prefixes, or `all` | `all` |
| `WD_N_HOUSEHOLDS` | number of households                             | 10,000  |
| `WD_N_STEPS`      | simulated months per replication                 | 10,000  |
| `WD_RECORD_START` | first recorded month (burn-in length)            | 2,000   |
| `WD_N_MC_RUNS`    | Monte Carlo replications per experiment          | 30      |

Further `WD_*` variables, read in the configuration section of
`scripts/run_working_data.jl`, override individual policy and bank limits.
Each replication uses its run number as random seed, so runs are
reproducible.

For series of runs, `scripts/run_experiment.sh <WAVE>` reads
`experiments/<WAVE>/<WAVE>.env` (run settings) and
`experiments/<WAVE>/<WAVE>.conf` (one run configuration per line); the
`experiments/` folder is not included and is created by the user. The script
header documents the file format and the flags (`--smoke`, `--dry-run`,
`--resume`, ...).

## Python

```bash
python data/euroarea/simulated_metrics.py --model-file <output_dir>/E1_Baseline_model_data.csv
```

computes summary moments of the baseline run, such as house-price volatility
and the dominant cycle period (`--help` lists the options).

## Lineage, licence and data

- Upstream models: [INET-Complexity/housing-model](https://github.com/INET-Complexity/housing-model)
  (UK) and [adrian-carro/housing-model-spain](https://github.com/adrian-carro/housing-model-spain)
  (Spain), both under the MIT licence.
- This code base: MIT licence, see `LICENSE`. Copyright notices of the
  upstream authors are retained there.
- Input data in `data/uk` and `data/spain` are unchanged copies of the
  upstream input files; see `NOTICE.md` and `data/README.md`.

## References

- Baptista, R., Farmer, J. D., Hinterschweiger, M., Low, K., Tang, D. and
  Uluc, A. (2016). Macroprudential policy in an agent-based model of the UK
  housing market. Bank of England Staff Working Paper No. 619.
- Carro, A. (2022). Could Spain be less different? Exploring the effects of
  macroprudential policy on the house price cycle. Banco de España Working
  Paper No. 2230.
- Carro, A., Hinterschweiger, M., Uluc, A. and Farmer, J. D. (2023).
  Heterogeneous effects and spillovers of macroprudential policy in an
  agent-based model of the UK housing market. *Industrial and Corporate
  Change*, 32(2), 386–432. https://doi.org/10.1093/icc/dtac030

## Citation and contact

Citation metadata are in `CITATION.cff`. Please cite the upstream papers
above when using the model.

Rafael Kothe, rafael.kothe.econ@gmail.com
