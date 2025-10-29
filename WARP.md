# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Overview

The Grove ALM Controller is a multi-chain Active Liquidity Management system built with Foundry/Solidity. It consists of onchain components that manage liquidity across different blockchains through a proxy-controller pattern, with integrated rate limiting and cross-chain bridging capabilities.

## Core Architecture

### Proxy-Controller Pattern
- **ALMProxy**: Stateless proxy contract that holds custody of all funds and routes calls to controller contracts
- **MainnetController**: Primary controller for Ethereum mainnet operations with full DeFi protocol integrations
- **ForeignController**: Simplified controller for non-mainnet chains with basic operations
- **RateLimits**: Stateful contract that enforces and updates rate limits across all operations

### Cross-Chain Infrastructure
- **CCTP Integration**: Circle's Cross-Chain Transfer Protocol for USDC transfers
- **LayerZero Integration**: General-purpose cross-chain messaging
- **Centrifuge Integration**: Real-world asset tokenization platform connectivity

### Libraries
- **CCTPLib**: Handles USDC transfers through Circle's protocol
- **PSMLib**: Manages Peg Stability Module operations for DAI/USDS
- **CurveLib**: Curve protocol integrations for swaps and liquidity
- **CentrifugeLib**: Centrifuge protocol operations

## Development Commands

### Building
```bash
forge build                    # Build all contracts
forge build --sizes           # Build with contract size information
forge build --force           # Clean build (clears cache)
```

### Testing
```bash
forge test                     # Run all tests
forge test -vvv               # Run tests with execution traces
forge test --match-test <TestName>    # Run specific test
forge test --match-contract <ContractName>    # Run tests in specific contract
forge test --fork-url $RPC_URL    # Run tests against forked network
```

### Testing Structure
- `test/unit/`: Unit tests for individual components
  - `test/unit/rate-limits/`: Rate limiting system tests
  - `test/unit/proxy/`: ALMProxy functionality tests
- `test/grove-avalanche-fork/`: Fork tests against Avalanche network
- `test/unit/mocks/`: Mock contracts for testing

### Deployment

#### Environment Setup
Deployments require environment variables:
- `ETH_FROM`: Deployer address
- `ENV`: Environment (staging/production)
- `CHAIN`: Target chain for foreign deployments

#### Mainnet Deployments
```bash
# Full deployment (proxy, controller, rate limits)
make deploy-mainnet-production-full

# Controller only
make deploy-mainnet-production-controller

# Staging deployments
make deploy-mainnet-staging-controller
```

#### Multi-Chain Deployments
```bash
# Arbitrum One
make deploy-arbitrum-one-production-full
make deploy-arbitrum-one-production-controller

# Base
make deploy-base-production-full
make deploy-base-production-controller

# Avalanche
make deploy-avalanche-production-full

# Optimism
make deploy-optimism-production-full

# Unichain
make deploy-unichain-production-full
```

### Development Utilities
```bash
forge fmt                      # Format Solidity code
forge snapshot                 # Generate gas snapshots
forge coverage                 # Run coverage analysis
forge doc                      # Generate documentation
```

## Key Development Concepts

### Rate Limiting System
All controller operations are rate-limited using a token bucket algorithm:
- **RateLimitData**: Contains maxAmount, slope (refill rate), lastAmount, lastUpdated
- **Key Generation**: Uses `RateLimitHelpers` for asset-specific, domain-specific keys
- **Modifiers**: Controllers use `rateLimited` modifiers to enforce limits automatically

### Role-Based Access Control
- **DEFAULT_ADMIN_ROLE**: Full system administration
- **CONTROLLER**: Granted to controller contracts for proxy interaction
- **RELAYER**: Operations role for executing bridging/transfer functions
- **FREEZER**: Emergency role that can disable relayers

### Multi-Chain Asset Management
- **Mainnet**: Full DeFi ecosystem integration (Aave, Curve, PSM, Centrifuge, Ethena)
- **Foreign Chains**: Simplified operations focused on USDC bridging and basic yield

### Configuration Management
Deploy scripts use JSON configuration files in `script/input/` directory:
- Format: `{chain}-{environment}.json`
- Contains addresses for external protocol integrations
- Exported contract addresses saved to `script/output/`

## Contract Interactions

### ALMProxy Functions
- `doCall(target, data)`: Execute arbitrary calls to external contracts
- `doCallWithValue(target, data, value)`: Execute calls with ETH value
- `doDelegateCall(target, data)`: Execute delegate calls

### Controller Functions
Controllers provide protocol-specific functions:
- **ERC4626 Operations**: `deposit4626`, `withdraw4626`
- **Aave Operations**: `depositAave`, `withdrawAave`  
- **Cross-Chain**: `transferUSDCToCCTP`, `sendLayerZero`
- **Rate Limit Management**: Built into all operations via modifiers

### Libraries Usage
Libraries are used for complex operations:
```solidity
CCTPLib.transferUSDCToCCTP(params);     // CCTP transfers
PSMLib.swapUSDStoUSDC(params);          // PSM operations
CurveLib.deposit(params);               // Curve liquidity
```

## Testing Patterns

### Fork Testing
Use fork tests for integration testing against live networks:
```solidity
vm.createSelectFork("mainnet", blockNumber);
```

### Mock Contracts
Extensive mocks in `test/unit/mocks/` for isolated unit testing

### Rate Limit Testing  
Rate limits have dedicated test suites in `test/unit/rate-limits/`

## Common Gotchas

- **Rate Limits**: All operations must have corresponding rate limits configured
- **Multi-Chain**: Different controllers have different capabilities - don't assume mainnet functions exist on foreign chains
- **Proxy Pattern**: Always call through proxy for state-changing operations
- **CCTP Limits**: USDC transfers may be split across multiple transactions due to burn limits
- **Gas Optimization**: Optimizer runs set to 1 for deployment cost optimization over runtime efficiency
