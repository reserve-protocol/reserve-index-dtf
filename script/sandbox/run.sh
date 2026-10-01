#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMAND="${1:-all}"
shift || true
SANDBOX_RPC_URL="${SANDBOX_RPC_URL:-http://127.0.0.1:8545}"
FORK_BLOCK="${FORK_BLOCK:-25834864}"
SANDBOX_STATE_DIR="${SANDBOX_STATE_DIR:-$REPO_ROOT/../index-subgraph/.fork}"
FORK_RPC_MAINNET="${FORK_RPC_MAINNET:-https://mainnet.gateway.tenderly.co}"
SANDBOX_SCENARIOS="${SANDBOX_SCENARIOS:-${*:-v5Control,v5OptimisticUpgrade,v5LegacyUpgrade,v6Native}}"
# Real mode: an existing 6.0.0 FolioDeployer (e.g. mainnet 0x2B1Cd9aEF0CD3B9fF5DCa1C66348eCfC46F37392) replaces the
# sandbox-built one. Unset keeps the sandbox-built deployer.
SANDBOX_V6_DEPLOYER="${SANDBOX_V6_DEPLOYER:-}"
export SANDBOX_RPC_URL FORK_BLOCK SANDBOX_STATE_DIR SANDBOX_V6_DEPLOYER
export ETHERSCAN_KEY="${ETHERSCAN_KEY:-sandbox-not-used}"
export BC_LINE_LENGTH=0

BOOTSTRAP_JSON="$SANDBOX_STATE_DIR/bootstrap.json"
PROPOSALS_JSON="$SANDBOX_STATE_DIR/proposals.json"
FIXTURE_JSON="$SANDBOX_STATE_DIR/fixture.json"
EXECUTION_PROPOSAL_JSON="$SANDBOX_STATE_DIR/execution-proposal.json"
EXECUTION_JSON="$SANDBOX_STATE_DIR/execution.json"
# Forge may only write inside the repo (fs_permissions), so a second concurrent sandbox needs its own stage dir here.
SOLIDITY_STATE_DIR="${SANDBOX_STAGE_DIR:-$REPO_ROOT/.fork/sandbox-stage}"

# The spell is upstream reserve-index-dtf branch upgrade-spell-6.0.0 at this commit; the sandbox copy adds only a
# comment header. `git show $SPELL_SOURCE_COMMIT:contracts/spells/upgrades/UpgradeSpell_6_0_0.sol | shasum -a 256`
# reproduces the hash.
SPELL_SOURCE_COMMIT="50f29f4a4dd2c8877d9879130f16eb23636cccfb"
SPELL_SOURCE_SHA256="6fd0b3d6fc77b0c0946db53d3b2c2afffde93d050fe268d5dc394eef45fd835c"
SPELL_FILE="$REPO_ROOT/script/sandbox/UpgradeSpell_6_0_0.sol"
ZERO_ADDRESS=0x0000000000000000000000000000000000000000
WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
SWAP_ROUTER02=0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
# Public Anvil dev keys: account 0 is the bootstrap actor (launcher/manager), account 1 an unprivileged bidder.
ACTOR_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
BIDDER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
BID_SELL_AMOUNT=10000000000000000 # {WETH wei} per completion bid: 0.01 WETH
BIDDER_USDC_FLOOR=100000000 # {USDC units} 100 USDC covers every start-price bid (~33.4 USDC each)
REBALANCE_STARTED_EVENT='RebalanceStarted(uint256,uint8,(address,(uint256,uint256,uint256),(uint256,uint256),uint256,bool)[],(uint256,uint256,uint256),uint256,uint256,uint256,bool)'
AUCTION_OPENED_EVENT='AuctionOpened(uint256,uint256,address[],(uint256,uint256,uint256)[],(uint256,uint256)[],(uint256,uint256,uint256),uint256,uint256)'

