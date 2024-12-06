// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./base/BaseTest.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { MockERC20Votes } from "utils/MockERC20Votes.sol";

contract GovernanceTest is BaseTest {
    FolioGovernor governor;
    TimelockController timelock;
    MockERC20Votes votingToken;

    function _deployTestGovernance(
        MockERC20Votes _votingToken,
        uint48 votingDelay_, // {s}
        uint32 votingPeriod_, // {s}
        uint256 proposalThresholdAsMicroPercent_, // e.g. 1e4 for 0.01%
        uint256 quorumPercent, // e.g 4 for 4%
        uint256 _executionDelay // {s} for timelock
    ) internal returns (FolioGovernor _governor, TimelockController _timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1); // add 0 address executor to enable permisionless execution
        _timelock = new TimelockController(_executionDelay, proposers, executors, address(this));
        _governor = new FolioGovernor(
            _votingToken,
            _timelock,
            votingDelay_,
            votingPeriod_,
            proposalThresholdAsMicroPercent_,
            quorumPercent
        );
    }

    function _testSetup() public virtual override {
        // mint voting token to owner and delegate votes
        votingToken = new MockERC20Votes("DAO Staked Token", "DAOSTKTKN");
        votingToken.mint(owner, 100e18);

        // deploy governance
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

    function test_deployment() public {
        assertEq(address(governor.token()), address(votingToken));
        assertEq(governor.votingDelay(), 1 days);
        assertEq(governor.votingPeriod(), 1 weeks);
        assertEq(governor.proposalThreshold(), 1e18); // 1% of 100 total supply
        assertEq(governor.quorum(block.number), 4e18); // 4% of 100 total supply
        assertEq(address(governor.timelock()), address(timelock));
        assertEq(timelock.getMinDelay(), 1 days);
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

        // Owner can propose, has enough votes
        vm.startPrank(owner);
        votingToken.delegate(owner);

        skip(1 days);
        vm.roll(block.number + 1);

        uint256 pid = governor.propose(targets, values, calldatas, description);
        assertGt(pid, 0);
        vm.stopPrank();
    }
}
