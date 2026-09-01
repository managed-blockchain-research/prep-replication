#!/bin/bash
# ============================================================
# PREP theta_p RECALIBRATION SWEEP — Besu @ 4 GB heap
#
# Pre-registered (see debate synthesis at
# ~/.claude-octopus/debates/local/002-prep-gate-contribution/synthesis.md):
# the default theta_p=0.20 never activates on Besu because observed JVM
# EWMA pressure (avg 0.033, max 0.089) never crosses it. This sweep tests
# theta_p in {0.04, 0.05, 0.07} -- confirmed via smoke test to trigger
# nonzero prep_deferred at all three -- for PREP and PREP_SCHED only.
# Baseline/HFL/MATS do not depend on theta_p; one fresh baseline rep is
# included as a drift check against the canonical n=5 result (5.93 ms/s),
# not as a new baseline dataset.
#
# Selection criterion (pre-registered, decided BEFORE seeing full results):
# among theta values where PREP/PREP_SCHED show a statistically detectable
# GC-pause change vs the canonical theta=0.20 (inactive-gate) result AND
# avg tx_count/block (utilization proxy) does not collapse >20% relative
# to baseline, report that theta as the calibrated value; otherwise report
# the full sweep honestly as "no theta in this grid rescues the gate."
#
# Order per rep: baseline(once,rep1 only) → prep@0.04 → prep_sched@0.04 →
#                prep@0.05 → prep_sched@0.05 → prep@0.07 → prep_sched@0.07
#
# Binary: besu-mats (besu-24.1.1 + PREP-patched blockcreation jar,
#         PREP_PRESSURE_THRESHOLD now reads -Dprep.theta_p, default 0.20)
# Load:   120s warmup + 300s measure, 150 TPS, 30 workers, 30 contracts (UNCHANGED
#         from canonical run_prep_eval_besu.sh -- the smoke test's shortened
#         60s/90s window was for activation-check only, not for these results)
# TX:     stateBloat 200 slots/tx
# GC:     JVM G1GC unified log per run + gc_total_delta_ms from LASTMetricsLogger
# Log:    last.log.path CSV per run (extended schema for PREP/PREP_SCHED)
# Secondary metric: avg tx_count/block (utilization) logged alongside GC pause,
#         per debate synthesis risk #2 (gate could activate but tank utilization)
# Output: results/prep_theta_sweep_besu/<RUN_ID>/
# ============================================================
set -e
# Isolated CWD (NOT the shared caliper-stress-test dir) so this host's
# networkconfig.json/caliper.log/report.html/deployed_contracts.json don't
# race with compute23's simultaneous run over the same NFS mount. Read-only
# assets (benchmarks/, StateBloater.json, log4j2-console.xml, benchconfig,
# deploy script) are symlinked back to the shared dir.
cd /home/yeochan.yoon/caliper-stress-test-c24

export JAVA_HOME="/home/yeochan.yoon/jdk17-portable"
export PATH="${JAVA_HOME}/bin:/home/yeochan.yoon/node22/bin:${PATH}"

BESU_BIN="/home/yeochan.yoon/besu-mats/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-last-vs-lass-nm.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

HEAP="4g"
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
NO_LASS="-Dlass.old.gen.activation.threshold=2.0"

REPLICATIONS=5
THETA_VALUES="0.04 0.05 0.07"
COOLDOWN_BETWEEN_RUNS=20
INTER_REP_COOLDOWN=60
CALIPER_TIMEOUT=1500

# SPLIT RUN (compute24 half): fixed shared RUN_ID so both halves land in one
# directory over NFS. This host runs PREP_SCHED variant only; compute23 runs
# the baseline drift-check + PREP only via run_prep_theta_sweep_besu_prep_only.sh.
RUN_ID="20260828_133000_prep_theta_sweep_besu"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/prep_theta_sweep_besu/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_rpc() {
    local max=120 count=0
    echo -n "  Waiting for RPC"
    while [ ${count} -lt ${max} ]; do
        if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1; then
            echo " READY"; return 0
        fi
        echo -n "."; sleep 1; count=$((count+1))
    done
    echo " TIMEOUT"; return 1
}