die() { printf 'sandbox: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
rpc() {
  local method="$1" params="${2:-[]}"
  curl -fsS -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" "$SANDBOX_RPC_URL"
}
is_loopback_rpc() {
  case "$SANDBOX_RPC_URL" in
    http://127.0.0.1:*|http://localhost:*|http://\[::1\]:*) return 0 ;;
    *) return 1 ;;
  esac
}
assert_safe_state_dir() {
  case "$SANDBOX_STATE_DIR" in ''|'/'|"$REPO_ROOT"|"$HOME") die "unsafe SANDBOX_STATE_DIR=$SANDBOX_STATE_DIR" ;; esac
}
assert_local_anvil() {
  is_loopback_rpc || die "refusing non-loopback RPC: $SANDBOX_RPC_URL"
  local client chain
  client="$(rpc web3_clientVersion | jq -r '.result // empty')"
  [[ "$client" == *anvil* || "$client" == *Anvil* ]] || die "RPC is not Anvil: $client"
  chain="$(rpc eth_chainId | jq -r '.result // empty')"
  [[ "$chain" == 0x1 ]] || die "Anvil must expose mainnet chain id 1, got $chain"
  rpc anvil_nodeInfo >/dev/null || die "RPC lacks Anvil-only methods"
}
# Everything above the SPDX line must be comments naming the commit; everything from it down must be upstream.
assert_spell_source() {
  local header body_hash
  header="$(sed '/^\/\/ SPDX-License-Identifier/,$d' "$SPELL_FILE")"
  body_hash="$(sed -n '/^\/\/ SPDX-License-Identifier/,$p' "$SPELL_FILE" | shasum -a 256 | awk '{print $1}')"
  [[ "$body_hash" == "$SPELL_SOURCE_SHA256" && "$header" == *"$SPELL_SOURCE_COMMIT"* ]] && ! grep -qv '^//' <<<"$header" ||
    die "UpgradeSpell source is not upstream $SPELL_SOURCE_COMMIT (body sha256 $body_hash)"
}
scenario_enabled() { case ",$SANDBOX_SCENARIOS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
scenario_folio_key() {
  case "$1" in
    v5Control) printf '.v5ControlFolio' ;;
    v5OptimisticUpgrade) printf '.optimisticFolio' ;;
    v5LegacyUpgrade) printf '.legacyFolio' ;;
    v6Native) printf '.nativeFolio' ;;
    *) die "unknown scenario $1" ;;
  esac
}
scenario_folio() { jq -r "$(scenario_folio_key "$1")" "$BOOTSTRAP_JSON"; }
set_scenario_env() {
  export SANDBOX_ENABLE_V5_CONTROL=false SANDBOX_ENABLE_V5_OPTIMISTIC=false
  export SANDBOX_ENABLE_V5_LEGACY=false SANDBOX_ENABLE_V6_NATIVE=false
  scenario_enabled v5Control && export SANDBOX_ENABLE_V5_CONTROL=true
  scenario_enabled v5OptimisticUpgrade && export SANDBOX_ENABLE_V5_OPTIMISTIC=true
  scenario_enabled v5LegacyUpgrade && export SANDBOX_ENABLE_V5_LEGACY=true
  if scenario_enabled v6Native; then export SANDBOX_ENABLE_V6_NATIVE=true SANDBOX_ENABLE_V5_OPTIMISTIC=true; fi
}
# A reused bootstrap must hold every declared scenario; undeclared bootstrapped scenarios are skipped by executions.
assert_declared_scenarios_bootstrapped() {
  local name
  for name in v5Control v5OptimisticUpgrade v5LegacyUpgrade v6Native; do
    scenario_enabled "$name" || continue
    [[ "$(scenario_folio "$name")" != "$ZERO_ADDRESS" ]] ||
      die "declared scenario $name is not in $BOOTSTRAP_JSON; reset the fork (SANDBOX_RESET=1)"
  done
}
bootstrap_valid() {
  [[ -s "$BOOTSTRAP_JSON" ]] || return 1
  local deployer code; deployer="$(jq -r '.v6Deployer // empty' "$BOOTSTRAP_JSON")"
  [[ "$deployer" =~ ^0x[0-9a-fA-F]{40}$ ]] || return 1
  code="$(cast code --rpc-url "$SANDBOX_RPC_URL" "$deployer")"; [[ "$code" != 0x ]] || return 1
  # A real deployer has code on any new-enough fork, so it cannot prove this fork holds the bootstrap; the spell can.
  if [[ "$(jq -r '.v6DeployerSource // "sandbox"' "$BOOTSTRAP_JSON")" == real ]]; then
    code="$(cast code --rpc-url "$SANDBOX_RPC_URL" "$(jq -r .spell "$BOOTSTRAP_JSON")")"; [[ "$code" != 0x ]]
  fi
}
# A bootstrap deployed with another spell source would certify that spell, not this one.
assert_bootstrap_spell() {
  jq -e --arg commit "$SPELL_SOURCE_COMMIT" '.spellSourceCommit == $commit' "$BOOTSTRAP_JSON" >/dev/null ||
    die "$BOOTSTRAP_JSON deployed spell source $(jq -r '.spellSourceCommit // "unrecorded"' "$BOOTSTRAP_JSON"), not $SPELL_SOURCE_COMMIT; reset the fork (SANDBOX_RESET=1)"
}
# Bootstraps without v6DeployerSource predate real mode and were sandbox-built.
bootstrap_matches_mode() {
  if [[ -n "$SANDBOX_V6_DEPLOYER" ]]; then
    jq -e --arg deployer "$SANDBOX_V6_DEPLOYER" \
      '.v6DeployerSource == "real" and (.v6Deployer | ascii_downcase) == ($deployer | ascii_downcase)' "$BOOTSTRAP_JSON" >/dev/null
  else
    jq -e '(.v6DeployerSource // "sandbox") != "real"' "$BOOTSTRAP_JSON" >/dev/null
  fi
}
# Real mode needs the deployer on the running fork and at FORK_BLOCK (recorded in the fixture and used as the log range).
assert_real_deployer_on_fork() {
  [[ -n "$SANDBOX_V6_DEPLOYER" ]] || return 0
  local latest at_fork_block
  latest="$(cast code --rpc-url "$SANDBOX_RPC_URL" "$SANDBOX_V6_DEPLOYER")"
  at_fork_block="$(cast code --rpc-url "$SANDBOX_RPC_URL" --block "$FORK_BLOCK" "$SANDBOX_V6_DEPLOYER" 2>/dev/null || true)"
  [[ "$latest" != 0x && -n "$at_fork_block" && "$at_fork_block" != 0x ]] ||
    die "real mode: SANDBOX_V6_DEPLOYER $SANDBOX_V6_DEPLOYER has no code on this fork at FORK_BLOCK=$FORK_BLOCK. Fork at or after its creation block (mainnet FolioDeployer 6.0.0: 26086050) and pass the same FORK_BLOCK."
}
assert_real_bootstrap_fork_block() {
  [[ -s "$BOOTSTRAP_JSON" && "$(jq -r '.v6DeployerSource // "sandbox"' "$BOOTSTRAP_JSON")" == real ]] || return 0
  [[ "$(jq -r .forkBlock "$BOOTSTRAP_JSON")" == "$FORK_BLOCK" ]] ||
    die "real-mode bootstrap was made at forkBlock $(jq -r .forkBlock "$BOOTSTRAP_JSON"); pass FORK_BLOCK=$(jq -r .forkBlock "$BOOTSTRAP_JSON") (got $FORK_BLOCK)"
}
bootstrap() {
  if bootstrap_valid && [[ "${SANDBOX_REUSE:-1}" == 1 && "${SANDBOX_RESET:-0}" != 1 ]]; then
    bootstrap_matches_mode ||
      die "$BOOTSTRAP_JSON was bootstrapped with v6 deployer $(jq -r '(.v6DeployerSource // "sandbox") + " " + .v6Deployer' "$BOOTSTRAP_JSON"), not the requested one (SANDBOX_V6_DEPLOYER=${SANDBOX_V6_DEPLOYER:-unset}); reset the fork"
    assert_bootstrap_spell
    assert_declared_scenarios_bootstrapped
    printf 'sandbox: reusing %s\n' "$BOOTSTRAP_JSON"; return
  fi
  if [[ "${SANDBOX_RESET:-0}" == 1 ]]; then
    # Fail before rewinding anything: the reset target must already hold the real deployer.
    if [[ -n "$SANDBOX_V6_DEPLOYER" && "$(cast code --rpc-url "$FORK_RPC_MAINNET" --block "$FORK_BLOCK" "$SANDBOX_V6_DEPLOYER")" == 0x ]]; then
      die "real mode: SANDBOX_V6_DEPLOYER $SANDBOX_V6_DEPLOYER has no code at FORK_BLOCK=$FORK_BLOCK. Fork at or after its creation block (mainnet FolioDeployer 6.0.0: 26086050)."
    fi
    rm -f "$PROPOSALS_JSON" "$FIXTURE_JSON" "$EXECUTION_PROPOSAL_JSON" "$EXECUTION_JSON"
    rm -f "$SOLIDITY_STATE_DIR/bootstrap.json" "$SOLIDITY_STATE_DIR/proposals.json" \
      "$SOLIDITY_STATE_DIR/execution-proposal.json"
    rpc anvil_reset "[{\"forking\":{\"jsonRpcUrl\":\"$FORK_RPC_MAINNET\",\"blockNumber\":$FORK_BLOCK}}]" >/dev/null
  fi
  assert_real_deployer_on_fork
  set_scenario_env
  mkdir -p "$SOLIDITY_STATE_DIR"
  rpc anvil_setBalance '["0xe8259842e71f4E44F2F68D6bfbC15EDA56E63064","0x56BC75E2D63100000"]' >/dev/null
  rpc anvil_impersonateAccount '["0xe8259842e71f4E44F2F68D6bfbC15EDA56E63064"]' >/dev/null
  stop_role_registry_impersonation() {
    rpc anvil_stopImpersonatingAccount '["0xe8259842e71f4E44F2F68D6bfbC15EDA56E63064"]' >/dev/null 2>&1 || true
  }
  trap stop_role_registry_impersonation EXIT INT TERM
  (export SANDBOX_STATE_DIR="$SOLIDITY_STATE_DIR"; cd "$REPO_ROOT" && \
    forge script script/sandbox/MainnetAnvilSandbox.s.sol:MainnetAnvilBootstrap \
    --rpc-url "$SANDBOX_RPC_URL" --broadcast --unlocked --slow -vv)
  stop_role_registry_impersonation
  trap - EXIT INT TERM
  jq --arg commit "$SPELL_SOURCE_COMMIT" --arg sha256 "$SPELL_SOURCE_SHA256" \
    '.spellSourceCommit=$commit | .spellSourceSha256=$sha256' "$SOLIDITY_STATE_DIR/bootstrap.json" >"$BOOTSTRAP_JSON.next"
  mv "$BOOTSTRAP_JSON.next" "$BOOTSTRAP_JSON"
}
advance() { rpc evm_increaseTime "[$1]" >/dev/null; rpc evm_mine >/dev/null; }
advance_to() {
  local target="$1" current delta
  current="$(block_timestamp)"
  (( current >= target )) && return
  delta="$((target - current))"
  advance "$delta"
}
run_stage() {
  export SANDBOX_STAGE="$1"
  mkdir -p "$SOLIDITY_STATE_DIR"
  cp "$BOOTSTRAP_JSON" "$SOLIDITY_STATE_DIR/bootstrap.json"
  [[ -s "$PROPOSALS_JSON" ]] && cp "$PROPOSALS_JSON" "$SOLIDITY_STATE_DIR/proposals.json"
  (export SANDBOX_STATE_DIR="$SOLIDITY_STATE_DIR"; cd "$REPO_ROOT" && \
    forge script script/sandbox/MainnetAnvilSandbox.s.sol:MainnetAnvilScenarios \
    --rpc-url "$SANDBOX_RPC_URL" --broadcast --slow -vv)
  [[ -s "$SOLIDITY_STATE_DIR/proposals.json" ]] && cp "$SOLIDITY_STATE_DIR/proposals.json" "$PROPOSALS_JSON"
}
run_execution_stage() {
  export SANDBOX_EXECUTION_STAGE="$1"
  mkdir -p "$SOLIDITY_STATE_DIR"
  cp "$BOOTSTRAP_JSON" "$SOLIDITY_STATE_DIR/bootstrap.json"
  rm -f "$SOLIDITY_STATE_DIR/execution-proposal.json"
  [[ -s "$EXECUTION_PROPOSAL_JSON" ]] && cp "$EXECUTION_PROPOSAL_JSON" "$SOLIDITY_STATE_DIR/execution-proposal.json"
  (export SANDBOX_STATE_DIR="$SOLIDITY_STATE_DIR"; cd "$REPO_ROOT" && \
    forge script script/sandbox/MainnetAnvilSandbox.s.sol:MainnetAnvilExecutionScenarios \
    --rpc-url "$SANDBOX_RPC_URL" --broadcast --slow -vv)
  if [[ "$SANDBOX_EXECUTION_STAGE" == propose-v6-* && -s "$SOLIDITY_STATE_DIR/execution-proposal.json" ]]; then
    cp "$SOLIDITY_STATE_DIR/execution-proposal.json" "$EXECUTION_PROPOSAL_JSON.next"
    mv "$EXECUTION_PROPOSAL_JSON.next" "$EXECUTION_PROPOSAL_JSON"
  fi
}
governor_state() {
  local id="$1" governor="$2" block="${3:-latest}"
  [[ "$id" == 0 ]] && { printf '7'; return; }
  cast call --rpc-url "$SANDBOX_RPC_URL" --block "$block" "$governor" 'state(uint256)(uint8)' "$id"
}
governor_time() {
  cast call --json --rpc-url "$SANDBOX_RPC_URL" "$1" "$2(uint256)(uint256)" "$3" | jq -r '.[0]'
}
# Governors read proposer votes at clock() - 1 and Forge simulates at the latest block's timestamp. A bootstrap that
# mines its delegation and every later block in one second leaves that snapshot empty; step one second (append-only).
ensure_proposer_votes_checkpointed() {
  local vault actor votes
  vault="$(jq -r .optimisticStToken "$BOOTSTRAP_JSON")"
  [[ "$vault" == "$ZERO_ADDRESS" ]] && return 0
  actor="$(jq -r .actor "$BOOTSTRAP_JSON")"
  votes="$(cast call --rpc-url "$SANDBOX_RPC_URL" "$vault" 'getPastVotes(address,uint256)(uint256)' "$actor" "$(( $(block_timestamp) - 1 ))" | awk '{print $1}')"
  [[ "$votes" == 0 ]] || return 0
  printf 'sandbox: proposer votes not yet checkpointed at clock()-1; advancing one second\n'
  advance 1
}
scenarios() {
  bootstrap_valid || die "bootstrap missing or stale"
  assert_real_bootstrap_fork_block
  assert_bootstrap_spell
  assert_declared_scenarios_bootstrapped
  if [[ ! -s "$PROPOSALS_JSON" ]]; then ensure_proposer_votes_checkpointed; run_stage propose; fi
  local oi li os ls target
  oi="$(jq -r '.optimisticProposalId // 0' "$PROPOSALS_JSON")"; li="$(jq -r '.legacyProposalId // 0' "$PROPOSALS_JSON")"
  os="$(governor_state "$oi" "$(jq -r .optimisticGovernor "$BOOTSTRAP_JSON")")"
  ls="$(governor_state "$li" "$(jq -r .legacyGovernor "$BOOTSTRAP_JSON")")"
  if [[ "$os" == 0 || "$ls" == 0 ]]; then
    target="$(proposal_max_time proposalSnapshot "$oi" "$(jq -r .optimisticGovernor "$BOOTSTRAP_JSON")" "$li" "$(jq -r .legacyGovernor "$BOOTSTRAP_JSON")")"
    advance_to "$((target + 1))"
  fi
  run_stage vote
  target="$(proposal_max_time proposalDeadline "$oi" "$(jq -r .optimisticGovernor "$BOOTSTRAP_JSON")" "$li" "$(jq -r .legacyGovernor "$BOOTSTRAP_JSON")")"
  advance_to "$((target + 1))"
  run_stage queue
  target="$(proposal_max_time proposalEta "$oi" "$(jq -r .optimisticGovernor "$BOOTSTRAP_JSON")" "$li" "$(jq -r .legacyGovernor "$BOOTSTRAP_JSON")")"
  advance_to "$((target + 1))"
  run_stage execute
  [[ "$(governor_state "$oi" "$(jq -r .optimisticGovernor "$BOOTSTRAP_JSON")")" == 7 ]] || die "optimistic upgrade proposal not executed"
  [[ "$(governor_state "$li" "$(jq -r .legacyGovernor "$BOOTSTRAP_JSON")")" == 7 ]] || die "legacy upgrade proposal not executed"
  write_fixture
}
proposal_max_time() {
  local method="$1" first_id="$2" first_governor="$3" second_id="$4" second_governor="$5"
  local first=0 second=0
  [[ "$first_id" == 0 ]] || first="$(governor_time "$first_governor" "$method" "$first_id")"
  [[ "$second_id" == 0 ]] || second="$(governor_time "$second_governor" "$method" "$second_id")"
  (( first >= second )) && printf '%s\n' "$first" || printf '%s\n' "$second"
}
has_role() {
  local target="$1" role="$2" account="$3" block="${4:-latest}"
  [[ "$(cast call --rpc-url "$SANDBOX_RPC_URL" --block "$block" "$target" 'hasRole(bytes32,address)(bool)' "$(cast keccak "$role")" "$account")" == true ]]
}
has_execution_roles() {
  local folio="$1" block="${2:-latest}" actor
  actor="$(jq -r .actor "$BOOTSTRAP_JSON")"
  has_role "$folio" REBALANCE_MANAGER "$actor" "$block" && has_role "$folio" AUCTION_LAUNCHER "$actor" "$block"
}
has_v6_execution_authority() {
  local folio="$1" timelock="$2" block="${3:-latest}" actor
  actor="$(jq -r .actor "$BOOTSTRAP_JSON")"
  has_role "$timelock" OPTIMISTIC_PROPOSER_ROLE "$actor" "$block" && has_role "$folio" AUCTION_LAUNCHER "$actor" "$block" &&
    has_role "$folio" REBALANCE_MANAGER "$timelock" "$block"
}
native_v6_rebalance() {
  local v6 governor timelock proposal_id rebalance_id state target nonce
  v6="$(jq -r .nativeFolio "$BOOTSTRAP_JSON")"
  governor="$(jq -r .nativeGovernor "$BOOTSTRAP_JSON")"
  timelock="$(jq -r .nativeTimelock "$BOOTSTRAP_JSON")"
  if ! has_v6_execution_authority "$v6" "$timelock"; then
    [[ -s "$EXECUTION_PROPOSAL_JSON" ]] || run_execution_stage propose-v6-authority
    proposal_id="$(jq -r '.authorityProposalId // "0"' "$EXECUTION_PROPOSAL_JSON")"
    [[ "$proposal_id" != 0 ]] || die "native-v6 authority proposal missing"
    state="$(governor_state "$proposal_id" "$governor")"
    if [[ "$state" == 2 || "$state" == 3 ]]; then
      run_execution_stage propose-v6-authority
      proposal_id="$(jq -r '.authorityProposalId // "0"' "$EXECUTION_PROPOSAL_JSON")"
      state="$(governor_state "$proposal_id" "$governor")"
    fi
    if [[ "$state" == 0 ]]; then
      target="$(governor_time "$governor" proposalSnapshot "$proposal_id")"
      advance_to "$((target + 1))"
    fi
    run_execution_stage vote-v6-authority
    target="$(governor_time "$governor" proposalDeadline "$proposal_id")"
    advance_to "$((target + 1))"
    run_execution_stage queue-v6-authority
    target="$(governor_time "$governor" proposalEta "$proposal_id")"
    advance_to "$((target + 1))"
    run_execution_stage execute-v6-authority
  elif [[ ! -s "$EXECUTION_PROPOSAL_JSON" ]]; then
    run_execution_stage propose-v6-authority
  fi
  has_v6_execution_authority "$v6" "$timelock" || die "native-v6 execution authority missing"
}
native_v6_start() {
  local v6 governor rebalance_id state target nonce
  v6="$(jq -r .nativeFolio "$BOOTSTRAP_JSON")"
  governor="$(jq -r .nativeGovernor "$BOOTSTRAP_JSON")"
  nonce="$(rebalance_json "$v6" | jq -r '.[0]')"
  [[ "$nonce" == 0 ]] || return 0
  if ! jq -e '.rebalanceProposalId and .rebalanceDeadline and .rebalanceNonce' "$EXECUTION_PROPOSAL_JSON" >/dev/null; then
    run_execution_stage propose-v6-rebalance
  fi
  rebalance_id="$(jq -r .rebalanceProposalId "$EXECUTION_PROPOSAL_JSON")"
  [[ "$rebalance_id" != 0 ]] || die "native-v6 optimistic rebalance proposal missing"
  [[ "$(cast call --rpc-url "$SANDBOX_RPC_URL" "$governor" 'isOptimistic(uint256)(bool)' "$rebalance_id")" == true ]] ||
    die "native-v6 rebalance proposal is not optimistic"
  state="$(governor_state "$rebalance_id" "$governor")"
  if [[ "$state" == 2 || "$state" == 3 || "$(block_timestamp)" -ge "$(jq -r .rebalanceDeadline "$EXECUTION_PROPOSAL_JSON")" ]]; then
    run_execution_stage propose-v6-rebalance
    rebalance_id="$(jq -r .rebalanceProposalId "$EXECUTION_PROPOSAL_JSON")"
    state="$(governor_state "$rebalance_id" "$governor")"
  fi
  if [[ "$state" == 0 ]]; then
    target="$(governor_time "$governor" proposalSnapshot "$rebalance_id")"
    advance_to "$((target + 1))"
  fi
  target="$(governor_time "$governor" proposalDeadline "$rebalance_id")"
  advance_to "$((target + 1))"
  run_execution_stage execute-v6-rebalance
  [[ "$(governor_state "$rebalance_id" "$governor")" == 7 ]] || die "native-v6 optimistic rebalance not executed"
}
# Rebalance after upgrade on the legacy Folio: direct manager start, then the permissionless unrestricted launch
# once RESTRICTED_AUCTION_BUFFER (120s) has passed.
legacy_v6_rebalance() {
  local folio started
  folio="$(scenario_folio v5LegacyUpgrade)"
  [[ "$(folio_version "$folio")" == 6.0.0 ]] || die "v5LegacyUpgrade must be upgraded before its rebalance"
  run_execution_stage start-legacy-v6
  started="$(rebalance_timestamps "$folio" latest | awk '{print $1}')"
  advance_to "$((started + 120))"
  run_execution_stage open-legacy-v6
}
execution_scenarios() {
  bootstrap_valid || die "bootstrap missing or stale"
  assert_real_bootstrap_fork_block
  assert_bootstrap_spell
  assert_declared_scenarios_bootstrapped
  local v5
  if scenario_enabled v5Control; then
    v5="$(jq -r .v5ControlFolio "$BOOTSTRAP_JSON")"
    run_execution_stage grant-v5-roles
    has_execution_roles "$v5" || die "v5 control execution roles missing"
  fi
  scenario_enabled v6Native && native_v6_rebalance
  if scenario_enabled v5Control; then run_execution_stage start-v5; run_execution_stage open-v5; fi
  scenario_enabled v6Native && native_v6_start
  # Funding mines blocks, so it runs before the last baseline auction opens: nothing may be mined between an
  # auction opening and its exact start-price bid.
  prepare_bidder
  scenario_enabled v6Native && run_execution_stage open-v6
  write_fixture
  write_execution_evidence
  scenario_enabled v6Native && complete_rebalance v6Native
  if scenario_enabled v5LegacyUpgrade; then legacy_v6_rebalance; complete_rebalance v5LegacyUpgrade; fi
  write_completion_evidence
  verify_execution
  verify_completion
}
uint_topic() {
  local hex
  hex="$(cast to-hex "$1")"
  printf '0x%064s' "${hex#0x}" | tr ' ' 0
}
# First matching log since FORK_BLOCK; fixture evidence is always the first rebalance/auction/bid/close/end, so
# rebalances appended later (Register's lane) never change it. Topics after the event are already 32-byte words.
first_log() {
  local address="$1" topics params
  topics="$(printf '%s\n' "${@:2}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  params="$(jq -cn --arg address "$address" --arg from "$(cast to-hex "$FORK_BLOCK")" --argjson topics "$topics" \
    '[{address:$address,fromBlock:$from,toBlock:"latest",topics:$topics}]')"
  rpc eth_getLogs "$params" | jq -ec '.result[0] // error("event log not found")'
}
has_log() { first_log "$@" >/dev/null 2>&1; }
event_log_with_data_id() {
  local address="$1" event="$2" id="$3" params word
  params="$(jq -cn --arg address "$address" --arg from "$(cast to-hex "$FORK_BLOCK")" --arg event "$event" \
    '[{address:$address,fromBlock:$from,toBlock:"latest",topics:[$event]}]')"
  word="$(uint_topic "$id")"
  word="${word#0x}"
  rpc eth_getLogs "$params" | jq -ec --arg word "$word" \
    '[.result[] | select((.data[2:66] | ascii_downcase) == ($word | ascii_downcase))][0] // error("event log not found")'
}
log_block() { hex_to_dec "$(jq -r .blockNumber <<<"$1")"; }
log_topic_dec() { cast to-dec "$(jq -r ".topics[$2]" <<<"$1")"; }
# ABI word $2 of a log's data, as a decimal string (uint256 safe).
log_word_dec() { local data; data="$(jq -r .data <<<"$1")"; cast to-dec "0x${data:$((2 + 64 * $2)):64}"; }
rebalance_json() {
  cast call --json --rpc-url "$SANDBOX_RPC_URL" --block "${2:-latest}" "$1" \
    'getRebalance()(uint256,uint8,(address,(uint256,uint256,uint256),(uint256,uint256),uint256,bool)[],(uint256,uint256,uint256),(uint256,uint256,uint256),bool)'
}
# "startedAt restrictedUntil availableUntil"
rebalance_timestamps() { rebalance_json "$1" "$2" | jq -r '.[4]' | tr -d '()[] "' | tr ',' ' '; }
# "startTime endTime"
auction_window() {
  cast call --json --rpc-url "$SANDBOX_RPC_URL" --block "$3" "$1" 'auctions(uint256)(uint256,uint256,uint256)' "$2" |
    jq -r '"\(.[1]) \(.[2])"'
}
folio_version() {
  cast call --json --rpc-url "$SANDBOX_RPC_URL" --block "${2:-latest}" "$1" 'version()(string)' | jq -r '.[0]'
}
erc20_balance() {
  cast call --json --rpc-url "$SANDBOX_RPC_URL" --block "${3:-latest}" "$1" 'balanceOf(address)(uint256)' "$2" | jq -r '.[0]'
}
ceil_div() { bc <<<"($1 + $2 - 1) / $2"; }
# Independent start-price bid: D27{USDC/WETH} = ceil(sellPrice.high * 1e27 / buyPrice.low) from the auction's own
# price inputs, then buy = ceil(BID_SELL_AMOUNT * price / 1e27). Prints "price buyAmount".
expected_start_bid() {
  local folio="$1" auction="$2" block="$3" sell_high buy_low price
  sell_high="$(cast call --json --rpc-url "$SANDBOX_RPC_URL" --block "$block" "$folio" 'getAuctionPrice(uint256,address)(uint256,uint256)' "$auction" "$WETH" | jq -r '.[1]')"
  buy_low="$(cast call --json --rpc-url "$SANDBOX_RPC_URL" --block "$block" "$folio" 'getAuctionPrice(uint256,address)(uint256,uint256)' "$auction" "$USDC" | jq -r '.[0]')"
  price="$(ceil_div "$sell_high * 10^27" "$buy_low")"
  printf '%s %s\n' "$price" "$(ceil_div "$BID_SELL_AMOUNT * $price" "10^27")"
}
send_tx() {
  local key="$1" receipt; shift
  receipt="$(cast send --json --rpc-url "$SANDBOX_RPC_URL" --private-key "$key" "$@")"
  [[ "$(jq -r .status <<<"$receipt")" == 0x1 ]] || die "transaction failed: $*"
  jq -r .transactionHash <<<"$receipt"
}
# Real swap on the fork (no storage writes) so the unprivileged bidder holds USDC and has approved each Folio.
prepare_bidder() {
  scenario_enabled v6Native || scenario_enabled v5LegacyUpgrade || return 0
  local bidder name folio
  bidder="$(cast wallet address --private-key "$BIDDER_KEY")"
  if [[ "$(bc <<<"$(erc20_balance "$USDC" "$bidder") < $BIDDER_USDC_FLOOR")" == 1 ]]; then
    send_tx "$BIDDER_KEY" --value 0.2ether "$SWAP_ROUTER02" \
      'exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))' \
      "($WETH,$USDC,500,$bidder,200000000000000000,$BIDDER_USDC_FLOOR,0)" >/dev/null
  fi
  for name in v6Native v5LegacyUpgrade; do
    scenario_enabled "$name" || continue
    folio="$(scenario_folio "$name")"
    [[ "$(bc <<<"$(cast call --json --rpc-url "$SANDBOX_RPC_URL" "$USDC" 'allowance(address,address)(uint256)' "$bidder" "$folio" | jq -r '.[0]') < $BIDDER_USDC_FLOOR")" == 1 ]] || continue
    send_tx "$BIDDER_KEY" "$USDC" 'approve(address,uint256)' "$folio" "$(cast max-uint)" >/dev/null
  done
}
rebalance_ended_log() {
  event_log_with_data_id "$1" "$(cast keccak 'RebalanceEnded(uint256)')" "$2"
}
# Economic completion of the scenario's first auction, appended after the baseline: an unprivileged bid at the exact
# auction start (closed-form price), closeAuction mid-auction, then endRebalance(nonce). Each step is skipped when its
# event already exists, so reruns append nothing.
complete_rebalance() {
  local name="$1" folio open_log nonce auction window start end expected
  folio="$(scenario_folio "$name")"
  open_log="$(first_log "$folio" "$(cast keccak "$AUCTION_OPENED_EVENT")")"
  nonce="$(log_topic_dec "$open_log" 1)"; auction="$(log_topic_dec "$open_log" 2)"
  window="$(auction_window "$folio" "$auction" "$(log_block "$open_log")")"; start="${window% *}"; end="${window#* }"
  if ! has_log "$folio" "$(cast keccak 'AuctionBid(uint256,address,address,uint256,uint256)')" "$(uint_topic "$auction")"; then
    (( $(block_timestamp) < start )) ||
      die "$name auction $auction started before its bid; an exact start-price bid needs a fresh fork (SANDBOX_RESET=1)"
    expected="$(expected_start_bid "$folio" "$auction" "$(log_block "$open_log")")"
    rpc evm_setNextBlockTimestamp "[$start]" >/dev/null
    send_tx "$BIDDER_KEY" --gas-limit 1500000 "$folio" 'bid(uint256,address,address,uint256,uint256,bool,bytes)' \
      "$auction" "$WETH" "$USDC" "$BID_SELL_AMOUNT" "${expected#* }" false 0x >/dev/null
  fi
  if ! has_log "$folio" "$(cast keccak 'AuctionClosed(uint256)')" "$(uint_topic "$auction")"; then
    (( $(block_timestamp) < end )) || die "$name auction $auction ended before closeAuction; reset the fork"
    send_tx "$ACTOR_KEY" "$folio" 'closeAuction(uint256)' "$auction" >/dev/null
  fi
  rebalance_ended_log "$folio" "$nonce" >/dev/null 2>&1 || send_tx "$ACTOR_KEY" "$folio" 'endRebalance(uint256)' "$nonce" >/dev/null
}
# Common rebalance/auction evidence from a Folio's first RebalanceStarted and AuctionOpened logs.
execution_json() {
  local folio="$1" start_log open_log nonce window
  start_log="$(first_log "$folio" "$(cast keccak "$REBALANCE_STARTED_EVENT")")"
  open_log="$(first_log "$folio" "$(cast keccak "$AUCTION_OPENED_EVENT")")"
  nonce="$(log_topic_dec "$start_log" 1)"
  [[ "$(log_topic_dec "$open_log" 1)" == "$nonce" ]] || die "$folio first auction is not on its first rebalance"
  window="$(auction_window "$folio" "$(log_topic_dec "$open_log" 2)" "$(log_block "$open_log")")"
  jq -n --arg weth "$WETH" --arg usdc "$USDC" --argjson nonce "$nonce" --argjson auction "$(log_topic_dec "$open_log" 2)" \
    --arg rebalanceTx "$(jq -r .transactionHash <<<"$start_log")" --argjson rebalanceBlock "$(log_block "$start_log")" \
    --arg auctionTx "$(jq -r .transactionHash <<<"$open_log")" --argjson auctionBlock "$(log_block "$open_log")" \
    --argjson start "${window% *}" --argjson end "${window#* }" \
    '{tokens:[$weth,$usdc],rebalanceNonce:$nonce,rebalanceTxHash:$rebalanceTx,rebalanceBlock:$rebalanceBlock,
      auctionId:$auction,auctionTxHash:$auctionTx,auctionBlock:$auctionBlock,auctionLength:($end-$start)}'
}
native_v6_execution_json() {
  local actor="$1" governor base authority_id rebalance_id rebalance_deadline proposal_event rebalance_proposal_log optimistic_log
  local authority_log authority_exec_log authority='{}'
  governor="$(jq -r .nativeGovernor "$BOOTSTRAP_JSON")"
  authority_id="$(jq -r '.authorityProposalId // "0"' "$EXECUTION_PROPOSAL_JSON")"
  rebalance_id="$(jq -r '.rebalanceProposalId // "0"' "$EXECUTION_PROPOSAL_JSON")"
  rebalance_deadline="$(jq -r '.rebalanceDeadline // "0"' "$EXECUTION_PROPOSAL_JSON")"
  [[ "$rebalance_id" != 0 && "$rebalance_deadline" != 0 ]] || die "native-v6 proposal evidence missing"
  base="$(execution_json "$(jq -r .nativeFolio "$BOOTSTRAP_JSON")")"
  [[ "$(jq -r .rebalanceNonce <<<"$base")" == "$(jq -r .rebalanceNonce "$EXECUTION_PROPOSAL_JSON")" ]] || die "native-v6 proposed nonce mismatch"
  proposal_event="$(cast keccak 'ProposalCreated(uint256,address,address[],uint256[],string[],bytes[],uint256,uint256,string)')"
  rebalance_proposal_log="$(event_log_with_data_id "$governor" "$proposal_event" "$rebalance_id")"
  optimistic_log="$(first_log "$governor" "$(cast keccak 'OptimisticProposalCreated(uint256,uint256)')" "$(uint_topic "$rebalance_id")")"
  [[ "$(jq -r .transactionHash <<<"$optimistic_log")" == "$(jq -r .transactionHash <<<"$rebalance_proposal_log")" ]] ||
    die "native-v6 optimistic proposal evidence mismatch"
  if [[ "$authority_id" == 0 ]]; then
    authority="$(jq -cn '{proposalTxHash:"0x0000000000000000000000000000000000000000000000000000000000000000",proposalBlock:0,
      executeTxHash:"0x0000000000000000000000000000000000000000000000000000000000000000",executeBlock:0}')"
  else
    authority_log="$(event_log_with_data_id "$governor" "$proposal_event" "$authority_id")"
    authority_exec_log="$(event_log_with_data_id "$governor" "$(cast keccak 'ProposalExecuted(uint256)')" "$authority_id")"
    authority="$(jq -cn --arg proposalTx "$(jq -r .transactionHash <<<"$authority_log")" --argjson proposalBlock "$(log_block "$authority_log")" \
      --arg executeTx "$(jq -r .transactionHash <<<"$authority_exec_log")" --argjson executeBlock "$(log_block "$authority_exec_log")" \
      '{proposalTxHash:$proposalTx,proposalBlock:$proposalBlock,executeTxHash:$executeTx,executeBlock:$executeBlock}')"
  fi
  jq -n --argjson base "$base" --argjson authority "$authority" --arg actor "$actor" --arg authorityId "$authority_id" \
    --arg rebalanceId "$rebalance_id" --argjson deadline "$rebalance_deadline" \
    --arg authorityDescription "$(jq -r '.authorityDescription // ""' "$EXECUTION_PROPOSAL_JSON")" \
    --arg rebalanceDescription "$(jq -r '.rebalanceDescription // ""' "$EXECUTION_PROPOSAL_JSON")" \
    --arg rebalanceProposalTx "$(jq -r .transactionHash <<<"$rebalance_proposal_log")" \
    --argjson rebalanceProposalBlock "$(log_block "$rebalance_proposal_log")" \
    '{actor:$actor,roleAuthority:"optimistic-governance",governanceMechanism:"optimistic",
      authority:({kind:"standard",optimistic:false,state:"executed",description:$authorityDescription,proposalId:$authorityId} + $authority),
      rebalanceProposal:{kind:"optimistic",optimistic:true,state:"executed",description:$rebalanceDescription,proposalId:$rebalanceId,
        proposalTxHash:$rebalanceProposalTx,proposalBlock:$rebalanceProposalBlock,executeTxHash:$base.rebalanceTxHash,
        executeBlock:$base.rebalanceBlock,deadline:$deadline},
      deadline:$deadline} + $base'
}
# Baseline evidence. stateBlock is pinned to the last baseline transaction (not latest), so rerunning after completion
# or after Register's lane appended rebalances rewrites the same baseline.
write_execution_evidence() {
  scenario_enabled v5Control || scenario_enabled v6Native || return 0
  local actor v5=null v6=null state_block=0 block
  actor="$(jq -r .actor "$BOOTSTRAP_JSON")"
  if scenario_enabled v5Control; then
    v5="$(execution_json "$(jq -r .v5ControlFolio "$BOOTSTRAP_JSON")" | jq -c --arg actor "$actor" '{actor:$actor,roleAuthority:"direct-admin"} + .')"
    state_block="$(jq -r .auctionBlock <<<"$v5")"
  fi
  if scenario_enabled v6Native; then
    v6="$(native_v6_execution_json "$actor" | jq -c .)"
    block="$(jq -r .auctionBlock <<<"$v6")"; (( block > state_block )) && state_block="$block"
  fi
  jq -n --argjson v5Control "$v5" --argjson v6Native "$v6" '{v5Control:$v5Control,v6Native:$v6Native}' >"$EXECUTION_JSON.next"
  mv "$EXECUTION_JSON.next" "$EXECUTION_JSON"
  jq --argjson v5 "$v5" --argjson v6 "$v6" --argjson stateBlock "$state_block" \
    --argjson stateTimestamp "$(block_timestamp "$state_block")" \
    '.stateBlock=$stateBlock | .stateTimestamp=$stateTimestamp
      | if $v5 then .scenarios.v5Control.execution=$v5 else . end
      | if $v6 then .scenarios.v6Native.execution=$v6 | .writePaths.deadline=$v6.deadline else . end' \
    "$FIXTURE_JSON" >"$FIXTURE_JSON.next"
  mv "$FIXTURE_JSON.next" "$FIXTURE_JSON"
}
tx_selector() { rpc eth_getTransactionByHash "$(jq -cn --arg hash "$1" '[$hash]')" | jq -r '.result.input[0:10]'; }
completion_json() {
  local name="$1" folio start_log open_log bid_log close_log end_log nonce auction auction_block window expected
  local bid_block close_block end_block close_window end_timestamps
  folio="$(scenario_folio "$name")"
  start_log="$(first_log "$folio" "$(cast keccak "$REBALANCE_STARTED_EVENT")")"
  open_log="$(first_log "$folio" "$(cast keccak "$AUCTION_OPENED_EVENT")")"
  nonce="$(log_topic_dec "$start_log" 1)"; auction="$(log_topic_dec "$open_log" 2)"; auction_block="$(log_block "$open_log")"
  [[ "$(log_topic_dec "$open_log" 1)" == "$nonce" ]] || die "$name first auction is not on its first rebalance"
  bid_log="$(first_log "$folio" "$(cast keccak 'AuctionBid(uint256,address,address,uint256,uint256)')" "$(uint_topic "$auction")")"
  close_log="$(first_log "$folio" "$(cast keccak 'AuctionClosed(uint256)')" "$(uint_topic "$auction")")"
  end_log="$(rebalance_ended_log "$folio" "$nonce")"
  bid_block="$(log_block "$bid_log")"; close_block="$(log_block "$close_log")"; end_block="$(log_block "$end_log")"
  window="$(auction_window "$folio" "$auction" "$auction_block")"
  expected="$(expected_start_bid "$folio" "$auction" "$auction_block")"
  close_window="$(auction_window "$folio" "$auction" "$close_block")"
  end_timestamps="$(rebalance_timestamps "$folio" "$end_block")"
  jq -n --arg bidder "$(cast wallet address --private-key "$BIDDER_KEY")" --arg launcher "$(jq -r .actor "$BOOTSTRAP_JSON")" \
    --argjson nonce "$nonce" --argjson auction "$auction" \
    --arg rebalanceTx "$(jq -r .transactionHash <<<"$start_log")" --argjson rebalanceBlock "$(log_block "$start_log")" \
    --arg rebalanceSelector "$(tx_selector "$(jq -r .transactionHash <<<"$start_log")")" \
    --arg auctionTx "$(jq -r .transactionHash <<<"$open_log")" --argjson auctionBlock "$auction_block" \
    --arg auctionSelector "$(tx_selector "$(jq -r .transactionHash <<<"$open_log")")" \
    --argjson startTime "${window% *}" --argjson endTime "${window#* }" \
    --arg bidTx "$(jq -r .transactionHash <<<"$bid_log")" --argjson bidBlock "$bid_block" \
    --argjson bidTimestamp "$(block_timestamp "$bid_block")" --arg weth "$WETH" --arg usdc "$USDC" \
    --arg sellAmount "$(log_word_dec "$bid_log" 0)" --arg buyAmount "$(log_word_dec "$bid_log" 1)" \
    --arg price "${expected% *}" --arg expectedBuy "${expected#* }" --arg expectedSell "$BID_SELL_AMOUNT" \
    --arg closeTx "$(jq -r .transactionHash <<<"$close_log")" --argjson closeBlock "$close_block" \
    --argjson closeTimestamp "$(block_timestamp "$close_block")" --argjson closedEndTime "${close_window#* }" \
    --arg endTx "$(jq -r .transactionHash <<<"$end_log")" --argjson endBlock "$end_block" \
    --argjson endTimestamp "$(block_timestamp "$end_block")" --argjson availableUntil "$(awk '{print $3}' <<<"$end_timestamps")" \
    '{bidder:$bidder,launcher:$launcher,rebalanceNonce:$nonce,auctionId:$auction,
      rebalance:{txHash:$rebalanceTx,block:$rebalanceBlock,selector:$rebalanceSelector},
      auction:{txHash:$auctionTx,block:$auctionBlock,selector:$auctionSelector,startTime:$startTime,endTime:$endTime,
        length:($endTime-$startTime)},
      bid:{txHash:$bidTx,block:$bidBlock,timestamp:$bidTimestamp,bidder:$bidder,sellToken:$weth,buyToken:$usdc,
        sellAmount:$sellAmount,buyAmount:$buyAmount,price:$price,priceBasis:"auction-start",
        expected:{sellAmount:$expectedSell,buyAmount:$expectedBuy}},
      close:{txHash:$closeTx,block:$closeBlock,timestamp:$closeTimestamp,endTime:$closedEndTime},
      end:{txHash:$endTx,block:$endBlock,timestamp:$endTimestamp,availableUntil:$availableUntil}}'
}
write_completion_evidence() {
  local name json completions='{}' completion_block=0 block
  for name in v6Native v5LegacyUpgrade; do
    scenario_enabled "$name" || continue
    json="$(completion_json "$name" | jq -c .)"
    completions="$(jq -c --arg name "$name" --argjson completion "$json" '.[$name]=$completion' <<<"$completions")"
    block="$(jq -r .end.block <<<"$json")"; (( block > completion_block )) && completion_block="$block"
  done
  [[ "$completions" != '{}' ]] || return 0
  jq --argjson completions "$completions" --argjson completionBlock "$completion_block" \
    --argjson completionTimestamp "$(block_timestamp "$completion_block")" \
    '.completionBlock=$completionBlock | .completionTimestamp=$completionTimestamp
      | reduce ($completions | to_entries[]) as $entry (.; .scenarios[$entry.key].completion=$entry.value)' \
    "$FIXTURE_JSON" >"$FIXTURE_JSON.next"
  mv "$FIXTURE_JSON.next" "$FIXTURE_JSON"
}
verify_receipt() {
  local tx_hash="$1" expected_block="$2" params receipt actual_block
  params="$(jq -cn --arg hash "$tx_hash" '[$hash]')"
  receipt="$(rpc eth_getTransactionReceipt "$params")"
  [[ "$(printf '%s' "$receipt" | jq -r '.result.status // empty')" == 0x1 ]] || die "transaction failed or missing: $tx_hash"
  actual_block="$(hex_to_dec "$(printf '%s' "$receipt" | jq -r .result.blockNumber)")"
  [[ "$actual_block" == "$expected_block" ]] || die "transaction block mismatch for $tx_hash"
}
verify_sender() {
  local tx_hash="$1" expected="$2" params
  params="$(jq -cn --arg hash "$tx_hash" '[$hash]')"
  [[ "$(rpc eth_getTransactionByHash "$params" | jq -r .result.from | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]] ||
    die "unexpected transaction sender for $tx_hash"
}
# Baseline execution checks read state at the fixture's stateBlock, never latest: later appended rebalances are legal.
verify_execution() {
  [[ -s "$FIXTURE_JSON" ]] || die "fixture missing"
  local name folio expected_version expected_nonce actual_rebalance actual_tokens tokens_length auction_id auction_state auction_nonce start end expected_length
  local rebalance_tx rebalance_block auction_tx auction_block actor state_block
  state_block="$(jq -r .stateBlock "$FIXTURE_JSON")"
  for name in v5Control v6Native; do
    jq -e ".scenarios.$name.execution" "$FIXTURE_JSON" >/dev/null || continue
    folio="$(jq -r ".scenarios.$name.folio" "$FIXTURE_JSON")"
    actor="$(jq -r ".scenarios.$name.execution.actor" "$FIXTURE_JSON")"
    expected_version="$(jq -r ".scenarios.$name.expectedVersion" "$FIXTURE_JSON")"
    [[ "$(folio_version "$folio" "$state_block")" == "$expected_version" ]] || die "$name version changed during execution flow"
    expected_nonce="$(jq -r ".scenarios.$name.execution.rebalanceNonce" "$FIXTURE_JSON")"
    actual_rebalance="$(rebalance_json "$folio" "$state_block")"
    [[ "$(printf '%s' "$actual_rebalance" | jq -r '.[0]')" == "$expected_nonce" ]] || die "$name rebalance nonce mismatch at stateBlock"
    tokens_length="$(jq -r ".scenarios.$name.execution.tokens | length" "$FIXTURE_JSON")"
    (( tokens_length >= 2 )) || die "$name rebalance must contain at least two tokens"
    actual_tokens="$(printf '%s' "$actual_rebalance" | jq -r '.[2]' | tr '[:upper:]' '[:lower:]')"
    [[ "$actual_tokens" == *0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2* &&
      "$actual_tokens" == *0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48* ]] || die "$name rebalance tokens mismatch"
    auction_id="$(jq -r ".scenarios.$name.execution.auctionId" "$FIXTURE_JSON")"
    auction_state="$(cast call --json --rpc-url "$SANDBOX_RPC_URL" --block "$state_block" "$folio" 'auctions(uint256)(uint256,uint256,uint256)' "$auction_id")"
    auction_nonce="$(printf '%s' "$auction_state" | jq -r '.[0]')"; start="$(printf '%s' "$auction_state" | jq -r '.[1]')"; end="$(printf '%s' "$auction_state" | jq -r '.[2]')"
    [[ "$auction_nonce" == "$expected_nonce" ]] || die "$name auction rebalance nonce mismatch"
    expected_length="$(jq -r ".scenarios.$name.execution.auctionLength" "$FIXTURE_JSON")"
    [[ "$((end - start))" == "$expected_length" ]] || die "$name auction length mismatch at stateBlock"
    rebalance_tx="$(jq -r ".scenarios.$name.execution.rebalanceTxHash" "$FIXTURE_JSON")"; rebalance_block="$(jq -r ".scenarios.$name.execution.rebalanceBlock" "$FIXTURE_JSON")"
    auction_tx="$(jq -r ".scenarios.$name.execution.auctionTxHash" "$FIXTURE_JSON")"; auction_block="$(jq -r ".scenarios.$name.execution.auctionBlock" "$FIXTURE_JSON")"
    (( rebalance_block < auction_block && auction_block <= state_block )) || die "$name execution blocks are unordered"
    verify_receipt "$rebalance_tx" "$rebalance_block"; verify_receipt "$auction_tx" "$auction_block"
    verify_sender "$rebalance_tx" "$actor"; verify_sender "$auction_tx" "$actor"
    [[ "$actor" == "$(jq -r .actor "$BOOTSTRAP_JSON")" ]] || die "$name execution actor mismatch"
  done
  if jq -e '.scenarios.v5Control.execution' "$FIXTURE_JSON" >/dev/null; then
    has_execution_roles "$(jq -r .v5ControlFolio "$BOOTSTRAP_JSON")" "$state_block" || die "v5 control execution roles missing"
  fi
  jq -e '.scenarios.v6Native.execution' "$FIXTURE_JSON" >/dev/null || return 0
  local governor timelock authority_id rebalance_id proposal_tx proposal_block deadline execute_timestamp
  actor="$(jq -r .scenarios.v6Native.execution.actor "$FIXTURE_JSON")"
  governor="$(jq -r .nativeGovernor "$BOOTSTRAP_JSON")"; timelock="$(jq -r .nativeTimelock "$BOOTSTRAP_JSON")"
  has_v6_execution_authority "$(jq -r .nativeFolio "$BOOTSTRAP_JSON")" "$timelock" "$state_block" || die "native-v6 authority missing"
  authority_id="$(jq -r '.scenarios.v6Native.execution.authority.proposalId' "$FIXTURE_JSON")"
  if [[ "$authority_id" != 0 ]]; then
    [[ "$(governor_state "$authority_id" "$governor" "$state_block")" == 7 ]] || die "native-v6 authority proposal not executed"
    [[ "$(cast call --rpc-url "$SANDBOX_RPC_URL" "$governor" 'isOptimistic(uint256)(bool)' "$authority_id")" == false ]] || die "native-v6 authority proposal must be standard"
    proposal_tx="$(jq -r '.scenarios.v6Native.execution.authority.proposalTxHash' "$FIXTURE_JSON")"
    proposal_block="$(jq -r '.scenarios.v6Native.execution.authority.proposalBlock' "$FIXTURE_JSON")"
    verify_receipt "$proposal_tx" "$proposal_block"; verify_sender "$proposal_tx" "$actor"
    verify_receipt "$(jq -r '.scenarios.v6Native.execution.authority.executeTxHash' "$FIXTURE_JSON")" \
      "$(jq -r '.scenarios.v6Native.execution.authority.executeBlock' "$FIXTURE_JSON")"
  fi
  rebalance_id="$(jq -r '.scenarios.v6Native.execution.rebalanceProposal.proposalId' "$FIXTURE_JSON")"
  [[ "$(governor_state "$rebalance_id" "$governor" "$state_block")" == 7 ]] || die "native-v6 rebalance proposal not executed"
  [[ "$(cast call --rpc-url "$SANDBOX_RPC_URL" "$governor" 'isOptimistic(uint256)(bool)' "$rebalance_id")" == true ]] || die "native-v6 rebalance proposal must be optimistic"
  proposal_tx="$(jq -r '.scenarios.v6Native.execution.rebalanceProposal.proposalTxHash' "$FIXTURE_JSON")"
  proposal_block="$(jq -r '.scenarios.v6Native.execution.rebalanceProposal.proposalBlock' "$FIXTURE_JSON")"
  verify_receipt "$proposal_tx" "$proposal_block"; verify_sender "$proposal_tx" "$actor"
  deadline="$(jq -r '.scenarios.v6Native.execution.deadline' "$FIXTURE_JSON")"
  execute_timestamp="$(block_timestamp "$(jq -r '.scenarios.v6Native.execution.rebalanceBlock' "$FIXTURE_JSON")")"
  (( execute_timestamp <= deadline )) || die "native-v6 rebalance executed after its calldata deadline"
  printf 'sandbox: execution fixture verified at block %s\n' "$state_block"
}
# Completion checks: receipts/senders, ordering, the exact start-price arithmetic recomputed from the auction inputs,
# the AuctionBid log and token deltas at the bid block, then the close and end post-state at their own blocks.
verify_completion() {
  [[ -s "$FIXTURE_JSON" ]] || die "fixture missing"
  local name c folio actor bidder field expected state_block completion_block bid_block receipt_logs delta
  local token holder sign amount before after closed_end end_timestamps
  state_block="$(jq -r .stateBlock "$FIXTURE_JSON")"; completion_block="$(jq -r '.completionBlock // 0' "$FIXTURE_JSON")"
  actor="$(jq -r .actor "$BOOTSTRAP_JSON")"; bidder="$(cast wallet address --private-key "$BIDDER_KEY")"
  for name in $(jq -r '.scenarios | to_entries[] | select(.value.completion) | .key' "$FIXTURE_JSON"); do
    c="$(jq -c ".scenarios.$name.completion" "$FIXTURE_JSON")"; folio="$(jq -r ".scenarios.$name.folio" "$FIXTURE_JSON")"
    [[ "$(lower "$(jq -r .bidder <<<"$c")")" == "$(lower "$bidder")" && "$(lower "$(jq -r .launcher <<<"$c")")" == "$(lower "$actor")" ]] ||
      die "$name completion accounts mismatch"
    for field in rebalance auction close end; do
      verify_receipt "$(jq -r ".$field.txHash" <<<"$c")" "$(jq -r ".$field.block" <<<"$c")"
      verify_sender "$(jq -r ".$field.txHash" <<<"$c")" "$actor"
    done
    verify_receipt "$(jq -r .bid.txHash <<<"$c")" "$(jq -r .bid.block <<<"$c")"; verify_sender "$(jq -r .bid.txHash <<<"$c")" "$bidder"
    jq -e --argjson completionBlock "$completion_block" \
      '.rebalance.block < .auction.block and .auction.block < .bid.block and .bid.block < .close.block
        and .close.block < .end.block and .end.block <= $completionBlock and .bid.timestamp == .auction.startTime
        and .close.endTime == .close.timestamp - 1 and .close.endTime < .auction.endTime
        and .end.availableUntil == .end.timestamp' <<<"$c" >/dev/null ||
      die "$name completion evidence is unordered or inconsistent"
    [[ "$(auction_window "$folio" "$(jq -r .auctionId <<<"$c")" "$(jq -r .auction.block <<<"$c")")" == "$(jq -r '"\(.auction.startTime) \(.auction.endTime)"' <<<"$c")" ]] ||
      die "$name auction window mismatch"
    expected="$(expected_start_bid "$folio" "$(jq -r .auctionId <<<"$c")" "$(jq -r .auction.block <<<"$c")")"
    [[ "$expected" == "$(jq -r '"\(.bid.price) \(.bid.buyAmount)"' <<<"$c")" && "$(jq -r .bid.sellAmount <<<"$c")" == "$BID_SELL_AMOUNT" ]] ||
      die "$name bid differs from the independent start-price computation ($expected)"
    bid_block="$(jq -r .bid.block <<<"$c")"
    [[ "$(block_timestamp "$bid_block")" == "$(jq -r .auction.startTime <<<"$c")" ]] || die "$name bid is not at the auction start"
    [[ "$(cast call --json --rpc-url "$SANDBOX_RPC_URL" --block "$bid_block" "$folio" 'getBid(uint256,address,address,uint256)(uint256,uint256,uint256)' \
      "$(jq -r .auctionId <<<"$c")" "$WETH" "$USDC" "$BID_SELL_AMOUNT" | jq -r '"\(.[0]) \(.[1]) \(.[2])"')" == \
      "$(jq -r '"\(.bid.sellAmount) \(.bid.buyAmount) \(.bid.price)"' <<<"$c")" ]] || die "$name onchain quote differs at the bid block"
    receipt_logs="$(rpc eth_getTransactionReceipt "$(jq -cn --arg hash "$(jq -r .bid.txHash <<<"$c")" '[$hash]')" |
      jq -c --arg folio "$(lower "$folio")" --arg topic "$(cast keccak 'AuctionBid(uint256,address,address,uint256,uint256)')" \
        '[.result.logs[] | select((.address | ascii_downcase) == $folio and .topics[0] == $topic)]')"
    [[ "$(jq length <<<"$receipt_logs")" == 1 ]] || die "$name bid receipt must hold one AuctionBid"
    [[ "$(log_word_dec "$(jq -c '.[0]' <<<"$receipt_logs")" 0) $(log_word_dec "$(jq -c '.[0]' <<<"$receipt_logs")" 1)" == \
      "$(jq -r '"\(.bid.sellAmount) \(.bid.buyAmount)"' <<<"$c")" ]] || die "$name AuctionBid amounts mismatch"
    while read -r token holder sign amount; do
      before="$(erc20_balance "$token" "$holder" "$((bid_block - 1))")"; after="$(erc20_balance "$token" "$holder" "$bid_block")"
      delta="$(bc <<<"$after - $before")"
      [[ "$delta" == "${sign#+}$amount" ]] || die "$name $token balance delta for $holder is $delta, expected $sign$amount"
    done <<EOF
$WETH $folio - $(jq -r .bid.sellAmount <<<"$c")
$WETH $bidder + $(jq -r .bid.sellAmount <<<"$c")
$USDC $folio + $(jq -r .bid.buyAmount <<<"$c")
$USDC $bidder - $(jq -r .bid.buyAmount <<<"$c")
EOF
    closed_end="$(auction_window "$folio" "$(jq -r .auctionId <<<"$c")" "$(jq -r .close.block <<<"$c")")"
    [[ "${closed_end#* }" == "$(jq -r .close.endTime <<<"$c")" ]] || die "$name closeAuction post-state mismatch"
    end_timestamps="$(rebalance_timestamps "$folio" "$(jq -r .end.block <<<"$c")")"
    [[ "$(rebalance_json "$folio" "$(jq -r .end.block <<<"$c")" | jq -r '.[0]')" == "$(jq -r .rebalanceNonce <<<"$c")" &&
      "$(awk '{print $3}' <<<"$end_timestamps")" == "$(jq -r .end.availableUntil <<<"$c")" ]] || die "$name endRebalance post-state mismatch"
    rebalance_ended_log "$folio" "$(jq -r .rebalanceNonce <<<"$c")" | jq -e --arg tx "$(jq -r .end.txHash <<<"$c")" '.transactionHash == $tx' >/dev/null ||
      die "$name RebalanceEnded(nonce) is not in the end transaction"
  done
  if jq -e '.scenarios.v6Native.completion' "$FIXTURE_JSON" >/dev/null; then
    jq -e --argjson stateBlock "$state_block" '.scenarios.v6Native as $s | $s.completion.bid.block > $stateBlock
      and $s.completion.auction.txHash == $s.execution.auctionTxHash and $s.completion.rebalance.txHash == $s.execution.rebalanceTxHash' \
      "$FIXTURE_JSON" >/dev/null || die "v6Native completion must extend its baseline execution after stateBlock"
  fi
  if jq -e '.scenarios.v5LegacyUpgrade.completion' "$FIXTURE_JSON" >/dev/null; then
    # Direct v6 startRebalance by the manager, then openAuctionUnrestricted.
    jq -e '.scenarios.v5LegacyUpgrade as $s | $s.completion.rebalance.block > $s.upgradeBlock
      and $s.completion.rebalance.selector == "0xc1e54b89" and $s.completion.auction.selector == "0x072c2f17"' \
      "$FIXTURE_JSON" >/dev/null ||
      die "v5LegacyUpgrade completion must be an unrestricted rebalance after its upgrade"
  fi
  [[ "$completion_block" == 0 ]] || printf 'sandbox: completion evidence verified through block %s\n' "$completion_block"
}
hex_to_dec() { printf '%d' "$((16#${1#0x}))"; }
block_number() { hex_to_dec "$(rpc eth_blockNumber | jq -r .result)"; }
block_timestamp() {
  local block="${1:-latest}"
  [[ "$block" == latest ]] || block="$(cast to-hex "$block")"
  hex_to_dec "$(rpc eth_getBlockByNumber "[\"$block\",false]" | jq -r .result.timestamp)"
}
topic_address() { printf '0x%024s%s' '' "${1#0x}" | tr ' ' 0; }
folio_creation_block() {
  local deployer="$1" folio="$2" topic params block
  [[ "$folio" == "$ZERO_ADDRESS" ]] && { printf '0'; return; }
  topic="$(cast keccak 'FolioDeployed(address,address,address)')"
  params="$(jq -cn --arg address "$deployer" --arg from "$(cast to-hex "$FORK_BLOCK")" --arg event "$topic" \
    --arg folio "$(topic_address "$folio")" '[{address:$address,fromBlock:$from,toBlock:"latest",topics:[$event,null,$folio]}]')"
  block="$(rpc eth_getLogs "$params" | jq -r '.result[0].blockNumber // empty')"
  [[ -n "$block" ]] || die "missing FolioDeployed log for $folio"
  hex_to_dec "$block"
}
proposal_execution_block() {
  local governor="$1" proposal_id="$2" topic params block
  [[ "$proposal_id" == 0 ]] && { printf '0'; return; }
  topic="$(cast keccak 'ProposalExecuted(uint256)')"
  params="$(jq -cn --arg address "$governor" --arg from "$(cast to-hex "$FORK_BLOCK")" --arg event "$topic" \
    '[{address:$address,fromBlock:$from,toBlock:"latest",topics:[$event]}]')"
  block="$(rpc eth_getLogs "$params" | jq -r '.result[0].blockNumber // empty')"
  [[ -n "$block" ]] || die "missing ProposalExecuted log for $governor"
  hex_to_dec "$block"
}
proposal_creation_block() {
  local governor="$1" proposal_id="$2" topic params block
  [[ "$proposal_id" == 0 ]] && { printf '0'; return; }
  topic="$(cast keccak 'ProposalCreated(uint256,address,address[],uint256[],string[],bytes[],uint256,uint256,string)')"
  params="$(jq -cn --arg address "$governor" --arg from "$(cast to-hex "$FORK_BLOCK")" --arg event "$topic" \
    '[{address:$address,fromBlock:$from,toBlock:"latest",topics:[$event]}]')"
  block="$(rpc eth_getLogs "$params" | jq -r '.result[0].blockNumber // empty')"
  [[ -n "$block" ]] || die "missing ProposalCreated log for $governor"
  hex_to_dec "$block"
}
write_fixture() {
  local state_block state_timestamp deadline implementation v6_governor_deployer v5_deployer v6_deployer
  local control_creation optimistic_creation legacy_creation native_creation optimistic_upgrade legacy_upgrade oi li
  local optimistic_proposal_block legacy_proposal_block optimistic_targets legacy_targets optimistic_calls legacy_calls
  state_block="$(block_number)"; state_timestamp="$(block_timestamp)"; deadline="$((state_timestamp + 3600))"
  v5_deployer="$(jq -r .v5Deployer "$BOOTSTRAP_JSON")"; v6_deployer="$(jq -r .v6Deployer "$BOOTSTRAP_JSON")"
  control_creation="$(folio_creation_block "$v5_deployer" "$(jq -r .v5ControlFolio "$BOOTSTRAP_JSON")")"
  optimistic_creation="$(folio_creation_block "$v5_deployer" "$(jq -r .optimisticFolio "$BOOTSTRAP_JSON")")"
  legacy_creation="$(folio_creation_block "$v5_deployer" "$(jq -r .legacyFolio "$BOOTSTRAP_JSON")")"
  native_creation="$(folio_creation_block "$v6_deployer" "$(jq -r .nativeFolio "$BOOTSTRAP_JSON")")"
  oi=0; li=0
  if [[ -s "$PROPOSALS_JSON" ]]; then oi="$(jq -r '.optimisticProposalId // "0"' "$PROPOSALS_JSON")"; li="$(jq -r '.legacyProposalId // "0"' "$PROPOSALS_JSON")"; fi
  optimistic_upgrade="$(proposal_execution_block "$(jq -r .optimisticGovernor "$BOOTSTRAP_JSON")" "$oi")"
  legacy_upgrade="$(proposal_execution_block "$(jq -r .legacyGovernor "$BOOTSTRAP_JSON")" "$li")"
  optimistic_proposal_block="$(proposal_creation_block "$(jq -r .optimisticGovernor "$BOOTSTRAP_JSON")" "$oi")"
  legacy_proposal_block="$(proposal_creation_block "$(jq -r .legacyGovernor "$BOOTSTRAP_JSON")" "$li")"
  optimistic_targets="$(jq -cn --arg registry "$(jq -r .optimisticSelectorRegistry "$BOOTSTRAP_JSON")" \
    --arg admin "$(jq -r .optimisticProxyAdmin "$BOOTSTRAP_JSON")" --arg spell "$(jq -r .spell "$BOOTSTRAP_JSON")" \
    '[$registry,$registry,$admin,$spell]')"
  legacy_targets="$(jq -cn --arg admin "$(jq -r .legacyProxyAdmin "$BOOTSTRAP_JSON")" \
    --arg spell "$(jq -r .spell "$BOOTSTRAP_JSON")" '[$admin,$spell]')"
  optimistic_calls="$(jq -cn \
    --arg register "$(cast calldata 'registerSelectors((address,bytes4[])[])' "[($(jq -r .optimisticFolio "$BOOTSTRAP_JSON"),[0xc1e54b89])]")" \
    --arg unregister "$(cast calldata 'unregisterSelectors((address,bytes4[])[])' "[($(jq -r .optimisticFolio "$BOOTSTRAP_JSON"),[0x207c8eed])]")" \
    --arg transfer "$(cast calldata 'transferOwnership(address)' "$(jq -r .spell "$BOOTSTRAP_JSON")")" \
    --arg cast "$(cast calldata 'cast(address,address,address)' "$(jq -r .optimisticFolio "$BOOTSTRAP_JSON")" \
      "$(jq -r .optimisticProxyAdmin "$BOOTSTRAP_JSON")" "$(jq -r .optimisticSelectorRegistry "$BOOTSTRAP_JSON")")" \
    '[$register,$unregister,$transfer,$cast]')"
  legacy_calls="$(jq -cn \
    --arg transfer "$(cast calldata 'transferOwnership(address)' "$(jq -r .spell "$BOOTSTRAP_JSON")")" \
    --arg cast "$(cast calldata 'cast(address,address,address)' "$(jq -r .legacyFolio "$BOOTSTRAP_JSON")" \
      "$(jq -r .legacyProxyAdmin "$BOOTSTRAP_JSON")" "$ZERO_ADDRESS")" \
    '[$transfer,$cast]')"
  jq --arg rpcUrl "$SANDBOX_RPC_URL" --argjson forkBlock "$FORK_BLOCK" --argjson stateBlock "$state_block" \
    --argjson stateTimestamp "$state_timestamp" --argjson deadline "$deadline" \
    --argjson controlCreation "$control_creation" --argjson optimisticCreation "$optimistic_creation" \
    --argjson legacyCreation "$legacy_creation" --argjson nativeCreation "$native_creation" \
    --argjson optimisticUpgrade "$optimistic_upgrade" --argjson legacyUpgrade "$legacy_upgrade" \
    --arg optimisticProposalId "$oi" --arg legacyProposalId "$li" \
    --argjson optimisticProposalBlock "$optimistic_proposal_block" --argjson legacyProposalBlock "$legacy_proposal_block" \
    --argjson optimisticTargets "$optimistic_targets" --argjson legacyTargets "$legacy_targets" \
    --argjson optimisticCalls "$optimistic_calls" --argjson legacyCalls "$legacy_calls" '{
      schemaVersion:1,rpcUrl:$rpcUrl,chainId:1,forkBlock:$forkBlock,stateBlock:$stateBlock,stateTimestamp:$stateTimestamp,
      writePaths:{deadline:$deadline,auctionLength:300},
      protocol:{v5Deployer:.v5Deployer,v6Deployer:.v6Deployer,v6Implementation:null,versionRegistry:.versionRegistry,
        upgradeSpell:.spell,upgradeSpellSourceCommit:.spellSourceCommit,upgradeSpellSourceSha256:.spellSourceSha256,
        startRebalanceSelectors:{v5:"0x207c8eed",v6:"0xc1e54b89"}},
      scenarios:{
        v5Control:{folio:.v5ControlFolio,proxyAdmin:.v5ControlProxyAdmin,governance:"0x0000000000000000000000000000000000000000",
          governanceKind:"standard",creationBlock:$controlCreation,expectedVersion:"5.0.0"},
        v5OptimisticUpgrade:{folio:.optimisticFolio,proxyAdmin:.optimisticProxyAdmin,governance:.optimisticGovernor,
          governanceKind:"optimistic",governanceAddresses:{governor:.optimisticGovernor,timelock:.optimisticTimelock,
          stakingVault:.optimisticStToken,selectorRegistry:.optimisticSelectorRegistry},creationBlock:$optimisticCreation,
          upgradeBlock:$optimisticUpgrade,proposalCallCount:4,expectedVersion:"6.0.0",
          proposal:{proposalId:$optimisticProposalId,entityId:((.optimisticGovernor|ascii_downcase)+"-"+$optimisticProposalId),
            kind:"standard",optimistic:false,state:"executed",proposalBlock:$optimisticProposalBlock,
            executeBlock:$optimisticUpgrade,targets:$optimisticTargets,values:[0,0,0,0],calldatas:$optimisticCalls,
            selectors:["0x39535e96","0x3bb9e672","0xf2fde38b","0x2aa6b211"]}},
        v5LegacyUpgrade:{folio:.legacyFolio,proxyAdmin:.legacyProxyAdmin,governance:.legacyGovernor,governanceKind:"standard",
          governanceAddresses:{governor:.legacyGovernor,timelock:.legacyTimelock,stakingVault:.legacyStToken,
          selectorRegistry:"0x0000000000000000000000000000000000000000"},creationBlock:$legacyCreation,
          upgradeBlock:$legacyUpgrade,proposalCallCount:2,expectedVersion:"6.0.0",
          proposal:{proposalId:$legacyProposalId,entityId:((.legacyGovernor|ascii_downcase)+"-"+$legacyProposalId),
            kind:"standard",optimistic:false,state:"executed",proposalBlock:$legacyProposalBlock,
            executeBlock:$legacyUpgrade,targets:$legacyTargets,values:[0,0],calldatas:$legacyCalls,
            selectors:["0xf2fde38b","0x2aa6b211"]}},
        v6Native:{folio:.nativeFolio,proxyAdmin:.nativeProxyAdmin,governance:.nativeGovernor,governanceKind:"optimistic",
          governanceAddresses:{governor:.nativeGovernor,timelock:.nativeTimelock,stakingVault:.optimisticStToken,
          selectorRegistry:.nativeSelectorRegistry},creationBlock:$nativeCreation,expectedVersion:"6.0.0"}
      }}' "$BOOTSTRAP_JSON" >"$FIXTURE_JSON.tmp"
  implementation="$(cast call --rpc-url "$SANDBOX_RPC_URL" "$(jq -r .v6Deployer "$BOOTSTRAP_JSON")" 'folioImplementation()(address)')"
  v6_governor_deployer="$(cast call --rpc-url "$SANDBOX_RPC_URL" "$(jq -r .v6Deployer "$BOOTSTRAP_JSON")" 'optimisticGovernorDeployer()(address)')"
  # Provenance: which 6.0.0 deployer (and so which optimistic governor deployer) built the native Folio; the spell is
  # always sandbox-built from upstream source. Bootstraps without v6DeployerSource predate real mode (sandbox-built).
  jq --arg implementation "$implementation" --arg v6GovernorDeployer "$v6_governor_deployer" --slurpfile bootstrap "$BOOTSTRAP_JSON" \
    '.protocol.v6Implementation=$implementation
      | .protocol.v6DeployerSource=($bootstrap[0].v6DeployerSource // "sandbox")
      | .protocol.v6OptimisticGovernorDeployer=$v6GovernorDeployer
      | .protocol.v5OptimisticGovernorDeployer=($bootstrap[0].v5OptimisticGovernorDeployer // null)
      | .protocol.upgradeSpellSource="sandbox"' \
    "$FIXTURE_JSON.tmp" >"$FIXTURE_JSON.next"
  mv "$FIXTURE_JSON.next" "$FIXTURE_JSON"
  rm -f "$FIXTURE_JSON.tmp"
  printf 'INDEX_DTF_FORK_MANIFEST=%s\n' "$FIXTURE_JSON"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# Real mode: the registry, every 6.0.0 Folio and the native governance must trace back to the real deployer.
verify_real_deployer() {
  local deployer implementation registry registered name folio slot governor_deployer governor timelock params state_block
  deployer="$(jq -r .protocol.v6Deployer "$FIXTURE_JSON")"
  implementation="$(jq -r .protocol.v6Implementation "$FIXTURE_JSON")"
  registry="$(jq -r .protocol.versionRegistry "$FIXTURE_JSON")"
  state_block="$(jq -r .stateBlock "$FIXTURE_JSON")"
  [[ -z "$SANDBOX_V6_DEPLOYER" || "$(lower "$SANDBOX_V6_DEPLOYER")" == "$(lower "$deployer")" ]] ||
    die "real mode: fixture deployer $deployer is not SANDBOX_V6_DEPLOYER $SANDBOX_V6_DEPLOYER"
  registered="$(cast call --rpc-url "$SANDBOX_RPC_URL" --block "$state_block" "$registry" 'deployments(bytes32)(address)' "$(cast keccak 6.0.0)")"
  [[ "$(lower "$registered")" == "$(lower "$deployer")" ]] || die "real mode: registry 6.0.0 is $registered, not $deployer"
  [[ "$(lower "$(cast call --rpc-url "$SANDBOX_RPC_URL" --block "$state_block" "$deployer" 'folioImplementation()(address)')")" == "$(lower "$implementation")" ]] ||
    die "real mode: $deployer folioImplementation() differs from fixture v6Implementation $implementation"
  for name in v5OptimisticUpgrade v5LegacyUpgrade v6Native; do
    folio="$(jq -r ".scenarios.$name.folio" "$FIXTURE_JSON")"
    [[ "$folio" == "$ZERO_ADDRESS" ]] && continue
    slot="$(cast storage --rpc-url "$SANDBOX_RPC_URL" --block "$state_block" "$folio" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)"
    [[ "0x$(lower "${slot: -40}")" == "$(lower "$implementation")" ]] || die "real mode: $name implementation is 0x${slot: -40}, not $implementation"
  done
  governor_deployer="$(jq -r .protocol.v6OptimisticGovernorDeployer "$FIXTURE_JSON")"
  governor="$(jq -r .scenarios.v6Native.governanceAddresses.governor "$FIXTURE_JSON")"
  timelock="$(jq -r .scenarios.v6Native.governanceAddresses.timelock "$FIXTURE_JSON")"
  params="$(jq -cn --arg address "$governor_deployer" --arg from "$(cast to-hex "$(jq -r .forkBlock "$FIXTURE_JSON")")" \
    --arg to "$(cast to-hex "$state_block")" \
    --arg event "$(cast keccak 'ReserveOptimisticGovernorSystemDeployed(address,address,address,address)')" \
    --arg governor "$(topic_address "$governor")" --arg timelock "$(topic_address "$timelock")" \
    '[{address:$address,fromBlock:$from,toBlock:$to,topics:[$event,null,$governor,$timelock]}]')"
  rpc eth_getLogs "$params" | jq -e '.result | length == 1' >/dev/null ||
    die "real mode: native governor $governor was not deployed by $governor_deployer"
  printf 'sandbox: real 6.0.0 deployer %s verified (implementation %s, governor deployer %s)\n' \
    "$deployer" "$implementation" "$governor_deployer"
}
# Baseline reads are pinned to the fixture's stateBlock so rebalances appended afterwards (completion, Register's
# lane) never fail verification of the state the fixture claims.
verify() {
  [[ -s "$FIXTURE_JSON" ]] || write_fixture
  assert_real_bootstrap_fork_block
  local failed=0 name folio expected actual state_block
  state_block="$(jq -r .stateBlock "$FIXTURE_JSON")"
  (( state_block <= $(block_number) )) || die "fixture stateBlock $state_block is ahead of this fork; wrong RPC or reset fork"
  for name in v5Control v5OptimisticUpgrade v5LegacyUpgrade v6Native; do
    folio="$(jq -r ".scenarios.$name.folio" "$FIXTURE_JSON")"
    [[ "$folio" == "$ZERO_ADDRESS" ]] && continue
    expected="$(jq -r ".scenarios.$name.expectedVersion" "$FIXTURE_JSON")"
    actual="$(folio_version "$folio" "$state_block" 2>/dev/null || true)"
    if [[ "$actual" != "$expected" ]]; then printf 'sandbox: %s expected %s, got %s\n' "$name" "$expected" "$actual" >&2; failed=1; fi
    local creation before_code at_code
    creation="$(jq -r ".scenarios.$name.creationBlock" "$FIXTURE_JSON")"
    before_code="$(cast code --rpc-url "$SANDBOX_RPC_URL" --block "$((creation - 1))" "$folio")"
    at_code="$(cast code --rpc-url "$SANDBOX_RPC_URL" --block "$creation" "$folio")"
    if [[ "$before_code" != 0x || "$at_code" == 0x ]]; then
      printf 'sandbox: %s has invalid creation block %s\n' "$name" "$creation" >&2; failed=1
    fi
  done
  for name in v5OptimisticUpgrade v5LegacyUpgrade; do
    folio="$(jq -r ".scenarios.$name.folio" "$FIXTURE_JSON")"
    [[ "$folio" == "$ZERO_ADDRESS" ]] && continue
    local upgrade before_version at_version
    upgrade="$(jq -r ".scenarios.$name.upgradeBlock" "$FIXTURE_JSON")"
    before_version="$(folio_version "$folio" "$((upgrade - 1))")"
    at_version="$(folio_version "$folio" "$upgrade")"
    if [[ "$before_version" != 5.0.0 || "$at_version" != 6.0.0 ]]; then
      printf 'sandbox: %s has invalid upgrade block %s (%s -> %s)\n' "$name" "$upgrade" "$before_version" "$at_version" >&2; failed=1
    fi
  done
  [[ "$failed" == 0 ]] || die "fixture verification failed"
  local registry
  folio="$(jq -r '.scenarios.v5OptimisticUpgrade.folio' "$FIXTURE_JSON")"
  registry="$(jq -r '.scenarios.v5OptimisticUpgrade.governanceAddresses.selectorRegistry' "$FIXTURE_JSON")"
  if [[ "$folio" != "$ZERO_ADDRESS" ]]; then
    [[ "$(cast call --rpc-url "$SANDBOX_RPC_URL" --block "$state_block" "$registry" 'isAllowed(address,bytes4)(bool)' "$folio" 0xc1e54b89)" == true ]] || die "v6 selector missing"
    [[ "$(cast call --rpc-url "$SANDBOX_RPC_URL" --block "$state_block" "$registry" 'isAllowed(address,bytes4)(bool)' "$folio" 0x207c8eed)" == false ]] || die "v5 selector remains"
  fi
  verify_execution
  verify_completion
  if [[ "$(jq -r '.protocol.v6DeployerSource // "sandbox"' "$FIXTURE_JSON")" == real ]]; then
    verify_real_deployer
  fi
  printf 'sandbox: fixture verified at block %s\nINDEX_DTF_FORK_MANIFEST=%s\n' "$state_block" "$FIXTURE_JSON"
}

need curl; need jq; need cast; need forge; need bc; need shasum
assert_safe_state_dir; assert_spell_source; mkdir -p "$SANDBOX_STATE_DIR"; assert_local_anvil
[[ -z "$SANDBOX_V6_DEPLOYER" || "$SANDBOX_V6_DEPLOYER" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "SANDBOX_V6_DEPLOYER is not an address: $SANDBOX_V6_DEPLOYER"
case "$COMMAND" in
  bootstrap) bootstrap ;;
  scenarios) scenarios ;;
  executions) execution_scenarios ;;
  all) bootstrap; scenarios; execution_scenarios; verify ;;
  verify) verify ;;
  *) die "usage: $0 <bootstrap|scenarios|executions|all|verify> [comma-separated-scenarios]" ;;
esac
