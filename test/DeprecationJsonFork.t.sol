// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PendingDeprecations } from "./base/PendingDeprecations.sol";

/**
 * @notice Validates a generated proposal JSON before it is submitted to the Safe.
 * @dev Decodes the propose() calldata out of the committed JSON, checks the action set against live
 *      onchain state, then executes those exact actions as the owner timelock. Once a proposal is
 *      onchain, DeprecationProposalFork takes over and runs it through the Governor instead.
 */
abstract contract DeprecationJsonForkTest is PendingDeprecations {
    DTFConfig internal cfg;

    address internal ownerGovernor;
    string internal jsonPath;

    function test_deprecationFromJson_fork() public {
        (
            address to,
            uint256 chainId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _loadProposalJson(jsonPath);

        assertEq(chainId, block.chainid, string.concat(cfg.symbol, ": JSON chainId mismatch"));
        assertEq(to, ownerGovernor, string.concat(cfg.symbol, ": JSON does not target the owner governor"));
        assertEq(description, string.concat("Deprecate ", cfg.symbol, " Index DTF"));

        _assertLiveAndGoverned(cfg);
        _assertProxyAdminOwned(cfg);
        _assertDeprecationActions(cfg, targets, values, calldatas);

        _executeAsTimelock(cfg, targets, values, calldatas);

        _assertRedemptionOnlyMode(cfg);
        _assertProxyAdminRenounced(cfg);
    }
}

contract DeprecationJsonFork_BED is DeprecationJsonForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), 25739000);

        PendingDTF memory dtf = _bed();
        cfg = dtf.cfg;
        ownerGovernor = dtf.governor;
        jsonPath = dtf.jsonPath;
    }
}

contract DeprecationJsonFork_SMEL is DeprecationJsonForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), 25739000);

        PendingDTF memory dtf = _smel();
        cfg = dtf.cfg;
        ownerGovernor = dtf.governor;
        jsonPath = dtf.jsonPath;
    }
}

contract DeprecationJsonFork_VLONE is DeprecationJsonForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_BASE", string("base")), 51905275);

        address[] memory launchers = new address[](2);
        launchers[0] = 0x10C7a322466ABA50f3802D81418C322C7C7565e4;
        launchers[1] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;

        cfg = DTFConfig({
            symbol: "VLONE",
            folio: 0xe00CFa595841fb331105b93C19827797C925E3E4,
            ownerTimelock: 0x7E60Fb1B6cA70B5B9A554bAAd83e1CE94b0710CC,
            tradingTimelock: 0xE9CdD5f7CE534D77b96aaB2716EF895afCBf51c3,
            auctionLaunchers: launchers,
            proxyAdmin: 0x17747f766e375a73959EBc0dBc623A174D4DB317,
            stakingVault: 0xBA06d11C94cb68F0A58087eDfb843f4b3CCf46Ab
        });

        ownerGovernor = 0xA4556436cc4547F07DC3E61474Ae5E839fF3D150;
        jsonPath = "script/deprecation/proposals/deprecate-VLONE.json";
    }
}

contract DeprecationJsonFork_MVTT10F is DeprecationJsonForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_BASE", string("base")), 51905275);

        address[] memory launchers = new address[](3);
        launchers[0] = 0xD8B0F4e54a8dac04E0A57392f5A630cEdb99C940;
        launchers[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        launchers[2] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;

        cfg = DTFConfig({
            symbol: "MVTT10F",
            folio: 0xe8b46b116D3BdFA787CE9CF3f5aCC78dc7cA380E,
            ownerTimelock: 0xcb487bf3406e66715e327EddBa62Ba510CAc871b,
            tradingTimelock: 0x0c98Dd13D07e4A7eaED952c7E6141bA5c82A344d,
            auctionLaunchers: launchers,
            proxyAdmin: 0xBe278Be45C265A589BD0bf8cDC6C9e5a04B3397D,
            stakingVault: 0x3D72D6E8a5829d02F0153dbBFE71b8D4f5C3B45D
        });

        ownerGovernor = 0x3d14EE40A64F30F3a3515FCA9Cf6787aCA1925b5;
        jsonPath = "script/deprecation/proposals/deprecate-MVTT10F.json";
    }
}
