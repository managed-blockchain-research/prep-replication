// SPDX-FileCopyrightText: 2025 LAST/MATS/PREP Research
// SPDX-License-Identifier: Apache-2.0
//
// Reconstructed from besu-24.1.1 bytecode and extended with MATS / PREP variants.
//
// Original variants (from besu-24.1.1):
//   DISABLED              — FIFO, no reordering
//   ADDRESS_LOCALITY      — group by destination address, largest groups first
//   WORKING_SET_AFFINITY  — warm-first partition, sorted by group size
//   HYBRID_FEE_LOCALITY   — HFL score = alpha*fee_norm + beta*locality_score
//
// MATS extension:
//   MATS      — HFL with alpha/beta driven by EWMA JVM GC pressure signal
//   MATS_RAW  — same but uses raw (non-EWMA) pressure (ablation baseline)
//
// PREP extension:
//   PREP      — admission gate defers cold txs when EWMA pressure > θ_p (0.20)
//   PREP_SCHED — PREP gate + boosted locality weight β' = min(β+0.30, 0.95)
//
// Pressure signal (JVM version):
//   raw_t  = 0.5*heap_pct + 0.3*gc_freq_norm + 0.2*gc_time_norm
//   ewma_t = 0.2*raw_t + 0.8*ewma_{t-1}
//   alpha(p) = max(0.05, 0.7 - 0.5*p)   beta(p) = 1 - alpha(p)
//
// PREP gate:
//   activate when ewma > PrepPressureThreshold (0.20)
//   admitThreshold = WARM_SCORE_BASE + ewma * 0.30
//   coldBudget = floor((1 - ewma) * PrepColdBudgetFrac * |B|)
//   starvation guard: admit after PrepMaxDeferrals (3) consecutive deferrals
//
// Configuration:
//   -Dlast.variant=PREP          (or PREP_SCHED, MATS, MATS_RAW, ...)
//   -Dlast.log.path=/path/to.csv
//   (alpha/beta ignored for MATS/PREP — computed dynamically)

package org.hyperledger.besu.ethereum.blockcreation.txselection;

import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.TimeUnit;
import org.hyperledger.besu.datatypes.Address;
import org.hyperledger.besu.datatypes.Hash;
import org.hyperledger.besu.datatypes.Wei;
import org.hyperledger.besu.ethereum.core.Transaction;
import org.hyperledger.besu.ethereum.eth.transactions.PendingTransaction;

public class LASTScheduler {

    // ── Variant enum ─────────────────────────────────────────────────────────
    public enum Variant {
        DISABLED,
        ADDRESS_LOCALITY,
        WORKING_SET_AFFINITY,
        HYBRID_FEE_LOCALITY,
        MATS,
        MATS_RAW,
        PREP,
        PREP_SCHED;
    }

    // ── PREP constants ────────────────────────────────────────────────────────
    // theta_p is overridable via -Dprep.theta_p=<value> for runtime-specific
    // calibration sweeps; defaults to the CLR-calibrated 0.20 used throughout
    // the original NM/Besu evaluation.
    private static final double PREP_PRESSURE_THRESHOLD =
            Double.parseDouble(System.getProperty("prep.theta_p", "0.20"));
    private static final double PREP_COLD_BUDGET_FRAC   = 0.25;
    private static final int    PREP_MAX_DEFERRALS       = 3;
    private static final double PREP_COST_PENALTY        = 0.30;
    private static final double WARM_SCORE_BASE          = 0.05;  // tanh(raw=0.05) ≈ 0.05

    // ── MATS JVM pressure sampler ─────────────────────────────────────────────
    private static final class MatsSignalSampler {
        private static final double LAMBDA     = 0.2;
        private static final double GC_SCALE   = 5.0;   // old-gen collections per block → full pressure
        private static final double TIME_SCALE = 500.0;  // old-gen pause ms per block → full pressure

        private final List<GarbageCollectorMXBean> gcBeans =
                ManagementFactory.getGarbageCollectorMXBeans();
        private long   prevOldCount = 0L;
        private long   prevOldMs    = 0L;
        private double ewma         = 0.0;

