#!/usr/bin/env bash
# =============================================================================
# scripts/run_experiment.sh - Wave runner for the Monte Carlo simulation
# =============================================================================
# Purpose
# -------
# Drives a series of simulation cells ("a wave") through scripts/run_working_data.jl.
# A wave is defined by two text files that you create yourself:
#
#   experiments/<WAVE>/<WAVE>.env    Wave-level settings (MC, STEPS, ...)
#   experiments/<WAVE>/<WAVE>.conf   Cell matrix: one cell per line
#
# .env file (sourced by bash; every key is optional):
#   MC=15                  Monte Carlo replications per cell
#   STEPS=10000            Simulated months per replication
#   RECORD_START=2000      First recorded month (burn-in length)
#   THREADS=16             Julia threads (may be capped, see below)
#   MC_IN_PATH=false       If true, results go to output/<WAVE>/<CELL>/<MC>mc
#   BANK_LIMITS=config     "config" keeps the Config.jl bank limits; "off"
#                          relaxes the bank limits so that only the regulatory
#                          (WD_LIMIT_*) settings of a cell are binding
#
# .conf file: each non-blank line is
#   <CELL_TAG> KEY=VALUE KEY=VALUE ...   # optional note
# The KEY=VALUE pairs are exported as environment variables for that cell
# (typically WD_* variables read by scripts/run_working_data.jl).
#
# Phases:
#   0  Preflight         parse command line, validate files, resolve the plan
#   1  Campaign set-up   create directories, write the master log and manifest
#   2  Cell loop         export the cell's variables and run the Julia simulation
#   3  Finalise          print a summary
#
# Override order (innermost wins):
#   src/core/Config.jl  ->  wave .env  ->  cell .conf row  ->  command line
#
# Usage:
#   scripts/run_experiment.sh <WAVE> [flags]
# Flags:
#   --smoke              MC=1 STEPS=360 RECORD_START=200, written to <WAVE>_smoke
#   --cells "A0 P0..."   run only the listed cell tags
#   --mc N               override MC
#   --steps N            override STEPS
#   --threads N          override THREADS
#   --force-threads      do not cap the thread count from the CPU/memory limits
#   --resume             skip cells whose output directory already has run_config.csv
#   --dry-run            print the plan and exit
#   --bg                 detach: re-run in the background with nohup, logging to
#                        output/logs/, and print the PID and log path
#
# The runner never touches a random number generator. All randomness lives
# inside Julia; the runner only sets environment variables and launches it.
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."

# ----------------------------------------------------------------------------
# Phase 0 - Preflight
# ----------------------------------------------------------------------------
WAVE="${1:-}"
[[ -n "$WAVE" ]] || { echo "usage: scripts/run_experiment.sh <WAVE> [flags]" >&2; exit 2; }
shift || true

ENV_FILE="experiments/${WAVE}/${WAVE}.env"
CONF_FILE="experiments/${WAVE}/${WAVE}.conf"
[[ -f "$ENV_FILE"  ]] || { echo "ERROR: missing $ENV_FILE"  >&2; exit 2; }
[[ -f "$CONF_FILE" ]] || { echo "ERROR: missing $CONF_FILE" >&2; exit 2; }

# Wave defaults, set before sourcing the .env file so that it can override them.
MC=15
STEPS=10000
RECORD_START=2000
THREADS=16
MC_IN_PATH=false
# BANK_LIMITS: wave-level bank-layer profile.
#   "config" (default) - the bank limits keep their Config.jl defaults; cell rows
#                        must set WD_BANK_* explicitly to neutralise the bank layer.
#   "off"              - the runner injects relaxed bank limits for every cell, so
#                        .conf rows can set only the regulatory (WD_LIMIT_*) keys.
#                        A cell can still override any WD_BANK_* value explicitly.
BANK_LIMITS="config"

# shellcheck disable=SC1090
source "$ENV_FILE"

# Command-line overrides
SMOKE=0
DRY_RUN=0
RESUME=0
BG=0
FORCE_THREADS=0
CELL_FILTER=""
RAW_CLI_ARGS=("$@")  # kept for the --bg re-exec

