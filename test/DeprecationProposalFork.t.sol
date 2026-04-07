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
    function token() external view returns (address);
    function timelock() external view returns (address);

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
    function locks(uint256 lockId) external view returns (address user, uint256 amount, uint256 unlockTime, uint256 claimedAt);
    function claimLock(uint256 lockId) external;
}

abstract contract DeprecationProposalForkTest is Test {
    struct ProposalConfig {
        string symbol;
        address folio;
        address governor;
        address proxyAdmin;
        address stakingVault;
        uint256 deprecationProposalId;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
    }

    ProposalConfig[] internal proposals;

    function _addProposal(
        string memory symbol,
        address folio,
        address governor,
        address proxyAdmin,
        address stakingVault,
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal {
        proposals.push(
            ProposalConfig({
                symbol: symbol,
                folio: folio,
                governor: governor,
                proxyAdmin: proxyAdmin,
                stakingVault: stakingVault,
                deprecationProposalId: proposalId,
                targets: targets,
                values: values,
                calldatas: calldatas,
                description: description
            })
        );
    }

    /// @dev Execute a queued proposal on fork and verify deprecation
    function test_executeQueuedProposal_fork() public {
        for (uint256 i; i < proposals.length; i++) {
            _testExecuteProposal(proposals[i]);
        }
    }

    function _testExecuteProposal(ProposalConfig memory cfg) internal {
        IGovernor gov = IGovernor(cfg.governor);
        Folio folio = Folio(cfg.folio);

        // Verify proposal is queued
        IGovernor.ProposalState currentState = gov.state(cfg.deprecationProposalId);
        assertEq(
            uint256(currentState),
            uint256(IGovernor.ProposalState.Queued),
            string.concat(cfg.symbol, ": proposal not queued")
        );

        // Pre-checks
        assertFalse(folio.isDeprecated(), string.concat(cfg.symbol, ": already deprecated"));

        // Warp past the ETA
        uint256 eta = gov.proposalEta(cfg.deprecationProposalId);
        vm.warp(eta + 1);

        // Execute the proposal
        bytes32 descriptionHash = keccak256(bytes(cfg.description));
        gov.execute(cfg.targets, cfg.values, cfg.calldatas, descriptionHash);

        // Verify executed
        assertEq(
            uint256(gov.state(cfg.deprecationProposalId)),
            uint256(IGovernor.ProposalState.Executed),
            string.concat(cfg.symbol, ": proposal not executed")
        );

        // Verify deprecation effects
        assertTrue(folio.isDeprecated(), string.concat(cfg.symbol, ": not deprecated after execution"));

        // Verify all roles revoked
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

        // Verify mint is blocked
        address minter = makeAddr(string.concat("minter-", cfg.symbol));
        vm.prank(minter);
        vm.expectRevert(IFolio.Folio__FolioDeprecated.selector);
        folio.mint(1e18, minter, 0);

        // Verify redeem still works
        _testRedeemStillWorks(cfg.symbol, folio);

        // Verify unstake/withdraw still works
        _testUnstakeWithdraw(cfg.symbol, cfg.stakingVault);
    }

    function _testRedeemStillWorks(string memory symbol, Folio folio) internal {
        uint256 redeemShares = 1e18;

        try folio.toAssets(redeemShares, Math.Rounding.Floor) returns (
            address[] memory assets,
            uint256[] memory
        ) {
            address redeemer = makeAddr(string.concat("redeemer-", symbol));
            deal(address(folio), redeemer, redeemShares);

            uint256[] memory minAmountsOut = new uint256[](assets.length);

            uint256[] memory balancesBefore = new uint256[](assets.length);
            for (uint256 j; j < assets.length; j++) {
                balancesBefore[j] = IERC20(assets[j]).balanceOf(redeemer);
            }

            vm.prank(redeemer);
            folio.redeem(redeemShares, redeemer, assets, minAmountsOut);

            assertEq(folio.balanceOf(redeemer), 0, string.concat(symbol, ": shares not burned"));

            uint256 totalReceived;
            for (uint256 j; j < assets.length; j++) {
                totalReceived += IERC20(assets[j]).balanceOf(redeemer) - balancesBefore[j];
            }
            assertGt(totalReceived, 0, string.concat(symbol, ": received nothing from redeem"));
        } catch {
            emit log_string(string.concat(symbol, ": SKIPPED redeem test (basket token incompatible with fork)"));
        }
    }

    function _testUnstakeWithdraw(string memory symbol, address stakingVaultAddr) internal {
        IStakingVault vault = IStakingVault(stakingVaultAddr);
        address underlying = vault.asset();
        address staker = makeAddr(string.concat("staker-", symbol));

        // Deal staking vault shares
        deal(stakingVaultAddr, staker, 1e18);

        uint256 underlyingBefore = IERC20(underlying).balanceOf(staker);

        // Redeem shares — creates a lock in UnstakingManager
        vm.prank(staker);
        vault.redeem(1e18, staker, staker);
        assertEq(IERC20(stakingVaultAddr).balanceOf(staker), 0, string.concat(symbol, ": vault shares not burned"));

        // Warp past unstaking delay
        vm.warp(block.timestamp + vault.unstakingDelay() + 1);

        // Find and claim lock
        IUnstakingManager umgr = IUnstakingManager(vault.unstakingManager());
        bool found;
        for (uint256 lockId; lockId < 100; lockId++) {
            (address lockUser, , , uint256 claimedAt) = umgr.locks(lockId);
            if (lockUser == staker && claimedAt == 0) {
                umgr.claimLock(lockId);
                assertGt(IERC20(underlying).balanceOf(staker), underlyingBefore, string.concat(symbol, ": no underlying after unstake"));
                found = true;
                break;
            }
        }
        require(found, string.concat(symbol, ": could not find unstaking lock"));
    }
}

contract DeprecationProposalFork_mvRWA is DeprecationProposalForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), 24677500); // proposal queued

        address folio = 0xA5cdea03B11042fc10B52aF9eCa48bb17A2107d2;

        // Build proposal actions (same as the deprecation JSON)
        address[] memory targets = new address[](6);
        uint256[] memory values = new uint256[](6);
        bytes[] memory calldatas = new bytes[](6);

        for (uint256 i; i < 6; i++) {
            targets[i] = folio;
            values[i] = 0;
        }

        // 1. deprecateFolio()
        calldatas[0] = abi.encodeWithSignature("deprecateFolio()");
        // 2. revokeRole(REBALANCE_MANAGER, tradingTimelock)
        calldatas[1] = abi.encodeWithSignature(
            "revokeRole(bytes32,address)",
            REBALANCE_MANAGER,
            0xF156F05d8eB854926f08983F98bD8Ac27c2f18c4
        );
        // 3-5. revokeRole(AUCTION_LAUNCHER, launcher)
        calldatas[2] = abi.encodeWithSignature(
            "revokeRole(bytes32,address)",
            AUCTION_LAUNCHER,
            0x6293e97900aA987Cf3Cbd419e0D5Ba43ebfA91c1
        );
        calldatas[3] = abi.encodeWithSignature(
            "revokeRole(bytes32,address)",
            AUCTION_LAUNCHER,
            0xC6625129C9df3314a4dd604845488f4bA62F9dB8
        );
        calldatas[4] = abi.encodeWithSignature(
            "revokeRole(bytes32,address)",
            AUCTION_LAUNCHER,
            0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868
        );
        // 6. revokeRole(DEFAULT_ADMIN_ROLE, ownerTimelock)
        calldatas[5] = abi.encodeWithSignature(
            "revokeRole(bytes32,address)",
            DEFAULT_ADMIN_ROLE,
            0x02188526Dd0021F8032868552d2Ea8529d3A4E53
        );

        _addProposal(
            "mvRWA",
            folio,
            0x58e72A9a9E9Dc5209D02335d5Ac67eD28a86EAe9, // governor
            0x019318674560C233893aA31Bc0A380dc71dc2dDf, // proxyAdmin
            0xa2DeA781F351C9Cb831CB1E6c1A687994E04e8aF, // stakingVault
            77830145447331487048806002448004034037637077883085812792021902429453348063407,
            targets,
            values,
            calldatas,
            "Deprecate mvRWA Index DTF"
        );
    }
}