        /** Sample at block-assembly time. Updates EWMA. Returns raw pressure. */
        public double sample() {
            Runtime rt = Runtime.getRuntime();
            double heapPct = (double)(rt.totalMemory() - rt.freeMemory()) / (double)rt.maxMemory();

            long oldCount = 0L, oldMs = 0L;
            for (GarbageCollectorMXBean gc : gcBeans) {
                if (!isOldGen(gc.getName())) continue;
                long cnt = gc.getCollectionCount();
                long ms  = gc.getCollectionTime();
                if (cnt >= 0) oldCount += cnt;
                if (ms  >= 0) oldMs    += ms;
            }
            double gcFreqNorm = Math.min(1.0, (double)(oldCount - prevOldCount) / GC_SCALE);
            double gcTimeNorm = Math.min(1.0, (double)(oldMs    - prevOldMs)    / TIME_SCALE);
            prevOldCount = oldCount;
            prevOldMs    = oldMs;

            double raw = 0.5 * heapPct + 0.3 * gcFreqNorm + 0.2 * gcTimeNorm;
            ewma = LAMBDA * raw + (1.0 - LAMBDA) * ewma;
            return raw;
        }

        public double getEwma() { return ewma; }

        private static boolean isOldGen(String name) {
            String n = name.toLowerCase();
            return n.contains("old") || n.contains("marksweep") ||
                   n.contains("concurrent") || n.contains("zgc") || n.contains("shenandoah");
        }

        /** alpha(p) = max(0.05, 0.7 - 0.5*p), beta = 1 - alpha */
        public static double[] pressureToWeights(double pressure) {
            double alpha = Math.max(0.05, 0.7 - 0.5 * pressure);
            return new double[]{alpha, 1.0 - alpha};
        }
    }

    // ── Fields ────────────────────────────────────────────────────────────────
    private final Variant            variant;
    private final StateLocalityTracker tracker;
    private final double             alpha;
    private final double             beta;
    private volatile long            lastOverheadUs = 0L;

    // MATS/PREP fields — written each block, read by LASTMetricsLogger
    private final MatsSignalSampler  matsSampler;
    private volatile double          matsRaw   = -1.0;
    private volatile double          matsEwma  = -1.0;
    private volatile double          matsAlpha = -1.0;
    private volatile double          matsBeta  = -1.0;

    // PREP-specific fields
    private final boolean            isPrepMode;
    private final Map<Hash, Integer> prepDeferralCount;
    private volatile int             prepAdmitted = 0;
    private volatile int             prepDeferred = 0;
    private long                     prepBlockCount = 0L;

    // ── Constructor ───────────────────────────────────────────────────────────
    public LASTScheduler(Variant variant, StateLocalityTracker tracker, double alpha, double beta) {
        this.variant  = variant;
        this.tracker  = tracker;
        this.alpha    = alpha;
        this.beta     = beta;
        boolean isMats = (variant == Variant.MATS || variant == Variant.MATS_RAW);
        this.isPrepMode = (variant == Variant.PREP || variant == Variant.PREP_SCHED);
        this.matsSampler = (isMats || isPrepMode) ? new MatsSignalSampler() : null;
        this.prepDeferralCount = isPrepMode ? new HashMap<>() : null;
    }

    // ── Public accessors ──────────────────────────────────────────────────────
    public Variant getVariant()        { return variant; }
    public long    getLastOverheadUs() { return lastOverheadUs; }
    public double  getMatsRaw()        { return matsRaw; }
    public double  getMatsEwma()       { return matsEwma; }
    public double  getMatsAlpha()      { return matsAlpha; }
    public double  getMatsBeta()       { return matsBeta; }
    public boolean isMatsMode()        {
        return variant == Variant.MATS || variant == Variant.MATS_RAW;
    }
    public boolean isPrepMode()        { return isPrepMode; }
    public int     getPrepAdmitted()   { return prepAdmitted; }
    public int     getPrepDeferred()   { return prepDeferred; }