while [[ $# -gt 0 ]]; do
    case "$1" in
        --smoke)         SMOKE=1; shift ;;
        --cells)         CELL_FILTER="$2"; shift 2 ;;
        --mc)            MC="$2"; shift 2 ;;
        --steps)         STEPS="$2"; shift 2 ;;
        --threads)       THREADS="$2"; shift 2 ;;
        --force-threads) FORCE_THREADS=1; shift ;;
        --resume)        RESUME=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --bg)            BG=1; shift ;;
        *) echo "ERROR: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

# --bg: detach with nohup-style redirection, then exit. The child re-runs the
# same command without --bg.
if [[ "$BG" -eq 1 ]]; then
    mkdir -p output/logs
    LOG="output/logs/${WAVE}_$(date +%Y%m%d_%H%M%S).log"
    REEXEC_ARGS=()
    for a in "${RAW_CLI_ARGS[@]}"; do [[ "$a" == "--bg" ]] || REEXEC_ARGS+=("$a"); done
    nohup bash "$0" "$WAVE" "${REEXEC_ARGS[@]}" > "$LOG" 2>&1 &
    CHILD_PID=$!
    disown "$CHILD_PID" 2>/dev/null || true
    echo "WAVE ${WAVE} launched in background"
    echo "  PID : $CHILD_PID"
    echo "  log : $LOG"
    echo "  tail: tail -f $LOG"
    exit 0
fi

# Smoke mode: small, sandboxed run
if [[ "$SMOKE" -eq 1 ]]; then
    MC=1
    STEPS=360
    RECORD_START=200
    WAVE_OUT="${WAVE}_smoke"
else
    WAVE_OUT="$WAVE"
fi

if [[ -n "${JULIA:-}" ]]; then
    JULIA_BIN="$JULIA"
elif command -v julia >/dev/null 2>&1; then
    JULIA_BIN="$(command -v julia)"
elif [[ -x "${HOME}/.juliaup/bin/julia" ]]; then
    JULIA_BIN="${HOME}/.juliaup/bin/julia"
else
    echo "ERROR: Julia executable not found. Set JULIA=/path/to/julia or add julia to PATH." >&2
    exit 2
fi

# ----------------------------------------------------------------------------
#
# Heuristic settings (override through the environment):
# - RUNNER_MEM_PER_THREAD_GB: estimated peak memory in GB per Julia worker thread.
# - RUNNER_MEM_RESERVE_GB:    fixed memory in GB reserved for the editor, the
#                             operating system and Julia compilation.
#
# The defaults are conservative for waves with 10,000 households and 10,000 steps.
# ----------------------------------------------------------------------------
REQ_THREADS="$THREADS"
AUTO_THREAD_CAP_REASON=""
CGROUP_MEM_MAX_BYTES="unknown"
CPU_COUNT="unknown"

if [[ "$FORCE_THREADS" -ne 1 ]]; then
    # CPU guard
    if command -v nproc >/dev/null 2>&1; then
        CPU_COUNT="$(nproc)"
        if [[ "$CPU_COUNT" =~ ^[0-9]+$ ]] && [[ "$CPU_COUNT" -gt 0 ]] && [[ "$THREADS" -gt "$CPU_COUNT" ]]; then
            THREADS="$CPU_COUNT"
            AUTO_THREAD_CAP_REASON="cpu"
        fi
    fi

    MEM_MAX_FILE="/sys/fs/cgroup/memory.max"
    if [[ -r "$MEM_MAX_FILE" ]]; then
        CGROUP_MEM_MAX_BYTES="$(cat "$MEM_MAX_FILE")"
        if [[ "$CGROUP_MEM_MAX_BYTES" =~ ^[0-9]+$ ]]; then
            MEM_PER_THREAD_GB="${RUNNER_MEM_PER_THREAD_GB:-3}"
            MEM_RESERVE_GB="${RUNNER_MEM_RESERVE_GB:-4}"

            # Integer arithmetic only: convert GiB to bytes.
            MEM_PER_THREAD_B=$(( MEM_PER_THREAD_GB * 1024 * 1024 * 1024 ))
            MEM_RESERVE_B=$(( MEM_RESERVE_GB * 1024 * 1024 * 1024 ))

            if [[ "$CGROUP_MEM_MAX_BYTES" -gt "$MEM_RESERVE_B" ]] && [[ "$MEM_PER_THREAD_B" -gt 0 ]]; then
                MEM_BUDGET_B=$(( CGROUP_MEM_MAX_BYTES - MEM_RESERVE_B ))
                SAFE_THREADS_BY_MEM=$(( MEM_BUDGET_B / MEM_PER_THREAD_B ))
                if [[ "$SAFE_THREADS_BY_MEM" -lt 1 ]]; then SAFE_THREADS_BY_MEM=1; fi

                if [[ "$THREADS" -gt "$SAFE_THREADS_BY_MEM" ]]; then
                    THREADS="$SAFE_THREADS_BY_MEM"
                    AUTO_THREAD_CAP_REASON="${AUTO_THREAD_CAP_REASON:+${AUTO_THREAD_CAP_REASON}+}memory"
                fi
            fi
        fi
    fi
