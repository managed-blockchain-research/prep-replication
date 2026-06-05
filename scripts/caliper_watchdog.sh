#!/bin/bash
# caliper_watchdog.sh — kills stuck caliper (Unfinished:1 for >30s) so the
# harness doesn't wait the full 1500s CALIPER_TIMEOUT.
# Run once in the background; kills itself when the harness PID exits.

HARNESS_PID="${1:?Usage: $0 <HARNESS_PID> [RESULTS_BASE]}"
RESULTS_BASE="${2:-/home/yeochan.yoon/caliper-stress-test/results}"
LOG="/home/yeochan.yoon/caliper-stress-test/caliper_watchdog.log"

echo "[$(date)] Watchdog started, monitoring harness PID ${HARNESS_PID}" | tee -a "${LOG}"

consecutive=0

while kill -0 "${HARNESS_PID}" 2>/dev/null; do
    # Find the most recently modified caliper_console.log
    latest=$(find "${RESULTS_BASE}" -name "caliper_console.log" 2>/dev/null \
        | xargs ls -t 2>/dev/null | head -1)

    if [ -n "${latest}" ]; then
        # Check if last line contains "Unfinished:1" (exactly 1)
        last_line=$(tail -1 "${latest}" 2>/dev/null)
        if echo "${last_line}" | grep -qE "Unfinished:[1-9]([^0-9]|$)"; then
            consecutive=$((consecutive + 1))
            if [ "${consecutive}" -ge 6 ]; then
                # 6 × 5s = 30s of Unfinished:1 → kill caliper
                echo "[$(date)] Unfinished:1 for ${consecutive} checks (${latest}). Killing caliper." | tee -a "${LOG}"
                pkill -TERM -u "$(whoami)" -f "caliper launch" 2>/dev/null || true
                sleep 3
                pkill -KILL -u "$(whoami)" -f "caliper launch" 2>/dev/null || true
                echo "[$(date)] Caliper killed." | tee -a "${LOG}"
                consecutive=0
                sleep 15  # wait for harness to process the kill
            fi
        else
            consecutive=0
        fi
    fi

    sleep 5
done

echo "[$(date)] Harness PID ${HARNESS_PID} exited. Watchdog done." | tee -a "${LOG}"