stop_besu() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0
    while kill -0 "${pid}" 2>/dev/null && [ ${w} -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
}

# run_single VARIANT REP LAST_VARIANT_FLAG [EXTRA_FLAGS]
run_single() {
    local variant="$1"
    local rep="$2"
    local last_flag="$3"
    local extra_flags="${4:-}"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_bprep_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc_besu.log"
    local last_csv="${run_dir}/last_metrics.csv"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | mode=${last_flag} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5

    rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    local java_opts="-Xms${HEAP} -Xmx${HEAP} \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
${NEWGEN_FLAGS} \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=3,filesize=50M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
${last_flag} ${extra_flags} \
-Dlast.log.path=${last_csv} \
${NO_LASS}"

    export BESU_OPTS="${java_opts}"

    nohup "${BESU_BIN}" \
        --network=dev \
        --miner-enabled \
        --miner-coinbase=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
        --data-path="${data_dir}" \
        --rpc-http-enabled --rpc-http-port=8545 --rpc-http-host=0.0.0.0 \
        --rpc-http-cors-origins="*" \
        --rpc-ws-enabled --rpc-ws-port=8546 \
        --rpc-ws-max-active-connections=200 \
        --rpc-http-max-active-connections=200 \
        --host-allowlist="*" \
        --min-gas-price=0 \
        --tx-pool-layer-max-capacity=1000000 \
        --tx-pool-max-prioritized=1000000 \
        --tx-pool-max-future-by-sender=100000 \
        > "${run_dir}/besu_console.log" 2>&1 &
    local besu_pid=$!
    echo "  Besu PID: ${besu_pid}"

    sleep 8
    if ! kill -0 ${besu_pid} 2>/dev/null; then
        echo "  ERROR: Besu died at startup."
        tail -20 "${run_dir}/besu_console.log" || true
        echo "failed=startup" > "${run_dir}/FAILED"; return 1
    fi

    wait_for_rpc || {
        stop_besu "${besu_pid}"
        echo "failed=rpc_timeout" > "${run_dir}/FAILED"; return 1
    }

    echo "  Deploying 30 StateBloater contracts..."
    python3 "${DEPLOY_SCRIPT}" > "${run_dir}/deploy.log" 2>&1
    if ! grep -q "Contract Address:" "${run_dir}/deploy.log" 2>/dev/null; then
        echo "  ERROR: Deploy failed."
        cat "${run_dir}/deploy.log"
        stop_besu "${besu_pid}"
        echo "failed=deploy" > "${run_dir}/FAILED"; return 1
    fi
    sleep 3

    echo "  Running Caliper (120s warmup + 300s measure @ 150 TPS)..."
    local t_start; t_start=$(date +%s)
    timeout ${CALIPER_TIMEOUT} npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true
    local caliper_exit=$?
    local t_end; t_end=$(date +%s)
    local elapsed=$(( t_end - t_start ))
    echo "  Caliper exit: ${caliper_exit}. Elapsed: ${elapsed}s"

    cp caliper.log  "${run_dir}/caliper.log"  2>/dev/null || true
    cp report.html  "${run_dir}/report.html"  2>/dev/null || true

    echo "  Stopping Besu..."
    stop_besu "${besu_pid}"
    rm -rf "${data_dir}"

    # ── Parse GC summary from last_metrics.csv ────────────────────────────────
    if [ -f "${last_csv}" ]; then
        local blocks; blocks=$(( $(wc -l < "${last_csv}") - 1 ))
        # sum gc_total_delta_ms (col 15) and block_duration_ms (col 10)
        # For PREP/PREP_SCHED: also sum prep_admitted (col 21) and prep_deferred (col 22)
        local gc_stats
        gc_stats=$(awk -F, 'NR>1 {gc+=$15; dur+=$10; tx+=$4; wh+=$5; pa+=$21; pd+=$22; nblk+=1}
            END {
                printf "total_gc_ms=%.0f\ntrace_duration_ms=%.0f\ntx_total=%d\nwarm_hits=%d\nprep_admitted=%d\nprep_deferred=%d\navg_tx_per_block=%.3f\n",
                       gc, dur, tx, wh, pa, pd, (nblk>0 ? tx/nblk : 0)
            }' "${last_csv}")
        echo "${gc_stats}" > "${run_dir}/gc_summary.txt"
        echo "  LAST log: ${blocks} blocks"
        echo "  $(grep total_gc_ms "${run_dir}/gc_summary.txt" | head -1)"
        echo "  $(grep prep_deferred "${run_dir}/gc_summary.txt" | head -1)"
        echo "  $(grep avg_tx_per_block "${run_dir}/gc_summary.txt" | head -1) (utilization proxy)"
    fi

    local measure_line; measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"
    echo "  ✓ ${label} complete"
    echo ""
    sleep ${COOLDOWN_BETWEEN_RUNS}
}

# ── Provenance ────────────────────────────────────────────────────────────────
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
PREP theta_p Recalibration Sweep — Besu 4 GB / 150 TPS
=============================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)
Binary: ${BESU_BIN}
Heap:   -Xms4g -Xmx4g (G1GC, MaxGCPauseMillis=200)
Theta values swept: ${THETA_VALUES} (PREP, PREP_SCHED only; n=${REPLICATIONS} each)
Drift check: 1 fresh baseline rep (canonical n=5 baseline = 5.93 ms/s)
Load:     150 TPS, 30 contracts × 200 slots, 120s warmup + 300s measure (UNCHANGED from canonical eval)
PREP gate: θ̄=0.05, Δ=0.30, f_c=0.25, τ=3 (unchanged); θ_p swept per-run via -Dprep.theta_p
PREP_SCHED: β' = min(β+0.30, 0.95)

