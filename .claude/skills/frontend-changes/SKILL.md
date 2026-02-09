---
name: release-changes
description: Analyze contract changes since last release to identify frontend integration impact (ABI changes, logic changes, new validation, behavioral shifts)
argument-hint: "[baseline-tag-override]"
disable-model-invocation: true
allowed-tools: Bash(git diff *), Bash(git log *), Bash(git tag *), Bash(git rev-parse *), Bash(git show *), Read, Grep, Glob
---

# Frontend Changes Analysis

Analyze Solidity contract changes since the last release and produce a structured report of everything a frontend developer needs to know to integrate the new version.

## Configuration

<!-- UPDATE AFTER EACH RELEASE: set to the latest rX.X.X tag -->

- **Baseline tag**: `r4.0.0`
- **Override**: If `$ARGUMENTS` is provided and non-empty, use it as the baseline tag instead.
- **Diff scope**: `contracts/` directory only
- **Exclude**: `contracts/spells/`, `contracts/mocks/`, any `test/` paths

## Exported Contracts (Frontend-Facing)

These contracts have their ABIs exported to `artifacts/` for frontend consumption via `script/export.ts`. Changes to these contracts or their interfaces are always frontend-relevant.

| Contract           | Source File                                 |
| ------------------ | ------------------------------------------- |
| Folio              | `contracts/Folio.sol`                       |
| FolioLens          | `contracts/periphery/FolioLens.sol`         |
| GovernanceDeployer | `contracts/deployer/GovernanceDeployer.sol` |
| FolioDeployer      | `contracts/deployer/FolioDeployer.sol`      |
| FolioProxyAdmin    | `contracts/folio/FolioProxy.sol`            |
| FolioProxy         | `contracts/folio/FolioProxy.sol`            |
| StakingVault       | `contracts/staking/StakingVault.sol`        |
| UnstakingManager   | `contracts/staking/UnstakingManager.sol`    |
| FolioGovernor      | `contracts/governance/FolioGovernor.sol`    |

## Interface Files (Define ABI Surface)

These interfaces define events, errors, structs, and enums consumed by the frontend:

- `contracts/interfaces/IFolio.sol` — primary: events, errors, structs, enums for Folio
- `contracts/interfaces/IFolioDeployer.sol`
- `contracts/interfaces/IGovernanceDeployer.sol`
- `contracts/interfaces/IFolioDAOFeeRegistry.sol`
- `contracts/interfaces/IFolioVersionRegistry.sol`
- `contracts/interfaces/IBidderCallee.sol`
- `contracts/interfaces/IRoleRegistry.sol`

## Supporting Files

- `contracts/utils/Constants.sol` — role hashes, fee limits, timing constants that frontend validation must respect
- `contracts/utils/RebalancingLib.sol` — library delegated to by Folio.sol; changes here affect Folio behavior transitively

## Analysis Procedure

### Step 1: Validate Baseline Tag

Run `git tag --list 'r*'` and confirm the baseline tag exists. If it does not exist, output:

```
ERROR: Baseline tag '<tag>' not found. Available release tags: <list them>
```

Then stop.

### Step 2: Get Changed Files

Run:

```
git diff --name-only <baseline-tag>..HEAD -- contracts/
```

Exclude any files under `contracts/spells/` or `contracts/mocks/`.

If no files remain, output:

```
============================================================
FRONTEND CHANGES REPORT: <baseline-tag> -> HEAD
============================================================

No contract changes detected since <baseline-tag>. No frontend impact.
```

Then stop.

### Step 3: Classify Changed Files

For each changed file, classify it:

- **Exported contract**: Files in the Exported Contracts table above
- **Interface file**: Files in `contracts/interfaces/`
- **Constants/utils**: `Constants.sol`, `RebalancingLib.sol`, `MathLib.sol`
- **Other**: Everything else in `contracts/` not excluded

If NONE of the changed files are exported contracts, interface files, or constants/utils, output:

```
============================================================
FRONTEND CHANGES REPORT: <baseline-tag> -> HEAD
============================================================

Changed files (not frontend-facing):
<list them>

None of the changed files are frontend-exported contracts or their interfaces.
No frontend impact expected.
```

Then stop.

### Step 4: Analyze ABI Changes

For each changed file that is an exported contract or interface file, read both the diff (`git diff <tag>..HEAD -- <file>`) and the current version of the file (using the Read tool).

Identify:

**4a. Function Signature Changes** (public/external only)

