# Mainnet Anvil sandbox

The sandbox appends persistent real-transaction fixtures for SDK and subgraph integration tests to the Compose-owned
Anvil at `127.0.0.1:8545`. It never starts or stops Anvil. It refuses to broadcast unless the RPC is loopback,
identifies itself as Anvil, supports Anvil-only RPC methods, and uses chain ID 1.

```sh
FORK_RPC_MAINNET=https://mainnet.gateway.tenderly.co script/sandbox/run.sh all
export INDEX_DTF_FORK_MANIFEST="$(pwd)/../index-subgraph/.fork/fixture.json"
```

The default fork block is `25834864`. Override `SANDBOX_RPC_URL`, `FORK_BLOCK`, or `SANDBOX_STATE_DIR` as needed.
`SANDBOX_STAGE_DIR` (default `.fork/sandbox-stage`, must stay inside this repo for Forge's file permissions) separates a
second concurrent sandbox, e.g. a disposable Anvil on another port.

`SANDBOX_SCENARIOS` accepts a comma-separated subset of `v5Control`, `v5OptimisticUpgrade`, `v5LegacyUpgrade`, and
`v6Native`. Native v6 automatically includes the optimistic v5 scenario because both reuse one staking vault.

- `bootstrap`: reuse Compose Anvil, deploy fixtures, write `bootstrap.json`.
- `scenarios`: resume propose/vote/queue/execute and write `fixture.json`.
- `executions`: append resumable v5-control and native-v6 rebalance/auction transactions, then the economic completion
  (below), and merge receipt-backed evidence into `fixture.json`.
- `all`: bootstrap, upgrade scenarios, execution scenarios, and verification.
- `verify`: read-only onchain verification of `fixture.json`. Baseline reads are pinned to `stateBlock`, so rebalances
  appended later (completion, Register's lane) do not fail it.

Executions honor `SANDBOX_SCENARIOS`: undeclared scenarios are skipped, and a reused bootstrap missing a declared
scenario is refused.

Set `SANDBOX_RESET=1` to reset the local fork before bootstrap, or `SANDBOX_REUSE=0` to force bootstrap against the
current fork. Reset is explicit and also deletes stale proposal and fixture state. Compose is the sole Anvil owner.

Both upgrades use standard proposals. The optimistic-governor system executes exactly four calls: register the v6
selector, unregister v5, transfer ProxyAdmin, cast the spell. Legacy governance executes exactly two: transfer
ProxyAdmin, cast the spell; the spell's fail-closed legacy check (no `version()` on the timelock, nonzero min delay)
accepts the production v5 legacy timelock.

`UpgradeSpell_6_0_0.sol` is upstream `contracts/spells/upgrades/UpgradeSpell_6_0_0.sol` at commit
`50f29f4a4dd2c8877d9879130f16eb23636cccfb` (branch `upgrade-spell-6.0.0`) plus a comment header. Everything from the
SPDX line down must hash to the pinned sha256; the runner checks that before compiling or broadcasting and
`MainnetAnvilSandboxTest` checks it in CI. Reproduce with
`git show 50f29f4:contracts/spells/upgrades/UpgradeSpell_6_0_0.sol | shasum -a 256`. `bootstrap.json` and the fixture
record `spellSourceCommit`/`upgradeSpellSourceCommit` and the sha256; reuse refuses a bootstrap deployed from another
spell source.

The execution scenarios use WETH and USDC. The v5 control Folio calls the legacy four-argument `startRebalance`
and five-argument `openAuction` as its assigned manager/launcher. Native v6 proposes the nonce/deadline-aware
six-argument `startRebalance` through `proposeOptimistic`, advances through its veto delay and period, executes via
the governance timelock, then calls the six-argument `openAuction` as the assigned launcher. The fixture records
proposal, execution, and auction transaction hashes and blocks, nonce, deadline, auction ID, and auction length.
`stateBlock` is pinned to the last of these baseline transactions.

## Economic completion

After the baseline, `executions` appends (never snapshots/reverts) an economic completion for `v6Native` (its baseline
auction) and `v5LegacyUpgrade` (a rebalance after upgrade: direct v6 `startRebalance(nonce, ...)` by the manager with no
launcher window, then `openAuctionUnrestricted` after the 120s buffer):

1. An unprivileged bidder (Anvil dev account 1) buys USDC with a real Uniswap V3 swap and approves each Folio before the
   last baseline auction opens, so nothing is mined between an auction opening and its bid.
2. The bid lands at exactly `auction.startTime` (`evm_setNextBlockTimestamp`), where the price is closed-form:
   `price = ceil(WETH.high * 1e27 / USDC.low)` and `buy = ceil(0.01 WETH * price / 1e27)`, computed with `bc` from the
   auction's price inputs and passed as `maxBuyAmount`, so any other charge reverts.
3. `closeAuction(auctionId)` mid-auction, then `endRebalance(nonce)`, both from the actor.

Each `scenarios.<name>.completion` records bidder/launcher, nonce, auction ID, and the rebalance, auction (with
selector and opened window), bid (amounts, price, expected amounts), close (closed `endTime`), and end
(`availableUntil`) transactions with blocks and timestamps; `completionBlock`/`completionTimestamp` mark the last one.
`verify` recomputes the arithmetic, checks the `AuctionBid` log, `getBid` at the bid block, all four token balance
deltas, and the close/end post-state at their own blocks. A bid needs the auction not yet started, so resuming after
the start requires `SANDBOX_RESET=1`.

## Real deployer mode

By default bootstrap builds its own 6.0.0 `FolioDeployer` wired to optimistic governor deployer 1.0.0. Set
`SANDBOX_V6_DEPLOYER` to use an already-deployed one instead, e.g. mainnet FolioDeployer 6.0.0
`0x2B1Cd9aEF0CD3B9fF5DCa1C66348eCfC46F37392` (created at block 26086050, wired to optimistic governor deployer 1.1.0
`0x4292433c772958ae93bebf32602ffDe0f9C5Fcd6`):

```sh
SANDBOX_V6_DEPLOYER=0x2B1Cd9aEF0CD3B9fF5DCa1C66348eCfC46F37392 FORK_BLOCK=<block >= 26086050> SANDBOX_RESET=1 \
  script/sandbox/run.sh all
```

- The deployer must have code at `FORK_BLOCK` and on the running fork, report `version()` 6.0.0, and use the canonical
  version registry. The runner refuses otherwise before broadcasting (and before `anvil_reset` when resetting).
- If 6.0.0 is unregistered, bootstrap registers that exact deployer as the canonical role-registry owner (simulating
  the pending production registration). If 6.0.0 is registered to a different deployer, bootstrap reverts; it never
  adopts it. Reuse also refuses a `bootstrap.json` made in the other mode.
- Native v6 is deployed through the real deployer, so its governance comes from that deployer's optimistic governor
  deployer. The v5 optimistic and legacy scenarios stay on the production v5 deployers and optimistic governor
  deployer 1.0.0. The 5.0.0 to 6.0.0 spell is still sandbox-built from the upstream source; it resolves the target
  implementation through the version registry, so it upgrades to the real deployer's implementation.
- `bootstrap.json` and `fixture.json` record provenance: `v6DeployerSource` (`real`, `sandbox`, or `registered` when
  sandbox mode adopted an existing registration), the deployer, its `folioImplementation()` and
  `optimisticGovernorDeployer()`, the v5 optimistic governor deployer, and that the spell is sandbox-built. In real
  mode `verify` also checks the registry entry, every 6.0.0 Folio's implementation slot, and that the native governor
  and timelock were deployed by the deployer's optimistic governor deployer.
- Every later command on a real-mode bootstrap must use the same `FORK_BLOCK`.
