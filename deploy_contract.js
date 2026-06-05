const ethers = require('ethers');
const fs = require('fs');

async function deploy() {
    console.log('Deploying StateBloater contract...\n');

    // Connect to Besu with polling disabled (avoid "latest" block issues)
    const provider = new ethers.JsonRpcProvider('http://127.0.0.1:8545', {
        name: 'besu',
        chainId: 1337
    }, {
        staticNetwork: true,  // Don't query network details
        batchMaxCount: 1
    });

    // Setup wallet with private key
    const privateKey = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689';
    const wallet = new ethers.Wallet(privateKey, provider);

    console.log(`✓ Connected to Besu`);
    console.log(`✓ Using deployer: ${wallet.address}`);

    // Load contract
    const artifact = JSON.parse(fs.readFileSync('./StateBloater.json', 'utf8'));

    console.log('\n🚀 Deploying contract...');

    // Create and sign transaction manually
    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);

    // Get deploy transaction
    const deployTx = await factory.getDeployTransaction();

    // Manual transaction parameters (ensure data is set explicitly)
    const tx = {
        data: deployTx.data,
        gasLimit: 8000000,
        gasPrice: 0,
        chainId: 1337
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

    // Update networkconfig.json
    console.log('\nUpdating networkconfig.json...');
    const config = JSON.parse(fs.readFileSync('./networkconfig.json', 'utf8'));
    config.ethereum.contracts.StateBloater.address = address;
    fs.writeFileSync('./networkconfig.json', JSON.stringify(config, null, 2));
    console.log('✓ Config updated');

    console.log('\n✅ Ready for baseline testing!\n');
}

deploy().catch(err => {
    console.error('\n❌ Deployment failed:');
    console.error(err.message || err);
    process.exit(1);
});
