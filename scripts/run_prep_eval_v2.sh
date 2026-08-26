#!/bin/bash
# ============================================================
# PREP Evaluation Harness v2 — Nethermind @ no heap limit
#
# Re-run of run_prep_eval.sh (2026-05-15 dataset) after fixing 4 real bugs found
# while diagnosing why every rep in that dataset showed 0% Caliper-confirmed
# success and a trace_duration_s ranging 200-1470s:
#   1. GC-trace window now stopped on a fixed wall-clock timer, not tied to
#      Caliper's own (treatment-dependent) exit time.
#   2. gasPrice now varies per-tx (benchmarks/stateBloatVariedFee.js) so
#      Nethermind's TxPool can't tie-lock permanently once full.
#   3. 3 independent Caliper/web3.js timeouts aligned (networkconfig_nethermind_prep.json):
#      txWallClockTimeout 8s→300s, transactionPollingTimeout 90s→280s,
#      transactionBlockTimeout 200→2000 blocks.
#   4. `wait "$caliper_pid"` under set -e no longer silently aborts the script
#      (and skips all cleanup) when the internal CALIPER_TIMEOUT actually fires.
#
# A fire-and-forget dispatch variant was also tried, but Little's Law makes it
# structurally unable to sustain 150 TPS once per-tx confirmation latency runs
# into the hundreds of seconds under backlog (would need ~tens of thousands of
# concurrent in-flight slots) — so this script deliberately uses the simpler
# synchronous-dispatch workload. Caliper's own Succ/Fail/latency numbers are
# NOT reliable at this load level for this workload — do not report them.
# The trustworthy sources are last_metrics.csv (admission/warm-hit/tx_count,
# NM's own LAST-scheduler log) and gc_summary.txt (dotnet-trace, now on a fixed
# comparable window).
#
# 5 variants × 5 replications = 25 runs, interleaved per rep
#   baseline   : NETHERMIND_LAST_MODE=DISABLED    (FIFO)
#   last_hfl   : NETHERMIND_LAST_MODE=HFL_5_5      (static hybrid α=β=0.5, control)
#   mats       : NETHERMIND_LAST_MODE=MATS          (adaptive α/β via EWMA — scheduling-only baseline)
#   prep       : NETHERMIND_LAST_MODE=PREP          (PREP admission gate only)
#   prep_sched : NETHERMIND_LAST_MODE=PREP_SCHED    (PREP gate + boosted locality priority)
#
# Interleaved order: b1→hfl1→mats1→prep1→ps1→b2→hfl2→…
#
# Binary: nethermind-last (PREP-patched Nethermind.Consensus.Ethash.dll)
# Load:   120s warmup + 300s measure, 150 TPS, 30 workers, 30 contracts
# GC:     dotnet-trace → NettraceGcParser per run
# Output: results/prep_eval/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
GC_PARSER="/home/yeochan.yoon/caliper-stress-test/gc-collector/publish/NettraceGcParser.dll"

NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
BENCHCONFIG="benchconfig-prep-variedfee-150tps.yaml"
NETWORKCONFIG="networkconfig_nethermind_prep.json"
DEPLOY_SCRIPT="deploy_multi_contracts_nm.js"

REPLICATIONS=5
COOLDOWN_BETWEEN_RUNS=20
CALIPER_TIMEOUT=1500

# GC trace must be stopped on a fixed wall-clock timer (LOAD_DURATION_S = warmup 120s +
# measure 300s from the benchconfig, + TRACE_BUFFER_S slack for round-transition
# overhead), NOT on Caliper's own process exit. Caliper's fixed-rate dispatcher
# submits for a deterministic 420s regardless of load, but the `caliper launch` process
# itself only returns once all outstanding transactions settle — under the PREP admission
# gate that confirmation-drain tail can stretch anywhere from ~200s to near CALIPER_TIMEOUT,
# which previously made trace_duration_s (and thus total_pause_ms/trace_duration_s) vary
# 200-1470s across variants instead of a comparable, fixed measurement window.
LOAD_DURATION_S=420
TRACE_BUFFER_S=10
TRACE_WINDOW_S=$((LOAD_DURATION_S + TRACE_BUFFER_S))

RUN_ID=$(date +%Y%m%d_%H%M%S)_prep_eval_v2
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/prep_eval/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="${DOTNET_ROOT}:${PATH}:${HOME}/.dotnet/tools"

echo "======================================================================"
echo "PREP Evaluation | 150 TPS | 120s+300s | 5 variants × 5 reps (interleaved)"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_rpc() {
    local max_wait=120
    local count=0
    echo -n "  Waiting for RPC"
    while [ ${count} -lt ${max_wait} ]; do
        if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1; then
            echo " READY"
            return 0
        fi
        echo -n "."
        sleep 1
        count=$((count + 1))
    done
    echo " TIMEOUT"
    return 1
}

