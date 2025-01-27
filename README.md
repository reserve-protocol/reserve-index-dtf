# Reserve Folio

## Overview

Reserve Folio is a protocol for creating and managing portfolios of ERC20-compliant assets entirely onchain. Folios are designed to be used as a single-source of truth for asset allocations, enabling composability of complex, multi-asset portfolios.

Folios support rebalancing trades via Dutch Auction over an exponential decay curve between two prices. Control flow over the trade is shared between two parties, with a `TRADE_PROPOSER` approving trades in advance and a `TRADE_LAUNCHER` opening them, optionally providing some amount of additional detail.

`TRADE_PROPOSER` is expected to be the timelock of the fast-moving trade governor associated with the Folio.

`TRADE_LAUNCHER` is expected to be a semi-trusted EOA or multisig; They can open trades within the bounds set by governance, hopefully adding basket definition and pricing precision. If they are offline the trade can be opened permissionlessly after a preset delay. If they are evil, at-best they can deviate trading within the governance-granted range, or prevent a Folio from rebalancing entirely by killing trades. They cannot access the backing directly.

### Architecture

#### 0. **DAO Contracts**

- **FolioDAOFeeRegistry.sol**: Handles the fees associated with the broader ecosystem DAO that Folios pay into.
- **FolioVersionRegistry.sol**: Keeps track of various versions of `FolioDeployer`, owned by the DAO.

While not included directly, `FolioVersionRegistry` and `FolioDAOFeeRegistry` also depend on an existing `RoleRegistry` instance. This contract must adhere to the [contracts/interfaces/IRoleRegistry.sol](contracts/interfaces/IRoleRegistry.sol) interface.

#### 1. **Folio Contracts**

- **Folio.sol**: The primary contract in the system. Represents a portfolio of ERC20 assets, and contains all trading logic.
- **FolioDeployer.sol**: Manages the deployment of new Folio instances.
- **FolioProxy.sol**: A proxy contract for delegating calls to a Folio implementation that checks upgrades with `FolioVersionRegistry`.

#### 2. **Governance**

- **FolioGovernor.sol**: Canonical governor in the system, time-based.
- **GovernanceDeployer.sol**: Deploys staking tokens and governing systems.

#### 3. **Staking**

- **StakingVault.sol**: A vault contract that holds staked tokens and allows users to earn rewards simultaneously in multiple reward tokens. Central voting token for all types of governance.

### Roles

##### Folio

A Folio has 3 roles:

1. `DEFAULT_ADMIN_ROLE`
   - Expected: Timelock of Slow Folio Governor
   - Can add/remove assets, set fees, configure auction length, and set the trade delay
   - Can configure the `TRADE_PROPOSER`/ `TRADE_LAUNCHER`
   - Primary owner of the Folio
2. `TRADE_PROPOSER`
   - Expected: Timelock of Fast Folio Governor
   - Can approve trades
3. `TRADE_LAUNCHER`
   - Expected: EOA or multisig
   - Can open and kill trades, optionally altering parameters of the trade within the approved ranges

##### StakingVault

The staking vault has ONLY a single owner:

- Expected: Timelock of Community Governor
- Can add/remove reward tokens, set reward half-life, and set unstaking delay

### Trading

##### Trade Lifecycle

1. Trade is approved by governance, including an initial price range
2. Trade is opened, starting a dutch auction
   a. ...either by the trade launcher (immediately)
   b. ...or permissionlessly (after a delay)
3. Bids occur
4. Auction expires

##### Auction Usage

###### Buy/Sell limits

Governance configures a range for the buy and sell limits, including a spot estimate:

```solidity
struct Range {
  uint256 spot; // D27{buyTok/share}
  uint256 low; // D27{buyTok/share} inclusive
  uint256 high; // D27{buyTok/share} inclusive
}

Range sellLimit; // D27{sellTok/share} min ratio of sell token to shares allowed, inclusive
Range buyLimit; // D27{buyTok/share} min ratio of sell token to shares allowed, exclusive
```

During `openTrade` the `TRADE_LAUNCHER` can set the buy and sell limits within the approved ranges provided by governance. If the trade is opened permissionlessly instead, the governance pre-approved spot estimates will be used instead.

###### Price

There are broadly 3 ways to parametrize `[startPrice, endPrice]`, as the `TRADE_PROPOSER`:

1. Can provide `[0, 0]` to _fully_ defer to the trade launcher for pricing. In this mode the auction CANNOT be opened permissionlessly. Loss can arise either due to the trade launcher setting `startPrice` too low, or due to precision issues from traversing too large a range.
2. Can provide `[startPrice, 0]` to defer to the trade launcher for _just_ the `endPrice`. In this mode the auction CANNOT be opened permissionlessly. Loss can arise due solely to precision issues only.
3. Can provide `[startPrice, endPrice]` to defer to the trade launcher for the `startPrice`. In this mode the auction CAN be opened permissionlessly, after a delay. Suggested default option.

The `TRADE_LAUNCHER` can always choose to raise `startPrice` within a limit of 100x, and `endPrice` by any amount. They cannot lower either value.

