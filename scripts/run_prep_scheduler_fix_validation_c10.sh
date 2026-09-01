#!/bin/bash
# ============================================================
# LASTScheduler.reorder() PERFORMANCE-FIX VALIDATION — Besu @ 4 GB heap
#
# Root cause found 2026-08-28: reorderHybridWithWeights() (shared by HFL,
# MATS, PREP, PREP_SCHED) sorted with a comparator that called
# computeHflScore() on BOTH operands of every comparison, turning an O(n)
# scoring pass into O(n log n) score recomputations. Measured
# scheduler_overhead_us in canonical Besu data: ~75,000-135,000us (75-135ms)
# per block-assembly call -- ~1000x the NM/CLR port's ~75-84us for the
# equivalent step. This is the prime suspect for why Besu scheduling
# variants achieve only 43-57% of Baseline FIFO's throughput while NM's
# HFL/MATS retain 94-96% -- a JVM-implementation-specific inefficiency, not
# a flaw in the locality-scheduling idea itself (confirmed via a
# rate-matched-FIFO control experiment showing Besu's GC-pause "benefit" is
# largely a throughput artifact -- see prep_fifo_ratematched results).
#
# Fix: precompute each candidate's score once (ScoredTx), then sort on the
# cached value -- O(n) scoring + O(n log n) cheap double comparisons.
#
# This validation reruns all 5 variants (Baseline, HFL, MATS, PREP,
# PREP_SCHED) at n=1, canonical theta_p=0.20 (default, gate inactive),
# 150 TPS, using the FIXED jar in an ISOLATED install
# (~/besu-mats-fixed, NOT ~/besu-mats -- compute23's ongoing theta_p sweep
# still uses the original, unpatched jar and must not be disturbed).
# Compare avg_tx_per_block / tx_per_sec / gc_ms_per_1000tx against the
# canonical (pre-fix) numbers:
#   Baseline: 34.0 tx/s, 270.8 tx/block, 66.6 ms/1000tx
#   HFL:      14.6 tx/s,  40.6 tx/block, 27.8 ms/1000tx
#   MATS:     14.7 tx/s,  42.4 tx/block, 26.9 ms/1000tx
#   PREP:     19.5 tx/s,  38.4 tx/block, 26.3 ms/1000tx
#   PREP_SCHED: 17.8 tx/s, 40.3 tx/block, 26.7 ms/1000tx
# If the fix worked, scheduling variants' tx/s and tx/block should move
# substantially toward Baseline's, while gc_ms_per_1000tx should stay low
# (confirming a genuine, throughput-independent locality benefit survives).
#
# Output: results/prep_scheduler_fix_validation/<RUN_ID>/
# ============================================================
set -e
# Isolated CWD (NOT the shared caliper-stress-test dir) so this host's
# networkconfig.json/caliper.log/report.html/deployed_contracts.json don't
# race with compute23's simultaneous run over the same NFS mount. Read-only
# assets (benchmarks/, StateBloater.json, log4j2-console.xml, benchconfig,
# deploy script) are symlinked back to the shared dir.
cd /home/yeochan.yoon/caliper-stress-test-c10

export JAVA_HOME="/home/yeochan.yoon/jdk17-portable"
export PATH="${JAVA_HOME}/bin:/home/yeochan.yoon/node22/bin:${PATH}"

BESU_BIN="/home/yeochan.yoon/besu-mats-fixed/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-last-vs-lass-nm.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

HEAP="4g"
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
NO_LASS="-Dlass.old.gen.activation.threshold=2.0"

REPLICATIONS=1
COOLDOWN_BETWEEN_RUNS=20
CALIPER_TIMEOUT=1500

