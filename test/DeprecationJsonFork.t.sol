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