- New function declarations
- Removed function declarations
- Changed parameter types, names, or order
- Changed return types
- Changed visibility (public <-> external)
- Changed mutability (view, pure, payable, nonpayable)

**4b. Event Changes**

- New/removed event declarations
- Changed parameter types, names, indexing, or order

**4c. Error Changes**

- New/removed error declarations
- Changed parameter types or names

**4d. Struct/Enum Changes**

- New/removed struct or enum declarations
- Added/removed/reordered fields in existing structs
- Added/removed values in existing enums
- Changed field types in existing structs

**4e. Constant Changes** (in Constants.sol)

- New constants affecting frontend (roles, limits, fee bounds, timing)
- Changed constant values
- Removed constants

### Step 5: Analyze Logic Changes

For each changed function body in exported contracts, identify changes that affect how the frontend constructs transactions or interprets results:

**5a. Validation Changes**

- New `require` or `revert` statements — new failure modes the frontend must handle
- Changed validation conditions — different input rules
- Removed validation — relaxed constraints

**5b. Behavioral Changes**

- Changed calculation logic affecting return values
- New state transitions or changed state machine behavior
- Changed event emission (different data, conditional emission)
- Reordered operations affecting calldata construction

**5c. Access Control Changes**

- Changed role requirements for functions
- New role-gated functions

**5d. Integration Changes**

- New external calls or changed call patterns
- Changed callback interfaces
- New or changed modifiers on external functions

**Important**: Changes to `RebalancingLib.sol` affect `Folio.sol` behavior since Folio delegates to it. Report these under Folio's logic changes section.

### Step 6: Read Full Context

For any contract where you found changes in Steps 4-5, use the Read tool to examine the CURRENT version of the full file to:

- Confirm whether a change is ABI-breaking vs internal-only
- Understand whether a new revert creates a new error type
- Check full function signatures, not just diff fragments

## Output Format

Always produce output. Structure the report exactly as follows:

```
============================================================
FRONTEND CHANGES REPORT: <baseline-tag> -> HEAD (<short-sha>)
============================================================

SUMMARY
-------
- Total files changed in contracts/: N
- Frontend-exported contracts changed: N
- Interface files changed: N
- ABI-breaking changes: YES/NO
- Logic-only changes: YES/NO

------------------------------------------------------------
ABI CHANGES
------------------------------------------------------------
```

If no ABI changes: `No ABI changes detected.`

Otherwise, organize by contract:

```
### <ContractName> (<filepath>)

**Functions:**
  [+] newFunction(uint256 param) external returns (bool)
  [-] removedFunction(address) external
  [~] modifiedFunction: param type changed from uint256 to int256

**Events:**
  [+] NewEvent(address indexed sender, uint256 amount)
  [-] OldEvent(address)
  [~] ModifiedEvent: added indexed to 'sender' parameter

**Errors:**
  [+] NewError__SomethingWrong()
  [-] OldError__Removed()

**Structs/Enums:**
  [+] struct NewStruct { address token; uint256 amount; }
  [-] enum RemovedEnum
  [~] struct ModifiedStruct: added field 'uint256 newField'

**Constants:**
  [+] NEW_CONSTANT = value
  [~] CHANGED_CONSTANT: old_value -> new_value
```

```
------------------------------------------------------------
LOGIC CHANGES
------------------------------------------------------------
```

If no logic changes: `No frontend-relevant logic changes detected.`

Otherwise, organize by contract and function:

```
### <ContractName>.<functionName>()

- [validation] New require: reverts with Folio__NewError() when X < Y
- [behavior] Changed fee calculation: now rounds up instead of down
- [access] Role check changed from ADMIN to REBALANCE_MANAGER
- [state] New state transition: can now go from OPEN to PAUSED
```

```
------------------------------------------------------------
RECOMMENDATIONS
------------------------------------------------------------
```

Provide 2-5 actionable bullet points for the frontend team:

- Which ABI artifacts need to be regenerated (run `pnpm export`)
- Which frontend transaction builders need updating
- Which event listeners need changes
- Which error handling needs updating
- Any new user-facing flows to implement

## Notation

- `[+]` = addition
- `[-]` = removal
- `[~]` = modification
- Focus on PUBLIC and EXTERNAL functions only for ABI analysis
- Internal/private function changes only matter if they affect public/external function behavior
- Struct changes in interface files (e.g., IFolio.sol) are always ABI-relevant since they define parameter/return types