RUN_ID=$(date +%Y%m%d_%H%M%S)_prep_scheduler_fix_validation
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/prep_scheduler_fix_validation/${RUN_ID}"
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
        local gc_stats
        gc_stats=$(awk -F, 'NR>1 {gc+=$15; dur+=$10; tx+=$4; wh+=$5; nblk+=1; if($9>0){sched_sum+=$9; sched_n+=1}}
            NR==2 {t0=$1}
            {t1=$1}
            END {
                gc_per_1000tx = (tx>0 ? gc/tx*1000 : 0)
                tps = (t1>t0 ? tx/((t1-t0)/1000.0) : 0)
                sched_avg_us = (sched_n>0 ? sched_sum/sched_n : 0)
                printf "total_gc_ms=%.0f\ntrace_duration_ms=%.0f\ntx_total=%d\nwarm_hits=%d\navg_tx_per_block=%.3f\ngc_ms_per_1000tx=%.3f\ntx_per_sec=%.3f\nscheduler_overhead_us_avg=%.1f\n",
                       gc, dur, tx, wh, (nblk>0 ? tx/nblk : 0), gc_per_1000tx, tps, sched_avg_us
            }' "${last_csv}")
        echo "${gc_stats}" > "${run_dir}/gc_summary.txt"
        echo "  LAST log: ${blocks} blocks"
        cat "${run_dir}/gc_summary.txt" | sed 's/^/  /'
    fi

    local measure_line; measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"
    echo "  ✓ ${label} complete"
    echo ""
    sleep ${COOLDOWN_BETWEEN_RUNS}
}

# ── Provenance ────────────────────────────────────────────────────────────────
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
LASTScheduler.reorder() Performance-Fix Validation — Besu 4 GB / 150 TPS
=============================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)
Binary: ${BESU_BIN} (FIXED jar, isolated install, canonical unpatched
        install at ~/besu-mats untouched -- compute23's theta_p sweep
        still uses the original scheduler)
Heap:   -Xms4g -Xmx4g (G1GC, MaxGCPauseMillis=200)
Variants: DISABLED, HYBRID_FEE_LOCALITY(0.5/0.5), MATS, PREP, PREP_SCHED
n=${REPLICATIONS} each (quick validation, not a publication-grade sample --
   scale to n=5 afterward only if this confirms the fix helps)
Load:     150 TPS, 30 contracts × 200 slots, 120s warmup + 300s measure
theta_p: default 0.20 (gate inactive on Besu, unchanged from canonical)

Canonical (pre-fix, n=5) reference values:
  Baseline:   34.0 tx/s,  270.8 tx/block, 66.6 ms/1000tx
  HFL:        14.6 tx/s,   40.6 tx/block, 27.8 ms/1000tx
  MATS:       14.7 tx/s,   42.4 tx/block, 26.9 ms/1000tx
  PREP:       19.5 tx/s,   38.4 tx/block, 26.3 ms/1000tx
  PREP_SCHED: 17.8 tx/s,   40.3 tx/block, 26.7 ms/1000tx
EOF

# ── Main loop (all 5 variants, n=1) ─────────────────────────────────────────────
TOTAL_RUNS=5
echo "======================================================================"
echo "Scheduler fix validation [compute24] | 150 TPS | 120s+300s | ${TOTAL_RUNS} runs"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"

run_single "baseline"   1 "-Dlast.variant=DISABLED" || true
run_single "last_hfl"   1 "-Dlast.variant=HYBRID_FEE_LOCALITY" "-Dlast.alpha=0.5 -Dlast.beta=0.5" || true
run_single "mats"       1 "-Dlast.variant=MATS" || true
run_single "prep"       1 "-Dlast.variant=PREP" || true
run_single "prep_sched" 1 "-Dlast.variant=PREP_SCHED" || true

echo ""
echo "======================================================================"
echo "Scheduler fix validation: all ${TOTAL_RUNS} runs complete."
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"
echo ""
echo "Summary vs canonical (pre-fix):"
for v in baseline last_hfl mats prep prep_sched; do
    f="${RESULTS_DIR}/${v}_1/gc_summary.txt"
    echo "  ${v}:"
    if [ -f "${f}" ]; then
        cat "${f}" | sed 's/^/    /'
    else
        echo "    NO SUMMARY (failed, check ${RESULTS_DIR}/${v}_1/)"
    fi
done
