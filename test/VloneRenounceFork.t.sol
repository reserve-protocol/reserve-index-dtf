// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import {
    BaseDeprecationForkTest,
    DEFAULT_ADMIN_ROLE,
    REBALANCE_MANAGER,
    AUCTION_LAUNCHER,
    DEPRECATE_FOLIO_SELECTOR,
    RENOUNCE_OWNERSHIP_SELECTOR
} from "./base/BaseDeprecationForkTest.sol";

/**
 * @notice Validates the follow-up proposal that renounces the VLONE ProxyAdmin.
 * @dev VLONE's open deprecation proposal covers deprecateFolio() and all four role revokes but
 *      omits the ProxyAdmin renounce, leaving the folio upgradeable by the owner timelock. This
 *      second proposal supplies the missing action on its own.
 *
 *      The renounce is gated by Ownable on the ProxyAdmin, not by the Folio's DEFAULT_ADMIN role,
 *      so it is independent of the other proposal and the two can execute in either order. The test
 *      pins the harder case: the open proposal has already run, the owner timelock no longer holds
 *      DEFAULT_ADMIN on the Folio, and the renounce still has to succeed.
 */
contract VloneRenounceFork is BaseDeprecationForkTest {
    address internal constant FOLIO = 0xe00CFa595841fb331105b93C19827797C925E3E4;
    address internal constant PROXY_ADMIN = 0x17747f766e375a73959EBc0dBc623A174D4DB317;
    address internal constant OWNER_TL = 0x7E60Fb1B6cA70B5B9A554bAAd83e1CE94b0710CC;
    address internal constant TRADING_TL = 0xE9CdD5f7CE534D77b96aaB2716EF895afCBf51c3;
    address internal constant OWNER_GOV = 0xA4556436cc4547F07DC3E61474Ae5E839fF3D150;

    string internal constant JSON = "script/deprecation/proposals/renounce-VLONE-proxyadmin.json";

    DTFConfig internal cfg;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_BASE", string("base")), 51905733);

        address[] memory launchers = new address[](2);
        launchers[0] = 0x10C7a322466ABA50f3802D81418C322C7C7565e4;
        launchers[1] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;

        cfg = DTFConfig({
            symbol: "VLONE",
            folio: FOLIO,
            ownerTimelock: OWNER_TL,
            tradingTimelock: TRADING_TL,
            auctionLaunchers: launchers,
            proxyAdmin: PROXY_ADMIN,
            stakingVault: 0xBA06d11C94cb68F0A58087eDfb843f4b3CCf46Ab
        });
    }

    function test_renounceCompletesDeprecation_fork() public {
        (
            address to,
            uint256 chainId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _loadProposalJson(JSON);

        assertEq(chainId, block.chainid, "JSON chainId mismatch");
        assertEq(to, OWNER_GOV, "JSON does not target the VLONE owner governor");
        assertEq(description, "Deprecate VLONE Index DTF #2: renounce ProxyAdmin ownership");

        // exactly one action: renounceOwnership() on the ProxyAdmin, no value
        assertEq(targets.length, 1, "expected a single action");
        assertEq(targets[0], PROXY_ADMIN, "action does not target the ProxyAdmin");
        assertEq(values[0], 0, "action must not send value");
        assertEq(bytes4(calldatas[0]), RENOUNCE_OWNERSHIP_SELECTOR, "not a renounceOwnership() call");
        assertEq(calldatas[0].length, 4, "renounceOwnership() takes no arguments");

        _assertLiveAndGoverned(cfg);
        _assertProxyAdminOwned(cfg);

        // --- the open proposal lands first, stripping every Folio role from the timelocks
        _simulateOpenDeprecationProposal();

        assertFalse(
            IAccessControlEnumerable(FOLIO).hasRole(DEFAULT_ADMIN_ROLE, OWNER_TL),
            "owner timelock should have lost DEFAULT_ADMIN"
        );
        assertEq(Ownable(PROXY_ADMIN).owner(), OWNER_TL, "ProxyAdmin ownership is what is still outstanding");

        // --- the renounce still works: Ownable on the ProxyAdmin, not the Folio's admin role
        _executeAsTimelock(cfg, targets, values, calldatas);

        _assertProxyAdminRenounced(cfg);
        _assertRedemptionOnlyMode(cfg);
    }

    /// @dev The five actions of VLONE's open proposal, run as the owner timelock
    function _simulateOpenDeprecationProposal() internal {
        vm.startPrank(OWNER_TL);
        (bool ok, ) = FOLIO.call(abi.encodeWithSelector(DEPRECATE_FOLIO_SELECTOR));
        require(ok, "deprecateFolio() failed");

        IAccessControlEnumerable(FOLIO).revokeRole(REBALANCE_MANAGER, TRADING_TL);
        for (uint256 i; i < cfg.auctionLaunchers.length; i++) {
            IAccessControlEnumerable(FOLIO).revokeRole(AUCTION_LAUNCHER, cfg.auctionLaunchers[i]);
        }
        IAccessControlEnumerable(FOLIO).revokeRole(DEFAULT_ADMIN_ROLE, OWNER_TL);
        vm.stopPrank();
    }
}
