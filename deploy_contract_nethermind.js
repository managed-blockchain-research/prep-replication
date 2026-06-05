const ethers = require('ethers');
const fs = require('fs');

async function deploy() {
    console.log('Deploying StateBloater contract to Nethermind...\n');

    const provider = new ethers.JsonRpcProvider('http://127.0.0.1:8545');
    const network = await provider.getNetwork();
    const chainId = Number(network.chainId);

    const privateKey = '0x' + '1'.padStart(64, '0');
    const wallet = new ethers.Wallet(privateKey, provider);

    console.log(`✓ Connected to Nethermind`);
    console.log(`✓ Using deployer: ${wallet.address}`);

    const artifact = JSON.parse(fs.readFileSync('./StateBloater.json', 'utf8'));
    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);
    const deployTx = await factory.getDeployTransaction();

    const fee = ethers.parseUnits('1', 'gwei');
    const tx = {
        data: deployTx.data,
        gasLimit: 8000000,
        maxFeePerGas: fee,
        maxPriorityFeePerGas: fee,
        chainId: chainId
    };

    console.log('  Sending deploy transaction...');
    const sentTx = await wallet.sendTransaction(tx);
    console.log(`✓ Transaction hash: ${sentTx.hash}`);
    console.log('  Waiting for confirmation...');

    const receipt = await sentTx.wait();
    const address = receipt.contractAddress;

    console.log('\n' + '='.repeat(60));
    console.log('✅ DEPLOYMENT SUCCESSFUL');
    console.log('='.repeat(60));
    console.log(`Contract Address: ${address}`);
    console.log('='.repeat(60));

    console.log('\nUpdating networkconfig_nethermind.json...');
    const config = JSON.parse(fs.readFileSync('./networkconfig_nethermind.json', 'utf8'));
    config.ethereum.contracts.StateBloater.address = address;
    config.ethereum.contracts.StateBloater.abi = artifact.abi;
    fs.writeFileSync('./networkconfig_nethermind.json', JSON.stringify(config, null, 2));
    console.log('✓ Config updated');
}

deploy().catch(err => {
    console.error('\n❌ Deployment failed:');
    console.error(err.message || err);
    process.exit(1);
});
