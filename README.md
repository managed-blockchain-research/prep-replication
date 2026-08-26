# PREP: Pre-Execution Admission Control

Replication package for PREP evaluation.

## Structure
- `configs/` — Caliper benchmark configurations
- `benchmarks/` — Caliper workload modules (transaction generators)
- `scripts/` — Run scripts
- `results/` — GC event and latency summary CSVs
- `src/` — Smart contract source

## NM harness: v1 vs v2

`scripts/run_prep_eval.sh` (v1, used for `results/prep_eval/20260515_184315_prep_eval`)
had 4 harness bugs that were found and fixed after the fact:

1. The GC-trace measurement window was stopped when the Caliper process exited,
   but that exit time is itself confounded by a treatment-dependent confirmation-
   drain tail — this made `trace_duration_s` (and therefore
   `total_pause_ms / trace_duration_s`) range 200-1470s across variants instead
   of a fixed, comparable window.
2. Every transaction used the same fixed `gasPrice`. Once Nethermind's TxPool
   filled up, a same-priced newcomer could never legitimately evict an
   already-pooled entry (ties lose), so the pool locked up permanently and
   every subsequent submission failed with `FeeTooLowToCompete`.
3. Three independent Caliper/web3.js timeouts (a custom `txWallClockTimeout`,
   web3.js's own `transactionPollingTimeout`, and `transactionBlockTimeout`)
   were all too short for this workload's confirmation latency under sustained
   150 TPS load, so many transactions that were genuinely mined were marked
   "Fail" anyway.
4. A `wait "$caliper_pid"` under `set -e` silently aborted the whole script
   (skipping all cleanup and reporting) whenever the internal `CALIPER_TIMEOUT`
   actually fired.

`scripts/run_prep_eval_v2.sh` fixes all four (paired with
`configs/benchconfig-prep-variedfee-150tps.yaml`,
`benchmarks/stateBloatVariedFee.js`, and `networkconfig_nethermind_prep.json`).
Bugs 1 and 4 are pure measurement/harness fixes. Bug 2's fix (`stateBloatVariedFee.js`)
is confirmed working — `FeeTooLowToCompete` drops to 0 and blocks stay
consistently near-full under load. Bug 3's fix is a genuine improvement but,
even after alignment, Caliper's own Succ/Fail/latency accounting still cannot
keep pace with 150 TPS once per-tx confirmation latency grows large under
backlog (by Little's Law, sustaining 150 TPS at ~150-280s average latency
would need on the order of tens of thousands of concurrent in-flight slots,
which is not a practical bound to raise). **Do not treat Caliper's own
Succ/Fail/latency numbers as reliable at this load level for this workload.**
The trustworthy sources — independent of Caliper's confirmation tracking — are:
- `last_metrics.csv` (NM's own LAST-scheduler log: `tx_count` per block,
  `warm_hits`, and for PREP/PREP_SCHED, `prep_admitted`/`prep_deferred`)
- `gc_summary.txt` (dotnet-trace parsed by `NettraceGcParser`, now on the fixed
  wall-clock window from fix 1)

A fire-and-forget dispatch workload (bounded per-worker semaphore + per-round
attempt cap) was also tried as an alternative to fix 3, but hits the same
Little's Law ceiling from a different angle and was not used in v2.

The old `results/prep_eval/20260515_184315_prep_eval` dataset predates these
fixes and should be treated as unreliable pending a v2 rerun.
