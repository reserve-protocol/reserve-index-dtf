# Reserve Folio

## Overview

Reserve Folio is a protocol for creating and managing portfolios of ERC20-compliant assets entirely onchain. Folios are designed to be used as a single-source of truth for asset allocations, enabling composability of complex, multi-asset portfolios.

To change their composition, Folios support a rebalancing process over a finite period of time during which either the `AUCTION_LAUNCHER` or anyone else can start Dutch Auctions to rebalance the Folio toward the rebalance targets. Each Dutch Auction manifests as an exponential decay between two prices under the assumption that the ideal clearing price (incl slippage) lies in between the price bounds.

The `AUCTION_LAUNCHER` is trusted to be provide additional precision to the rebalance process, either by: (i) modifying the rebalance targets; or (ii) tweaking the auction price curve, within reason. In both cases, the `AUCTION_LAUNCHER` is bound to act within the bounds set by the `REBALANCE_MANAGER`. If an auction is opened permissionlessly instead, the caller has no sway over the rebalance targets or price curve. Rebalances _away_ from the rebalance targets are always disallowed.

`REBALANCE_MANAGER` is expected to be the timelock of the rebalancing governor associated with the Folio.

`AUCTION_LAUNCHER` is expected to be a semi-trusted EOA or multisig; They can open auctions within the bounds set by governance, hopefully adding basket definition and pricing precision. If they are offline the auction can be opened through the permissonless route instead. If the `AUCTION_LAUNCHER` is not just offline but actively evil, at-best they can maximally deviate rebalancing within the governance-granted range, or prevent a Folio from rebalancing entirely by repeatedly closing-out auctions. (TODO follow-up after deciding on whether to keep the "no backpedaling" property during audit, in which case they can also cause double-trading arbitrarily)

There is no limit to how many auctions can be opened during a rebalance, just how many auction lengths fit within the rebalance period.

### Architecture

#### 0. **DAO Contracts**

- **FolioDAOFeeRegistry.sol**: Handles the fees associated with the broader ecosystem DAO that Folios pay into.
- **FolioVersionRegistry.sol**: Keeps track of various versions of `FolioDeployer`, owned by the DAO.

While not included directly, `FolioVersionRegistry` and `FolioDAOFeeRegistry` also depend on an existing `RoleRegistry` instance. This contract must adhere to the [contracts/interfaces/IRoleRegistry.sol](contracts/interfaces/IRoleRegistry.sol) interface.

#### 1. **Folio Contracts**

- **Folio.sol**: The primary contract in the system. Represents a portfolio of ERC20 assets, and contains auction logic that enables it to rebalance its holdings.
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
   - Can add/remove assets, set fees, configure auction length, set the auction delay, and closeout auctions
   - Can configure the `REBALANCE_MANAGER`/ `AUCTION_LAUNCHER`
   - Primary owner of the Folio
2. `REBALANCE_MANAGER`
   - Expected: Timelock of Fast Folio Governor
   - Can start rebalances
3. `AUCTION_LAUNCHER`
   - Expected: EOA or multisig
   - Can open and close auctions, optionally altering parameters of the auction within the approved ranges

##### StakingVault

The staking vault has ONLY a single owner:

- Expected: Timelock of Community Governor
- Can add/remove reward tokens, set reward half-life, and set unstaking delay

### Rebalancing

##### Rebalance Lifecycle

1. A rebalance is started by the `REBALANCE_MANAGER`, including initial prices for each asset as well as a range for basket ratios
2. An auction is opened on a token pair, initiating the progression through a predetermined price curve
   a. ...either by the auction launcher (optionally tweaking basket ratios / prices)
   b. ...or permissionlessly (after the restricted period passes)
3. Bids occur
4. Auction expires

A rebalance can have any number of auctions running in parallel. At anytime any auction can be closed or a new rebalance can be started, closing all running auctions.

##### Rebalance Usage

###### Auction Launcher Window

Rebalances first pass through a restricted period where only the `AUCTION_LAUNCHER` can open auctions. This is to ensure that the `AUCTION_LAUNCHER` always has time to act first. Additionally, there is always >= 120s buffer before an auction can be opened permissionlessly.

###### TTL

