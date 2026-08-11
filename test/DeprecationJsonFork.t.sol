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

interface IStakingVault is IERC4626 {
    function unstakingDelay() external view returns (uint256);
    function unstakingManager() external view returns (address);
}

interface IUnstakingManager {
    function claimLock(uint256 lockId) external;
}

/// @dev Executes the deprecation actions decoded from the generated Safe Transaction Builder JSON,
///      pranking as the owner timelock (the account the governor's timelock executes as).
abstract contract DeprecationJsonForkTest is Test {
    struct DTFConfig {
        string symbol;
        string jsonPath;
        address folio;
        address ownerGovernor;
        address ownerTimelock;
        address tradingTimelock; // address(0) if none
        address[] auctionLaunchers;
        address proxyAdmin;
        address stakingVault;
    }

    DTFConfig internal cfg;

    /// @dev Full flow, driven entirely by the committed proposal JSON
    function test_deprecationFromJson_fork() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _loadAndCheckProposal();

        _preChecks();
        _executeAsTimelock(targets, values, calldatas);
        _assertDeprecated();

        _testRedeemStillWorks();
        _testMintBlocked();
        _testUnstakeWithdraw();
    }

    // ==== Proposal loading ====

    /// @dev Decodes the propose() calldata out of the JSON and asserts it matches the expected action set
    function _loadAndCheckProposal()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        string memory json = vm.readFile(cfg.jsonPath);

        assertEq(
            vm.parseUint(vm.parseJsonString(json, ".chainId")),
            block.chainid,
            string.concat(cfg.symbol, ": JSON chainId mismatch")
        );
        assertEq(
            vm.parseJsonAddress(json, ".transactions[0].to"),
            cfg.ownerGovernor,
            string.concat(cfg.symbol, ": JSON does not target the owner governor")
        );

        // one proposal per DTF: a single propose() transaction carrying every deprecation action
        assertEq(
            vm.parseJsonKeys(json, ".transactions[0]").length,
            3,
            string.concat(cfg.symbol, ": unexpected tx keys")
        );

        bytes memory data = vm.parseJsonBytes(json, ".transactions[0].data");
        assertEq(
            bytes4(data),
            PROPOSE_SELECTOR,
            string.concat(cfg.symbol, ": JSON transaction is not a propose() call")
        );

        string memory description;
        (targets, values, calldatas, description) = abi.decode(
            _stripSelector(data),
            (address[], uint256[], bytes[], string)
        );

        assertEq(description, string.concat("Deprecate ", cfg.symbol, " Index DTF"));

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

    function _executeAsTimelock(address[] memory targets, uint256[] memory values, bytes[] memory calldatas) internal {
        for (uint256 i; i < targets.length; i++) {
            vm.prank(cfg.ownerTimelock);
            (bool success, ) = targets[i].call{ value: values[i] }(calldatas[i]);
            assertTrue(success, string.concat(cfg.symbol, ": action reverted"));
        }
    }

    // ==== Checks ====

    function _preChecks() internal view {
        assertFalse(Folio(cfg.folio).isDeprecated(), string.concat(cfg.symbol, ": already deprecated"));
        assertTrue(
            IAccessControlEnumerable(cfg.folio).hasRole(DEFAULT_ADMIN_ROLE, cfg.ownerTimelock),
            string.concat(cfg.symbol, ": timelock missing admin role")
        );
        assertEq(
            Ownable(cfg.proxyAdmin).owner(),
            cfg.ownerTimelock,
            string.concat(cfg.symbol, ": proxyAdmin not owned by timelock")
        );
        if (cfg.tradingTimelock != address(0)) {
            assertTrue(
                IAccessControlEnumerable(cfg.folio).hasRole(REBALANCE_MANAGER, cfg.tradingTimelock),
                string.concat(cfg.symbol, ": trading timelock missing REBALANCE_MANAGER")
            );
        }
        for (uint256 i; i < cfg.auctionLaunchers.length; i++) {
            assertTrue(
                IAccessControlEnumerable(cfg.folio).hasRole(AUCTION_LAUNCHER, cfg.auctionLaunchers[i]),
                string.concat(cfg.symbol, ": launcher missing AUCTION_LAUNCHER")
            );
        }
    }

    function _assertDeprecated() internal view {
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

        assertEq(Ownable(cfg.proxyAdmin).owner(), address(0), string.concat(cfg.symbol, ": proxyAdmin owner not zero"));
    }

    function _testRedeemStillWorks() internal {
        Folio folio = Folio(cfg.folio);

        uint256 redeemShares = 1e18;
        (address[] memory assets, ) = folio.toAssets(redeemShares, Math.Rounding.Floor);
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

        for (uint256 i; i < assets.length; i++) {
            assertGt(
                IERC20(assets[i]).balanceOf(redeemer),
                balancesBefore[i],
                string.concat(cfg.symbol, ": received nothing for a basket token")
            );
        }
    }

    function _testMintBlocked() internal {
        address minter = makeAddr(string.concat("minter-", cfg.symbol));

        vm.prank(minter);
        vm.expectRevert(IFolio.Folio__FolioDeprecated.selector);
        Folio(cfg.folio).mint(1e18, minter, 0);
    }

    function _testUnstakeWithdraw() internal {
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

        uint256 lockId;
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != unstakingManager || logs[i].topics[0] != LOCK_CREATED_TOPIC) {
                continue;
            }

            (uint256 id, address user, , ) = abi.decode(logs[i].data, (uint256, address, uint256, uint256));
            if (user == staker) {
                lockId = id;
                found = true;
                break;
            }
        }
        require(found, string.concat(cfg.symbol, ": no unstaking lock created"));

        // Warp past the unstaking delay and claim
        vm.warp(block.timestamp + vault.unstakingDelay() + 1);
        IUnstakingManager(unstakingManager).claimLock(lockId);

        assertGt(
            IERC20(underlying).balanceOf(staker),
            underlyingBefore,
            string.concat(cfg.symbol, ": no underlying after unstake")
        );
    }

    // ==== Helpers ====

    function _stripSelector(bytes memory data) internal pure returns (bytes memory out) {
        require(data.length >= 4, "calldata too short");

        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }
}

