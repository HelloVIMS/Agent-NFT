#!/bin/bash
set -e

# Load environment
source ../.env

# Deploy to Base Sepolia
echo "Deploying ERC-8004 contracts to Base Sepolia..."
echo "Deployer: $DEPLOYER_ADDRESS"

# Check balance
BALANCE=$(cast balance $DEPLOYER_ADDRESS --rpc-url $BASE_SEPOLIA_RPC_URL)
echo "Balance: $BALANCE wei"

if [ "$BALANCE" = "0" ]; then
    echo "ERROR: Wallet has no ETH. Fund it at https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet"
    echo "Address: $DEPLOYER_ADDRESS"
    exit 1
fi

# Deploy contracts
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url $BASE_SEPOLIA_RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --broadcast \
    --verify \
    -vvvv

echo ""
echo "=== DEPLOYMENT COMPLETE ==="
echo "Update pkg/erc8004/erc8004.go with the deployed addresses above"
