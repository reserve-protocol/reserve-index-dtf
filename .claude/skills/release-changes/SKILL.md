---
name: release-changes
description: Analyze contract changes between two release tags (struct changes, deployer changes, recommendations)
argument-hint: "<from-tag> <to-tag> (e.g. r4.0.0 r5.0.0)"
disable-model-invocation: true
allowed-tools: Bash(git diff *), Bash(git log *), Bash(git tag *), Bash(git rev-parse *), Bash(git show *), Read, Grep, Glob
---

# Frontend Changes Analysis

Analyze Solidity contract changes between two release tags. Produce a concise report of what a frontend developer needs to know.

## Configuration

- **Arguments**: `$ARGUMENTS` — two space-separated tags: `<from-tag> <to-tag>` (e.g. `r4.0.0 r5.0.0`)
- **from-tag**: The older release tag (baseline)
- **to-tag**: The newer release tag (target)
- **Diff scope**: `contracts/` directory only
- **Exclude**: `contracts/spells/`, `contracts/mocks/`, any `test/` paths

## Exported Contracts (Frontend-Facing)

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

## Interface Files

- `contracts/interfaces/IFolio.sol`
- `contracts/interfaces/IFolioDeployer.sol`
- `contracts/interfaces/IGovernanceDeployer.sol`
- `contracts/interfaces/IFolioDAOFeeRegistry.sol`
- `contracts/interfaces/IFolioVersionRegistry.sol`
- `contracts/interfaces/IBidderCallee.sol`
- `contracts/interfaces/IRoleRegistry.sol`

## Procedure

### Step 1: Validate Tags

Parse `$ARGUMENTS` into `<from-tag>` and `<to-tag>` (space-separated). If fewer than 2 arguments, list available release tags with `git tag --list 'r*'` and ask the user to provide both. Then stop.

Run `git tag --list 'r*'` and confirm both tags exist. If either is missing, list available tags and stop.

### Step 2: Get Changed Files

```
git diff --name-only <from-tag>..<to-tag> -- contracts/
```

Exclude `contracts/spells/`, `contracts/mocks/`, and `test/` paths. If no files remain, report "No contract changes" and stop.

### Step 3: Classify

For each changed file: is it an exported contract, interface file, deployer, or other? If none are frontend-facing, report that and stop.

### Step 4: Analyze

For each changed interface file and deployer file, read the diff (`git diff <from-tag>..<to-tag> -- <file>`) and the `<to-tag>` version of the file (`git show <to-tag>:<file>`).

Focus on:

**4a. Struct/Enum Changes** (interface files only)

- New/removed structs or enums
- Added/removed/reordered fields in existing structs
- Changed field types

**4b. Event Changes** (interface files only)

- New/removed event declarations
- Changed event parameters (types, names, indexing, order)

**4c. Deployer Changes** (`FolioDeployer.sol`, `GovernanceDeployer.sol`)

Report changes that affect how the frontend *calls* the deployer:
- New deployment functions or changed function signatures
- Changed parameters or new parameters the caller must provide
- New deployment modes (e.g. self-governance option)
- Struct changes from interface files that affect deployer calldata (e.g. new fields in `FolioFlags` that the caller must populate)

Do NOT report internal implementation details like deploy ordering, temporary ownership patterns, or internal role grant/renounce sequences — these are invisible to the caller.

## Output Format

```
============================================================
FRONTEND CHANGES REPORT: <from-tag> -> <to-tag>
============================================================

Releases:
- <from-tag>: https://github.com/reserve-protocol/reserve-index-dtf/releases/tag/<from-tag>
- <to-tag>: https://github.com/reserve-protocol/reserve-index-dtf/releases/tag/<to-tag>

------------------------------------------------------------
STRUCT & ENUM CHANGES
------------------------------------------------------------
```

If none: `No struct/enum changes detected.`

Otherwise, organize by interface file:

```
### IFolio (contracts/interfaces/IFolio.sol)

  [+] struct NewStruct { address token; uint256 amount; }
  [-] enum RemovedEnum
  [~] struct ModifiedStruct: added field 'uint256 newField'
```

```
------------------------------------------------------------
EVENT CHANGES
------------------------------------------------------------
```

If none: `No event changes detected.`

Otherwise, organize by interface file:

```
### IFolio (contracts/interfaces/IFolio.sol)

  [+] NewEvent(address indexed sender, uint256 amount)
  [-] OldEvent(address)
  [~] ModifiedEvent: added indexed to 'sender' parameter
```

```
------------------------------------------------------------
DEPLOYER CHANGES
------------------------------------------------------------
```

If none: `No deployer changes detected.`

Otherwise, summarize per deployer:

```
### FolioDeployer (contracts/deployer/FolioDeployer.sol)

- <concise bullet describing what changed and why it matters for frontend>
```

```
------------------------------------------------------------
RECOMMENDATIONS
------------------------------------------------------------
```

Provide 2-5 actionable bullet points for the frontend team:

- Which ABI artifacts need regenerating (`pnpm export`)
- Which frontend transaction builders need updating
- Which event listeners need changes
- Any new user-facing flows to implement

## Notation

- `[+]` = addition
- `[-]` = removal
- `[~]` = modification