contract DeprecationJsonFork_BED is DeprecationJsonForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), 25730000);

        address[] memory launchers = new address[](3);
        launchers[0] = 0x280730d9277EF586d58dB74c277Aa710ca8F87C9;
        launchers[1] = 0xC6625129C9df3314a4dd604845488f4bA62F9dB8;
        launchers[2] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;

        cfg = DTFConfig({
            symbol: "BED",
            jsonPath: "script/deprecation/proposals/deprecate-BED.json",
            folio: 0x4E3B170DcBe704b248df5f56D488114acE01B1C5,
            ownerGovernor: 0xFaD4823Ae478637fD8FfdafB6c912f63c8cd1Dd7,
            ownerTimelock: 0x6B45fe3F4464477f657702b8e942b71C3bA83944,
            tradingTimelock: 0x8E530CD0C47d515558229AAE193DD119cc791A40,
            auctionLaunchers: launchers,
            proxyAdmin: 0xEAa356F6CD6b3fd15B47838d03cF34fa79F7c712,
            stakingVault: 0x5CdE24d90f9Fe1C1893dD30Ca74F99265b46818F
        });
    }
}

contract DeprecationJsonFork_SMEL is DeprecationJsonForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), 25730000);

        address[] memory launchers = new address[](3);
        launchers[0] = 0x280730d9277EF586d58dB74c277Aa710ca8F87C9;
        launchers[1] = 0xC6625129C9df3314a4dd604845488f4bA62F9dB8;
        launchers[2] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;

        cfg = DTFConfig({
            symbol: "SMEL",
            jsonPath: "script/deprecation/proposals/deprecate-SMEL.json",
            folio: 0xF91384484F4717314798E8975BCd904A35fc2BF1,
            ownerGovernor: 0x622c0b5aD82a2A47F330D4a2061a0e3562F583b0,
            ownerTimelock: 0x476aE35B6dEccda7969F105e983a916BCc12C31A,
            tradingTimelock: 0x395417220aE7447D19752f38327B96fAF52e1911,
            auctionLaunchers: launchers,
            proxyAdmin: 0xDd885B0F2f97703B94d2790320b30017a17768BF,
            stakingVault: 0x5CdE24d90f9Fe1C1893dD30Ca74F99265b46818F
        });
    }
}
