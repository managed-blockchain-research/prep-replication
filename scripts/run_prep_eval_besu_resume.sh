#!/bin/bash
# ============================================================
# PREP Evaluation Besu — RESUME SCRIPT
#
# Resumes run 20260518_074856_prep_eval_besu from mats_2.
# Skips runs that already have gc_summary.txt.
# Pre-flight: checks load average and free memory.
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

# ── Fixed run identity ─────────────────────────────────────────────────────────
RESUME_RUN_ID="20260518_074856_prep_eval_besu"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/prep_eval_besu/${RESUME_RUN_ID}"

# ── Config (must match original run) ──────────────────────────────────────────
BESU_BIN="/home/yeochan.yoon/besu-mats/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-last-vs-lass-nm.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

HEAP="4g"
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
NO_LASS="-Dlass.old.gen.activation.threshold=2.0"

REPLICATIONS=5
COOLDOWN_BETWEEN_RUNS=30
INTER_REP_COOLDOWN=90
CALIPER_TIMEOUT=1500

# server idle: load5 < 4.0 AND MemAvailable > 80 GB AND no other Besu
IDLE_LOAD_THRESH=20
IDLE_MEM_THRESH_GB=18
IDLE_POLL_INTERVAL=600  # seconds between polls when server is busy
IDLE_MAX_WAIT=28800     # give up after 8 hours

# ── wait_for_idle: block until server is quiet, then return ───────────────────
# Prints a one-line status on each poll. Silent on the happy path.
wait_for_idle() {
    local waited=0
    while true; do
        local load5; load5=$(awk '{print $2}' /proc/loadavg)
        local load5_int; load5_int=$(echo "$load5" | cut -d. -f1)
        local mem_gb; mem_gb=$(awk '/MemAvailable/{print int($2/1024/1024)}' /proc/meminfo)
        local besu_running=0
        for _pid in $(pgrep -f "hyperledger.besu.Besu" 2>/dev/null); do
            [ "$(cat /proc/$_pid/comm 2>/dev/null)" = "java" ] && besu_running=1 && break
        done

        if [ "$load5_int" -lt "$IDLE_LOAD_THRESH" ] \
           && [ "$mem_gb" -gt "$IDLE_MEM_THRESH_GB" ] \
           && [ "$besu_running" -eq 0 ]; then
            [ "$waited" -gt 0 ] && echo "  [idle] load5=${load5} mem=${mem_gb}GB — resuming."
            return 0
        fi

        echo "  [busy] load5=${load5} mem=${mem_gb}GB besu=${besu_running} — waiting ${IDLE_POLL_INTERVAL}s..."
        sleep "$IDLE_POLL_INTERVAL"
        waited=$(( waited + IDLE_POLL_INTERVAL ))

        if [ "$waited" -ge "$IDLE_MAX_WAIT" ]; then
            echo "  [ERROR] Server still busy after ${IDLE_MAX_WAIT}s. Giving up."
            exit 1
        fi
    done
}

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

    # ── Skip if already complete ───────────────────────────────────────────────
    if [ -f "${run_dir}/gc_summary.txt" ] && [ -f "${run_dir}/report.html" ]; then
        echo "  [SKIP] ${label} — already complete"
        return 0
    fi

    # ── Wait until server is idle before starting this run ────────────────────
    echo "  Waiting for idle server before ${label}..."
    wait_for_idle

    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_bprep_${label}_${RESUME_RUN_ID}"
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

    if [ -f "${last_csv}" ]; then
        local blocks; blocks=$(( $(wc -l < "${last_csv}") - 1 ))
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

    # Clean up transient caliper.log in workspace root after each run
    rm -f /home/yeochan.yoon/caliper-stress-test/caliper.log 2>/dev/null || true

    echo ""
    sleep ${COOLDOWN_BETWEEN_RUNS}
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "======================================================================"
echo "PREP Eval Besu — RESUME | Run ID: ${RESUME_RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "Started: $(date)"
echo "======================================================================"

for rep in $(seq 1 ${REPLICATIONS}); do
    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    echo "REPLICATION ${rep}/${REPLICATIONS}"
    echo "══════════════════════════════════════════════════════════════════"

    run_single "baseline"   ${rep} "-Dlast.variant=DISABLED" || true
    run_single "last_hfl"   ${rep} "-Dlast.variant=HYBRID_FEE_LOCALITY" "-Dlast.alpha=0.5 -Dlast.beta=0.5" || true
    run_single "mats"       ${rep} "-Dlast.variant=MATS" || true
    run_single "prep"       ${rep} "-Dlast.variant=PREP" || true
    run_single "prep_sched" ${rep} "-Dlast.variant=PREP_SCHED" || true

    if [ ${rep} -lt ${REPLICATIONS} ]; then
        echo "  (inter-rep cooldown ${INTER_REP_COOLDOWN}s)"
        sleep ${INTER_REP_COOLDOWN}
    fi
done

echo ""
echo "======================================================================"
echo "All runs complete. Run ID: ${RESUME_RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "Finished: $(date)"
echo "======================================================================"

# ── Post-processing ───────────────────────────────────────────────────────────
NM_RESULTS="/home/yeochan.yoon/caliper-stress-test/results/prep_eval/20260515_184315_prep_eval"
echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running fill_todos.py all_prep..."
cd /home/yeochan.yoon/banning/papers
python3 fill_todos.py all_prep "${NM_RESULTS}" "${RESULTS_DIR}" 2>&1 || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Post-processing done."
