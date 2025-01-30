// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IGovernanceDeployer } from "contracts/interfaces/IGovernanceDeployer.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import "./base/BaseTest.sol";

contract GovernanceDeployerTest is BaseTest {
    function test_deployGovernedStakingToken() public {
        address[] memory guardians = new address[](1);
        guardians[0] = user1;
        vm.startSnapshotGas("deployGovernedStakingToken()");
        (StakingVault stToken, address _governor, address _timelock) = governanceDeployer.deployGovernedStakingToken(
            "Test Staked MEME Token",
            "STKMEME",
            MEME,
            IGovernanceDeployer.GovParams(1 days, 1 weeks, 0.01e18, 4, 1 days, guardians)
        );
        vm.stopSnapshotGas();

        vm.startPrank(user1);
        MEME.approve(address(stToken), type(uint256).max);
        stToken.deposit(D18_TOKEN_1, user1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);

        FolioGovernor governor = FolioGovernor(payable(_governor));
        TimelockController timelock = TimelockController(payable(_timelock));

        assertEq(governor.votingDelay(), 1 days, "wrong voting delay");
        assertEq(governor.votingPeriod(), 1 weeks, "wrong voting period");
        assertEq(governor.proposalThreshold(), 0.01e18, "wrong proposal threshold");
        assertEq(governor.quorumNumerator(), 4, "wrong quorum numerator");
        assertEq(governor.quorumDenominator(), 100, "wrong quorum denominator");
        assertEq(timelock.getMinDelay(), 1 days, "wrong timelock min delay");
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)), "wrong admin role");
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), _governor), "wrong admin role");
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(governanceDeployer)), "wrong admin role");
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), owner), "wrong admin role");
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), user1), "wrong admin role");
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(0)), "wrong proposer role");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), _governor), "wrong proposer role");
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), _governor), "wrong executor role");
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "wrong executor role");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), user1), "wrong canceler role");
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), address(0)), "wrong canceler role");
    }
}
