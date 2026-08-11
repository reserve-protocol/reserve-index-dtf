// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseDeprecationForkTest, DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER, AUCTION_LAUNCHER } from "./base/BaseDeprecationForkTest.sol";

/**
 * @notice Executes a live onchain deprecation proposal through the Governor.
 * @dev Pin the fork to a block where the proposal is queued but not yet executed. Subclasses supply the
 *      proposal actions, either from the generated JSON (see DeprecationProposalForkFromJson) or inline
 *      for proposals that predate the current generator.
 */
abstract contract DeprecationProposalForkTest is BaseDeprecationForkTest {
    DTFConfig internal cfg;

    address internal governor;

    /// @dev Whether the proposal also renounces ProxyAdmin ownership; early proposals did this in a second round
    bool internal renouncesProxyAdmin;

    function _proposalActions()
        internal
        view
        virtual
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        );

    function test_executeQueuedProposal_fork() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _proposalActions();

        _assertLiveAndGoverned(cfg);

        if (renouncesProxyAdmin) {
            _assertProxyAdminOwned(cfg);
            _assertDeprecationActions(cfg, targets, values, calldatas);
        }

        _executeViaGovernor(cfg, governor, targets, values, calldatas, description);

        _assertRedemptionOnlyMode(cfg);

        if (renouncesProxyAdmin) {
            _assertProxyAdminRenounced(cfg);
        }
    }
}

/// @dev Runs the proposal exactly as generated, so the JSON is the single source of truth end to end:
///      DeprecationJsonFork validates it before submission, this validates it after it is queued
abstract contract DeprecationProposalForkFromJson is DeprecationProposalForkTest {
    string internal jsonPath;

    function _proposalActions()
        internal
        view
        override
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        address to;
        uint256 chainId;
        (to, chainId, targets, values, calldatas, description) = _loadProposalJson(jsonPath);

        assertEq(chainId, block.chainid, string.concat(cfg.symbol, ": JSON chainId mismatch"));
        assertEq(to, governor, string.concat(cfg.symbol, ": JSON does not target the governor"));
    }
}

/// @dev Proposal id 77830145447331487048806002448004034037637077883085812792021902429453348063407.
///      Predates the single-proposal flow: the ProxyAdmin renounce was a separate second proposal.
contract DeprecationProposalFork_mvRWA is DeprecationProposalForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), 24677500); // proposal queued

        address[] memory launchers = new address[](3);
        launchers[0] = 0x6293e97900aA987Cf3Cbd419e0D5Ba43ebfA91c1;
        launchers[1] = 0xC6625129C9df3314a4dd604845488f4bA62F9dB8;
        launchers[2] = 0x7DaAf7Bc2eE8bf4C0ac7f37E6b6cfaEB3ed9a868;

        cfg = DTFConfig({
            symbol: "mvRWA",
            folio: 0xA5cdea03B11042fc10B52aF9eCa48bb17A2107d2,
            ownerTimelock: 0x02188526Dd0021F8032868552d2Ea8529d3A4E53,
            tradingTimelock: 0xF156F05d8eB854926f08983F98bD8Ac27c2f18c4,
            auctionLaunchers: launchers,
            proxyAdmin: 0x019318674560C233893aA31Bc0A380dc71dc2dDf,
            stakingVault: 0xa2DeA781F351C9Cb831CB1E6c1A687994E04e8aF
        });

        governor = 0x58e72A9a9E9Dc5209D02335d5Ac67eD28a86EAe9;
        renouncesProxyAdmin = false;
    }

    function _proposalActions()
        internal
        view
        override
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](6);
        values = new uint256[](6);
        calldatas = new bytes[](6);

        for (uint256 i; i < targets.length; i++) {
            targets[i] = cfg.folio;
        }

        calldatas[0] = abi.encodeWithSignature("deprecateFolio()");
        calldatas[1] = abi.encodeWithSignature("revokeRole(bytes32,address)", REBALANCE_MANAGER, cfg.tradingTimelock);
        calldatas[2] = abi.encodeWithSignature(
            "revokeRole(bytes32,address)",
            AUCTION_LAUNCHER,
            cfg.auctionLaunchers[0]
        );
        calldatas[3] = abi.encodeWithSignature(
            "revokeRole(bytes32,address)",
            AUCTION_LAUNCHER,
            cfg.auctionLaunchers[1]
        );
        calldatas[4] = abi.encodeWithSignature(
            "revokeRole(bytes32,address)",
            AUCTION_LAUNCHER,
            cfg.auctionLaunchers[2]
        );
        calldatas[5] = abi.encodeWithSignature("revokeRole(bytes32,address)", DEFAULT_ADMIN_ROLE, cfg.ownerTimelock);

        description = "Deprecate mvRWA Index DTF";
    }
}
