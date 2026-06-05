#!/bin/bash

# Simple contract deployment using curl and raw RPC calls

echo "Deploying StateBloater contract using raw RPC calls..."
echo ""

# Contract bytecode from StateBloater.json
BYTECODE="0x608060405234801561001057600080fd5b5061012a806100206000396000f3fe608060405234801561001057600080fd5b50600436106100365760003560e01c80637951e60a1461003b578063e52e698b14610059575b600080fd5b6100436004803603602081101561005157600080fd5b8101908080359060200190929190505050610077565b6040518082815260200191505060405180910390f35b6100756004803603604081101561006f57600080fd5b81019080803590602001909291908035906020019092919050505061008a565b005b60006020528060005260406000206000915090505481565b6000819050816000036100e4575050565b5b6000818110156100e0574281018483016000526020600020810155808060010191505061009e565b505056fea264697066735822122045e050307873138383574d6c69438259695624736f6c63430008000033"

FROM_ADDRESS="0xBE0cf996DE312b11990E4BcbBf7Fc156880AcFC8"
RPC_URL="http://localhost:8545"

echo "Using deployer address: $FROM_ADDRESS"
echo "RPC URL: $RPC_URL"
echo ""

# Send deployment transaction
echo "Sending deployment transaction..."
RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"method\":\"eth_sendTransaction\",
    \"params\":[{
      \"from\":\"$FROM_ADDRESS\",
      \"gas\":\"0x7A1200\",
      \"gasPrice\":\"0x0\",
      \"data\":\"$BYTECODE\"
    }],
    \"id\":1
  }" \
  $RPC_URL)

echo "Response: $RESPONSE"

# Extract transaction hash
TX_HASH=$(echo $RESPONSE | grep -o '"result":"0x[^"]*"' | cut -d'"' -f4)

if [ -z "$TX_HASH" ]; then
    echo ""
    echo "❌ Deployment failed. Check if Besu is running and the account is unlocked."
    exit 1
fi

echo ""
echo "✓ Transaction hash: $TX_HASH"
echo "  Waiting for transaction receipt..."

# Wait for transaction to be mined
sleep 3

# Get transaction receipt
RECEIPT=$(curl -s -X POST -H "Content-Type: application/json" \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"method\":\"eth_getTransactionReceipt\",
    \"params\":[\"$TX_HASH\"],
    \"id\":1
  }" \
  $RPC_URL)

# Extract contract address
CONTRACT_ADDRESS=$(echo $RECEIPT | grep -o '"contractAddress":"0x[^"]*"' | cut -d'"' -f4)

if [ -z "$CONTRACT_ADDRESS" ]; then
    echo "❌ Failed to get contract address. Transaction may still be pending."
    echo "Receipt: $RECEIPT"
    exit 1
fi

echo ""
echo "============================================================"
echo "✅ DEPLOYMENT SUCCESSFUL"
echo "============================================================"
echo "Contract Address: $CONTRACT_ADDRESS"
echo "============================================================"
echo ""

# Update networkconfig.json
echo "Updating networkconfig.json..."

# Use python to update JSON properly
python3 << EOF
import json

with open('networkconfig.json', 'r') as f:
    config = json.load(f)

config['ethereum']['contracts']['StateBloater']['address'] = '$CONTRACT_ADDRESS'

with open('networkconfig.json', 'w') as f:
    json.dump(config, f, indent=2)

print('✓ networkconfig.json updated')
EOF

echo ""
echo "✅ Ready to run baseline tests!"
echo ""
echo "Next step:"
echo "  ./scripts/run_baseline_tests.sh --only low"
echo ""
