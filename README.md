# Reserve Folio

## Overview

The Reserve Folio protocol is a platform for creating and managing portfolios of onchain, ERC20-compliant assets.

Folios support rebalancing via dutch auction. The TRADE_PROPOSER role (expected: Governance) may approve trades over a range of prices. These trades can be permissionlessly opened after an additional delay, or immediately opened by a PRICE_CURATOR (expected: semi-trusted EOA). Folios can function with or without price curators, however, the price curator is bound to act within the bounds set by governance.

## Roles

### Folio

A Folio has 3 roles:

1. DEFAULT_ADMIN_ROLE
   - Expected: Slow Timelocked Governor
   - Can add/remove assets, set fees, configure auction length, and set the trade delay
   - Can set the TRADE_PROPOSER / PRICE_CURATOR
2. TRADE_PROPOSER
   - Expected: Fast Timelocked Governor
   - Can approve trades
3. PRICE_CURATOR
   - Expected: EOA or multisig
   - Can open and kill trades

### StakingVault

The staking vault has ONLY a single owner:

- Expected: Community Timelocked Governor
- Can add/remove reward tokens, set reward half-life
- Can set unstaking delay

## Architecture

### 1. **Core Contracts**

- **Folio.sol**: The primary contract in the system. Represents a portfolio of ERC20 assets, and contains all trading logic.
- **FolioDeployer.sol**: Manages the deployment of new Folio instances.
- **FolioVersionRegistry.sol**: Keeps track of various versions of FolioDeployer.
- **FolioProxy.sol**: A proxy contract for delegating calls to the latest Folio implementation.
- **FolioDAOFeeRegistry.sol**: Handles the fees associated with the broader ecosystem DAO

### 2. **Governance**

- **GovernanceDeployer.sol**: Deploys staking tokens and governing systems. To be extended over time as more ways of creating communities are developed.
- **FolioGovernor.sol**: Implements the governance logic for ALL instances of governors in the system.

### 3. **Staking**

- **StakingVault.sol**: A vault contract that holds staked tokens and allows users to claim rewards in multiple tokens. Voting token for governance.

## Testing

TODO

- unit test all basic functionality in isolation, using mocks where necessary
  - Folio.sol
  - FolioDutchTrade.sol
- integration test all core functionality, using mocks where necessary
  - Folio.sol + FolioDutchTrade.sol
- fork test all core functionality using invariants
  - mainnet, base, (arbitrum?, optimism?)
- extreme test all core functionality (parameters and units at the extreme ends of what the protocol accepts)
  - token decimals (esp with high unit bias)
  - basket sizes
  - demurrage
  - price oracle trade prices