Rebalances have a time-to-live (TTL) that controls how long the rebalance can run. Any number of auctions can be opened during this time. Note: an auction can be opened at `ttl - 1` and run beyond the rebalance's TTL.

###### Buy/Sell limits

The `REBALANCE_MANAGER` configures buy and sell limits for the basket ratios, including a spot estimate:

```solidity
struct RebalanceDetails {
  bool inRebalance;
  BasketRange limits; // D27{tok/share}
  Prices prices; // D27{UoA/tok} prices can be in any Unit of Account as long as it's consistent across the rebalance
}

struct BasketRange {
  uint256 spot; // D27{tok/share}
  uint256 low; // D27{tok/share} inclusive
  uint256 high; // D27{tok/share} inclusive
}

struct Prices {
  uint256 low; // D27{UoA/tok}
  uint256 high; // D27{UoA/tok}
}
```

During `openAuction` the `AUCTION_LAUNCHER` can set new spot limits as long as it is within the ranges initially provided by the `REBALANCE_MANAGER`. If the auction is opened permissionlessly, the pre-approved spot estimates will be used instead.

###### Price

For each token supplied to the rebalance, the `REBALANCE_MANAGER` provides a `low` and `high` price estimate. These should be set such that in the vast majority (99.9%+) of scenarios, the asset's price on secondary markets lies within the provided range. If the price of an asset rises above its `high` price, this can result in a loss of value for Folio holders due to the auction price curve on a token pair starting at too-low-a-price.

When an auction is started, the `low` and `high` prices for both assets are used to calculate a `startPrice` and `endPrice` for the auction.

There are 2 ways to price assets, depending on the risk tolerance of the `REBALANCE_MANAGER`:

1. **Priced**

- The `REBALANCE_MANAGER` provides a list of NONZERO prices for each token. No token price can be 0.
- The `AUCTION_LAUNCHER` can always choose to raise the starting price up to 100x from the natural starting price, or raise the ending price arbitrarily (up to the starting price). They cannot lower either price.

2. **Unpriced**

- The `REBALANCE_MANAGER` provides ALL 0 prices for each token. This allows the `AUCTION_LAUNCHER` to set prices freely and prevents auctions from being opened permissionlessly.

Overall the price range for any dutch auction (`startPrice / endPrice`) must be less than `1e9` to prevent precision issues. (TODO limit to 1e4 range per token in startRebalance?)

###### Price Curve

![alt text](auction.png "Auction Curve")

Note: The first block may not have a price of exactly `startPrice` if it does not occur on the `start` timestamp. Similarly, the `endPrice` may not be exactly `endPrice` in the final block if it does not occur on the `end` timestamp.

###### Lot Sizing

Auctions are sized by the difference between current balances and the basket ratios provided by the `limits`.

The auction `sellAmount` represents the single largest quantity of sell token that can be transacted without violating the `limits` of either tokens in the pair.

In general it is possible for the `sellAmount` to either increase or decrease over time, depending on whether the surplus of the sell token or deficit of the buy token is the limiting factor.

1. If the surplus of the sell token is the limiting factor, the `sellAmount` will increase over time.
2. If the deficit of the buy token is the limiting factor, the `sellAmount` will decrease over time.

###### Auction Participation

Anyone can bid in any auction up to and including the `sellAmount` size, as long as the `price` exchange rate is met.

```
/// @return sellAmount {sellTok} The amount of sell token on sale in the auction at a given timestamp
/// @return bidAmount {buyTok} The amount of buy tokens required to bid for the full sell amount
/// @return price D27{buyTok/sellTok} The price at the given timestamp as an 27-decimal fixed point
function getBid(
   uint256 auctionId,
   uint256 timestamp,
   uint256 maxSellAmount
) external view returns (uint256 sellAmount, uint256 bidAmount, uint256 price);
```

### Fee Structure

Folios support 2 types of fees. Both have a DAO portion that work the same underlying way, placing limits on how small the fee can be.

##### `tvlFee`

**Per-unit time fee on AUM**

The DAO takes a cut with a minimum floor of 15 bps. A consequence of this is that the Folio always inflates at least 15 bps annually. If the tvl fee is set to 15 bps, then 100% of this inflation goes towards the DAO.

Max: 10% annualy

##### `mintFee`

**Fee on mints**

