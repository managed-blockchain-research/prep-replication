'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');

class StateBloaterWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex = 0;
        this.contractId = null;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);
        if (this.roundArguments) {
            this.workerArguments = this.roundArguments;
        }

        const args = this.workerArguments || { slotsPerTx: 50, numContracts: 1, contractPrefix: 'SB' };
        const numContracts = args.numContracts || 1;
        const prefix = args.contractPrefix || 'SB';

        this.numContracts = numContracts;
        this.contractPrefix = prefix;
        console.log(`Worker ${workerIndex} → cycling ${numContracts} contracts`);
    }

    async submitTransaction() {
        this.txIndex++;
        const args = this.workerArguments || { slotsPerTx: 50 };
        const slotsPerTx = args.slotsPerTx || 50;
        const slotCycleSize = args.slotCycleSize || 0;
        const contractIndex = (this.txIndex - 1) % this.numContracts;
        const contractId = `${this.contractPrefix}${contractIndex}`;
        // Per-contract cycling: each contract owns slot range [0..slotCycleSize-1]
        // txsForThisContract counts how many times this worker has touched this contract
        // → same slots repeat after slotCycleSize/slotsPerTx rounds → warm re-accesses
        // → LAST-AL grouping keeps trie nodes hot → fewer RocksDB reloads → less CLR GC
        const txsForThisContract = Math.floor((this.txIndex - 1) / this.numContracts);
        const startIdx = slotCycleSize > 0
            ? (txsForThisContract * slotsPerTx) % slotCycleSize
            : (this.workerIndex * 1000000) + (this.txIndex * slotsPerTx);

        const request = {
            contract: contractId,
            verb: 'bloat',
            args: [startIdx, slotsPerTx],
            readOnly: false
        };

        await this.sutAdapter.sendRequests(request);
    }
}

function createWorkloadModule() {
    return new StateBloaterWorkload();
}

module.exports.createWorkloadModule = createWorkloadModule;