stop_nm() {
    local nm_pid="$1"
    kill "${nm_pid}" 2>/dev/null || true
    local w=0
    while kill -0 "${nm_pid}" 2>/dev/null && [ "${w}" -lt 30 ]; do
        sleep 1; w=$((w+1))
    done
    kill -9 "${nm_pid}" 2>/dev/null || true
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

run_single() {
    local variant="$1"   # baseline | last_hfl | mats | prep | prep_sched
    local rep="$2"
    local last_mode="$3" # DISABLED | HFL_5_5 | MATS | PREP | PREP_SCHED

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_${RUN_ID}"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | mode=${last_mode} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5

    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"

    export NETHERMIND_LAST_MODE="${last_mode}"
    export LAST_LOG_FILE="${run_dir}/last_metrics.csv"
    unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
          DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
    export DOTNET_EnableDiagnostics=1

    nohup "${DOTNET_BIN}" "${NM_DLL}" \
        --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}" \
        --Blocks.MinGasPrice 0 \
        > "${run_dir}/nm_console.log" 2>&1 &
    local nm_pid=$!
    echo "  Nethermind PID: ${nm_pid}"

    sleep 8
    if ! kill -0 "${nm_pid}" 2>/dev/null; then
        echo "  ERROR: Nethermind died at startup"
        tail -20 "${run_dir}/nm_console.log" || true
        echo "failed=startup" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE LAST_LOG_FILE
        return 1
    fi

    wait_for_rpc || {
        stop_nm "${nm_pid}"
        echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE LAST_LOG_FILE
        return 1
    }

    echo "  Deploying 30 StateBloater contracts..."
    node "${DEPLOY_SCRIPT}" > "${run_dir}/deploy.log" 2>&1
    local contract_addr
    contract_addr=$(grep "Contract Address:" "${run_dir}/deploy.log" | head -1 | awk '{print $3}')
    if [ -z "${contract_addr}" ]; then
        echo "  ERROR: Deploy failed"; cat "${run_dir}/deploy.log"
        stop_nm "${nm_pid}"
        echo "failed=deploy" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE LAST_LOG_FILE
        return 1
    fi
    echo "  First contract: ${contract_addr}"

    sleep 5

    # Start dotnet-trace GC collection
    local nettrace_file="${run_dir}/gc_trace.nettrace"
    local dotnet_trace_pid=""
    local trace_watcher_pid=""
    if [ -f "${DT_BIN}" ]; then
        "${DT_BIN}" collect \
            --process-id "${nm_pid}" \
            --providers "Microsoft-Windows-DotNETRuntime:0x1:5" \
            --output "${nettrace_file}" \
            > "${run_dir}/dotnet_trace.log" 2>&1 &
        dotnet_trace_pid=$!
        echo "  dotnet-trace PID: ${dotnet_trace_pid}"

        # Fixed wall-clock stop, independent of Caliper's own exit (see TRACE_WINDOW_S comment above).
        (
            sleep "${TRACE_WINDOW_S}"
            if kill -0 "${dotnet_trace_pid}" 2>/dev/null; then
                kill -INT "${dotnet_trace_pid}" 2>/dev/null || true
                sleep 5
                kill "${dotnet_trace_pid}" 2>/dev/null || true
            fi
        ) &
        trace_watcher_pid=$!
        echo "  Trace fixed-window watcher PID: ${trace_watcher_pid} (stops at T0+${TRACE_WINDOW_S}s)"
    fi

    echo "  Running Caliper (120s warmup + 300s measure @ 150 TPS)..."
    local t_start
    t_start=$(date +%s)

    timeout "${CALIPER_TIMEOUT}" npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1 &
    local caliper_pid=$!
    # `wait` returns the backgrounded command's exit status; under `set -e` a
    # non-zero return here (e.g. 124 when the internal CALIPER_TIMEOUT above
    # actually fires) would abort the whole script right at this line, before
    # any cleanup (dotnet-trace stop, stop_nm, results reporting) ever runs.
    set +e
    wait "${caliper_pid}"
    local caliper_exit=$?
    set -e

    local t_end
    t_end=$(date +%s)
    echo "  Caliper exit: ${caliper_exit}. Elapsed: $((t_end - t_start))s"

    # Ensure trace + its watcher are torn down even if Caliper finished before or long after T0+TRACE_WINDOW_S.
    if [ -n "${dotnet_trace_pid}" ] && kill -0 "${dotnet_trace_pid}" 2>/dev/null; then
        kill -INT "${dotnet_trace_pid}" 2>/dev/null || true
        sleep 5
        kill "${dotnet_trace_pid}" 2>/dev/null || true
    fi
    if [ -n "${trace_watcher_pid}" ]; then
        kill "${trace_watcher_pid}" 2>/dev/null || true
    fi

    # Flag runs contaminated by RPC-layer distress (previously silently averaged into mats_5-style outliers).
    if grep -q "FeeTooLowToCompete" "${run_dir}/nm_console.log" "${run_dir}/caliper_console.log" 2>/dev/null; then
        local feetoolow_count
        feetoolow_count=$(grep -c "FeeTooLowToCompete" "${run_dir}/nm_console.log" "${run_dir}/caliper_console.log" 2>/dev/null | awk -F: '{s+=$2} END {print s}')
        echo "  WARNING: FeeTooLowToCompete detected (${feetoolow_count} occurrences) — flagging run"
        echo "feetoolow_count=${feetoolow_count}" > "${run_dir}/WARN_FEETOOLOW"
    fi

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true

    echo "  Stopping Nethermind..."
    stop_nm "${nm_pid}"
    rm -rf "${data_dir}"

    unset NETHERMIND_LAST_MODE LAST_LOG_FILE

    # Parse GC trace
    if [ -f "${nettrace_file}" ] && [ -f "${GC_PARSER}" ]; then
        echo "  Parsing GC trace..."
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace_file}" 2>/dev/null \
            | tee "${run_dir}/gc_summary.txt" \
            | sed 's/^/    /'
    fi

    # Quick summary
    local measure_line
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" 2>/dev/null | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"

    if [ -f "${run_dir}/last_metrics.csv" ]; then
        local block_count
        block_count=$(tail -n +2 "${run_dir}/last_metrics.csv" | wc -l)
        local total_alloc
        total_alloc=$(tail -n +2 "${run_dir}/last_metrics.csv" | awk -F',' '{s+=$9} END {printf "%.1f", s}')
        # For PREP/PREP_SCHED, print admission stats (cols 14,15 in extended schema)
        if [[ "${last_mode}" == PREP* ]]; then
            local total_admitted total_deferred
            total_admitted=$(tail -n +2 "${run_dir}/last_metrics.csv" | awk -F',' '{s+=$14} END {print int(s)}' 2>/dev/null || echo "-")
            total_deferred=$(tail -n +2 "${run_dir}/last_metrics.csv" | awk -F',' '{s+=$15} END {print int(s)}' 2>/dev/null || echo "-")
            echo "  LAST log: ${block_count} blocks | alloc_mb_total=${total_alloc} | prep_admitted=${total_admitted} prep_deferred=${total_deferred}"
        else
            echo "  LAST log: ${block_count} blocks | alloc_mb_total=${total_alloc}"
        fi
    fi

    echo "  ✓ ${label} complete"
}

