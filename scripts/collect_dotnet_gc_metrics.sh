#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <pid> <duration_dd:hh:mm:ss> <output_dir>"
  echo "Example: $0 12345 00:10:00 results/nethermind/metrics"
  exit 1
fi

PID="$1"
DURATION="$2"
OUTPUT_DIR="$3"

if ! ps -p "${PID}" > /dev/null 2>&1; then
  echo "ERROR: PID ${PID} is not running."
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="${OUTPUT_DIR}/dotnet_counters_${TIMESTAMP}.csv"

echo "Collecting .NET GC/memory counters from PID ${PID}"
echo "Duration: ${DURATION}"
echo "Output:   ${OUT_FILE}"

# System.Runtime exposes GC + LOH counters (gc-heap-size, gen0/1/2 counts,
# time-in-gc, alloc-rate, loh-size, loh-fragmentation, pinned-objects-size, etc.)
dotnet-counters collect \
  --process-id "${PID}" \
  --counters "System.Runtime" \
  --refresh-interval 1 \
  --duration "${DURATION}" \
  --format csv \
  --output "${OUT_FILE}"

echo "Done. Wrote: ${OUT_FILE}"
