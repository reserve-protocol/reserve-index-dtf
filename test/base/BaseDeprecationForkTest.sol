// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { IAccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IFolio } from "contracts/interfaces/IFolio.sol";
import { Folio } from "@src/Folio.sol";

bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
bytes32 constant REBALANCE_MANAGER = keccak256("REBALANCE_MANAGER");
bytes32 constant AUCTION_LAUNCHER = keccak256("AUCTION_LAUNCHER");

bytes4 constant PROPOSE_SELECTOR = bytes4(keccak256("propose(address[],uint256[],bytes[],string)"));
bytes4 constant DEPRECATE_FOLIO_SELECTOR = bytes4(keccak256("deprecateFolio()"));
bytes4 constant REVOKE_ROLE_SELECTOR = bytes4(keccak256("revokeRole(bytes32,address)"));
bytes4 constant RENOUNCE_OWNERSHIP_SELECTOR = bytes4(keccak256("renounceOwnership()"));

/// @dev UnstakingManager.LockCreated(uint256 lockId, address user, uint256 amount, uint256 unlockTime)
bytes32 constant LOCK_CREATED_TOPIC = keccak256("LockCreated(uint256,address,uint256,uint256)");

interface IGovernor {
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    function state(uint256 proposalId) external view returns (ProposalState);
    function proposalEta(uint256 proposalId) external view returns (uint256);
    function hashProposal(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external pure returns (uint256);

    function execute(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256);
}

interface IStakingVault is IERC4626 {
    function unstakingDelay() external view returns (uint256);
    function unstakingManager() external view returns (address);
}

interface IUnstakingManager {
    function claimLock(uint256 lockId) external;
}

/**
 * @title BaseDeprecationForkTest
 * @notice Shared setup and post-conditions for the deprecation fork suites.
 * @dev Subclasses differ only in where the deprecation actions come from and who executes them:
 *      - DeprecationJsonFork: decoded from the generated proposal JSON, executed as the owner timelock
 *      - DeprecationProposalFork: a live onchain proposal, executed through the Governor
 *      - DeprecationFork: assembled inline, executed as the owner timelock
 */
abstract contract BaseDeprecationForkTest is Test {
    struct DTFConfig {
        string symbol;
        address folio;
        address ownerTimelock;
        address tradingTimelock; // address(0) if none
        address[] auctionLaunchers;
        address proxyAdmin;
        address stakingVault;
    }

    // ==== Pre-conditions ====

    /// @dev Roles other than the admin are not asserted here: a DTF can reach deprecation having already
    ///      given some of them up. _assertDeprecationActions checks the ones a proposal actually revokes.
    function _assertLiveAndGoverned(DTFConfig memory cfg) internal view {
        assertFalse(Folio(cfg.folio).isDeprecated(), string.concat(cfg.symbol, ": already deprecated"));
        assertTrue(
            IAccessControlEnumerable(cfg.folio).hasRole(DEFAULT_ADMIN_ROLE, cfg.ownerTimelock),
            string.concat(cfg.symbol, ": timelock missing admin role")
        );
    }

    function _assertProxyAdminOwned(DTFConfig memory cfg) internal view {
        assertEq(
            Ownable(cfg.proxyAdmin).owner(),
            cfg.ownerTimelock,
            string.concat(cfg.symbol, ": proxyAdmin not owned by timelock")
        );
    }

    // ==== Post-conditions ====

    /// @dev Deprecated, with no address left holding any operational role
    function _assertDeprecated(DTFConfig memory cfg) internal view {
        assertTrue(Folio(cfg.folio).isDeprecated(), string.concat(cfg.symbol, ": not deprecated"));

        assertEq(
            IAccessControlEnumerable(cfg.folio).getRoleMemberCount(DEFAULT_ADMIN_ROLE),
            0,
            string.concat(cfg.symbol, ": admin role count != 0")
        );
        assertEq(
            IAccessControlEnumerable(cfg.folio).getRoleMemberCount(REBALANCE_MANAGER),
            0,
            string.concat(cfg.symbol, ": rebalance manager count != 0")
        );
        assertEq(
            IAccessControlEnumerable(cfg.folio).getRoleMemberCount(AUCTION_LAUNCHER),
            0,
            string.concat(cfg.symbol, ": auction launcher count != 0")
        );
    }

    function _assertProxyAdminRenounced(DTFConfig memory cfg) internal view {
        assertEq(Ownable(cfg.proxyAdmin).owner(), address(0), string.concat(cfg.symbol, ": proxyAdmin owner not zero"));
    }

    /// @dev Redemption is the one Folio entrypoint that must survive deprecation. Every basket token quoted
    ///      by toAssets has to actually pay out; tokens quoted at zero are dust weights that floor away for
    ///      a single share.
    function _assertRedeemStillWorks(DTFConfig memory cfg) internal {
        Folio folio = Folio(cfg.folio);
        assertTrue(folio.isDeprecated(), string.concat(cfg.symbol, ": should be deprecated for redeem test"));

        uint256 redeemShares = 1e18;
        (address[] memory assets, uint256[] memory quoted) = folio.toAssets(redeemShares, Math.Rounding.Floor);
        assertGt(assets.length, 0, string.concat(cfg.symbol, ": empty basket"));

        address redeemer = makeAddr(string.concat("redeemer-", cfg.symbol));
        deal(cfg.folio, redeemer, redeemShares);
        assertEq(folio.balanceOf(redeemer), redeemShares, string.concat(cfg.symbol, ": deal failed"));

        uint256[] memory balancesBefore = new uint256[](assets.length);
        for (uint256 i; i < assets.length; i++) {
            balancesBefore[i] = IERC20(assets[i]).balanceOf(redeemer);
        }

        vm.prank(redeemer);
        folio.redeem(redeemShares, redeemer, assets, new uint256[](assets.length));

        assertEq(folio.balanceOf(redeemer), 0, string.concat(cfg.symbol, ": shares not burned"));

        uint256 totalReceived;
        for (uint256 i; i < assets.length; i++) {
            uint256 received = IERC20(assets[i]).balanceOf(redeemer) - balancesBefore[i];
            totalReceived += received;

            if (quoted[i] != 0) {
                assertGt(received, 0, string.concat(cfg.symbol, ": received nothing for a quoted basket token"));
            }
        }
        assertGt(totalReceived, 0, string.concat(cfg.symbol, ": received nothing from redeem"));
    }

    function _assertMintBlocked(DTFConfig memory cfg) internal {
        address minter = makeAddr(string.concat("minter-", cfg.symbol));

        vm.prank(minter);
        vm.expectRevert(IFolio.Folio__FolioDeprecated.selector);
        Folio(cfg.folio).mint(1e18, minter, 0);
    }

    /// @dev Stakers must still be able to exit the governance staking vault
    function _assertUnstakeStillWorks(DTFConfig memory cfg) internal {
        IStakingVault vault = IStakingVault(cfg.stakingVault);
        address underlying = vault.asset();
        address unstakingManager = vault.unstakingManager();
        address staker = makeAddr(string.concat("staker-", cfg.symbol));

        deal(cfg.stakingVault, staker, 1e18);
        uint256 underlyingBefore = IERC20(underlying).balanceOf(staker);

        // Redeem shares — creates a lock in the UnstakingManager
        vm.recordLogs();
        vm.prank(staker);
        vault.redeem(1e18, staker, staker);
        assertEq(IERC20(cfg.stakingVault).balanceOf(staker), 0, string.concat(cfg.symbol, ": vault shares not burned"));

        uint256 lockId = _findLockId(cfg.symbol, vm.getRecordedLogs(), unstakingManager, staker);

        // Warp past the unstaking delay and claim
        vm.warp(block.timestamp + vault.unstakingDelay() + 1);
        IUnstakingManager(unstakingManager).claimLock(lockId);

        assertGt(
            IERC20(underlying).balanceOf(staker),
            underlyingBefore,
            string.concat(cfg.symbol, ": no underlying after unstake")
        );
    }

    /// @dev Reads the lock id off the LockCreated event; vaults shared by several DTFs hold too many
    ///      locks to scan by index
    function _findLockId(
        string memory symbol,
        Vm.Log[] memory logs,
        address unstakingManager,
        address staker
    ) internal pure returns (uint256 lockId) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != unstakingManager || logs[i].topics[0] != LOCK_CREATED_TOPIC) {
                continue;
            }

