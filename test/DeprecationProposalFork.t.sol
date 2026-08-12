// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { IGovernor, DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER, AUCTION_LAUNCHER } from "./base/BaseDeprecationForkTest.sol";
import { PendingDeprecations } from "./base/PendingDeprecations.sol";

uint8 constant VOTE_FOR = 1;

/**
 * @notice Shared state for the suites that run a live onchain deprecation proposal.
 * @dev Subclasses supply the proposal actions, either from the generated JSON (DeprecationProposalForkFromJson)
 *      or inline for proposals that predate the current generator, and mix in one of the two test entrypoints:
 *      DeprecationQueuedForkTest (proposal already queued) or DeprecationLifecycleForkTest (still Pending).
 */
abstract contract DeprecationProposalForkTest is PendingDeprecations {
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
}

/// @notice Executes an already-queued proposal through the Governor.
/// @dev Pin the fork to a block where the proposal is queued but not yet executed.
abstract contract DeprecationQueuedForkTest is DeprecationProposalForkTest {
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

/**
 * @notice Drives a submitted proposal through its whole lifecycle: vote, queue, execute.
 * @dev Lets a proposal be validated end to end while it is still Pending, rather than waiting days for it to
 *      reach Queued. Voting power is acquired before the snapshot, so the fork MUST be pinned to a block
 *      before voting opens. The vote is simulated; everything else — proposal id, actions, timelock delay —
 *      is the real onchain proposal.
 */
abstract contract DeprecationLifecycleForkTest is DeprecationProposalForkFromJson {
    address internal votingToken;

    function test_proposalLifecycle_fork() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _proposalActions();

        IGovernor gov = IGovernor(governor);
        uint256 proposalId = gov.hashProposal(targets, values, calldatas, keccak256(bytes(description)));

        // the proposal exists onchain and voting has not opened yet
        assertEq(
            uint256(gov.state(proposalId)),
            uint256(IGovernor.ProposalState.Pending),
            string.concat(cfg.symbol, ": proposal not Pending - pin the fork before the voting snapshot")
        );

        _assertLiveAndGoverned(cfg);
        _assertProxyAdminOwned(cfg);
        _assertDeprecationActions(cfg, targets, values, calldatas);

        _voteFor(gov, proposalId);
        _queue(gov, proposalId, targets, values, calldatas, description);

        _executeViaGovernor(cfg, governor, targets, values, calldatas, description);

        _assertRedemptionOnlyMode(cfg);
        _assertProxyAdminRenounced(cfg);
    }

    /// @dev Acquires voting power before the snapshot, then votes once voting opens
    function _voteFor(IGovernor gov, uint256 proposalId) internal {
        uint256 snapshot = gov.proposalSnapshot(proposalId);
        assertLt(block.timestamp, snapshot, string.concat(cfg.symbol, ": fork pinned past the voting snapshot"));

        // dealing shares does not move voting units, delegating afterwards does — and neither raises the
        // total-supply checkpoint that quorum is measured against
        address voter = makeAddr(string.concat("voter-", cfg.symbol));
        uint256 stake = IERC20(votingToken).totalSupply() / 2;
        deal(votingToken, voter, stake);

        vm.prank(voter);
        IVotes(votingToken).delegate(voter);

        vm.warp(snapshot + 1);
        assertEq(
            uint256(gov.state(proposalId)),
            uint256(IGovernor.ProposalState.Active),
            string.concat(cfg.symbol, ": proposal not Active after the snapshot")
        );
        assertGe(
            IVotes(votingToken).getPastVotes(voter, snapshot),
            gov.quorum(snapshot),
            string.concat(cfg.symbol, ": test voter below quorum")
        );

        vm.prank(voter);
        gov.castVote(proposalId, VOTE_FOR);

        vm.warp(gov.proposalDeadline(proposalId) + 1);
        assertEq(
            uint256(gov.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded),
            string.concat(cfg.symbol, ": proposal did not succeed")
        );
    }

    function _queue(
        IGovernor gov,
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal {
        gov.queue(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(
            uint256(gov.state(proposalId)),
            uint256(IGovernor.ProposalState.Queued),
            string.concat(cfg.symbol, ": proposal not queued")
        );
        assertGt(gov.proposalEta(proposalId), block.timestamp, string.concat(cfg.symbol, ": timelock delay skipped"));
    }
}

contract DeprecationLifecycleFork_BED is DeprecationLifecycleForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), 25739000); // before voting opens

        PendingDTF memory dtf = _bed();
        cfg = dtf.cfg;
        governor = dtf.governor;
        jsonPath = dtf.jsonPath;
        votingToken = VLRSR_STEAKHOUSE;
        renouncesProxyAdmin = true;
    }
}

contract DeprecationLifecycleFork_SMEL is DeprecationLifecycleForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), 25739000); // before voting opens

        PendingDTF memory dtf = _smel();
        cfg = dtf.cfg;
        governor = dtf.governor;
        jsonPath = dtf.jsonPath;
        votingToken = VLRSR_STEAKHOUSE;
        renouncesProxyAdmin = true;
    }
}

/// @dev Proposal id 77830145447331487048806002448004034037637077883085812792021902429453348063407.
///      Predates the single-proposal flow: the ProxyAdmin renounce was a separate second proposal.
contract DeprecationProposalFork_mvRWA is DeprecationQueuedForkTest {
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
