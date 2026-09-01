// Reconstructed from besu-24.1.1 bytecode (unchanged from original)
package org.hyperledger.besu.ethereum.blockcreation.txselection;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import org.hyperledger.besu.datatypes.Address;

public class StateLocalityTracker {
    private static final double DECAY_PER_TX    = 0.98;
    private static final double DECAY_PER_BLOCK = 0.8;
    private static final double WARM_THRESHOLD  = 0.05;
    private static final double ACCESS_DELTA    = 1.0;

    private final Map<Address, Double> scores = new HashMap<>();
    private long warmHits   = 0L;
    private long coldMisses = 0L;

    public void recordAccess(Set<Address> addrs) {
        for (Address a : addrs) scores.merge(a, 1.0, Double::sum);
    }

    public void onTransactionBoundary() {
        scores.replaceAll((a, v) -> v * DECAY_PER_TX);
        scores.entrySet().removeIf(e -> e.getValue() < WARM_THRESHOLD);
    }

    public void reset() {
        scores.replaceAll((a, v) -> v * DECAY_PER_BLOCK);
        scores.entrySet().removeIf(e -> e.getValue() < WARM_THRESHOLD);
        warmHits   = 0L;
        coldMisses = 0L;
    }

    public boolean isWarm(Address addr) {
        if (addr == null) return false;
        return scores.getOrDefault(addr, 0.0) >= WARM_THRESHOLD;
    }

    public double getScore(Address addr) {
        if (addr == null) return 0.0;
        return Math.tanh(scores.getOrDefault(addr, 0.0));
    }

    public void observeAccess(Address addr) {
        if (addr == null) return;
        if (isWarm(addr)) warmHits++; else coldMisses++;
    }

    public int    getWarmSetSize()       { return scores.size(); }
    public long   getWarmHits()          { return warmHits; }
    public long   getColdMisses()        { return coldMisses; }
    public long   getTotalObservations() { return warmHits + coldMisses; }
    public double getWarmHitRate() {
        long total = warmHits + coldMisses;
        return total == 0 ? 0.0 : (double)warmHits / (double)total;
    }
}
