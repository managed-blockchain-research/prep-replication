// SPDX-FileCopyrightText: 2025 LAST Research
// SPDX-License-Identifier: LGPL-3.0-only

// LastTxPoolTxSource — LAST/MATS-aware transaction ordering for NethDev experiments.
// Overrides GetOrderedTransactions in TxPoolTxSource to apply one of:
//   DISABLED  (default baseline)
//   AL        (address locality — coarse-grained consecutive sender-group ordering by destination)
//   WSA       (warm-set affinity — frequency-based warm-first partition, consecutive per sender)
//   WSA_EWMA  (EWMA-guided warm-set, consecutive grouping)
//   HFL_9_1   (hybrid fee+locality, α=0.9 β=0.1)
//   HFL_5_5   (hybrid fee+locality, α=0.5 β=0.5)
//   HFL_1_9   (hybrid fee+locality, α=0.1 β=0.9)
//   MATS      (memory-aware transaction scheduling — HFL with α/β driven by EWMA memory pressure)
//   MATS_RAW  (MATS ablation — same logic but uses raw block-level pressure instead of EWMA)
//
// Configuration via environment variables:
//   NETHERMIND_LAST_MODE=MATS      (which variant to use)
//   LAST_LOG_FILE=/tmp/last_gc.csv (where to write per-block GC metrics)
//
// GC metrics written per block (DISABLED/AL/WSA/HFL):
//   block_num,last_mode,tx_count,warm_hits,sched_us,g0,g1,g2,alloc_mb
//
// GC metrics written per block (MATS/MATS_RAW — extended schema):
//   block_num,last_mode,tx_count,warm_hits,sched_us,g0,g1,g2,alloc_mb,
//   mats_raw_pressure,mats_ewma_pressure,mats_alpha,mats_beta

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime;
using Nethermind.Config;
using Nethermind.Consensus.Comparers;
using Nethermind.Consensus.Transactions;
using Nethermind.Core;
using Nethermind.Core.Specs;
using Nethermind.Logging;
using Nethermind.TxPool;
using Nethermind.TxPool.Comparison;

namespace Nethermind.Consensus.Producers
{
    /// <summary>
    /// LAST-aware subclass of TxPoolTxSource for NethDev LAST evaluation.
    /// </summary>
    public class LastTxPoolTxSource : TxPoolTxSource
    {
        // ── EWMA constants (mirror StateLocalityTracker.java) ──────────────
        private const double EwmaDeltaTx    = 0.02;
        private const double EwmaDeltaBlock = 0.20;
        private const double EwmaTheta      = 0.05;

        // ── MATS memory signal sampler ─────────────────────────────────────
        // Computes a composite memory-pressure score ∈ [0, 1] per block from
        // three CLR GC signals, then maintains an EWMA for stable scheduling decisions.
        //
        // raw_t  = 0.5·heap_pct + 0.3·gc_freq_norm + 0.2·alloc_rate_norm
        // m_t    = λ·raw_t + (1−λ)·m_{t−1}   (λ = 0.2)
        //
        // Scheduling weights (continuous linear):
        //   α(p) = 0.7 − 0.5·p   (fee weight; 0.7 at idle → 0.2 at max pressure)
        //   β(p) = 0.3 + 0.5·p   (locality weight; 0.3 at idle → 0.8 at max pressure)
        private sealed class MatsSignalSampler
        {
            private const double Lambda      = 0.2;   // EWMA smoothing factor
            private const double GcFreqScale = 5.0;   // gen0 count/block → full pressure
            private const double AllocScale  = 200.0; // MB/block → full pressure

            private int  _prevG0;
            private long _prevAlloc;

            public double EwmaPressure { get; private set; }

            public MatsSignalSampler()
            {
                _prevG0      = GC.CollectionCount(0);
                _prevAlloc   = GC.GetTotalAllocatedBytes(precise: false);
                EwmaPressure = 0.0;
            }

            // Call once at block-assembly time. Returns raw pressure; updates EwmaPressure.
            public double Sample()
            {
                var gcInfo = GC.GetGCMemoryInfo();
                double heapPct = gcInfo.HeapSizeBytes > 0
                    ? Math.Min(1.0, (double)gcInfo.MemoryLoadBytes / gcInfo.HeapSizeBytes)
                    : 0.0;

                int curG0 = GC.CollectionCount(0);
                double gcFreqNorm = Math.Min(1.0, (curG0 - _prevG0) / GcFreqScale);
                _prevG0 = curG0;

                long curAlloc   = GC.GetTotalAllocatedBytes(precise: false);
                double allocMB  = (curAlloc - _prevAlloc) / 1_048_576.0;
                double allocNorm = Math.Min(1.0, allocMB / AllocScale);
                _prevAlloc = curAlloc;

                double raw   = 0.5 * heapPct + 0.3 * gcFreqNorm + 0.2 * allocNorm;
                EwmaPressure = Lambda * raw + (1.0 - Lambda) * EwmaPressure;
                return raw;
            }

