# Reserve Folio

## Overview

The Reserve Folio protocol is a platform for creating and managing portfolios of onchain, ERC20-compliant assets. Folios are designed to be used as a single-source of truth for asset allocations, enabling the composability of complex, multi-asset portfolios.

Folios support rebalancing trades via dutch auction over an exponential decay curve between two prices. Control flow over the trade is shared between two parties, with a TRADE_PROPOSER approving trades and a PRICE_CURATOR opening them.

TRADE_PROPOSER is expected to be the timelock of the fast-moving governor associated with the Folio.

PRICE_CURATOR is expected to be a semi-trusted EOA or multisig: they can open trades within the bounds set by governance, hopefully adding precision. If they are offline, the trade can be opened permissionlessly after a preset delay. If they are evil, at-best they can prevent a Folio from rebalancing by killing trades, but they cannot access the backing directly.

## Architecture

### 1. **Folio Contracts**

- **Folio.sol**: The primary contract in the system. Represents a portfolio of ERC20 assets, and contains all trading logic
- **FolioDeployer.sol**: Manages the deployment of new Folio instances
- **FolioVersionRegistry.sol**: Keeps track of various versions of FolioDeployer
- **FolioProxy.sol**: A proxy contract for delegating calls to a Folio implementation that checks upgrades with FolioVersionRegistry
- **FolioDAOFeeRegistry.sol**: Handles the fees associated with the broader ecosystem DAO that Folios pay into

While not included directly, FolioVersionRegistry and FolioDAOFeeRegistry also depend on a pre-existing `RoleRegistry` instance. This contract must adhere to the [contracts/interfaces/IRoleRegistry.sol](contracts/interfaces/IRoleRegistry.sol) interface.

### 2. **Governance**

- **GovernanceDeployer.sol**: Deploys staking tokens and governing systems
- **FolioGovernor.sol**: Canonical governor in the system, time-based

### 3. **Staking**

- **StakingVault.sol**: A vault contract that holds staked tokens and allows users to earn rewards simultaneously in multiple reward tokens. Central voting token for all types of governance

## Roles

### Folio

A Folio has 3 roles:

1. DEFAULT_ADMIN_ROLE
   - Expected: Slow Timelocked Folio Governor
   - Can add/remove assets, set fees, configure auction length, and set the trade delay
   - Can configure the TRADE_PROPOSER / PRICE_CURATOR
2. TRADE_PROPOSER
   - Expected: Fast Timelocked Folio Governor
   - Can approve trades
3. PRICE_CURATOR
   - Expected: EOA or multisig
   - Can open and kill trades

### StakingVault

The staking vault has ONLY a single owner:

- Expected: Community Timelocked Governor
- Can add/remove reward tokens, set reward half-life, and set unstaking delay

## Fee Structure

- Folios maintain a governance-controlled `folioFee`, representing the % of the total value of a Folio that should be extracted as a fee
- Within the `folioFee`, the DAO takes a cut based on `FolioDAOFeeRegistry.getFeeDetails()`
- The remaining portion is distributed prorata to `feeRecipients[]` based on their configured portions

## Future Work / Not Implemented Yet

1. **delegatecall functionality / way to claim rewards**
   currently there is no way to claim rewards, for example to claim AERO as a result of holding a staked Aerodrome position. An autocompounding layer such as beefy or yearn would be required in order to put this kind of position into a Folio
2. **alternative communiuty governance systems**
   currently only bring-your-own-erc20 governance is supported but we would like to add alternatives in the future such as (i) NFT-based governance; and (ii) an ERC20 fair launch system
3. **price-based rebalancing**
   currently rebalancing is trade-driven, at the quantity level. this requires making projections about how many tokens will be held at the time of execution and what their values will be. in an alternative price-based world, governance provides a target basket in terms of share-by-value and a trusted party provides prices at time of execution to convert this into a concrete set of quantities/quantity-ratios