    // ── Main reorder entry point ───────────────────────────────────────────────
    public List<PendingTransaction> reorder(List<PendingTransaction> list, Optional<Wei> baseFee) {
        // Sample MATS/PREP pressure unconditionally so empty blocks still record real signal.
        if (matsSampler != null) {
            double raw      = matsSampler.sample();
            double ewma     = matsSampler.getEwma();
            // MATS_RAW uses raw; MATS/PREP/PREP_SCHED use EWMA
            double pressure = (variant == Variant.MATS_RAW) ? raw : ewma;
            double[] w      = MatsSignalSampler.pressureToWeights(pressure);
            matsRaw   = raw;
            matsEwma  = ewma;
            matsAlpha = w[0];
            matsBeta  = w[1];
        }

        if (list.isEmpty() || variant == Variant.DISABLED) {
            for (PendingTransaction pt : list) {
                tracker.observeAccess(toAddress(pt));
            }
            return list;
        }

        long t0 = System.nanoTime();

        // PREP gate: filter list before scheduling
        List<PendingTransaction> txs = list;
        if (isPrepMode && !list.isEmpty()) {
            txs = applyPrepGate(list, matsEwma);
        }

        List<PendingTransaction> result;
        switch (variant) {
            case ADDRESS_LOCALITY    -> result = reorderByAddress(txs);
            case WORKING_SET_AFFINITY -> result = reorderByWarmSet(txs);
            case HYBRID_FEE_LOCALITY -> result = reorderHybridWithWeights(txs, baseFee, alpha, beta);
            case MATS, MATS_RAW     -> result = reorderHybridWithWeights(txs, baseFee, matsAlpha, matsBeta);
            case PREP               -> result = reorderHybridWithWeights(txs, baseFee, matsAlpha, matsBeta);
            case PREP_SCHED         -> result = reorderHybridWithWeights(txs, baseFee, matsAlpha,
                                                    Math.min(0.95, matsBeta + PREP_COST_PENALTY));
            default                 -> result = txs;
        }

        lastOverheadUs = TimeUnit.NANOSECONDS.toMicros(System.nanoTime() - t0);
        for (PendingTransaction pt : result) {
            tracker.observeAccess(toAddress(pt));
        }
        return result;
    }

    // ── PREP admission gate ───────────────────────────────────────────────────
    private List<PendingTransaction> applyPrepGate(List<PendingTransaction> list, double pressure) {
        prepBlockCount++;

        if (pressure <= PREP_PRESSURE_THRESHOLD) {
            // Low pressure: admit all, clear stale deferral counts
            for (PendingTransaction pt : list) {
                Hash hash = pt.getTransaction().getHash();
                if (hash != null) prepDeferralCount.remove(hash);
            }
            prepAdmitted = list.size();
            prepDeferred = 0;
            return list;
        }

        double admitThreshold = WARM_SCORE_BASE + pressure * 0.30;
        int coldBudget = (int)(list.size() * PREP_COLD_BUDGET_FRAC * (1.0 - pressure));
        int coldAdmitted = 0;

        List<PendingTransaction> admitted = new ArrayList<>(list.size());
        int nDeferred = 0;

        for (PendingTransaction pt : list) {
            Address addr   = toAddress(pt);
            double  warm   = tracker.getScore(addr);
            boolean isWarm = warm >= admitThreshold;
            Hash    hash   = pt.getTransaction().getHash();
            boolean guard  = hash != null &&
                             prepDeferralCount.getOrDefault(hash, 0) >= PREP_MAX_DEFERRALS;
            boolean budgetOk = !isWarm && !guard && coldAdmitted < coldBudget;

            if (isWarm || guard || budgetOk) {
                if (!isWarm && !guard) coldAdmitted++;
                admitted.add(pt);
                if (hash != null) prepDeferralCount.remove(hash);
            } else {
                if (hash != null)
                    prepDeferralCount.merge(hash, 1, Integer::sum);
                nDeferred++;
            }
        }

        // Periodic cleanup of stale deferral entries
        if (prepBlockCount % 200 == 0 && prepDeferralCount.size() > 500) {
            prepDeferralCount.entrySet().removeIf(e -> e.getValue() <= 0);
        }

        prepAdmitted = admitted.size();
        prepDeferred = nDeferred;
        return admitted;
    }

    // ── ADDRESS_LOCALITY ──────────────────────────────────────────────────────
    private List<PendingTransaction> reorderByAddress(List<PendingTransaction> list) {
        LinkedHashMap<Address, List<PendingTransaction>> groups = new LinkedHashMap<>();
        List<PendingTransaction> noAddr = new ArrayList<>();

        for (PendingTransaction pt : list) {
            Address addr = toAddress(pt);
            if (addr != null) {
                groups.computeIfAbsent(addr, a -> new ArrayList<>()).add(pt);
            } else {
                noAddr.add(pt);
            }
        }

        List<List<PendingTransaction>> sorted = new ArrayList<>(groups.values());
        sorted.sort((a, b) -> Integer.compare(b.size(), a.size()));

        List<PendingTransaction> result = new ArrayList<>(list.size());
        for (List<PendingTransaction> g : sorted) result.addAll(g);
        result.addAll(noAddr);
        return result;
    }

