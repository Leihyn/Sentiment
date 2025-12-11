# Sentiment-Responsive Fee Hook

A Uniswap v4 hook that dynamically adjusts swap fees based on real-time market sentiment, optimizing LP revenue and trader costs across market cycles.

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)
![Foundry](https://img.shields.io/badge/Foundry-Latest-orange)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/Tests-50%20Passing-brightgreen)

---

## Table of Contents

- [Overview](#overview)
- [Problem Statement](#problem-statement)
- [Solution](#solution)
- [Architecture](#architecture)
- [Fee Model](#fee-model)
- [Installation](#installation)
- [Usage](#usage)
- [Testing](#testing)
- [Deployment](#deployment)
- [Keeper Infrastructure](#keeper-infrastructure)
- [Data Sources](#data-sources)
- [Security Considerations](#security-considerations)
- [Configuration](#configuration)
- [API Reference](#api-reference)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

The Sentiment-Responsive Fee Hook is a Uniswap v4 hook that implements dynamic fee adjustment based on market sentiment indicators. By monitoring the crypto Fear & Greed Index and other market signals, the hook automatically adjusts swap fees between 0.25% and 0.44%, optimizing for both LP revenue and trading activity.

### Key Features

- **Dynamic Fees**: Automatically adjusts fees based on market conditions
- **Multi-Source Sentiment**: Aggregates 8 free data sources for robust signals
- **EMA Smoothing**: Prevents fee manipulation through exponential moving average
- **Staleness Protection**: Falls back to default fee if data becomes stale
- **Gas Efficient**: Minimal on-chain computation, off-chain data aggregation
- **Fully Tested**: 50 comprehensive tests (42 unit + 8 integration)

---

## Problem Statement

Traditional AMMs use **fixed fees** regardless of market conditions:

```
Bull Market (Greed)          Bear Market (Fear)
┌─────────────────────┐      ┌─────────────────────┐
│ Traders: "I'll pay  │      │ Traders: "0.3% is   │
│ anything for this   │      │ too expensive, I'll │
│ trade!"             │      │ wait..."            │
│                     │      │                     │
│ Fee: 0.3% (fixed)   │      │ Fee: 0.3% (fixed)   │
│                     │      │                     │
│ Result: LPs miss    │      │ Result: Zero volume │
│ revenue opportunity │      │ LPs earn nothing    │
└─────────────────────┘      └─────────────────────┘
```

**The Problem**: Fixed fees leave money on the table during bull markets and kill volume during bear markets.

---

## Solution

Dynamic fees that adapt to market sentiment:

```
Bull Market (Greed)          Bear Market (Fear)
┌─────────────────────┐      ┌─────────────────────┐
│                     │      │                     │
│ Sentiment: 80       │      │ Sentiment: 20       │
│ Fee: 0.40%          │      │ Fee: 0.29%          │
│                     │      │                     │
│ Result: LPs capture │      │ Result: Lower fees  │
│ premium from FOMO   │      │ encourage trading   │
│ traders             │      │ volume returns      │
└─────────────────────┘      └─────────────────────┘
```

**The Solution**: Maximize `fee × volume` across all market conditions.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           OFF-CHAIN                                      │
│                                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐ │
│  │ Fear & Greed │  │  CoinGecko   │  │ DeFi Llama   │  │ Blockchain  │ │
│  │    Index     │  │   Global     │  │    TVL       │  │    Stats    │ │
│  │    (30%)     │  │   (20%)      │  │   (10%)      │  │    (5%)     │ │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬──────┘ │
│         │                 │                 │                 │         │
│         └────────────────┼─────────────────┼─────────────────┘         │
│                          │                 │                            │
│                          ▼                 ▼                            │
│                   ┌─────────────────────────────┐                       │
│                   │      KEEPER BOT             │                       │
│                   │  (TypeScript / Chainlink)   │                       │
│                   │                             │                       │
│                   │  • Fetches sentiment data   │                       │
│                   │  • Calculates composite     │                       │
│                   │  • Submits transactions     │                       │
│                   └──────────────┬──────────────┘                       │
│                                  │                                      │
└──────────────────────────────────┼──────────────────────────────────────┘
                                   │ updateSentiment(score)
                                   ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                           ON-CHAIN                                        │
│                                                                           │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                    SentimentFeeHook.sol                          │   │
│   │                                                                  │   │
│   │  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐ │   │
│   │  │ Sentiment   │    │    EMA      │    │   Fee Calculation   │ │   │
│   │  │  Storage    │───▶│  Smoothing  │───▶│                     │ │   │
│   │  │             │    │  (α = 30%)  │    │  fee = MIN + (sent  │ │   │
│   │  │ score: u8   │    │             │    │        × RANGE/100) │ │   │
│   │  └─────────────┘    └─────────────┘    └─────────────────────┘ │   │
│   │                                                  │               │   │
│   │                                                  ▼               │   │
│   │                                    ┌─────────────────────────┐  │   │
│   │                                    │     beforeSwap()        │  │   │
│   │                                    │                         │  │   │
│   │                                    │  Returns dynamic fee    │  │   │
│   │                                    │  with OVERRIDE_FEE_FLAG │  │   │
│   │                                    └─────────────────────────┘  │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                           │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                    Uniswap v4 PoolManager                        │   │
│   │                                                                  │   │
│   │              Pool with DYNAMIC_FEE_FLAG enabled                  │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## Fee Model

### Fee Range

| Parameter | Value | Notes |
|-----------|-------|-------|
| Minimum Fee | 0.25% (2500 bps) | Applied at sentiment = 0 (extreme fear) |
| Maximum Fee | 0.44% (4400 bps) | Applied at sentiment = 100 (extreme greed) |
| Default Fee | 0.30% (3000 bps) | Used when data is stale |
| Fee Range | 0.19% (1900 bps) | MAX - MIN |

### Fee Calculation Formula

```
fee = MIN_FEE + (sentimentScore × FEE_RANGE / 100)

Where:
  MIN_FEE   = 2500 (0.25%)
  FEE_RANGE = 1900 (0.19%)
  sentimentScore = 0-100
```

### Example Calculations

| Sentiment | Classification | Fee Calculation | Final Fee |
|-----------|----------------|-----------------|-----------|
| 0 | Extreme Fear | 2500 + (0 × 19) | 0.25% |
| 25 | Fear | 2500 + (25 × 19) | 0.30% |
| 50 | Neutral | 2500 + (50 × 19) | 0.345% |
| 75 | Greed | 2500 + (75 × 19) | 0.39% |
| 100 | Extreme Greed | 2500 + (100 × 19) | 0.44% |

### EMA Smoothing

To prevent manipulation and sudden fee changes, sentiment updates use Exponential Moving Average:

```
newEMA = (rawScore × α + currentEMA × (100 - α)) / 100

Where α (alpha) = 30% by default
```

This means:
- New data has 30% weight
- Historical data has 70% weight
- Gradual transitions, no sudden jumps

---

## Installation

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/) v18+
- [Git](https://git-scm.com/)

### Clone & Install

```bash
# Clone the repository
git clone https://github.com/yourusername/sentiment-fee-hook.git
cd sentiment-fee-hook

# Install Foundry dependencies
forge install

# Install keeper dependencies
cd keeper && npm install && cd ..
```

### Build

```bash
forge build
```

---

## Usage

### Quick Start (Local Testing)

```bash
# Terminal 1: Start local Anvil node
anvil

# Terminal 2: Deploy everything
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
forge script script/DeployFullDemo.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

# Terminal 3: Run keeper
cd keeper
cp .env.example .env
# Edit .env with deployed HOOK_ADDRESS
npx ts-node src/multi-source-keeper.ts --once
```

### Reading Contract State

```bash
# Current sentiment score (0-100)
cast call $HOOK_ADDRESS "sentimentScore()" --rpc-url $RPC_URL

# Current fee in basis points
cast call $HOOK_ADDRESS "getCurrentFee()" --rpc-url $RPC_URL

# Check if data is stale
cast call $HOOK_ADDRESS "isStale()" --rpc-url $RPC_URL

# Time until data becomes stale
cast call $HOOK_ADDRESS "timeUntilStale()" --rpc-url $RPC_URL
```

---

## Testing

### Run All Tests

```bash
forge test
```

### Run with Verbosity

```bash
forge test -vvv
```

### Run Specific Test

```bash
forge test --match-test test_swap_feeChangesWithSentiment -vvv
```

### Test Coverage

```bash
forge coverage
```

### Test Summary

| Test Suite | Count | Description |
|------------|-------|-------------|
| Unit Tests | 42 | Core functionality, access control, EMA, multi-keeper |
| Integration Tests | 8 | Full swap flow with PoolManager |
| **Total** | **50** | All passing |

---

## Deployment

### Environment Setup

```bash
# Create .env file
cp .env.example .env

# Edit with your values
PRIVATE_KEY=0x...
KEEPER_ADDRESS=0x...
RPC_URL=https://...
POOL_MANAGER=0x...  # Optional, uses NetworkConfig if not set
```

### Deploy to Testnet

```bash
# Sepolia
forge script script/DeploySentimentHook.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify

# Base Sepolia
forge script script/DeploySentimentHook.s.sol \
  --rpc-url https://sepolia.base.org \
  --broadcast \
  --verify
```

### Deploy Full Demo (with mock tokens)

```bash
TOKEN0_NAME="MyToken" \
TOKEN0_SYMBOL="MTK" \
TOKEN1_NAME="USDC" \
TOKEN1_SYMBOL="USDC" \
forge script script/DeployFullDemo.s.sol \
  --rpc-url $RPC_URL \
  --broadcast
```

### CREATE2 Address Mining

The hook address must have specific bits set for Uniswap v4 validation. The deployment scripts automatically mine a valid salt:

```solidity
// Hook must have BEFORE_SWAP_FLAG set in lower 14 bits
uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);

// Mining loop finds salt where:
// uint160(hookAddress) & ALL_HOOK_MASK == flags
```

---

## Keeper Infrastructure

### Option 1: TypeScript Keeper (Self-Hosted)

```bash
cd keeper
npm install
cp .env.example .env
# Configure .env

# Single run
npx ts-node src/multi-source-keeper.ts --once

# Continuous (every 4 hours)
npx ts-node src/multi-source-keeper.ts
```

### Option 2: Chainlink Automation

```solidity
// Hook implements Chainlink-compatible interface
function checkUpkeep(bytes calldata) external view returns (bool, bytes memory);
function performUpkeep(bytes calldata) external;
```

Register at [automation.chain.link](https://automation.chain.link)

### Option 3: Gelato Network

Use Gelato's Web3 Functions for serverless keeper execution.

### Keeper Comparison

| Method | Cost | Reliability | Setup |
|--------|------|-------------|-------|
| Self-hosted | Gas only | Depends on infra | Easy |
| Chainlink | LINK + Gas | High | Medium |
| Gelato | ETH + Gas | High | Medium |

---

## Data Sources

### Multi-Source Aggregation (8 sources)

| Source | Weight | API | Rate Limit |
|--------|--------|-----|------------|
| Fear & Greed Index | 30% | alternative.me | Unlimited |
| CoinGecko Global | 20% | coingecko.com | 30/min |
| CoinGecko Trending | 10% | coingecko.com | 30/min |
| BTC Dominance | 10% | coingecko.com | 30/min |
| DeFi Llama TVL | 10% | llama.fi | Unlimited |
| ETH Price Change | 10% | coingecko.com | 30/min |
| CryptoCompare Social | 5% | cryptocompare.com | Free tier |
| Blockchain.com Stats | 5% | blockchain.info | Unlimited |

### All Sources Are FREE

Total cost: **$0/month** for data

---

## Security Considerations

### Access Control

| Function | Access | Protection |
|----------|--------|------------|
| `updateSentiment()` | Authorized keepers | `isKeeper` mapping check |
| `setKeeper()` | Owner only | `onlyOwner` modifier |
| `setKeeperAuthorization()` | Owner only | `onlyOwner` modifier |
| `setEmaAlpha()` | Owner only | `onlyOwner` modifier |
| `setStalenessThreshold()` | Owner only | `onlyOwner` modifier |
| `transferOwnership()` | Owner only | `onlyOwner` modifier |

### Manipulation Resistance

1. **EMA Smoothing**: Prevents single-update manipulation
2. **Staleness Protection**: Falls back to default fee if data is old
3. **Bounded Fees**: Fees capped between MIN and MAX
4. **Score Validation**: Raw scores must be 0-100

### Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Keeper compromise | EMA limits impact; owner can replace keeper; multi-keeper support |
| Data source manipulation | 8 sources with weighted aggregation |
| Stale data | Auto-fallback to default fee after 6 hours |
| Front-running updates | EMA smoothing + randomized timing jitter |
| Single point of failure | Multi-keeper authorization system |

### Audit Status

⚠️ **This code has not been audited.** Use at your own risk. Recommended to get professional audit before mainnet deployment with significant TVL.

---

## Decentralization Roadmap

The hook is designed with a clear path to decentralization:

### Current Implementation (v1)
- ✅ Single keeper with staleness fallback
- ✅ EMA smoothing prevents manipulation
- ✅ Multi-keeper support (multiple authorized addresses)
- ✅ Randomized update timing (anti-frontrunning jitter)

### Short-Term (v1.5)
- 🔜 Multi-sig keeper (3-of-5 trusted updaters)
- 🔜 Chainlink Automation for reliable execution
- 🔜 Gelato Network as backup executor

### Medium-Term (v2)
- 📅 Chainlink Functions for trustless off-chain computation
- 📅 Multiple independent data aggregators
- 📅 On-chain verification of data source signatures

### Long-Term (v3)
- 🔮 Fully decentralized oracle network
- 🔮 TEE-based computation for sensitive data
- 🔮 DAO governance for parameter updates

### Multi-Keeper Usage

```solidity
// Owner can authorize multiple keepers
hook.setKeeperAuthorization(keeper1, true);
hook.setKeeperAuthorization(keeper2, true);
hook.setKeeperAuthorization(keeper3, true);

// Any authorized keeper can update
hook.updateSentiment(75); // Works from any authorized address

// Check if address is authorized
bool isKeeper = hook.isAuthorizedKeeper(someAddress);
```

### Anti-Frontrunning

The keeper includes randomized timing jitter to make update times unpredictable:

```bash
# Enable jitter (default: ±30 minutes)
JITTER_MINUTES=30 npx ts-node src/multi-source-keeper.ts

# Disable jitter for testing
npx ts-node src/multi-source-keeper.ts --no-jitter
```

---

## Configuration

### Hook Parameters

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `emaAlpha` | 30 | 1-100 | EMA smoothing factor (%) |
| `stalenessThreshold` | 6 hours | ≥1 hour | Time until data considered stale |
| `MIN_FEE` | 2500 | - | Minimum fee (0.25%) |
| `MAX_FEE` | 4400 | - | Maximum fee (0.44%) |
| `DEFAULT_FEE` | 3000 | - | Fallback fee (0.30%) |

### Keeper Configuration (.env)

```bash
# Required
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
PRIVATE_KEY=0x...
HOOK_ADDRESS=0x...

# Optional
UPDATE_INTERVAL=14400000      # 4 hours in ms
MIN_CHANGE_THRESHOLD=5        # Min score change to update
JITTER_MINUTES=30             # Random delay range for anti-frontrunning
```

---

## API Reference

### Read Functions

```solidity
// Get current sentiment score (0-100)
function sentimentScore() external view returns (uint8);

// Get current fee in basis points
function getCurrentFee() external view returns (uint24);

// Check if data is stale
function isStale() external view returns (bool);

// Get seconds until staleness
function timeUntilStale() external view returns (uint256);

// Get last update timestamp
function lastUpdateTimestamp() external view returns (uint256);

// Get primary keeper address
function primaryKeeper() external view returns (address);

// Legacy getter for backward compatibility
function keeper() external view returns (address);

// Check if address is authorized keeper
function isAuthorizedKeeper(address _address) external view returns (bool);

// Check keeper mapping directly
function isKeeper(address) external view returns (bool);

// Get EMA alpha value
function emaAlpha() external view returns (uint8);

// Get staleness threshold
function stalenessThreshold() external view returns (uint256);

// Get contract owner
function owner() external view returns (address);
```

### Write Functions

```solidity
// Update sentiment (authorized keeper only)
function updateSentiment(uint8 _rawScore) external;

// Set new primary keeper (owner only)
function setKeeper(address _newKeeper) external;

// Authorize or revoke a keeper (owner only)
function setKeeperAuthorization(address _keeper, bool _authorized) external;

// Set EMA alpha (owner only)
function setEmaAlpha(uint8 _newAlpha) external;

// Set staleness threshold (owner only)
function setStalenessThreshold(uint256 _newThreshold) external;

// Transfer ownership (owner only)
function transferOwnership(address _newOwner) external;
```

### Events

```solidity
// Emitted when sentiment score is updated
event SentimentUpdated(
    uint8 indexed previousScore,
    uint8 indexed rawScore,
    uint8 smoothedScore,
    uint256 timestamp
);

// Emitted when primary keeper changes
event PrimaryKeeperUpdated(address indexed previousKeeper, address indexed newKeeper);

// Emitted when keeper authorization changes
event KeeperAuthorizationUpdated(address indexed keeper, bool isAuthorized);

// Emitted when EMA alpha changes
event EmaAlphaUpdated(uint8 previousAlpha, uint8 newAlpha);

// Emitted when staleness threshold changes
event StalenessThresholdUpdated(uint256 previousThreshold, uint256 newThreshold);

// Emitted when ownership transfers
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

---

## Project Structure

```
sentiment-fee-hook/
├── src/
│   └── SentimentFeeHook.sol       # Main hook contract (professionally documented)
├── test/
│   ├── SentimentFeeHook.t.sol     # Unit tests (42 tests)
│   ├── SentimentFeeHook.integration.t.sol  # Integration tests (8 tests)
│   └── utils/
│       └── HookMiner.sol          # CREATE2 address mining utility
├── script/
│   ├── DeploySentimentHook.s.sol  # Production deployment
│   ├── DeployLocal.s.sol          # Local Anvil deployment
│   ├── DeployFullDemo.s.sol       # Full demo with mock tokens
│   ├── CreatePool.s.sol           # Pool creation helper
│   ├── DemoSwaps.s.sol            # Swap demonstration script
│   ├── MineHookAddress.s.sol      # Address mining utility
│   └── NetworkConfig.sol          # Multi-chain configurations
├── keeper/
│   ├── src/
│   │   ├── keeper.ts              # Basic keeper (2 sources)
│   │   └── multi-source-keeper.ts # Production keeper (8 sources, jitter)
│   ├── package.json
│   ├── tsconfig.json
│   └── .env.example
├── frontend/
│   └── demo.html                  # Interactive demo UI
├── lib/                           # Foundry dependencies
├── foundry.toml
└── README.md
```

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines

- Run `forge test` before submitting PR
- Add tests for new functionality
- Follow existing code style
- Update documentation as needed

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Acknowledgments

- [Uniswap v4](https://github.com/Uniswap/v4-core) - Hook architecture
- [Uniswap Hook Incubator](https://atrium.academy/uniswap) - Education & support
- [Alternative.me](https://alternative.me/crypto/fear-and-greed-index/) - Fear & Greed Index API
- [CoinGecko](https://www.coingecko.com/) - Market data API
- [DeFi Llama](https://defillama.com/) - TVL data API

---

## Contact

- GitHub Issues: [Report bugs or request features](https://github.com/yourusername/sentiment-fee-hook/issues)
- Twitter: [@yourhandle](https://twitter.com/yourhandle)

---

**Built for Uniswap Hook Incubator Cohort 7**