            public static (double alpha, double beta) PressureToWeights(double pressure)
            {
                double alpha = Math.Max(0.05, 0.7 - 0.5 * pressure);
                double beta  = 1.0 - alpha;
                return (alpha, beta);
            }
        }

        // ── warm-set tracker ───────────────────────────────────────────────
        private sealed class WarmSetTracker
        {
            private readonly Dictionary<string, double> _scores = new();

            public double GetScore(string key)  => _scores.GetValueOrDefault(key, 0.0);
            public bool   IsWarm(string key)    => GetScore(key) >= EwmaTheta;

            public void RecordAccess(string key)
            {
                double prev = _scores.GetValueOrDefault(key, 0.0);
                _scores[key] = prev * (1.0 - EwmaDeltaTx) + EwmaDeltaTx;
            }

            public void OnBlockEnd()
            {
                string[] keys = [.. _scores.Keys];
                foreach (string k in keys)
                {
                    double v = _scores[k] * (1.0 - EwmaDeltaBlock);
                    if (v < 1e-6) _scores.Remove(k);
                    else          _scores[k] = v;
                }
            }

            public void Reset() => _scores.Clear();
        }

        // ── state ──────────────────────────────────────────────────────────
        private enum LastMode { Disabled, AL, WSA, WsaEwma, Hfl, Mats, MatsRaw }

        private readonly LastMode       _mode;
        private readonly double         _hflAlpha;
        private readonly double         _hflBeta;
        private readonly string         _modeLabel;
        private readonly WarmSetTracker _tracker = new();
        private readonly MatsSignalSampler? _matsSampler;
        private readonly StreamWriter?  _logWriter;
        private readonly bool           _isMatsMode;
        private long _blockCount;

        // running GC counters (for delta computation)
        private int  _prevG0, _prevG1, _prevG2;
        private long _prevAlloc;

        public LastTxPoolTxSource(
            ITxPool transactionPool,
            ISpecProvider specProvider,
            ITransactionComparerProvider transactionComparerProvider,
            ILogManager logManager,
            ITxFilterPipeline txFilterPipeline,
            IBlocksConfig blocksConfig)
            : base(transactionPool, specProvider, transactionComparerProvider, logManager, txFilterPipeline, blocksConfig)
        {
            string rawMode = Environment.GetEnvironmentVariable("NETHERMIND_LAST_MODE") ?? "DISABLED";
            (_mode, _hflAlpha, _hflBeta, _modeLabel) = ParseMode(rawMode.ToUpperInvariant().Trim());

            _isMatsMode = _mode == LastMode.Mats || _mode == LastMode.MatsRaw;
            if (_isMatsMode) _matsSampler = new MatsSignalSampler();

            string? logFile = Environment.GetEnvironmentVariable("LAST_LOG_FILE");
            if (!string.IsNullOrEmpty(logFile))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(logFile)!);
                _logWriter = new StreamWriter(logFile, append: false) { AutoFlush = true };
                string header = "block_num,last_mode,tx_count,warm_hits,sched_us,g0,g1,g2,alloc_mb";
                if (_isMatsMode) header += ",mats_raw_pressure,mats_ewma_pressure,mats_alpha,mats_beta";
                _logWriter.WriteLine(header);
            }

            // Snapshot initial GC state
            _prevG0    = GC.CollectionCount(0);
            _prevG1    = GC.CollectionCount(1);
            _prevG2    = GC.CollectionCount(2);
            _prevAlloc = GC.GetTotalAllocatedBytes(precise: false);