            (uint256 id, address user, , ) = abi.decode(logs[i].data, (uint256, address, uint256, uint256));
            if (user == staker) {
                return id;
            }
        }

        revert(string.concat(symbol, ": no unstaking lock created"));
    }

    /// @dev Everything a holder is still entitled to once the DTF is deprecated
    function _assertRedemptionOnlyMode(DTFConfig memory cfg) internal {
        _assertDeprecated(cfg);
        _assertRedeemStillWorks(cfg);
        _assertMintBlocked(cfg);
        _assertUnstakeStillWorks(cfg);
    }

    // ==== Proposal helpers ====

    /// @dev Decodes the propose() call out of a generated Safe Transaction Builder JSON
    function _loadProposalJson(
        string memory jsonPath
    )
        internal
        view
        returns (
            address to,
            uint256 chainId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        )
    {
        string memory json = vm.readFile(jsonPath);

        chainId = vm.parseUint(vm.parseJsonString(json, ".chainId"));

        // one proposal per DTF: a single propose() call carrying every deprecation action
        to = vm.parseJsonAddress(json, ".transactions[0].to");

        bytes memory data = vm.parseJsonBytes(json, ".transactions[0].data");
        assertEq(bytes4(data), PROPOSE_SELECTOR, "transaction is not a propose() call");

        (targets, values, calldatas, description) = abi.decode(
            _stripSelector(data),
            (address[], uint256[], bytes[], string)
        );
    }

    /// @dev Asserts the action set fully deprecates the DTF, in an order that keeps every call authorized
    function _assertDeprecationActions(
        DTFConfig memory cfg,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) internal view {
        // 1 deprecate + 1 rebalance manager (optional) + N launchers + 1 admin + 1 renounce
        uint256 expectedLength = 3 + cfg.auctionLaunchers.length + (cfg.tradingTimelock != address(0) ? 1 : 0);
        assertEq(targets.length, expectedLength, string.concat(cfg.symbol, ": unexpected action count"));
        assertEq(values.length, expectedLength, string.concat(cfg.symbol, ": values length mismatch"));
        assertEq(calldatas.length, expectedLength, string.concat(cfg.symbol, ": calldatas length mismatch"));

        for (uint256 i; i < values.length; i++) {
            assertEq(values[i], 0, string.concat(cfg.symbol, ": nonzero value"));
        }

        // first action deprecates the Folio
        assertEq(targets[0], cfg.folio, string.concat(cfg.symbol, ": action 0 not the Folio"));
        assertEq(bytes4(calldatas[0]), DEPRECATE_FOLIO_SELECTOR, string.concat(cfg.symbol, ": action 0 not deprecate"));

        // middle actions revoke roles that are currently held
        uint256 lastFolioAction = expectedLength - 2;
        for (uint256 i = 1; i <= lastFolioAction; i++) {
            assertEq(targets[i], cfg.folio, string.concat(cfg.symbol, ": revoke not targeting the Folio"));
            assertEq(bytes4(calldatas[i]), REVOKE_ROLE_SELECTOR, string.concat(cfg.symbol, ": not a revokeRole call"));

            (bytes32 role, address account) = abi.decode(_stripSelector(calldatas[i]), (bytes32, address));
            assertTrue(
                IAccessControlEnumerable(cfg.folio).hasRole(role, account),
                string.concat(cfg.symbol, ": revoking a role that is not held")
            );
        }

        // the admin revocation is the final Folio action, after every call that needs admin rights
        (bytes32 lastRole, address lastAccount) = abi.decode(
            _stripSelector(calldatas[lastFolioAction]),
            (bytes32, address)
        );
        assertEq(
            lastRole,
            DEFAULT_ADMIN_ROLE,
            string.concat(cfg.symbol, ": last Folio action is not the admin revoke")
        );
        assertEq(lastAccount, cfg.ownerTimelock, string.concat(cfg.symbol, ": admin revoked from the wrong account"));

        // ProxyAdmin renounce closes the proposal; it is owner-gated, not role-gated
        assertEq(
            targets[expectedLength - 1],
            cfg.proxyAdmin,
            string.concat(cfg.symbol, ": last action not ProxyAdmin")
        );
        assertEq(
            bytes4(calldatas[expectedLength - 1]),
            RENOUNCE_OWNERSHIP_SELECTOR,
            string.concat(cfg.symbol, ": last action not renounceOwnership")
        );
    }

    /// @dev Executes the actions the way the timelock would, without waiting on governance
    function _executeAsTimelock(
        DTFConfig memory cfg,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) internal {
        for (uint256 i; i < targets.length; i++) {
            vm.prank(cfg.ownerTimelock);
            (bool success, ) = targets[i].call{ value: values[i] }(calldatas[i]);
            assertTrue(success, string.concat(cfg.symbol, ": action reverted"));
        }
    }

    /// @dev Executes a queued onchain proposal through the Governor
    function _executeViaGovernor(
        DTFConfig memory cfg,
        address governor,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal {
        IGovernor gov = IGovernor(governor);
        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 proposalId = gov.hashProposal(targets, values, calldatas, descriptionHash);

        assertEq(
            uint256(gov.state(proposalId)),
            uint256(IGovernor.ProposalState.Queued),
            string.concat(cfg.symbol, ": proposal not queued")
        );

        vm.warp(gov.proposalEta(proposalId) + 1);
        gov.execute(targets, values, calldatas, descriptionHash);

        assertEq(
            uint256(gov.state(proposalId)),
            uint256(IGovernor.ProposalState.Executed),
            string.concat(cfg.symbol, ": proposal not executed")
        );
    }

    function _stripSelector(bytes memory data) internal pure returns (bytes memory out) {
        require(data.length >= 4, "calldata too short");

        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }
}
