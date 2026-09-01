#!/bin/bash
# ============================================================
# PREP theta_p SMOKE TEST — Besu @ 4 GB heap
#
# NOT for reporting GC-pause numbers. Purpose: confirm that a
# recalibrated theta_p actually produces nonzero prep_deferred
# telemetry within a short window, before committing hardware
# time to the full n=5 x 3-theta sweep. One rep per theta value,
# PREP variant only (PREP_SCHED shares the same gate logic).
#
# Binary: besu-mats (besu-24.1.1 + PREP-patched blockcreation jar,
#         PREP_PRESSURE_THRESHOLD now reads -Dprep.theta_p, default 0.20)
# Load:   60s warmup + 90s measure, 150 TPS, 30 workers, 30 contracts
# Output: results/prep_theta_smoke/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

export JAVA_HOME="/home/yeochan.yoon/jdk17-portable"
export PATH="${JAVA_HOME}/bin:${PATH}"

BESU_BIN="/home/yeochan.yoon/besu-mats/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-prep-theta-smoke.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

HEAP="4g"
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
NO_LASS="-Dlass.old.gen.activation.threshold=2.0"

THETA_VALUES="0.04 0.05 0.07"
COOLDOWN_BETWEEN_RUNS=15
CALIPER_TIMEOUT=400

RUN_ID=$(date +%Y%m%d_%H%M%S)_prep_theta_smoke
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/prep_theta_smoke/${RUN_ID}"
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

    echo "  Running Caliper (60s warmup + 90s measure @ 150 TPS, smoke)..."
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
        gc_stats=$(awk -F, 'NR>1 {gc+=$15; dur+=$10; tx+=$4; wh+=$5; pa+=$21; pd+=$22}
            END {
                printf "total_gc_ms=%.0f\ntrace_duration_ms=%.0f\ntx_total=%d\nwarm_hits=%d\nprep_admitted=%d\nprep_deferred=%d\n",
                       gc, dur, tx, wh, pa, pd
            }' "${last_csv}")
        echo "${gc_stats}" > "${run_dir}/gc_summary.txt"
        echo "  LAST log: ${blocks} blocks"
        echo "  $(grep total_gc_ms "${run_dir}/gc_summary.txt" | head -1)"
        echo "  $(grep prep_deferred "${run_dir}/gc_summary.txt" | head -1)"
    fi

    local measure_line; measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"
    echo "  ✓ ${label} complete"
    echo ""
    sleep ${COOLDOWN_BETWEEN_RUNS}
}

# ── Provenance ────────────────────────────────────────────────────────────────
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
PREP theta_p SMOKE TEST — Besu 4 GB / 150 TPS / PREP variant only / 1 rep per theta
=====================================================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)
Binary: ${BESU_BIN}
Heap:   -Xms4g -Xmx4g (G1GC, MaxGCPauseMillis=200)
Theta values swept: ${THETA_VALUES}
Load:     150 TPS, 30 contracts × 200 slots, 60s warmup + 90s measure (SHORT WINDOW)
Purpose:  confirm nonzero prep_deferred at each candidate theta_p before
          committing to the full n=5 x 3-theta evaluation sweep.
NOT a result for the paper -- window too short for steady-state GC-pause numbers.
EOF

# ── Main loop ─────────────────────────────────────────────────────────────────
echo "======================================================================"
echo "PREP theta_p smoke test | 150 TPS | 60s+90s | PREP variant, 1 rep/theta"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"

for theta in ${THETA_VALUES}; do
    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    echo "THETA_P = ${theta}"
    echo "══════════════════════════════════════════════════════════════════"

    run_single "prep_theta${theta}" 1 "-Dlast.variant=PREP" "-Dprep.theta_p=${theta}" || true

    echo "  (cooldown ${COOLDOWN_BETWEEN_RUNS}s)"
    sleep ${COOLDOWN_BETWEEN_RUNS}
done

echo ""
echo "======================================================================"
echo "Smoke test complete for theta_p in: ${THETA_VALUES}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"
echo ""
echo "Checking deferral telemetry per theta:"
for theta in ${THETA_VALUES}; do
    summary="${RESULTS_DIR}/prep_theta${theta}_1/gc_summary.txt"
    if [ -f "${summary}" ]; then
        echo "  theta_p=${theta}: $(grep prep_deferred "${summary}") $(grep prep_admitted "${summary}")"
    else
        echo "  theta_p=${theta}: NO SUMMARY (run likely failed, check ${RESULTS_DIR}/prep_theta${theta}_1/)"
    fi
done