Pre-registered selection criterion (decided before seeing full results):
  report as "calibrated" the theta_p (if any) where PREP/PREP_SCHED show a
  statistically detectable GC-pause change vs the canonical theta=0.20
  (gate-inactive) result AND avg_tx_per_block does not collapse >20% vs
  baseline. If no theta in {0.04, 0.05, 0.07} satisfies this, report the
  full grid honestly as a null result for gate recalibration.

Smoke test (1 rep, 60s/90s, prior to this run) confirmed nonzero prep_deferred
at all three theta values: 0.04 -> 5208, 0.05 -> 5476, 0.07 -> 1752 (out of
~980-998k prep_admitted each, i.e. gate activates only briefly near pressure
spikes -- consistent with avg EWMA 0.033 rarely exceeding these thresholds).
EOF

# ── Main loop (compute24 half: PREP_SCHED only) ────────────────────────────────
TOTAL_RUNS=$(( REPLICATIONS * 3 ))
echo "======================================================================"
echo "PREP theta_p sweep Besu [compute24/PREP_SCHED half] | 150 TPS | 120s+300s | ${TOTAL_RUNS} runs"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"

for rep in $(seq 1 ${REPLICATIONS}); do
    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    echo "REPLICATION ${rep}/${REPLICATIONS}"
    echo "══════════════════════════════════════════════════════════════════"

    for theta in ${THETA_VALUES}; do
        run_single "prep_sched_theta${theta}" ${rep} "-Dlast.variant=PREP_SCHED" "-Dprep.theta_p=${theta}" || true
    done

    if [ ${rep} -lt ${REPLICATIONS} ]; then
        echo "  (inter-rep cooldown ${INTER_REP_COOLDOWN}s)"
        sleep ${INTER_REP_COOLDOWN}
    fi
done

echo ""
echo "======================================================================"
echo "compute24/PREP_SCHED half: all ${TOTAL_RUNS} runs complete."
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"
echo ""
echo "Per-theta deferral + GC summary (PREP_SCHED):"
for theta in ${THETA_VALUES}; do
    echo "  prep_sched_theta${theta}:"
    for rep in $(seq 1 ${REPLICATIONS}); do
        f="${RESULTS_DIR}/prep_sched_theta${theta}_${rep}/gc_summary.txt"
        if [ -f "${f}" ]; then
            echo "    rep${rep}: $(grep total_gc_ms "$f") $(grep prep_deferred "$f") $(grep avg_tx_per_block "$f")"
        else
            echo "    rep${rep}: NO SUMMARY (failed, check ${RESULTS_DIR}/prep_sched_theta${theta}_${rep}/)"
        fi
    done
done
