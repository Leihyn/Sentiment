#!/bin/bash

# Sentiment Fee Hook - Complete Demo Script
# This script demonstrates the hook's behavior in an actual pool

set -e

echo "==========================================="
echo "  SENTIMENT FEE HOOK - COMPLETE DEMO"
echo "==========================================="
echo ""

# Configuration
RPC_URL="http://127.0.0.1:8545"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# Check if Anvil is running
if ! curl -s $RPC_URL > /dev/null 2>&1; then
    echo "ERROR: Anvil is not running!"
    echo "Please start Anvil first: anvil --host 127.0.0.1 --port 8545"
    exit 1
fi

echo "Step 1: Deploying contracts..."
echo "-------------------------------------------"

# Deploy everything
OUTPUT=$(forge script script/DeployFullDemo.s.sol \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast 2>&1)

echo "$OUTPUT"

# Extract addresses from output (simple parsing)
HOOK_ADDRESS=$(echo "$OUTPUT" | grep -oP 'Hook: \K0x[a-fA-F0-9]+' | head -1)
TOKEN0_ADDRESS=$(echo "$OUTPUT" | grep -oP 'Token0: \K0x[a-fA-F0-9]+' | head -1)
TOKEN1_ADDRESS=$(echo "$OUTPUT" | grep -oP 'Token1: \K0x[a-fA-F0-9]+' | head -1)
SWAP_ROUTER=$(echo "$OUTPUT" | grep -oP 'SwapRouter: \K0x[a-fA-F0-9]+' | head -1)

if [ -z "$HOOK_ADDRESS" ]; then
    echo "Could not extract addresses. Please check deployment output."
    exit 1
fi

echo ""
echo "Extracted Addresses:"
echo "  Hook: $HOOK_ADDRESS"
echo "  Token0: $TOKEN0_ADDRESS"
echo "  Token1: $TOKEN1_ADDRESS"
echo "  SwapRouter: $SWAP_ROUTER"
echo ""

echo "Step 2: Running swap demo at different sentiments..."
echo "-------------------------------------------"

# Run the demo swaps
HOOK_ADDRESS=$HOOK_ADDRESS \
TOKEN0_ADDRESS=$TOKEN0_ADDRESS \
TOKEN1_ADDRESS=$TOKEN1_ADDRESS \
SWAP_ROUTER_ADDRESS=$SWAP_ROUTER \
PRIVATE_KEY=$PRIVATE_KEY \
forge script script/DemoSwaps.s.sol \
    --rpc-url $RPC_URL \
    --broadcast

echo ""
echo "==========================================="
echo "  DEMO COMPLETE!"
echo "==========================================="