The price range (`startPrice / endPrice`) must be less than `1e9` to prevent precision issues.

##### Auction Dynamics

###### Price Curve

![alt text](auction.png "Auction Curve")

Note: The first block may not have a price of exactly `startPrice`, if it does not occur on the `start` timestamp. Similarly, the `endPrice` may not be exactly `endPrice` in the final block if it does not occur on the `end` timestamp.

###### Lot Sizing

Auction lots are sized by `Trade.sellLimit` and `Trade.buyLimit`. Both correspond to invariants about the auction that should be maintained throughout the auction:

- `sellLimit` is the minimum ratio of sell token to the Folio token
- `buyLimit` is the maximum ratio of buy token to Folio token

The auction `lot()` represents the single largest quantity of sell token that can be transacted under these invariants.

In general it is possible for the `lot` to both increase and decrease over time, depending on whether `sellLimit` or `buyLimit` is the constraining factor.

###### Auction Participation

Anyone can bid in any auction in size up to and including the `lot` size. Use `getBid()` to determine the amount of buy tokens required in any given timestamp.

`Folio.getBid(uint256 tradeId, uint256 timestamp, uint256 sellAmount) external view returns (uint256 bidAmount)`

### Fee Structure

Folios support 2 types of fee

##### `folioFee`

Per-unit time fee on AUM

The DAO takes a cut

##### `mintingFee`

Fee on mints

The DAO takes a cut with a minimum floor of 5 bps. The DAO always receives at least 5 bps of the value of the mint. If the minting fee is set to 5 bps, then 100% of the minting fee is taken by the DAO.

### Units

Units are documented with curly brackets (`{}`) throughout the codebase with the additional `D18` or `D27` prefixes being used to denote when additional decimals of precision have been applied, for example in the case of a ratio. Amounts and percentages are generally 18-decimal throughout the codebase, but exchange rates are generally 27-decimal.

Units:

- `{tok}` OR `{share}` OR `{reward}`: token balances
- `D27`: 1e27
- `D18`: 1e18
- `D18{tok}`: a ratio of two token balances with 18 decimals of added precision
- `D18{1}`: a percentage value with 18 decimals of added precision
- `D18{tok1/tok2}`: a ratio of two token balances with 18 decimals of added precision
- `{s}`: seconds

Example:

```
    // {share} = {share} * D18{1} / D18
    uint256 shares = (pendingFeeShares * feeRecipients[i].portion) / SCALAR;
```

### Valid Ranges

Tokens are assumed to be within the following ranges:

|              | Folio | Folio Collateral | StakingVault | StakingVault underlying/rewards |
| ------------ | ----- | ---------------- | ------------ | ------------------------------- |
| **Supply**   | 1e36  | 1e36             | 1e36         | 1e36                            |
| **Decimals** |       | 27               |              | 21                              |

It is the job of governance to ensure the Folio supply does not grow beyond 1e36 supply.

Exchange rates / prices are permitted to be up to 1e54, and are 27 decimal fixed point numbers instead of 18.

### Weird ERC20s

Some ERC20s are NOT supported

| Weirdness                      | Folio | StakingVault |
| ------------------------------ | ----- | ------------ |
| Multiple Entrypoints           | ❌    | ❌           |
| Pausable / Blocklist           | ❌    | ❌           |
| Fee-on-transfer                | ❌    | ❌           |
| ERC777 / Callback              | ✅    | ❌           |
| Downward-rebasing              | ✅    | ❌           |
| Upward-rebasing                | ✅    | ❌           |
| Revert on zero-value transfers | ✅    | ✅           |
| Flash mint                     | ✅    | ✅           |
| Missing return values          | ✅    | ✅           |
| No revert on failure           | ✅    | ✅           |

Note: While the Folio itself is not susceptible to reentrancy, read-only reentrancy on the part of a consuming protocol is still possible.

### Governance Guidelines

- After governors remove a token from the basket via `Folio.removeFromBasket()`, users have a limited amount of time to claim rewards. Removal should only be used if the reward token has become malicious or otherwise compromised.
-

TODO

### Future Work / Not Implemented Yet

1. **`delegatecall` functionality / way to claim rewards**
   currently there is no way to claim rewards, for example to claim AERO as a result of holding a staked Aerodrome position. An autocompounding layer such as beefy or yearn would be required in order to put this kind of position into a Folio
2. **alternative community governance systems**
   currently only bring-your-own-erc20 governance is supported but we would like to add alternatives in the future such as (i) NFT-based governance; and (ii) an ERC20 fair launch system
3. **price-based rebalancing**
   currently rebalancing is trade-driven, at the quantity level. this requires making projections about how many tokens will be held at the time of execution and what their values will be. in an alternative price-based world, governance provides a target basket in terms of share-by-value and a trusted party provides prices at time of execution to convert this into a concrete set of quantities/quantity-ratios

### Development

1. Required Tools:
   - Foundry
   - Node v20+
   - Yarn
2. Install Dependencies: `yarn install`
3. Build: `yarn compile`
4. Testing:
   - Basic Tests: `yarn test`
   - Extreme Tests: `yarn test:extreme`
   - All Tests: `yarn test:all`