fi

if [[ "$THREADS" -ne "$REQ_THREADS" ]]; then
    echo "[thread-guard] Requested --threads=${REQ_THREADS}; auto-capped to ${THREADS} (${AUTO_THREAD_CAP_REASON:-guard})."
    echo "[thread-guard] cgroup.memory.max=${CGROUP_MEM_MAX_BYTES}; cpu_count=${CPU_COUNT}."
    echo "[thread-guard] Override: pass --force-threads (or tune RUNNER_MEM_PER_THREAD_GB / RUNNER_MEM_RESERVE_GB)."
fi

# ----------------------------------------------------------------------------
# Parse the .conf file into the parallel arrays CELL_TAGS[], CELL_EXPORTS[] and
# CELL_NOTES[]. Blank and comment lines are skipped; a trailing "# note" is split
# off into CELL_NOTES.
# ----------------------------------------------------------------------------
CELL_TAGS=()
CELL_EXPORTS=()
CELL_NOTES=()
while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"                       # strip the inline note
    line="${line#"${line%%[![:space:]]*}"}" # trim leading whitespace
    [[ -z "$line" ]] && continue
    tag="${line%%[[:space:]]*}"
    rest="${line#${tag}}"
    rest="${rest#"${rest%%[![:space:]]*}"}" # trim leading whitespace again
    note=""
    if [[ "$raw" == *"#"* ]]; then
        note="${raw#*#}"
        note="${note#"${note%%[![:space:]]*}"}"
    fi
    CELL_TAGS+=("$tag")
    CELL_EXPORTS+=("$rest")
    CELL_NOTES+=("$note")
done < "$CONF_FILE"

