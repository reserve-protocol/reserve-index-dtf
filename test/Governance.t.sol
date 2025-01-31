// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { MockERC20Votes } from "utils/MockERC20Votes.sol";
import "./base/BaseTest.sol";

contract GovernanceTest is BaseTest {
    FolioGovernor governor;
    TimelockControllerUpgradeable timelock;
    MockERC20Votes votingToken;

    function _deployTestGovernance(
        MockERC20Votes _votingToken,
        uint48 _votingDelay, // {s}
        uint32 _votingPeriod, // {s}
        uint256 _proposalThreshold, // {1} e.g. 1e14 for 0.01%
        uint256 _quorumPercent, // e.g 4 for 4%
        uint256 _executionDelay // {s} for timelock
    ) internal returns (FolioGovernor _governor, TimelockControllerUpgradeable _timelock) {
        _timelock = TimelockControllerUpgradeable(payable(Clones.clone(timelockImplementation)));

        _governor = FolioGovernor(payable(Clones.clone(governorImplementation)));
        _governor.initialize(_votingToken, _timelock, _votingDelay, _votingPeriod, _proposalThreshold, _quorumPercent);

        address[] memory proposers = new address[](1);
        proposers[0] = address(_governor);
        address[] memory executors = new address[](1); // add 0 address executor to enable permisionless execution
        _timelock.initialize(_executionDelay, proposers, executors, address(this));
        _timelock.grantRole(_timelock.CANCELLER_ROLE(), owner); // set guardian
    }

    function _testSetup() public virtual override {
        // mint voting token to owner and delegate votes
        votingToken = new MockERC20Votes("DAO Staked Token", "DAOSTKTKN");
        votingToken.mint(owner, 100e18);

        governorImplementation = address(new FolioGovernor());
        timelockImplementation = address(new TimelockControllerUpgradeable());

        (governor, timelock) = _deployTestGovernance(
            votingToken,
            1 days,
            1 weeks,
            0.01e18 /* 1% proposal threshold */,
            4,
            1 days
        );

        skip(1 weeks);
        vm.roll(block.number + 1);
    }

    function test_deployment() public view {
        assertEq(address(governor.token()), address(votingToken));
        assertEq(governor.votingDelay(), 1 days);
        assertEq(governor.votingPeriod(), 1 weeks);
        assertEq(governor.proposalThreshold(), 1e18); // 1% of 100 total supply
        assertEq(governor.quorum(block.number), 4e18); // 4% of 100 total supply
        assertEq(address(governor.timelock()), address(timelock));
        assertEq(timelock.getMinDelay(), 1 days);
    }

    function test_tradingGovernorConfiguration() public {
        (FolioGovernor tradingGovernor, TimelockControllerUpgradeable tradingTimelock) = _deployTestGovernance(
            votingToken,
            1 seconds,
            30 minutes,
            0.01e18 /* 1% proposal threshold */,
            4,
            0 seconds // 0s execution delay for rebalancing governor
        );

        assertEq(address(tradingGovernor.token()), address(votingToken));
        assertEq(tradingGovernor.votingDelay(), 1 seconds);
        assertEq(tradingGovernor.votingPeriod(), 30 minutes);
        assertEq(address(tradingGovernor.timelock()), address(tradingTimelock));
        assertEq(tradingTimelock.getMinDelay(), 0 seconds);
    }

    function testCannotProposeWithoutSufficientBalance() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(governor.setVotingDelay.selector, 2 days);
        string memory description = "Update voting delay";

        // Attempt to propose with user 2, with not enough votes
        vm.prank(address(owner));
        votingToken.transfer(address(user2), 1e15); // below 1%

        // delegate (user2)
        vm.startPrank(user2);
        votingToken.delegate(user2);

        skip(10);
        vm.roll(block.number + 1);

        // attempt to propose
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, user2, 1e15, 1e18)
        );
        governor.propose(targets, values, calldatas, description);
        vm.stopPrank();

        // // Owner can propose, has enough votes
        // vm.startPrank(owner);
        // votingToken.delegate(owner);

        // skip(1 days);
        // vm.roll(block.number + 1);

        // uint256 pid = governor.propose(targets, values, calldatas, description);
        // assertGt(pid, 0);
        // vm.stopPrank();
    }

    function testGovernanceCycle() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(governor.setVotingDelay.selector, 2 days);
        string memory description = "Update voting delay";

        assertEq(governor.votingDelay(), 1 days);

        // propose
        vm.prank(address(owner));
        votingToken.transfer(address(user1), 10e18);

        // delegate (user1)
        vm.prank(user1);
        votingToken.delegate(user1);

        skip(10);
        vm.roll(block.number + 1);

        vm.prank(user1);
        uint256 pid = governor.propose(targets, values, calldatas, description);

        // Not ready to vote yet
        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Pending));
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                pid,
                IGovernor.ProposalState.Pending,
                bytes32(1 << uint8(IGovernor.ProposalState.Active))
            )
        );
        governor.castVote(pid, 1);

        skip(2 days);
        vm.roll(block.number + 1);

        assertEq(votingToken.getPastVotes(address(user1), block.timestamp - 1), 10e18);
        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Active));

        // vote
        vm.prank(user1);
        governor.castVote(pid, 1);
        assertEq(governor.hasVoted(pid, user1), true);
        assertEq(governor.hasVoted(pid, user2), false);
        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(pid);
        assertEq(againstVotes, 0);
        assertEq(forVotes, 10e18);
        assertEq(abstainVotes, 0);
        assertEq(uint256(governor.state(pid)), uint256(IGovernor.ProposalState.Active));

        skip(1);
        vm.roll(block.number + 1);

        // cannot vote twice
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorAlreadyCastVote.selector, user1));
        governor.castVote(pid, 2);

        // no-op if voting with no weight
        vm.prank(user2);
        governor.castVote(pid, 2);
        (againstVotes, forVotes, abstainVotes) = governor.proposalVotes(pid);
        assertEq(againstVotes, 0);
        assertEq(forVotes, 10e18);
        assertEq(abstainVotes, 0);

        // Advance post voting period
        skip(7 days);
        vm.roll(block.number + 1);
        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Succeeded));

        // queue
        assertEq(governor.proposalNeedsQueuing(pid), true);
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Queued));

        // Advance time (required by timelock)
        skip(2 days);
        vm.roll(block.number + 1);

        // execute
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint256(governor.state(pid)), uint256(IGovernor.ProposalState.Executed));
        assertEq(governor.votingDelay(), 2 days);
    }

    function testCancelProposalByProposer() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(governor.setVotingDelay.selector, 2 days);
        string memory description = "Update voting delay";

        assertEq(governor.votingDelay(), 1 days);

        // propose
        vm.prank(address(owner));
        votingToken.transfer(address(user1), 10e18);

        // delegate (user1)
        vm.prank(user1);
        votingToken.delegate(user1);

        skip(10);
        vm.roll(block.number + 1);

        vm.prank(user1);
        uint256 pid = governor.propose(targets, values, calldatas, description);

        // Proposer can cancel at this stage
        vm.prank(user1);
        governor.cancel(targets, values, calldatas, keccak256(bytes(description)));

        // check final state
        assertEq(uint256(governor.state(pid)), uint256(IGovernor.ProposalState.Canceled));
        assertEq(governor.votingDelay(), 1 days); // no changes
    }

    function test_cannotProposeWhenSupplyZero() public {
        votingToken.burn(owner, 100e18);
        assertEq(votingToken.totalSupply(), 0);
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(governor.setVotingDelay.selector, 2 days);
        string memory description = "desc";

        // attempt to propose
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, address(this), 0, 1)
        );
        governor.propose(targets, values, calldatas, description);
    }

    function test_setProposalThreshold() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(governor.setProposalThreshold.selector, 0.005e18);
        string memory description = "Update proposal threshold";

        assertEq(governor.proposalThreshold(), 1e18);

        // propose
        vm.prank(address(owner));
        votingToken.transfer(address(user1), 10e18);

        // delegate (user1)
        vm.prank(user1);
        votingToken.delegate(user1);

        skip(10);
        vm.roll(block.number + 1);

        vm.prank(user1);
        uint256 pid = governor.propose(targets, values, calldatas, description);

        skip(2 days);
        vm.roll(block.number + 1);

        // vote
        vm.prank(user1);
        governor.castVote(pid, 1);

        skip(1);
        vm.roll(block.number + 1);

        // Advance post voting period
        skip(7 days);
        vm.roll(block.number + 1);
        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Succeeded));

        // queue
        assertEq(governor.proposalNeedsQueuing(pid), true);
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Queued));

        // Advance time (required by timelock)
        skip(2 days);
        vm.roll(block.number + 1);

        // execute
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint256(governor.state(pid)), uint256(IGovernor.ProposalState.Executed));

        assertEq(governor.proposalThreshold(), 0.5e18);
    }

    function test_cannotSetProposalThresholdAboveOne() public {
        vm.expectRevert(FolioGovernor.Governor__InvalidProposalThreshold.selector);
        governor.setProposalThreshold(1e18 + 1);
    }

    function test_zeroGuardianDoesNotAllowAnyoneToCancel() public {
        vm.prank(address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(0));

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(governor.setVotingDelay.selector, 2 days);
        string memory description = "Update voting delay";

        // propose
        vm.prank(address(owner));
        votingToken.transfer(address(user1), 10e18);

        // delegate (user1)
        vm.prank(user1);
        votingToken.delegate(user1);

        skip(10);
        vm.roll(block.number + 1);

        vm.prank(user1);
        uint256 pid = governor.propose(targets, values, calldatas, description);

        skip(2 days);
        vm.roll(block.number + 1);

        // vote
        vm.prank(user1);
        governor.castVote(pid, 1);

        skip(1);
        vm.roll(block.number + 1);

        // Advance post voting period
        skip(7 days);
        vm.roll(block.number + 1);
        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Succeeded));

        // queue
        assertEq(governor.proposalNeedsQueuing(pid), true);
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Queued));

        // Advance time (required by timelock)
        skip(2 days);
        vm.roll(block.number + 1);

        // cancel should revert
        vm.startPrank(user1);
        bytes32 timelockSalt = bytes20(address(governor)) ^ keccak256(bytes(description));
        bytes32 timelockId = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), timelockSalt);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                timelock.CANCELLER_ROLE()
            )
        );
        timelock.cancel(timelockId);
    }
}
