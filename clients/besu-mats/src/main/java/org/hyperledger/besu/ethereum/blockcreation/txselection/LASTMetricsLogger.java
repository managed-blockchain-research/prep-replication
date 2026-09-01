// SPDX-FileCopyrightText: 2025 LAST/MATS Research
// SPDX-License-Identifier: Apache-2.0
//
// Reconstructed from besu-24.1.1 bytecode and extended with MATS columns.
//
// Original CSV schema:
//   timestamp_ms,block_number,last_variant,tx_count,warm_hits,cold_misses,
//   warm_set_size,warm_hit_rate,scheduler_overhead_us,block_duration_ms,
//   gc_young_delta_count,gc_old_delta_count,gc_young_delta_ms,gc_old_delta_ms,
//   gc_total_delta_ms,gc_pause_ratio
//
// MATS extended schema (appends 4 extra columns when variant is MATS or MATS_RAW):
//   ...,mats_raw_pressure,mats_ewma_pressure,mats_alpha,mats_beta

package org.hyperledger.besu.ethereum.blockcreation.txselection;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.io.PrintWriter;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.time.Instant;
import java.util.List;

public class LASTMetricsLogger implements AutoCloseable {

    private static final String HEADER_BASE =
        "timestamp_ms,block_number,last_variant,tx_count,warm_hits,cold_misses," +
        "warm_set_size,warm_hit_rate,scheduler_overhead_us,block_duration_ms," +
        "gc_young_delta_count,gc_old_delta_count,gc_young_delta_ms,gc_old_delta_ms," +
        "gc_total_delta_ms,gc_pause_ratio";

    private static final String HEADER_MATS_SUFFIX =
        ",mats_raw_pressure,mats_ewma_pressure,mats_alpha,mats_beta";

    private static final String HEADER_PREP_SUFFIX =
        ",mats_raw_pressure,mats_ewma_pressure,mats_alpha,mats_beta,prep_admitted,prep_deferred";

    private final PrintWriter          writer;
    private final LASTScheduler        scheduler;
    private final StateLocalityTracker tracker;
    private final List<GarbageCollectorMXBean> gcBeans;
    private final boolean              matsMode;
    private final boolean              prepMode;

    private long baseYoungCount = 0L;
    private long baseOldCount   = 0L;
    private long baseYoungMs    = 0L;
    private long baseOldMs      = 0L;

    public LASTMetricsLogger(String path, LASTScheduler scheduler, StateLocalityTracker tracker)
            throws IOException {
        this.scheduler = scheduler;
        this.tracker   = tracker;
        this.gcBeans   = ManagementFactory.getGarbageCollectorMXBeans();
        this.matsMode  = scheduler.isMatsMode();
        this.prepMode  = scheduler.isPrepMode();

        File file = new File(path);
        boolean writeHeader = !file.exists() || file.length() == 0;
        FileWriter fw = new FileWriter(path, true);
        this.writer = new PrintWriter(fw, true);
        if (writeHeader) {
            String header = HEADER_BASE;
            if (matsMode) header += HEADER_MATS_SUFFIX;
            if (prepMode) header += HEADER_PREP_SUFFIX;
            this.writer.println(header);
        }

        this.baseYoungCount = gcCount(false);
        this.baseOldCount   = gcCount(true);
        this.baseYoungMs    = gcTimeMs(false);
        this.baseOldMs      = gcTimeMs(true);
    }

    public void logBlock(long blockNumber, int txCount, long blockDurationMs) {
        long now        = Instant.now().toEpochMilli();
        long youngCount = gcCount(false);
        long oldCount   = gcCount(true);
        long youngMs    = gcTimeMs(false);
        long oldMs      = gcTimeMs(true);

        long dYoungCount = Math.max(0L, youngCount - baseYoungCount);
        long dOldCount   = Math.max(0L, oldCount   - baseOldCount);
        long dYoungMs    = Math.max(0L, youngMs    - baseYoungMs);
        long dOldMs      = Math.max(0L, oldMs      - baseOldMs);
        long dTotalMs    = dYoungMs + dOldMs;

        baseYoungCount = youngCount;
        baseOldCount   = oldCount;
        baseYoungMs    = youngMs;
        baseOldMs      = oldMs;

        long   warmHits     = tracker.getWarmHits();
        long   coldMisses   = tracker.getColdMisses();
        int    warmSetSize  = tracker.getWarmSetSize();
        double warmHitRate  = tracker.getWarmHitRate();
        long   overheadUs   = scheduler.getLastOverheadUs();
        double pauseRatio   = blockDurationMs > 0
                            ? (double)dTotalMs / (double)blockDurationMs : 0.0;

        writer.printf("%d,%d,%s,%d,%d,%d,%d,%.4f,%d,%d,%d,%d,%d,%d,%d,%.4f",
            now, blockNumber, scheduler.getVariant().name(),
            txCount, warmHits, coldMisses, warmSetSize, warmHitRate,
            overheadUs, blockDurationMs,
            dYoungCount, dOldCount, dYoungMs, dOldMs, dTotalMs, pauseRatio);

        if (matsMode) {
            writer.printf(",%.4f,%.4f,%.4f,%.4f",
                scheduler.getMatsRaw(),
                scheduler.getMatsEwma(),
                scheduler.getMatsAlpha(),
                scheduler.getMatsBeta());
        }
        if (prepMode) {
            writer.printf(",%.4f,%.4f,%.4f,%.4f,%d,%d",
                scheduler.getMatsRaw(),
                scheduler.getMatsEwma(),
                scheduler.getMatsAlpha(),
                scheduler.getMatsBeta(),
                scheduler.getPrepAdmitted(),
                scheduler.getPrepDeferred());
        }
        writer.println();
        writer.flush();
    }

    @Override
    public void close() {
        if (writer != null) {
            writer.flush();
            writer.close();
        }
    }

    private long gcCount(boolean oldGen) {
        long total = 0L;
        for (GarbageCollectorMXBean gc : gcBeans) {
            if (isOldGen(gc.getName()) != oldGen) continue;
            long c = gc.getCollectionCount();
            if (c >= 0) total += c;
        }
        return total;
    }

    private long gcTimeMs(boolean oldGen) {
        long total = 0L;
        for (GarbageCollectorMXBean gc : gcBeans) {
            if (isOldGen(gc.getName()) != oldGen) continue;
            long t = gc.getCollectionTime();
            if (t >= 0) total += t;
        }
        return total;
    }

    private static boolean isOldGen(String name) {
        String n = name.toLowerCase();
        return n.contains("old") || n.contains("marksweep") ||
               n.contains("concurrent") || n.contains("zgc") || n.contains("shenandoah");
    }
}
