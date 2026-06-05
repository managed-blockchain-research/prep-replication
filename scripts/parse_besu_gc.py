#!/usr/bin/env python3
"""
Parser 1 — Besu G1GC Log Parser
Reads Besu's -Xlog:gc*:file=gc_besu.log and outputs:
  1. Per-event CSV:  variant,run,type,pause_ms
  2. Per-run summary Markdown table with Total GC Time and Full GC event count

Usage:
  # Single file:
  python3 parse_besu_gc.py --log results/baseline_1/gc_besu.log --variant baseline --run 1

  # Aggregate an entire results directory:
  python3 parse_besu_gc.py --results-dir results/scenario_b_besu_1g_ddos/<RUN_ID> \
                           --out-csv /tmp/besu_gc_events.csv
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict

import numpy as np

# Matches the completion line of any stop-the-world pause event.
# Format:  [timestamp][uptime][level][gc          ] GC(N) Pause TYPE ... X.XXXms
# We skip gc,start lines (they have no duration).
_PAUSE_RE = re.compile(
    r"\[gc\s+\]\s+GC\(\d+\)\s+Pause\s+(Young|Mixed|Full|Remark|Cleanup)"
    r".*?(\d+\.\d+)ms\s*$"
)

GC_TYPES = ("Young", "Mixed", "Full")


def parse_one_log(log_path: str) -> list[dict]:
    """Return list of {type, pause_ms} dicts from a single gc log file."""
    events = []
    try:
        with open(log_path, errors="replace") as f:
            for line in f:
                m = _PAUSE_RE.search(line)
                if m:
                    gc_type = m.group(1)
                    pause_ms = float(m.group(2))
                    if gc_type in GC_TYPES:
                        events.append({"type": gc_type, "pause_ms": pause_ms})
    except OSError as e:
        print(f"  WARNING: cannot read {log_path}: {e}", file=sys.stderr)
    return events


def summarise_run(events: list[dict]) -> dict:
    """Compute per-run aggregate stats."""
    all_ms = [e["pause_ms"] for e in events]
    full_ms = [e["pause_ms"] for e in events if e["type"] == "Full"]
    young_ms = [e["pause_ms"] for e in events if e["type"] == "Young"]
    mixed_ms = [e["pause_ms"] for e in events if e["type"] == "Mixed"]

    def _stats(vals):
        if not vals:
            return dict(n=0, mean=0, p50=0, p95=0, p99=0, max=0, total=0)
        return dict(
            n=len(vals),
            mean=float(np.mean(vals)),
            p50=float(np.percentile(vals, 50)),
            p95=float(np.percentile(vals, 95)),
            p99=float(np.percentile(vals, 99)),
            max=float(max(vals)),
            total=float(sum(vals)),
        )

    return {
        "all":   _stats(all_ms),
        "young": _stats(young_ms),
        "mixed": _stats(mixed_ms),
        "full":  _stats(full_ms),
        "total_gc_time_ms":  sum(all_ms),
        "full_gc_count":     len(full_ms),
        "total_event_count": len(all_ms),
    }


def discover_runs(results_dir: str) -> list[tuple[str, int, str]]:
    """Walk results_dir/<variant>_<rep>/ and return (variant, rep, gc_log_path) tuples."""
    runs = []
    for entry in sorted(os.listdir(results_dir)):
        run_dir = os.path.join(results_dir, entry)
        if not os.path.isdir(run_dir):
            continue
        # Expect names like: baseline_1, last_hfl_lass75_3, etc.
        parts = entry.rsplit("_", 1)
        if len(parts) != 2 or not parts[1].isdigit():
            continue
        variant, rep = parts[0], int(parts[1])
        for gc_name in ("gc_besu.log", "gc.log"):
            gc_path = os.path.join(run_dir, gc_name)
            if os.path.exists(gc_path):
                runs.append((variant, rep, gc_path))
                break
    return runs


def print_markdown_table(per_variant: dict):
    """Print the two Markdown tables (per-run summary + cross-rep aggregate)."""

    variants = list(per_variant.keys())

    # ── Per-run table ─────────────────────────────────────────────────────────
    print("\n## Per-Run GC Summary\n")
    header = ("Run", "Total GC Time (ms)", "Full GC Events",
              "Young GC Count", "Mixed GC Count",
              "Mean Pause (ms)", "p95 Pause (ms)", "Max Pause (ms)")
    print("| " + " | ".join(header) + " |")
    print("|" + "|".join(["-" * (len(h) + 2) for h in header]) + "|")

    for variant in variants:
        for rep, s in per_variant[variant]:
            cells = [
                f"{variant}_{rep}",
                f"{s['total_gc_time_ms']:.0f}",
                f"{s['full_gc_count']}",
                f"{s['young']['n']}",
                f"{s['mixed']['n']}",
                f"{s['all']['mean']:.1f}",
                f"{s['all']['p95']:.1f}",
                f"{s['all']['max']:.1f}",
            ]
            print("| " + " | ".join(cells) + " |")

    # ── Cross-rep aggregate table ──────────────────────────────────────────────
    print("\n## Aggregate GC Statistics (mean ± sd across reps)\n")
    agg_header = ("Variant", "Reps",
                  "Total GC Time/run (ms)", "Full GCs/run",
                  "Mean Pause (ms)", "p95 Pause (ms)", "p99 Pause (ms)", "Max Pause (ms)")
    print("| " + " | ".join(agg_header) + " |")
    print("|" + "|".join(["-" * (len(h) + 2) for h in agg_header]) + "|")

    for variant in variants:
        reps_data = [s for _, s in per_variant[variant]]
        if not reps_data:
            continue

        def _col(key, sub=None):
            vals = [d[sub][key] if sub else d[key] for d in reps_data]
            return f"{np.mean(vals):.1f} ± {np.std(vals):.1f}"

        cells = [
            variant,
            str(len(reps_data)),
            _col("total_gc_time_ms"),
            _col("full_gc_count"),
            _col("mean", "all"),
            _col("p95", "all"),
            _col("p99", "all"),
            _col("max", "all"),
        ]
        print("| " + " | ".join(cells) + " |")

    # ── Totals footer (requested) ──────────────────────────────────────────────
    print("\n### Total GC Time and Full GC Events per Run\n")
    print("| Run | Total GC Time (ms) | Total Full GC Events |")
    print("|-----|-------------------|----------------------|")
    for variant in variants:
        for rep, s in per_variant[variant]:
            print(f"| {variant}_{rep} | {s['total_gc_time_ms']:.0f} | {s['full_gc_count']} |")


def main():
    p = argparse.ArgumentParser(description="Besu G1GC log parser")
    p.add_argument("--log",         help="Single gc log file")
    p.add_argument("--variant",     default="unknown", help="Variant label for single-file mode")
    p.add_argument("--run",         type=int, default=1, help="Rep number for single-file mode")
    p.add_argument("--results-dir", help="Directory containing <variant>_<rep>/ subdirs")
    p.add_argument("--out-csv",     default=None, help="Write per-event CSV to this path")
    args = p.parse_args()

    # Collect runs
    if args.results_dir:
        runs = discover_runs(args.results_dir)
        if not runs:
            sys.exit(f"ERROR: no gc log files found under {args.results_dir}")
    elif args.log:
        runs = [(args.variant, args.run, args.log)]
    else:
        sys.exit("ERROR: provide --log or --results-dir")

    # Parse
    all_events_rows = []
    per_variant: dict[str, list] = defaultdict(list)

    for variant, rep, log_path in runs:
        print(f"  Parsing {variant}_{rep}: {log_path}", file=sys.stderr)
        events = parse_one_log(log_path)
        s = summarise_run(events)
        per_variant[variant].append((rep, s))
        print(f"    → events={s['total_event_count']}  full={s['full_gc_count']}"
              f"  total_ms={s['total_gc_time_ms']:.0f}"
              f"  p99={s['all']['p99']:.1f}  max={s['all']['max']:.1f}", file=sys.stderr)
        for e in events:
            all_events_rows.append({
                "variant": variant, "run": rep,
                "type": e["type"], "pause_ms": e["pause_ms"],
            })

    # Write per-event CSV
    if args.out_csv:
        os.makedirs(os.path.dirname(os.path.abspath(args.out_csv)), exist_ok=True)
        with open(args.out_csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["variant", "run", "type", "pause_ms"])
            w.writeheader()
            w.writerows(all_events_rows)
        print(f"\nPer-event CSV: {args.out_csv}  ({len(all_events_rows)} events)", file=sys.stderr)

    # Print Markdown
    print_markdown_table(per_variant)


if __name__ == "__main__":
    main()