[[ ${#CELL_TAGS[@]} -gt 0 ]] || { echo "ERROR: no cells parsed from $CONF_FILE" >&2; exit 2; }

# Apply the --cells filter (the order of the .conf file is preserved)
if [[ -n "$CELL_FILTER" ]]; then
    declare -A KEEP
    for t in $CELL_FILTER; do KEEP[$t]=1; done
    FILT_TAGS=(); FILT_EXP=(); FILT_NOTE=()
    for i in "${!CELL_TAGS[@]}"; do
        [[ -n "${KEEP[${CELL_TAGS[$i]}]:-}" ]] || continue
        FILT_TAGS+=("${CELL_TAGS[$i]}")
        FILT_EXP+=("${CELL_EXPORTS[$i]}")
        FILT_NOTE+=("${CELL_NOTES[$i]}")
    done
    CELL_TAGS=("${FILT_TAGS[@]}")
    CELL_EXPORTS=("${FILT_EXP[@]}")
    CELL_NOTES=("${FILT_NOTE[@]}")
    [[ ${#CELL_TAGS[@]} -gt 0 ]] || { echo "ERROR: --cells filter matched 0 cells" >&2; exit 2; }
fi

# Output directory of a cell
cell_dir() {
    local cell="$1"
    if [[ "$MC_IN_PATH" == "true" ]]; then
        echo "output/${WAVE_OUT}/${cell}/${MC}mc"
    else
        echo "output/${WAVE_OUT}/${cell}"
    fi
}

# Plan banner
TS="$(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo " WAVE: ${WAVE}  (out=${WAVE_OUT})"
echo " Started: ${TS}"
echo " MC=${MC}  STEPS=${STEPS}  RECORD_START=${RECORD_START}  THREADS=${THREADS}"
echo " Cells: ${#CELL_TAGS[@]}  (filter: ${CELL_FILTER:-none})"
echo " Layout: $(cell_dir '<CELL>')   (MC_IN_PATH=${MC_IN_PATH})"
echo " Bank limits   : ${BANK_LIMITS}  $([[ "$BANK_LIMITS" == "off" ]] && echo '(relaxed; cells set regulatory limits only)' || echo '(Config defaults; cells must set WD_BANK_* to neutralise)')"
echo " Mode: $([[ $SMOKE -eq 1 ]] && echo SMOKE || echo PRODUCTION)$([[ $RESUME -eq 1 ]] && echo ' +RESUME')"
echo "================================================================"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo " --dry-run: planned cells (in execution order):"
    for tag in "${CELL_TAGS[@]}"; do echo "   $tag"; done
    exit 0
fi

# ----------------------------------------------------------------------------
# Phase 1 - Campaign set-up
# ----------------------------------------------------------------------------
WAVE_DIR="output/${WAVE_OUT}"
mkdir -p "$WAVE_DIR"

CAMPAIGN_LOG="${WAVE_DIR}/${WAVE_OUT}_master_log.log"
MANIFEST="${WAVE_DIR}/${WAVE_OUT}_runs_manifest.csv"

{
    echo "================================================================"
    echo " WAVE: ${WAVE}  (out=${WAVE_OUT})"
    echo " Started: ${TS}"
    echo " MC=${MC}  STEPS=${STEPS}  RECORD_START=${RECORD_START}  THREADS=${THREADS}"
    echo " Cells: ${#CELL_TAGS[@]}"
    echo "================================================================"
} > "$CAMPAIGN_LOG"

if [[ ! -f "$MANIFEST" ]]; then
    echo "wave,cell,mc,steps,record_start,exports,note,status,started,finished,run_dir" > "$MANIFEST"
fi

# ----------------------------------------------------------------------------
# Phase 2 - Cell loop
# ----------------------------------------------------------------------------
# Every KEY exported for a cell is remembered so that it can be unset before the
# next cell: a cell that leaves a key unset must not inherit the previous cell's
# value.
SEEN_KEYS=()
seen_add() {
    local k="$1"
    for s in "${SEEN_KEYS[@]:-}"; do [[ "$s" == "$k" ]] && return 0; done
    SEEN_KEYS+=("$k")
}
reset_cell_env() {
    for k in "${SEEN_KEYS[@]:-}"; do unset "$k" || true; done
}

CELLS_RUN=0; CELLS_OK=0; CELLS_FAIL=0; CELLS_SKIP=0

run_cell() {
    local idx="$1"
    local cell="${CELL_TAGS[$idx]}"
    local exports="${CELL_EXPORTS[$idx]}"
    local note="${CELL_NOTES[$idx]}"
    local dir; dir="$(cell_dir "$cell")"

    CELLS_RUN=$((CELLS_RUN + 1))

    if [[ "$RESUME" -eq 1 && -f "${dir}/run_config.csv" ]]; then
        CELLS_SKIP=$((CELLS_SKIP + 1))
        echo "  [$CELLS_RUN/${#CELL_TAGS[@]}] SKIP $cell (run_config.csv exists)" | tee -a "$CAMPAIGN_LOG"
        return 0
    fi

    # Start each cell from an empty output directory
    rm -rf "$dir"
    mkdir -p "$dir"

    # Reset the previous cell's variables, then export this cell's keys
    reset_cell_env
    # Wave-wide run-size settings (read by run_working_data.jl)
    export WD_N_MC_RUNS="$MC"          ; seen_add WD_N_MC_RUNS
    export WD_N_STEPS="$STEPS"         ; seen_add WD_N_STEPS
    export WD_RECORD_START="$RECORD_START" ; seen_add WD_RECORD_START

    # BANK_LIMITS=off: inject relaxed bank limits. WD_BANK_* tokens in the cell
    # row are applied afterwards, so an explicit cell value wins. This lets .conf
    # rows set regulatory (WD_LIMIT_*) keys only, without the Config.jl bank
    # defaults binding by accident.
    if [[ "${BANK_LIMITS}" == "off" ]]; then
        export WD_BANK_LTV_FTB=0.99    ; seen_add WD_BANK_LTV_FTB
        export WD_BANK_LTV_HM=0.99     ; seen_add WD_BANK_LTV_HM
        export WD_BANK_LTV_BTL=0.99    ; seen_add WD_BANK_LTV_BTL
        export WD_BANK_LTI_FTB=99      ; seen_add WD_BANK_LTI_FTB
        export WD_BANK_LTI_HM=99       ; seen_add WD_BANK_LTI_HM
        export WD_BANK_DSTI_MAX=1.0    ; seen_add WD_BANK_DSTI_MAX
        export WD_BANK_ICR_MIN=0.0     ; seen_add WD_BANK_ICR_MIN
    fi

    # Per-cell KEY=VALUE tokens
    for kv in $exports; do
        [[ "$kv" == *"="* ]] || continue
        local key="${kv%%=*}"
        local val="${kv#*=}"
        export "$key=$val"
        seen_add "$key"
    done

    local started; started="$(date '+%Y-%m-%d %H:%M:%S')"
    {
        echo "------------------------------------------------------------"
        echo " [$CELLS_RUN/${#CELL_TAGS[@]}] CELL: $cell"
        [[ -n "$note" ]] && echo "   note   : $note"
        echo "   dir    : $dir"
        echo "   exports: $exports"
        echo "   started: ${started:-N/A}"
    } | tee -a "$CAMPAIGN_LOG"

    local cell_log="${dir}/run.log"

    # Simulation
    if ! "$JULIA_BIN" --project=. --threads="$THREADS" scripts/run_working_data.jl "$dir" > "$cell_log" 2>&1; then
        CELLS_FAIL=$((CELLS_FAIL + 1))
        echo "   FAILED - see $cell_log" | tee -a "$CAMPAIGN_LOG"
        printf '%s,%s,%s,%s,%s,"%s","%s",FAIL,%s,%s,%s\n' \
            "$WAVE" "$cell" "$MC" "$STEPS" "$RECORD_START" \
            "$exports" "$note" "${started:-N/A}" "$(date '+%Y-%m-%d %H:%M:%S')" "$dir" >> "$MANIFEST"
        return 0
    fi

    CELLS_OK=$((CELLS_OK + 1))
    local finished; finished="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "   OK $finished" | tee -a "$CAMPAIGN_LOG"
    printf '%s,%s,%s,%s,%s,"%s","%s",OK,%s,%s,%s\n' \
        "$WAVE" "$cell" "$MC" "$STEPS" "$RECORD_START" \
        "$exports" "$note" "${started:-N/A}" "${finished:-N/A}" "$dir" >> "$MANIFEST"

    # Per-cell audit file: one row recording exactly what ran. Overwritten when
    # the cell is re-run.
    local cell_manifest="${dir}/runs_manifest.csv"
    {
        echo "wave,cell,mc,steps,record_start,sim_log_bytes,started,finished,run_dir"
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$WAVE" "$cell" "$MC" "$STEPS" "$RECORD_START" \
            "$(wc -c < "$cell_log" 2>/dev/null || echo 0)" \
            "${started:-N/A}" "${finished:-N/A}" "$dir"
    } > "$cell_manifest"
}

for i in "${!CELL_TAGS[@]}"; do
    run_cell "$i"
done

# ----------------------------------------------------------------------------
# Phase 3 - Finalise
# ----------------------------------------------------------------------------
FIN="$(date '+%Y-%m-%d %H:%M:%S')"
{
    echo "================================================================"
    echo " ${WAVE_OUT} COMPLETE - RUN=${CELLS_RUN} OK=${CELLS_OK} FAIL=${CELLS_FAIL} SKIP=${CELLS_SKIP}"
    echo " Started:  ${TS}"
    echo " Finished: ${FIN}"
    echo " Manifest: ${MANIFEST}"
    echo "================================================================"
} | tee -a "$CAMPAIGN_LOG"