# ── Provenance ────────────────────────────────────────────────────────────────
NM_COMMIT=$(cd /home/yeochan.yoon/nethermind && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
PREP Evaluation — Nethermind, no heap limit
============================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Binary:  ${NM_DLL}
  Nethermind.Consensus.Ethash.dll: PREP-patched (LastTxPoolTxSource with PrepAdmissionGate)
  source commit: ${NM_COMMIT}

Load:    150 TPS fixed-rate, 120s warmup + 300s measure, 30 workers
TX:      stateBloat 200 slots/tx, 30 contracts
GC:      CLR default (no heap limit), dotnet-trace per run

Variants (interleaved b1→hfl1→mats1→prep1→ps1→b2→…):
  baseline   : NETHERMIND_LAST_MODE=DISABLED    (FIFO baseline)
  last_hfl   : NETHERMIND_LAST_MODE=HFL_5_5      (static hybrid fee+locality, α=β=0.5)
  mats       : NETHERMIND_LAST_MODE=MATS          (adaptive α/β via EWMA pressure — scheduling-only baseline)
  prep       : NETHERMIND_LAST_MODE=PREP          (PREP admission gate + MATS scheduling)
  prep_sched : NETHERMIND_LAST_MODE=PREP_SCHED    (PREP gate + boosted locality priority shaping)

PREP gate:
  Activates when m_t > 0.20 (EWMA pressure threshold)
  Adaptive warm threshold: θ_admit = EwmaTheta + m_t × 0.30
  Cold budget: (1 - m_t) × 0.25 × block_size cold txs allowed through
  Starvation guard: admit after 3 consecutive deferrals
PREP_SCHED: same gate + matsBeta boosted by +0.30 (capped at 0.95)

Key metrics:
  GC:         total_pause_ms / trace_duration_s (from gc_summary.txt)
  Alloc:      alloc_mb per transaction (last_metrics.csv)
  Warm ratio: warm_hits / tx_count (last_metrics.csv)
  Admission:  prep_admitted, prep_deferred (last_metrics.csv cols 10,11 for PREP modes)
EOF

# ── Pre-flight ─────────────────────────────────────────────────────────────────
pkill -9 -f "nethermind.dll" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
sleep 3

# ── Main loop ─────────────────────────────────────────────────────────────────
echo ""
echo "Starting 25 runs (5 variants × 5 reps, interleaved)..."
echo ""

VARIANTS=("baseline:DISABLED" "last_hfl:HFL_5_5" "mats:MATS" "prep:PREP" "prep_sched:PREP_SCHED")

for rep in $(seq 1 "${REPLICATIONS}"); do
    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    echo "REPLICATION ${rep}/${REPLICATIONS}"
    echo "══════════════════════════════════════════════════════════════════"

    for var_spec in "${VARIANTS[@]}"; do
        local_variant="${var_spec%%:*}"
        local_mode="${var_spec##*:}"
        run_single "${local_variant}" "${rep}" "${local_mode}" || true
        sleep "${COOLDOWN_BETWEEN_RUNS}"
    done
done

echo ""
echo "======================================================================"
echo "PREP Evaluation COMPLETE"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "Run analysis: python3 analyze_prep.py ${RESULTS_DIR}"
echo "======================================================================"