The DAO takes a cut with a minimum floor of 15 bps. The DAO always receives at least 15 bps of the value of the mint. If the mint fee is set to 15 bps, then 100% of the mint fee is taken by the DAO.

Max: 5%

#### Fee Floor

The universal 15 bps fee floor can be lowered by the DAO, as well as set (only lower) on a per Folio basis.

### Units

Units are documented with curly brackets (`{}`) throughout the codebase with the additional `D18` or `D27` prefixes being used to denote when additional decimals of precision have been applied, for example in the case of a ratio. Percentages are generally 18-decimal throughout the codebase while exchange rates and prices are 27-decimal.

Units:

- `{tok}` OR `{share}` OR `{reward}`: token balances
- `D27`: 1e27
- `D18`: 1e18
- `D18{1}`: a percentage value with 18 decimals of added precision
- `D27{tok/share}`: a ratio of token quanta to Folio share quanta, with 27 decimals of precision
- `D27{UoA/tok}`: a price in USD per token quanta, with 27 decimals of precision
- `D27{tok1/tok2}`: a ratio of two token balances, with 27 decimals of precision
- `{s}`: seconds

Example:

````

    // {share} = {share} * D18{1} / D18
    uint256 shares = (pendingFeeShares * feeRecipients[i].portion) / D18;

```

### Valid Ranges

Tokens are assumed to be within the following ranges:

|              | Folio | Folio Collateral | StakingVault | StakingVault underlying/rewards |
| ------------ | ----- | ---------------- | ------------ | ------------------------------- |
| **Supply**   | 1e36  | 1e36             | 1e36         | 1e36                            |
| **Decimals** |       | 27               |              | 21                              |

It is the job of governance to ensure the Folio supply does not grow beyond 1e36 supply.

Exchange rates for rebalance limits are permitted to be up to 1e54, and are 27 decimal fixed point numbers.

Prices for individual tokens are permitted to be up to 1e36, and are 27 decimal fixed point numbers.

Prices for auctions are permitted to be up to 1e63, and are 27 decimal fixed point numbers.

### Weird ERC20s

Some ERC20s are NOT supported

| Weirdness                      | Folio | StakingVault |
| ------------------------------ | ----- | ------------ |
| Multiple Entrypoints           | ❌    | ❌           |
| Pausable / Blocklist           | ❌    | ❌           |
| Fee-on-transfer                | ❌    | ❌           |
| ERC777 / Callback              | ❌    | ❌           |
| Downward-rebasing              | ✅    | ❌           |
| Upward-rebasing                | ✅    | ❌           |
| Revert on zero-value transfers | ✅    | ✅           |
| Flash mint                     | ✅    | ✅           |
| Missing return values          | ✅    | ✅           |
| No revert on failure           | ✅    | ✅           |

Note: While the Folio itself is not susceptible to reentrancy, read-only reentrancy on the part of a consuming protocol is still possible. To check for reentrancy, call `stateChangeActive()` and require that both return values are false. The (non-ERC20) Folio mutator calls are all `nonReentrant` and will close async actions as a pre-hook, but for view functions this check is important to perform before relying on any returned data.

### Chain Assumptions

The chain is assumed to have block times under 60s. The `AUCTION_LAUNCHER` has 120s reserved to act first before anyone else can open an auction.

### Governance Guidelines

- If governors plan to remove a token from the basket via `Folio.removeFromBasket()`, users will only have a limited amount of time to redeem before the token becomes inaccessible. Removal should only be used if the reward token has become malicious or otherwise compromised.

### Future Work / Not Implemented Yet

1. **`delegatecall` functionality / way to claim rewards**
   currently there is no way to claim rewards, for example to claim AERO as a result of holding a staked Aerodrome position. An autocompounding layer such as beefy or yearn would be required in order to put this kind of position into a Folio
2. **alternative community governance systems**
   we would like to add alternatives in the future such as (i) NFT-based governance; and (ii) an ERC20 fair launch system

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
5. Deployment:
   - Deployment: `yarn deploy --rpc-url <RPC_URL> --verify --verifier etherscan`
     Set ETHERSCAN_API_KEY env var to the API key for whichever network you're targeting (basescan, etherscan, arbiscan, etc)
```
````