    // ── WORKING_SET_AFFINITY ──────────────────────────────────────────────────
    private List<PendingTransaction> reorderByWarmSet(List<PendingTransaction> list) {
        LinkedHashMap<Address, List<PendingTransaction>> warm = new LinkedHashMap<>();
        LinkedHashMap<Address, List<PendingTransaction>> cold = new LinkedHashMap<>();
        List<PendingTransaction> noAddr = new ArrayList<>();

        for (PendingTransaction pt : list) {
            Address addr = toAddress(pt);
            if (addr == null) { noAddr.add(pt); continue; }
            if (tracker.isWarm(addr)) {
                warm.computeIfAbsent(addr, a -> new ArrayList<>()).add(pt);
            } else {
                cold.computeIfAbsent(addr, a -> new ArrayList<>()).add(pt);
            }
        }

        List<PendingTransaction> result = new ArrayList<>(list.size());
        warm.values().stream()
            .sorted((a, b) -> Integer.compare(b.size(), a.size()))
            .forEach(result::addAll);
        cold.values().stream()
            .sorted((a, b) -> Integer.compare(b.size(), a.size()))
            .forEach(result::addAll);
        result.addAll(noAddr);
        return result;
    }

    // ── HYBRID_FEE_LOCALITY / MATS / PREP (shared sort logic) ────────────────
    private List<PendingTransaction> reorderHybridWithWeights(
            List<PendingTransaction> list, Optional<Wei> baseFee, double a, double b) {

        Map<Address, Integer> freqMap = new HashMap<>();
        long maxFee = 1L;
        for (PendingTransaction pt : list) {
            Address addr = toAddress(pt);
            if (addr != null) freqMap.merge(addr, 1, Integer::sum);
            Wei fee = pt.getTransaction().getEffectivePriorityFeePerGas(baseFee);
            if (fee != null && fee.toLong() > maxFee) maxFee = fee.toLong();
        }
        int maxFreq = freqMap.values().stream().mapToInt(v -> v).max().orElse(1);

        final long   mf = maxFee;
        final int    mq = maxFreq;
        final double fa = a, fb = b;

        // Precompute each candidate's score once, then sort on the cached value.
        // The previous comparator called computeHflScore() on both operands of
        // every comparison, turning an O(n) scoring pass into O(n log n) score
        // recomputations -- this dominated block-assembly time under overload
        // (measured scheduler_overhead_us in the 100+ ms range on Besu, ~1000x
        // the CLR port's ~80 us) and was the primary cause of the throughput
        // collapse in scheduling-aware variants relative to Baseline FIFO.
        List<ScoredTx> scored = new ArrayList<>(list.size());
        for (PendingTransaction pt : list) {
            scored.add(new ScoredTx(pt, computeHflScore(pt, baseFee, mf, freqMap, mq, fa, fb)));
        }
        scored.sort((s1, s2) -> Double.compare(s2.score, s1.score));

        List<PendingTransaction> result = new ArrayList<>(scored.size());
        for (ScoredTx s : scored) result.add(s.tx);
        return result;
    }

    private static final class ScoredTx {
        final PendingTransaction tx;
        final double score;
        ScoredTx(PendingTransaction tx, double score) { this.tx = tx; this.score = score; }
    }

    private double computeHflScore(PendingTransaction pt, Optional<Wei> baseFee,
                                   long maxFee, Map<Address, Integer> freqMap, int maxFreq,
                                   double a, double b) {
        Transaction tx  = pt.getTransaction();
        Wei fee         = tx.getEffectivePriorityFeePerGas(baseFee);
        double feeNorm  = (fee == null) ? 0.0 : Math.min(1.0, (double)fee.toLong() / (double)maxFee);
        Address addr    = toAddress(pt);
        double locScore = (addr == null || maxFreq == 0) ? 0.0
                        : (double)freqMap.getOrDefault(addr, 0) / (double)maxFreq;
        return a * feeNorm + b * locScore;
    }

    // ── Utility ───────────────────────────────────────────────────────────────
    private static Address toAddress(PendingTransaction pt) {
        return pt.getTransaction().getTo().orElse(null);
    }
}
