'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');

// Caliper's runDuration() dispatches submitTransaction() fire-and-forget (the
// outer loop resolves on dispatch, not on completion), so an `await` inside
// submitTransaction() does NOT serialize a worker's dispatch rate to its own
// confirmation latency the way it might appear to. What it DOES do without a
// bound is let unconfirmed calls pile up unboundedly once confirmation slows
// under backlog (see mixedAttackLOHRaacBurst.js for the documented incident).
// Port that module's fixes here: a semaphore bounding concurrent in-flight
// calls per worker, and a per-round dispatch cap (attempts, not confirmations)
// so a degraded SUT causes bounded backpressure instead of unbounded pile-up
// or runaway over-dispatch.
const MAX_INFLIGHT = Number(process.env.PREP_MAX_INFLIGHT) || 10;
const BASE_GAS_PRICE = 1000000000;

class Semaphore {
    constructor(max) { this.max = max; this.count = 0; this.queue = []; }
    async acquire() {
        if (this.count < this.max) { this.count++; return; }
        await new Promise(resolve => this.queue.push(resolve));
        this.count++;
    }
    release() {
        this.count--;
        const next = this.queue.shift();
        if (next) next();
    }
}

class StateBloaterFireAndForgetWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex = 0;
        this._inflightSem = new Semaphore(MAX_INFLIGHT);
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);
        if (this.roundArguments) {
            this.workerArguments = this.roundArguments;
        }

        const args = this.workerArguments || { slotsPerTx: 50, numContracts: 1, contractPrefix: 'SB' };
        this.numContracts = args.numContracts || 1;
        this.contractPrefix = args.contractPrefix || 'SB';
        this.moduleStartMs = Date.now();
        this._firstAttemptTime = null;

        // Per-round dispatch cap: same rationale as mixedAttackLOHRaacBurst.js —
        // once this worker has attempted its share of the round's target count,
        // stop dispatching instead of queuing further attempts past the round's
        // nominal window (roundDurationSeconds/tps are passed explicitly in the
        // benchconfig's `arguments:` block; they are not auto-derived from
        // Caliper's own txDuration/rateControl fields).
        const roundDurationSeconds = Number(args.roundDurationSeconds) || 0;
        const targetTps = Number(args.tps) || 0;
        const tpsPerWorker = targetTps / totalWorkers;
        this._maxAttempts = roundDurationSeconds > 0 && tpsPerWorker > 0
            ? Math.ceil(tpsPerWorker * roundDurationSeconds * 1.05)   // +5% slack for pacing jitter
            : Infinity;
        this._tpsPerWorker = tpsPerWorker;

        console.log(`Worker ${workerIndex} → cycling ${this.numContracts} contracts (maxAttempts=${this._maxAttempts}, maxInflight=${MAX_INFLIGHT})`);
    }

    async submitTransaction() {
        // Atomically claim this attempt's slot BEFORE any await, so concurrent
        // fire-and-forget invocations of submitTransaction() can't both read the
        // same stale this.txIndex and pass the cap check before either increments
        // it (see mixedAttackLOHRaacBurst.js UPDATE 2026-08-01 for the incident
        // this guards against).
        if (this.txIndex >= this._maxAttempts) {
            await new Promise(resolve => setTimeout(resolve, 200));
            return;
        }
        const myIndex = this.txIndex;
        this.txIndex++;

        if (this._tpsPerWorker > 0) {
            const sleepTimeMs = 1000 / this._tpsPerWorker;
            if (this._firstAttemptTime === null) this._firstAttemptTime = Date.now();
            const diff = sleepTimeMs * myIndex - (Date.now() - this._firstAttemptTime);
            if (diff > 0) await new Promise(resolve => setTimeout(resolve, diff));
        }

        const args = this.workerArguments || { slotsPerTx: 50 };
        const slotsPerTx = args.slotsPerTx || 50;
        const slotCycleSize = args.slotCycleSize || 0;
        const contractIndex = myIndex % this.numContracts;
        const contractId = `${this.contractPrefix}${contractIndex}`;
        const txsForThisContract = Math.floor(myIndex / this.numContracts);
        const startIdx = slotCycleSize > 0
            ? (txsForThisContract * slotsPerTx) % slotCycleSize
            : (this.workerIndex * 1000000) + ((myIndex + 1) * slotsPerTx);

        // Uniform gasPrice let Nethermind's TxPool "compete" eviction deadlock
        // permanently once full (a same-priced newcomer can never legitimately
        // evict an already-pooled entry). Bump price by elapsed wall-clock ms
        // (+ a small per-worker offset to break ties within the same ms) so
        // newer transactions always outbid older pooled ones.
        const elapsedMs = Date.now() - this.moduleStartMs;
        const gasPrice = BASE_GAS_PRICE + elapsedMs + this.workerIndex;

        const request = {
            contract: contractId,
            verb: 'bloat',
            args: [startIdx, slotsPerTx],
            readOnly: false,
            gasPrice
        };

        await this._inflightSem.acquire();
        try {
            await this.sutAdapter.sendRequests(request);
        } finally {
            this._inflightSem.release();
        }
    }
}

function createWorkloadModule() {
    return new StateBloaterFireAndForgetWorkload();
}

module.exports.createWorkloadModule = createWorkloadModule;
