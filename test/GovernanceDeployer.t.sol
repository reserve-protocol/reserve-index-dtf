// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IFolioDeployer } from "contracts/interfaces/IFolioDeployer.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import "./base/BaseTest.sol";

contract GovernanceDeployerTest is BaseTest {
    function test_deployGovernedStakingToken() public {
        vm.startSnapshotGas("deployGovernedStakingToken()");
        (address _stToken, address _governor) = governanceDeployer.deployGovernedStakingToken(
            "Test Staked MEME Token",
            "STKMEME",
            MEME,
            IFolioDeployer.GovParams(1 days, 1 weeks, 0.01e18, 4, 1 days, user1)
        );
        vm.stopSnapshotGas();

        StakingVault stToken = StakingVault(_stToken);
        vm.startPrank(user1);
        MEME.approve(address(stToken), type(uint256).max);
        stToken.deposit(D18_TOKEN_1, user1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);

        FolioGovernor governor = FolioGovernor(payable(_governor));
        TimelockController timelock = TimelockController(payable(governor.timelock()));

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
    }
}
