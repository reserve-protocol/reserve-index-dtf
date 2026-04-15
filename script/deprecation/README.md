# Index DTF Deprecation

Full deprecation of an Index DTF renders it permanently in **redemption-only mode** with no governance control and no upgrade path.

## Deprecation Actions

A single governance proposal performs all of the following atomically:

1. **`deprecateFolio()`** — sets `isDeprecated = true`, blocking minting, auctions, and rebalancing
2. **`revokeRole(REBALANCE_MANAGER, tradingTimelock)`** — removes basket management capability
3. **`revokeRole(AUCTION_LAUNCHER, ...)`** — removes all auction launcher addresses (one call per launcher)
4. **`revokeRole(DEFAULT_ADMIN_ROLE, ownerTimelock)`** — removes governance control from the Folio
5. **`renounceOwnership()`** on `FolioProxyAdmin` — permanently prevents contract upgrades

The admin role revocation must come before the ProxyAdmin renounce, so the timelock still has permission to execute all prior calls.

### Post-Deprecation State

- `isDeprecated = true` — minting, auctions, rebalancing all blocked
- All roles revoked — no address holds `DEFAULT_ADMIN_ROLE`, `REBALANCE_MANAGER`, or `AUCTION_LAUNCHER`
- ProxyAdmin owner is `address(0)` — no further upgrades possible
- **Redeem still works** — holders can always redeem shares for underlying basket tokens
- **Unstake/withdraw still works** — stakers can still exit the StakingVault

## Generating Proposals

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) installed (`cast` CLI)

### Script

```bash
bash script/deprecation/generate-deprecation-proposals.sh
```

This generates one Safe Transaction Builder JSON per DTF in `script/deprecation/proposals/`.

### Adding a New DTF

Add a call to `generate_proposal` in the script:

```bash
generate_proposal "<SYMBOL>" "<CHAIN_ID>" \
  "<folio_address>" \
  "<owner_governor_address>" \
  "<owner_timelock_address>" \
  "<trading_timelock_address|none>" \
  "<proxy_admin_address>" \
  "<auction_launcher_1>" \
  "<auction_launcher_2>" \
  ...
```

**Finding the addresses:**

- **Folio** — the DTF token contract
- **Owner Governor** — the FolioGovernor that controls the Folio's admin role
- **Owner Timelock** — `governor.timelock()`
- **Trading Timelock** — the address holding `REBALANCE_MANAGER` (or `"none"` if not applicable)
- **ProxyAdmin** — read from the ERC1967 admin storage slot:
  ```bash
  cast storage <folio_address> 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103 --rpc-url <rpc>
  ```
- **Auction Launchers** — all addresses holding `AUCTION_LAUNCHER` role on the Folio

### Output Format

Each JSON follows the [Safe Transaction Builder](https://help.safe.global/en/articles/40841-transaction-builder) format:

```json
{
  "version": "1.0",
  "chainId": "<chain_id>",
  "createdAt": <timestamp>,
  "meta": { "name": "Deprecate <SYMBOL>", "description": "..." },
  "transactions": [
    {
      "to": "<owner_governor>",
      "value": "0",
      "data": "<abi_encoded_propose_call>"
    }
  ]
}
```

The `data` field is an ABI-encoded `propose(address[],uint256[],bytes[],string)` call containing all deprecation actions.

## Submitting Proposals

1. Open the [Safe Transaction Builder](https://app.safe.global) for the appropriate chain
2. Upload the JSON file for the DTF
3. Verify the parsed calls match expected actions (use `cast 4byte-decode <data>` to decode)
4. Submit and sign the transaction
5. Vote on the proposal through the Governor
6. After the voting period + timelock delay, execute the proposal

### Re-submitting Expired Proposals

If a proposal expires (missed the voting deadline), append a suffix to the description (e.g., `"(2)"`) to generate a different proposal ID hash. The Governor rejects duplicate proposal IDs.

## Verifying On-Chain

After execution, verify the deprecation state:

```bash
# Check deprecated flag
cast call <folio> "isDeprecated()(bool)" --rpc-url <rpc>

# Check all roles revoked
cast call <folio> "getRoleMemberCount(bytes32)(uint256)" 0x00 --rpc-url <rpc>
cast call <folio> "getRoleMemberCount(bytes32)(uint256)" 0x4ff6ae4d6a29e79ca45c6441bdc89b93878ac6118485b33c8baa3749fc3cb130 --rpc-url <rpc>
cast call <folio> "getRoleMemberCount(bytes32)(uint256)" 0x13ff1b2625181b311f257c723b5e6d366eb318b212d9dd694c48fcf227659df5 --rpc-url <rpc>

# Check ProxyAdmin ownership renounced
cast call <proxy_admin> "owner()(address)" --rpc-url <rpc>

# Check proposal state (7 = Executed)
cast call <governor> "state(uint256)(uint8)" <proposal_id> --rpc-url <rpc>
```

## Fork Tests

Two test suites validate the deprecation flow against live on-chain state:

### Direct Simulation (`test/DeprecationFork.t.sol`)

Pranks as the owner timelock to execute all deprecation steps directly on a fork.

```bash
FORK_RPC_MAINNET="<archive_rpc>" FORK_RPC_BASE="<archive_rpc>" \
  forge test --match-contract DeprecationForkTest --evm-version cancun -vv
```

### On-Chain Proposal Execution (`test/DeprecationProposalFork.t.sol`)

Retrieves an actual queued proposal on-chain, warps past the timelock ETA, and executes it through the Governor.

```bash
FORK_RPC_MAINNET="<archive_rpc>" \
  forge test --match-contract DeprecationProposalFork --evm-version cancun -vv
```

### What the Tests Verify

- `isDeprecated` set to `true`
- All role counts drop to zero (`DEFAULT_ADMIN_ROLE`, `REBALANCE_MANAGER`, `AUCTION_LAUNCHER`)
- **Redeem works** — 1 share redeemed, assets received > 0
- **Mint blocked** — reverts with `Folio__FolioDeprecated`
- **Unstake/withdraw works** — StakingVault shares redeemed, lock claimed after delay, underlying tokens received
- ProxyAdmin ownership renounced to `address(0)`

### Requirements

- **`--evm-version cancun`** — required because some basket tokens (e.g., ENA) use the `PUSH0` opcode which is not available in the default `paris` EVM version
- **Archive RPC endpoints** — the tests pin to historical blocks (before deprecation was executed), so standard RPCs that don't serve historical state will fail. Set `FORK_RPC_MAINNET` and `FORK_RPC_BASE` environment variables to archive node URLs (e.g., Alchemy)

## Reference

### Function Selectors

| Function                                      | Selector     |
| --------------------------------------------- | ------------ |
| `deprecateFolio()`                            | `0x7aeaafb3` |
| `revokeRole(bytes32,address)`                 | `0xd547741f` |
| `renounceOwnership()`                         | `0x715018a6` |
| `propose(address[],uint256[],bytes[],string)` | `0x7d5e81e2` |

### Role Hashes

| Role                 | Hash                                                                 |
| -------------------- | -------------------------------------------------------------------- |
| `DEFAULT_ADMIN_ROLE` | `0x0000000000000000000000000000000000000000000000000000000000000000` |
| `REBALANCE_MANAGER`  | `0x4ff6ae4d6a29e79ca45c6441bdc89b93878ac6118485b33c8baa3749fc3cb130` |
| `AUCTION_LAUNCHER`   | `0x13ff1b2625181b311f257c723b5e6d366eb318b212d9dd694c48fcf227659df5` |

### ERC1967 Admin Slot

```
0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
```
