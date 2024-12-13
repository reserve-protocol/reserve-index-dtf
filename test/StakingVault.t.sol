// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { StakingVault } from "contracts/staking/StakingVault.sol";
import { MockERC20 } from "utils/MockERC20.sol";

contract StakingVaultTest is Test {
    MockERC20 private token;
    MockERC20 private reward;

    StakingVault private vault;

    uint256 private constant REWARD_HALF_LIFE = 3 days;

    address constant ACTOR_ALICE = address(0x123123001);
    address constant ACTOR_BOB = address(0x123123002);

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18);
        reward = new MockERC20("Reward Token", "REWARD", 18);
        vm.label(address(token), "Test Token");
        vm.label(address(reward), "Reward Token");

        vault = new StakingVault("Staked Test Token", "sTEST", IERC20(address(token)), address(this), REWARD_HALF_LIFE);

        vault.addRewardToken(address(reward));

        vm.label(ACTOR_ALICE, "Alice");
        vm.label(ACTOR_BOB, "Bob");
    }

    function _payoutRewards(uint256 cycles) internal {
        vm.warp(block.timestamp + REWARD_HALF_LIFE * cycles);
    }

    function _mintAndDepositFor(address receiver, uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount, receiver);
    }

    function _withdrawAs(address actor, uint256 amount) internal {
        vm.startPrank(actor);
        vault.redeem(amount, actor, actor);
        vm.stopPrank();
    }

    function _claimRewardsAs(address actor) internal {
        vm.startPrank(actor);
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(reward);
        vault.claimRewards(rewardTokens);
        vm.stopPrank();
    }

    // @todo Remove this later
    function test_check() public {
        _mintAndDepositFor(address(this), 1000 * 1e18);
        vm.warp(block.timestamp + 1);

        reward.mint(address(vault), 1000 * 1e18);

        vm.startSnapshotGas("poke with one token");
        vault.poke();
        vm.stopSnapshotGas();

        vm.warp(block.timestamp + 3 days);

        vault.poke();

        vm.warp(block.timestamp + 3 days);

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(reward);
        vault.claimRewards(rewardTokens);
        console2.log("balance %18e", reward.balanceOf(address(this)));

        vm.warp(block.timestamp + 3 days);

        vault.poke();
    }

    function testGas_pokeWithTokens() public {
        uint8[4] memory rewardTokens = [1, 10, 25, 50];

        for (uint8 i = 0; i < rewardTokens.length; i++) {
            StakingVault newVault = new StakingVault(
                "Staked Test Token",
                "sTEST",
                IERC20(address(token)),
                address(this),
                REWARD_HALF_LIFE
            );

            token.mint(address(this), 1000 * 1e18);
            token.approve(address(newVault), 1000 * 1e18);
            newVault.deposit(1000 * 1e18, address(this));

            vm.warp(block.timestamp + 1);
            newVault.poke();

            for (uint8 j = 0; j < rewardTokens[i]; j++) {
                MockERC20 rewardToken = new MockERC20("Reward Token", "REWARD", 18);
                rewardToken.mint(address(newVault), 1000 * 1e18);

                newVault.addRewardToken(address(rewardToken));
            }

            string memory gasTag1 = string.concat("poke(1, ", vm.toString(rewardTokens[i]), " tokens)");
            _payoutRewards(1);
            newVault.poke();
            vm.snapshotGasLastCall(gasTag1);

            string memory gasTag2 = string.concat("poke(2, ", vm.toString(rewardTokens[i]), " tokens)");
            _payoutRewards(1);
            newVault.poke();
            vm.snapshotGasLastCall(gasTag2);
        }
    }

    function test__accrual_singleRewardTokenMultipleEvenActors() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);
        _mintAndDepositFor(ACTOR_BOB, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertEq(reward.balanceOf(ACTOR_ALICE), reward.balanceOf(ACTOR_BOB));
        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 250e18, 0.001e18);

        _payoutRewards(1);
        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertEq(reward.balanceOf(ACTOR_ALICE), reward.balanceOf(ACTOR_BOB));
        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 375e18, 0.001e18);
    }

    function test__accrual_singleRewardTokenMultipleUnevenActors() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);
        _mintAndDepositFor(ACTOR_BOB, 3000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 125e18, 0.001e18);
        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 375e18, 0.001e18);

        _payoutRewards(1);
        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 187.5e18, 0.001e18);
        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 562.5e18, 0.001e18);
    }

    function test__accrual_complexSerialEntry() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        _withdrawAs(ACTOR_ALICE, 1000e18);
        _claimRewardsAs(ACTOR_ALICE);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 500e18, 0.001e18);

        _mintAndDepositFor(ACTOR_BOB, 1000e18);

        _payoutRewards(1);

        _withdrawAs(ACTOR_BOB, 1000e18);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 250e18, 0.001e18);
    }

    function test__accrual_simpleTransferActors() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        vm.prank(ACTOR_ALICE);
        vault.transfer(ACTOR_BOB, 1000e18);

        _payoutRewards(1);

        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 500e18, 0.001e18);
        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 250e18, 0.001e18);
    }

    function test__accrual_complexTransferActors() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        vm.prank(ACTOR_ALICE);
        vault.transfer(ACTOR_BOB, 500e18);

        _payoutRewards(1);

        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 625e18, 0.001e18);
        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 125e18, 0.001e18);
    }

    function test_accrual_composesOverTime() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);
        _mintAndDepositFor(ACTOR_BOB, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 2000e18);
        vault.poke();

        // paying out 1 cycle 10 times should be the same as paying out 10 cycles once
        for (uint256 i = 0; i < 10; i++) {
            _payoutRewards(1);
            _claimRewardsAs(ACTOR_ALICE);
        }
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 999.02344e18, 0.0001e18);
        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 999.02344e18, 0.0001e18);
    }
}