            _logger.Info($"LAST TxSource initialized: mode={_modeLabel}, logFile={logFile ?? "(none)"}");
        }

        private static (LastMode mode, double alpha, double beta, string label) ParseMode(string raw) => raw switch
        {
            "AL"       => (LastMode.AL,      0,   0,   "AL"),
            "WSA"      => (LastMode.WSA,     0,   0,   "WSA"),
            "WSA_EWMA" => (LastMode.WsaEwma, 0,   0,   "WSA_EWMA"),
            "HFL_9_1"  => (LastMode.Hfl,    0.9, 0.1,  "HFL_9_1"),
            "HFL_5_5"  => (LastMode.Hfl,    0.5, 0.5,  "HFL_5_5"),
            "HFL_1_9"  => (LastMode.Hfl,    0.1, 0.9,  "HFL_1_9"),
            "MATS"     => (LastMode.Mats,    0,   0,   "MATS"),
            "MATS_RAW" => (LastMode.MatsRaw, 0,   0,   "MATS_RAW"),
            _          => (LastMode.Disabled, 0,  0,   "DISABLED"),
        };

        protected override IEnumerable<Transaction> GetOrderedTransactions(
            IDictionary<AddressAsKey, Transaction[]> pendingTransactions,
            IComparer<Transaction> comparer,
            Func<Transaction, bool> filter,
            long gasLimit)
        {
            if (_mode == LastMode.Disabled)
            {
                var baseResult = Order(pendingTransactions, comparer, filter, gasLimit).ToList();
                LogBlock(baseResult.Count, 0, 0L);
                return baseResult;
            }

            // Sample MATS signals before scheduling (captures pre-scheduling memory state)
            double matsRaw  = -1;
            double matsEwma = -1;
            double matsAlpha = -1;
            double matsBeta  = -1;
            if (_isMatsMode)
            {
                matsRaw  = _matsSampler!.Sample();
                matsEwma = _matsSampler.EwmaPressure;
                double decisionPressure = _mode == LastMode.Mats ? matsEwma : matsRaw;
                (matsAlpha, matsBeta) = MatsSignalSampler.PressureToWeights(decisionPressure);
            }

            // Measure scheduling overhead
            var sw = Stopwatch.StartNew();

            // Step 1: Get baseline ordered list (respects gas limit, fee filter, nonce order)
            List<Transaction> baseTxs = Order(pendingTransactions, comparer, filter, gasLimit).ToList();

            if (baseTxs.Count == 0)
            {
                sw.Stop();
                LogBlock(0, 0, 0L, matsRaw, matsEwma, matsAlpha, matsBeta);
                return baseTxs;
            }

            // Step 2: Apply LAST/MATS reordering
            (List<Transaction> reordered, int warmHits) = _mode switch
            {
                LastMode.AL      => ApplyLastAl(baseTxs),
                LastMode.WSA     => ApplyLastWsa(baseTxs),
                LastMode.WsaEwma => ApplyLastWsaEwma(baseTxs),
                LastMode.Hfl     => ApplyLastHfl(baseTxs, _hflAlpha, _hflBeta),
                LastMode.Mats    => ApplyLastHfl(baseTxs, matsAlpha, matsBeta),
                LastMode.MatsRaw => ApplyLastHfl(baseTxs, matsAlpha, matsBeta),
                _                => (baseTxs, 0),
            };

            sw.Stop();
            long schedUs = sw.ElapsedTicks * 1_000_000L / Stopwatch.Frequency;
            LogBlock(reordered.Count, warmHits, schedUs, matsRaw, matsEwma, matsAlpha, matsBeta);

            return reordered;
        }

        // ── LAST-AL: group by destination address, consecutive per dest ────
        private static (List<Transaction>, int warmHits) ApplyLastAl(List<Transaction> txs)
        {
            // Group sender chains by their primary destination (first tx.To)
            var destGroups = new Dictionary<string, List<Transaction>>();
            var destOrder  = new List<string>();
            var noDestList = new List<Transaction>();

            foreach (Transaction tx in txs)
            {
                string dest = tx.To?.ToString() ?? "__null__";
                if (!destGroups.ContainsKey(dest)) { destGroups[dest] = new(); destOrder.Add(dest); }
                destGroups[dest].Add(tx);
            }

            var result = new List<Transaction>(txs.Count);
            foreach (string dest in destOrder) result.AddRange(destGroups[dest]);

            // warm_hits approximation: txs in the largest dest group beyond the first tx
            int warmHits = destGroups.Values.Sum(g => g.Count - 1);
            return (result, warmHits);
        }

        // ── LAST-WSA: warm-set affinity (frequency-based, partition only) ─
        private static (List<Transaction>, int warmHits) ApplyLastWsa(List<Transaction> txs)
        {
            // Classify destinations by call frequency
            var freq = new Dictionary<string, int>();
            foreach (Transaction tx in txs)
            {
                string dest = tx.To?.ToString() ?? "__null__";
                freq[dest] = freq.GetValueOrDefault(dest) + 1;
            }

            double medFreq = Median(freq.Values.ToList());

            // Warm-first, cold-second; NOT consecutive within groups (honest negative)
            var warm = new List<Transaction>(); var cold = new List<Transaction>();
            foreach (Transaction tx in txs)
            {
                string dest = tx.To?.ToString() ?? "__null__";
                if (freq[dest] >= medFreq) warm.Add(tx); else cold.Add(tx);
            }

            var result = new List<Transaction>(txs.Count);
            result.AddRange(warm);
            result.AddRange(cold);
            int warmHits = warm.Count > 0 ? warm.Count - freq.Count(kv => kv.Value >= medFreq) : 0;
            return (result, Math.Max(0, warmHits));
        }

        // ── LAST-WSA-EWMA: EWMA-guided consecutive grouping ───────────────
        private (List<Transaction>, int warmHits) ApplyLastWsaEwma(List<Transaction> txs)
        {
            // Update tracker with block's txs
            foreach (Transaction tx in txs)
                _tracker.RecordAccess(tx.To?.ToString() ?? "__null__");

            // Partition warm/cold, emit consecutively within each
            var warmGroups = new Dictionary<string, List<Transaction>>();
            var coldGroups = new Dictionary<string, List<Transaction>>();
            var warmOrder  = new List<string>(); var coldOrder = new List<string>();
            int warmHits   = 0;

            foreach (Transaction tx in txs)
            {
                string dest = tx.To?.ToString() ?? "__null__";
                if (_tracker.IsWarm(dest))
                {
                    if (!warmGroups.ContainsKey(dest)) { warmGroups[dest] = new(); warmOrder.Add(dest); }
                    else warmHits++;
                    warmGroups[dest].Add(tx);
                }
                else
                {
                    if (!coldGroups.ContainsKey(dest)) { coldGroups[dest] = new(); coldOrder.Add(dest); }
                    coldGroups[dest].Add(tx);
                }
            }

            var result = new List<Transaction>(txs.Count);
            foreach (string d in warmOrder) result.AddRange(warmGroups[d]);
            foreach (string d in coldOrder) result.AddRange(coldGroups[d]);

            _tracker.OnBlockEnd();
            return (result, warmHits);
        }

        // ── LAST-HFL: hybrid fee+locality scoring ─────────────────────────
        private (List<Transaction>, int warmHits) ApplyLastHfl(
            List<Transaction> txs, double alpha, double beta)
        {
            if (txs.Count == 0) return (txs, 0);

            // Normalize max gas price in this block as fee proxy
            ulong maxGas = txs.Max(tx => (ulong)tx.GasPrice);
            ulong minGas = txs.Min(tx => (ulong)tx.GasPrice);
            ulong feeRange = maxGas - minGas;

            // Score each tx: σ = α×fee_norm + β×ewma_score
            var scored = txs.Select(tx =>
            {
                string dest     = tx.To?.ToString() ?? "__null__";
                ulong  gasPrice = (ulong)tx.GasPrice;
                double feeNorm  = feeRange > 0 ? (double)(gasPrice - minGas) / feeRange : 0.5;
                double sigma    = alpha * feeNorm + beta * _tracker.GetScore(dest);
                return (tx, dest, sigma);
            }).ToList();

            // Group by destination, compute group score = max sigma in group
            var groupScore = new Dictionary<string, double>();
            foreach (var (tx, dest, sigma) in scored)
            {
                if (!groupScore.ContainsKey(dest) || sigma > groupScore[dest])
                    groupScore[dest] = sigma;
            }

            // Sort destinations by group score descending
            var sortedDests = groupScore.Keys.OrderByDescending(d => groupScore[d]).ToList();

            // Emit groups consecutively in score order
            var groups = scored.GroupBy(x => x.dest)
                               .ToDictionary(g => g.Key, g => g.Select(x => x.tx).ToList());

            var result = new List<Transaction>(txs.Count);
            int warmHits = 0;
            foreach (string dest in sortedDests)
            {
                var grp = groups[dest];
                // Update tracker with this group's accesses
                foreach (Transaction tx in grp) _tracker.RecordAccess(dest);
                if (_tracker.IsWarm(dest)) warmHits += grp.Count - 1;
                result.AddRange(grp);
            }

            _tracker.OnBlockEnd();
            return (result, warmHits);
        }

        private void LogBlock(int txCount, int warmHits, long schedUs,
                              double matsRaw = -1, double matsEwma = -1,
                              double matsAlpha = -1, double matsBeta = -1)
        {
            _blockCount++;
            if (_logWriter is null) return;

            int g0  = GC.CollectionCount(0);
            int g1  = GC.CollectionCount(1);
            int g2  = GC.CollectionCount(2);
            long al = GC.GetTotalAllocatedBytes(precise: false);

            int  dg0 = g0 - _prevG0; int dg1 = g1 - _prevG1; int dg2 = g2 - _prevG2;
            double dAllocMB = (al - _prevAlloc) / (1024.0 * 1024.0);

            _prevG0 = g0; _prevG1 = g1; _prevG2 = g2; _prevAlloc = al;

            string line = $"{_blockCount},{_modeLabel},{txCount},{warmHits},{schedUs},{dg0},{dg1},{dg2},{dAllocMB:F3}";
            if (_isMatsMode)
                line += $",{matsRaw:F4},{matsEwma:F4},{matsAlpha:F4},{matsBeta:F4}";
            _logWriter.WriteLine(line);
        }

        private static double Median(List<int> vals)
        {
            if (vals.Count == 0) return 0;
            vals.Sort();
            int n = vals.Count;
            return n % 2 == 0 ? (vals[n/2-1] + vals[n/2]) / 2.0 : vals[n/2];
        }
    }
}
