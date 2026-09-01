#!/bin/bash
# ============================================================
# RATE-MATCHED FIFO CONTROL — Besu @ 4 GB heap
#
# Motivation (brainstorm session, 2026-08-28, /octo:brainstorm Team mode):
# re-analysis of the canonical n=5 Besu results showed locality-aware
# scheduling variants (HFL/MATS/PREP/PREP_SCHED) achieve ~60% lower
# GC-ms-per-1000-tx than Baseline FIFO, but ALSO only 43-57% of Baseline's
# actual throughput (tx/sec) under the 150 TPS offered overload. Question:
# is the lower per-tx GC cost a genuine locality effect, or just an
# artifact of processing fewer transactions per unit time?
#
# This experiment throttles plain FIFO (DISABLED variant, no scheduling)
# down to ~15 TPS -- matching the scheduling variants' ACHIEVED throughput
# -- and re-measures GC-ms-per-1000-tx. Decisive interpretation:
#   - if rate-matched FIFO still shows ~66 ms/1000tx (like full-rate FIFO):
#     locality effect is real, independent of throughput.
#   - if it drops to ~26-28 ms/1000tx (like the scheduling variants):
#     the "locality benefit" is largely a throughput artifact -- any
#     variant processing fewer tx/sec would show the same GC reduction.
#
# n=5 replicates of DISABLED variant @ 15 TPS (vs 150 TPS in the canonical
# eval). Everything else (heap, warmup/measure duration, workload, workers)
# matches the canonical run_prep_eval_besu.sh exactly.
#
# Output: results/prep_fifo_ratematched/<RUN_ID>/
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
BENCHCONFIG="benchconfig-prep-fifo-ratematched-15tps.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

HEAP="4g"
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
NO_LASS="-Dlass.old.gen.activation.threshold=2.0"

REPLICATIONS=5
COOLDOWN_BETWEEN_RUNS=20
INTER_REP_COOLDOWN=60
CALIPER_TIMEOUT=1500

RUN_ID=$(date +%Y%m%d_%H%M%S)_prep_fifo_ratematched
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/prep_fifo_ratematched/${RUN_ID}"
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

    echo "  Running Caliper (120s warmup + 300s measure @ 15 TPS, rate-matched)..."
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
        gc_stats=$(awk -F, 'NR>1 {gc+=$15; dur+=$10; tx+=$4; wh+=$5; nblk+=1}
            NR==2 {t0=$1}
            {t1=$1}
            END {
                gc_per_1000tx = (tx>0 ? gc/tx*1000 : 0)
                tps = (t1>t0 ? tx/((t1-t0)/1000.0) : 0)
                printf "total_gc_ms=%.0f\ntrace_duration_ms=%.0f\ntx_total=%d\nwarm_hits=%d\navg_tx_per_block=%.3f\ngc_ms_per_1000tx=%.3f\ntx_per_sec=%.3f\n",
                       gc, dur, tx, wh, (nblk>0 ? tx/nblk : 0), gc_per_1000tx, tps
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
Rate-Matched FIFO Control — Besu 4 GB / 15 TPS (DISABLED variant only)
=============================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)
Binary: ${BESU_BIN}
Heap:   -Xms4g -Xmx4g (G1GC, MaxGCPauseMillis=200)
Variant: DISABLED (plain FIFO), n=${REPLICATIONS}
Load:     15 TPS (vs 150 TPS canonical), 30 contracts × 200 slots, 120s warmup + 300s measure

Motivation: canonical n=5 Besu results show HFL/MATS/PREP/PREP_SCHED at ~26-28
gc_ms_per_1000tx vs Baseline's 66.6, but those variants also only achieve
43-57% of Baseline's actual tx/sec (14.6-19.5 vs 34.0). This experiment
throttles FIFO down to ~15 TPS -- matching the scheduling variants' achieved
rate -- to test whether the lower per-tx GC cost is a genuine locality
effect or a throughput artifact.

Decisive interpretation (pre-registered before running):
  - gc_ms_per_1000tx stays near ~66 (full-rate FIFO's value): locality
    effect is real and independent of throughput.
  - gc_ms_per_1000tx drops to ~26-28 (matching scheduling variants):
    the "locality benefit" is largely explained by lower throughput alone.
EOF

# ── Main loop ────────────────────────────────────────────────────────────────
TOTAL_RUNS=${REPLICATIONS}
echo "======================================================================"
echo "Rate-matched FIFO control [compute24] | 15 TPS | 120s+300s | ${TOTAL_RUNS} runs"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"

for rep in $(seq 1 ${REPLICATIONS}); do
    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    echo "REPLICATION ${rep}/${REPLICATIONS}"
    echo "══════════════════════════════════════════════════════════════════"

    run_single "fifo_15tps" ${rep} "-Dlast.variant=DISABLED" || true

    if [ ${rep} -lt ${REPLICATIONS} ]; then
        echo "  (inter-rep cooldown ${INTER_REP_COOLDOWN}s)"
        sleep ${INTER_REP_COOLDOWN}
    fi
done

echo ""
echo "======================================================================"
echo "Rate-matched FIFO control: all ${TOTAL_RUNS} runs complete."
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"
echo ""
echo "Per-rep GC summary (fifo_15tps):"
for rep in $(seq 1 ${REPLICATIONS}); do
    f="${RESULTS_DIR}/fifo_15tps_${rep}/gc_summary.txt"
    if [ -f "${f}" ]; then
        echo "  rep${rep}: $(grep gc_ms_per_1000tx "$f") $(grep tx_per_sec "$f")"
    else
        echo "  rep${rep}: NO SUMMARY (failed, check ${RESULTS_DIR}/fifo_15tps_${rep}/)"
    fi
done
