#!/bin/bash
set -euo pipefail

# Role constants
DEFAULT_ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"
REBALANCE_MANAGER="0x4ff6ae4d6a29e79ca45c6441bdc89b93878ac6118485b33c8baa3749fc3cb130"
AUCTION_LAUNCHER="0x13ff1b2625181b311f257c723b5e6d366eb318b212d9dd694c48fcf227659df5"

OUTDIR="script/deprecation/proposals"
mkdir -p "$OUTDIR"

TIMESTAMP=$(date +%s)

# generate_proposal <symbol> <chainId> <folio_addr> <owner_governor> <owner_timelock>
#   <trading_timelock|"none"> <proxy_admin> <auction_launcher1> [auction_launcher2...]
generate_proposal() {
  local symbol="$1"
  local chain_id="$2"
  local folio="$3"
  local owner_governor="$4"
  local owner_timelock="$5"
  local trading_timelock="$6" # REBALANCE_MANAGER holder, or "none"
  local proxy_admin="$7"
  shift 7
  local auction_launchers=("$@")

  echo "Generating proposal for $symbol (chain $chain_id)..."

  local targets=()
  local calldatas=()

  # 1. deprecateFolio()
  local deprecate_cd
  deprecate_cd=$(cast calldata "deprecateFolio()")
  targets+=("$folio")
  calldatas+=("$deprecate_cd")

  # 2. Revoke REBALANCE_MANAGER roles
  if [[ "$trading_timelock" != "none" ]]; then
    local revoke_cd
    revoke_cd=$(cast calldata "revokeRole(bytes32,address)" "$REBALANCE_MANAGER" "$trading_timelock")
    targets+=("$folio")
    calldatas+=("$revoke_cd")
  fi

  # 3. Revoke AUCTION_LAUNCHER roles
  for launcher in "${auction_launchers[@]}"; do
    local revoke_cd
    revoke_cd=$(cast calldata "revokeRole(bytes32,address)" "$AUCTION_LAUNCHER" "$launcher")
    targets+=("$folio")
    calldatas+=("$revoke_cd")
  done

  # 4. Revoke DEFAULT_ADMIN_ROLE
  local revoke_admin_cd
  revoke_admin_cd=$(cast calldata "revokeRole(bytes32,address)" "$DEFAULT_ADMIN_ROLE" "$owner_timelock")
  targets+=("$folio")
  calldatas+=("$revoke_admin_cd")

  # 5. Renounce ProxyAdmin ownership (last — irreversible)
  if [[ "$proxy_admin" != "0x0000000000000000000000000000000000000000" ]]; then
    local renounce_cd
    renounce_cd=$(cast calldata "renounceOwnership()")
    targets+=("$proxy_admin")
    calldatas+=("$renounce_cd")
  fi

  # Build propose() argument arrays
  local n=${#targets[@]}
  local target_arr=""
  local value_arr=""
  local calldata_arr=""

  for ((i = 0; i < n; i++)); do
    if [[ $i -gt 0 ]]; then
      target_arr+=","
      value_arr+=","
      calldata_arr+=","
    fi
    target_arr+="${targets[$i]}"
    value_arr+="0"
    calldata_arr+="${calldatas[$i]}"
  done

  local description="Deprecate ${symbol} Index DTF"

  # Encode propose() call
  local propose_cd
  propose_cd=$(cast calldata \
    "propose(address[],uint256[],bytes[],string)" \
    "[${target_arr}]" \
    "[${value_arr}]" \
    "[${calldata_arr}]" \
    "$description")

  # Write Safe Transaction Builder JSON
  cat > "${OUTDIR}/deprecate-${symbol}.json" <<ENDJSON
{
  "version": "1.0",
  "chainId": "${chain_id}",
  "createdAt": ${TIMESTAMP},
  "meta": {
    "name": "Deprecate ${symbol}",
    "description": "Governance proposal to deprecate ${symbol} Index DTF"
  },
  "transactions": [
    {
      "to": "${owner_governor}",
      "value": "0",
      "data": "${propose_cd}"
    }
  ]
}
ENDJSON

  echo "  -> ${OUTDIR}/deprecate-${symbol}.json (${n} actions)"
}

# ──────────────────────────────────────────────
# Ethereum Mainnet (chainId: 1)
# ──────────────────────────────────────────────

generate_proposal "mvRWA" "1" \
  "0xa5cdea03b11042fc10b52af9eca48bb17a2107d2" \
  "0x58e72a9a9e9dc5209d02335d5ac67ed28a86eae9" \
  "0x02188526dd0021f8032868552d2ea8529d3a4e53" \
  "0xf156f05d8eb854926f08983f98bd8ac27c2f18c4" \
  "0x019318674560c233893aa31bc0a380dc71dc2ddf" \
  "0x6293e97900aa987cf3cbd419e0d5ba43ebfa91c1" \
  "0xc6625129c9df3314a4dd604845488f4ba62f9db8" \
  "0x7daaf7bc2ee8bf4c0ac7f37e6b6cfaeb3ed9a868"

generate_proposal "mvDEFI" "1" \
  "0x20d81101d254729a6e689418526be31e2c544290" \
  "0xa5168b7b5c081a2098420892c9da26b6b30fc496" \
  "0x9f4d7074fe0b9717030e5763e4155cc75b36380d" \
  "0x9c2c381588db0248103ea239044a3ea60f29b346" \
  "0x3927882f047944a9c561f29e204c370dd84852fd" \
  "0x6293e97900aa987cf3cbd419e0d5ba43ebfa91c1" \
  "0x6f1d6b86d4ad705385e751e6e88b0fdfdbadf298" \
  "0x7daaf7bc2ee8bf4c0ac7f37e6b6cfaeb3ed9a868"

# ──────────────────────────────────────────────
# Base (chainId: 8453)
# ──────────────────────────────────────────────

generate_proposal "AI" "8453" \
  "0xfe45eda533e97198d9f3deeda9ae6c147141f6f9" \
  "0x26305e88587ecfde34a9dce37d7cb292a3b51b02" \
  "0x1b0545ef805841b7abef6b5c3a9458772476282e" \
  "0xb72e489124f1f75e9afa4f54cd348c191f84d5dd" \
  "0x456219b7897384217ca224f735dbbc30c395c87f" \
  "0x5edb66b4c01355b07df3ea9e4c2508e4cc542c6a" \
  "0x6f1d6b86d4ad705385e751e6e88b0fdfdbadf298" \
  "0x7daaf7bc2ee8bf4c0ac7f37e6b6cfaeb3ed9a868"

generate_proposal "VTF" "8453" \
  "0x47686106181b3cefe4eaf94c4c10b48ac750370b" \
  "0xa8ce43762de703d285b019fac8829148e3013442" \
  "0xc290b859f4f6f0644600dd18d53822bcf95d2602" \
  "0xccb16edde81843e42f3c39ab70598671eb668bb0" \
  "0x7c1faffc7f3a52aa9dbd265e5709202eea3a8a48" \
  "0x93db2e90f8b2b073010b425f9350202330bd923e" \
  "0x6f1d6b86d4ad705385e751e6e88b0fdfdbadf298" \
  "0x7daaf7bc2ee8bf4c0ac7f37e6b6cfaeb3ed9a868"

generate_proposal "CLUB" "8453" \
  "0xf8ef6e785473e82527908b06023ac3e401ccfdcd" \
  "0x48259e5b4d39305e445c6c32fe598a9b418d4524" \
  "0x3a9137c17a33dd884adf267171f066ccbf4bc86f" \
  "none" \
  "0x0000000000000000000000000000000000000000" \
  "0x17aac44f3617521383a23a89b3a272e0d6dbc66e"

generate_proposal "MVDA25" "8453" \
  "0xd600e748c17ca237fcb5967fa13d688aff17be78" \
  "0x9c799bb988679e5cab0d7e8b5480a4015e25f403" \
  "0xb396e2bec0e914b8a5ef9c1ed748e8e6be2af135" \
  "0x364768c014b312b5ff92ce5d878393f15de3d484" \
  "0xb467947f35697fadb46d10f36546e99a02088305" \
  "0xd8b0f4e54a8dac04e0a57392f5a630cedb99c940" \
  "0x6f1d6b86d4ad705385e751e6e88b0fdfdbadf298" \
  "0x7daaf7bc2ee8bf4c0ac7f37e6b6cfaeb3ed9a868"

generate_proposal "SBR" "8453" \
  "0x89ff8f639d402839205a6bf03cc01bdffa4768b7" \
  "0x90d1f8317911617d0a6683927149b6493b881fba" \
  "0x2e2959d4841916289ec9119fff3268ea28283aff" \
  "0x630ac17e8582e08f2154dd29d6e9b58a6a863776" \
  "0x00b34834cabe9e38992d1e04081369c43c149685" \
  "0x349f3a7031f4166f7282db894184980437266c4f" \
  "0x3874884c2e86ad61117d8b9860c548eb0a7368d1" \
  "0x637299ad0d15d740b4539e7e14b6cde3ab73bc63"

generate_proposal "ZINDEX" "8453" \
  "0x160c18476f6f5099f374033fbc695c9234cda495" \
  "0xd71981cc95f29077199b4cabe601be78b662a88c" \
  "0xd3348dd7ec6e942938beb57961c2ae9dc5664229" \
  "0xdc02e2e322129c4d9c625c3cc59cfb4291759862" \
  "0xe6179eef5312487e6cab447356c855eee805781e" \
  "0x6bc2f0cefe18ec4e5afeb8f810c7063bed3f92b9" \
  "0xb28a4fe7d71535d99a77c46ff7d4296e0225be1b" \
  "0x718841c68eab4038ef389c154f8e91f9923b2fda"

echo ""
echo "Done. Generated $(ls -1 ${OUTDIR}/deprecate-*.json | wc -l | tr -d ' ') proposal files in ${OUTDIR}/"
