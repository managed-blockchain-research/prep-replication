#!/usr/bin/env python3
"""Deploy StateBloater contract using web3.py"""

import json
from web3 import Web3

# Connect to Besu
w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))

print('Deploying StateBloater contract...\n')

# Check connection
if not w3.is_connected():
    print('❌ Could not connect to Besu')
    print('Start Besu with: ./scripts/start_besu_baseline.sh')
    exit(1)

print(f'✓ Connected to Besu')
print(f'  Current block: {w3.eth.block_number}')

# Load contract
with open('StateBloater.json', 'r') as f:
    artifact = json.load(f)

# Account setup
private_key = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689'
account = w3.eth.account.from_key(private_key)

print(f'✓ Using deployer: {account.address}')

# Create contract object
Contract = w3.eth.contract(abi=artifact['abi'], bytecode=artifact['bytecode'])

print('\n🚀 Deploying contract...')

# Build transaction
tx = Contract.constructor().build_transaction({
    'from': account.address,
    'nonce': w3.eth.get_transaction_count(account.address),
    'gas': 8000000,
    'gasPrice': 0,
    'chainId': 1337
})

# Sign and send
signed_tx = account.sign_transaction(tx)
tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)

print(f'✓ Transaction hash: {tx_hash.hex()}')
print('  Waiting for confirmation...')

# Wait for receipt
receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
contract_address = receipt.contractAddress

print('\n' + '=' * 60)
print('✅ DEPLOYMENT SUCCESSFUL')
print('=' * 60)
print(f'Contract Address: {contract_address}')
print('=' * 60)

# Update networkconfig.json
print('\nUpdating networkconfig.json...')
with open('networkconfig.json', 'r') as f:
    config = json.load(f)

config['ethereum']['contracts']['StateBloater']['address'] = contract_address

with open('networkconfig.json', 'w') as f:
    json.dump(config, f, indent=2)

print('✓ Config updated')
print('\n✅ Ready for baseline testing!\n')
