// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseDeprecationForkTest } from "./base/BaseDeprecationForkTest.sol";

/**
 * @notice Validates a generated proposal JSON before it is submitted to the Safe.
 * @dev Decodes the propose() calldata out of the committed JSON, checks the action set against live
 *      onchain state, then executes those exact actions as the owner timelock. Once a proposal is
 *      onchain, DeprecationProposalFork takes over and runs it through the Governor instead.
 */
abstract contract DeprecationJsonForkTest is BaseDeprecationForkTest {
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
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), 25730000);

        address[] memory launchers = new address[](3);
        launchers[0] = 0x280730d9277EF586d58dB74c277Aa710ca8F87C9;
        launchers[1] = 0xC6625129C9df3314a4dd604845488f4bA62F9dB8;
        launchers[2] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;

        cfg = DTFConfig({
            symbol: "BED",
            folio: 0x4E3B170DcBe704b248df5f56D488114acE01B1C5,
            ownerTimelock: 0x6B45fe3F4464477f657702b8e942b71C3bA83944,
            tradingTimelock: 0x8E530CD0C47d515558229AAE193DD119cc791A40,
            auctionLaunchers: launchers,
            proxyAdmin: 0xEAa356F6CD6b3fd15B47838d03cF34fa79F7c712,
            stakingVault: 0x5CdE24d90f9Fe1C1893dD30Ca74F99265b46818F
        });

        ownerGovernor = 0xFaD4823Ae478637fD8FfdafB6c912f63c8cd1Dd7;
        jsonPath = "script/deprecation/proposals/deprecate-BED.json";
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
            folio: 0xF91384484F4717314798E8975BCd904A35fc2BF1,
            ownerTimelock: 0x476aE35B6dEccda7969F105e983a916BCc12C31A,
            tradingTimelock: 0x395417220aE7447D19752f38327B96fAF52e1911,
            auctionLaunchers: launchers,
            proxyAdmin: 0xDd885B0F2f97703B94d2790320b30017a17768BF,
            stakingVault: 0x5CdE24d90f9Fe1C1893dD30Ca74F99265b46818F
        });

        ownerGovernor = 0x622c0b5aD82a2A47F330D4a2061a0e3562F583b0;
        jsonPath = "script/deprecation/proposals/deprecate-SMEL.json";
    }
}
