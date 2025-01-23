// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { IERC20, IERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { StakingVault, UnstakingManager } from "contracts/staking/StakingVault.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
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

        vault = new StakingVault(
            "Staked Test Token",
            "sTEST",
            IERC20(address(token)),
            address(this),
            REWARD_HALF_LIFE,
            0
        );

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

    function test_deployment() public view {
        assertEq(vault.clock(), block.timestamp);
        assertEq(vault.CLOCK_MODE(), "mode=timestamp");
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(ACTOR_ALICE), 0);
        assertEq(vault.balanceOf(ACTOR_BOB), 0);
        assertEq(vault.nonces(ACTOR_ALICE), 0);
        assertEq(vault.nonces(ACTOR_BOB), 0);
        assertEq(vault.decimals(), 18);
        assertEq(reward.balanceOf(address(vault)), 0);
        assertEq(reward.balanceOf(ACTOR_ALICE), 0);
        assertEq(reward.balanceOf(ACTOR_BOB), 0);

        address[] memory _rewardTokens = vault.getAllRewardTokens();
        assertEq(_rewardTokens.length, 1);
        assertEq(_rewardTokens[0], address(reward));
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
                REWARD_HALF_LIFE,
                0
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

    function test__accrual_emitsEventWhenClaimingRewards() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        vm.recordLogs();
        _claimRewardsAs(ACTOR_ALICE);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries[1].topics[0], keccak256("RewardsClaimed(address,address,uint256)"));
        assertEq(entries[1].data, abi.encode(address(ACTOR_ALICE), address(reward), reward.balanceOf(ACTOR_ALICE)));
        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 500e18, 0.001e18);
    }

    function test_addRewardToken() public {
        MockERC20 newReward = new MockERC20("New Reward Token", "NREWARD", 18);
        vm.expectEmit(true, false, false, true);
        emit StakingVault.RewardTokenAdded(address(newReward));
        vault.addRewardToken(address(newReward));

        address[] memory _rewardTokens = vault.getAllRewardTokens();
        assertEq(_rewardTokens.length, 2);
        assertEq(_rewardTokens[0], address(reward));
        assertEq(_rewardTokens[1], address(newReward));
    }

    function test_cannotAddRewardTokenIfNotOwner() public {
        MockERC20 newReward = new MockERC20("New Reward Token", "NREWARD", 18);
        vm.prank(ACTOR_ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ACTOR_ALICE));
        vault.addRewardToken(address(newReward));
    }

    function test_cannotAddRewardTokenIfInvalid() public {
        vm.expectRevert();
        vault.addRewardToken(address(0));

        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__InvalidRewardToken.selector, address(token)));
        vault.addRewardToken(address(token));

        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__InvalidRewardToken.selector, address(vault)));
        vault.addRewardToken(address(vault));
    }

    function test_cannotAddRewardTokenIfPreviouslyRemoved() public {
        // Remove reward token
        vault.removeRewardToken(address(reward));
        address[] memory _rewardTokens = vault.getAllRewardTokens();
        assertEq(_rewardTokens.length, 0);

        // Cannot re-add token
        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__DisallowedRewardToken.selector, address(reward)));
        vault.addRewardToken(address(reward));
    }

    function test_cannotAddRewardTokenIfAlreadyRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__RewardAlreadyRegistered.selector));
        vault.addRewardToken(address(reward));
    }

    function test_removeRewardToken() public {
        vm.expectEmit(true, false, false, true);
        emit StakingVault.RewardTokenRemoved(address(reward));
        vault.removeRewardToken(address(reward));
        address[] memory _rewardTokens = vault.getAllRewardTokens();
        assertEq(_rewardTokens.length, 0);
    }

    function test_cannotRemoveRewardTokenIfNotOwner() public {
        vm.prank(ACTOR_ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ACTOR_ALICE));
        vault.removeRewardToken(address(reward));
    }

    function test_cannotRemoveRewardTokenIfNotRegistered() public {
        MockERC20 newReward = new MockERC20("New Reward Token", "NREWARD", 18);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__RewardNotRegistered.selector));
        vault.removeRewardToken(address(newReward));
    }

    function test_setRewardRatio() public {
        uint256 rewardRatioPrev = vault.rewardRatio();
        vm.expectEmit(true, true, false, true);
        emit StakingVault.RewardRatioSet(rewardRatioPrev * 2, REWARD_HALF_LIFE / 2);

        vault.setRewardRatio(REWARD_HALF_LIFE / 2);
        assertEq(vault.rewardRatio(), rewardRatioPrev * 2);
    }

    function test_cannotSetRewardRatioIfNotOwner() public {
        vm.prank(ACTOR_ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ACTOR_ALICE));
        vault.setRewardRatio(REWARD_HALF_LIFE / 2);
    }

    function test_cannotSetRewardRatioWithInvalidValue() public {
        vm.expectRevert(StakingVault.Vault__InvalidRewardsHalfLife.selector);
        vault.setRewardRatio(2 weeks + 1);
    }

    function test_depositAndDelegate() public {
        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);

        // normal deposit (no delegation)
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(address(this), address(this), 500e18, 500e18);
        vault.deposit(500e18, address(this));
        assertEq(vault.balanceOf(address(this)), 500e18);
        assertEq(vault.delegates(address(this)), address(0));

        // deposit and delegate
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(address(this), address(this), 500e18, 500e18);
        vm.expectEmit(true, true, true, true);
        emit IVotes.DelegateChanged(address(this), address(0), address(this));
        vault.depositAndDelegate(500e18);

        assertEq(vault.delegates(address(this)), address(this)); // delegated
        assertEq(vault.balanceOf(address(this)), 1000e18); // has full balance
    }

    function test_unstake_noDelay() public {
        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);

        vault.deposit(1000e18, address(this));
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(address(this), address(this), address(this), 1000e18, 1000e18);
        vault.redeem(1000e18, address(this), address(this));
        assertEq(token.balanceOf(address(this)), 1000e18);
    }

    function test_unstake_noDelay_redeemOnBehalf() public {
        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);

        vault.deposit(1000e18, address(this));

        // Reedem on behalf
        vault.approve(ACTOR_ALICE, 1000e18);

        vm.startPrank(ACTOR_ALICE);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(ACTOR_ALICE, address(this), address(this), 1000e18, 1000e18);
        vault.redeem(1000e18, address(this), address(this));
        vm.stopPrank();

        assertEq(token.balanceOf(address(this)), 1000e18);
    }

    function test_unstakingDelay_claimLock() public {
        StakingVault newVault = new StakingVault(
            "Staked Test Token",
            "sTEST",
            IERC20(address(token)),
            address(this),
            REWARD_HALF_LIFE,
            14 days
        );
        UnstakingManager manager = newVault.unstakingManager();

        token.mint(address(this), 1000e18);
        token.approve(address(newVault), 1000e18);

        newVault.deposit(1000e18, address(this));
        vm.expectEmit(true, true, true, true);
        emit UnstakingManager.LockCreated(0, address(this), 1000e18, block.timestamp + newVault.unstakingDelay());
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(address(this), address(this), address(this), 1000e18, 1000e18);
        newVault.redeem(1000e18, address(this), address(this));

        assertEq(token.balanceOf(address(this)), 0);

        vm.expectRevert(UnstakingManager.UnstakingManager__NotUnlockedYet.selector);
        manager.claimLock(0);

        vm.warp(block.timestamp + 14 days);
        vm.expectEmit(true, false, false, true);
        emit UnstakingManager.LockClaimed(0);
        manager.claimLock(0);

        assertEq(token.balanceOf(address(this)), 1000e18);

        // Cannot claim again
        vm.expectRevert(UnstakingManager.UnstakingManager__AlreadyClaimed.selector);
        manager.claimLock(0);
    }

    function test_unstakingDelay_cancelLock() public {
        StakingVault newVault = new StakingVault(
            "Staked Test Token",
            "sTEST",
            IERC20(address(token)),
            address(this),
            REWARD_HALF_LIFE,
            14 days
        );
        UnstakingManager manager = newVault.unstakingManager();

        token.mint(address(this), 1000e18);
        token.approve(address(newVault), 1000e18);

        newVault.deposit(1000e18, address(this));
        vm.expectEmit(true, true, true, true);
        emit UnstakingManager.LockCreated(0, address(this), 1000e18, block.timestamp + newVault.unstakingDelay());
        newVault.redeem(1000e18, address(this), address(this));

        assertEq(token.balanceOf(address(this)), 0);

        vm.expectRevert(UnstakingManager.UnstakingManager__NotUnlockedYet.selector);
        manager.claimLock(0);

        vm.expectEmit(true, false, false, true);
        emit UnstakingManager.LockCancelled(0);
        manager.cancelLock(0);

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(newVault.balanceOf(address(this)), 1000e18);

        // Cannot claim
        vm.expectRevert(UnstakingManager.UnstakingManager__NotUnlockedYet.selector);
        manager.claimLock(0);
    }

    function test_unstakingDelay_redeemOnBehalf() public {
        StakingVault newVault = new StakingVault(
            "Staked Test Token",
            "sTEST",
            IERC20(address(token)),
            address(this),
            REWARD_HALF_LIFE,
            14 days
        );
        UnstakingManager manager = newVault.unstakingManager();

        token.mint(address(this), 1000e18);
        token.approve(address(newVault), 1000e18);
        newVault.deposit(1000e18, address(this));

        // Reedem on behalf
        newVault.approve(ACTOR_ALICE, 1000e18);

        vm.startPrank(ACTOR_ALICE);
        vm.expectEmit(true, true, true, true);
        emit UnstakingManager.LockCreated(0, address(this), 1000e18, block.timestamp + newVault.unstakingDelay());
        newVault.redeem(1000e18, address(this), address(this));
        vm.stopPrank();

        assertEq(token.balanceOf(address(this)), 0);

        vm.warp(block.timestamp + 14 days);
        vm.expectEmit(true, false, false, true);
        emit UnstakingManager.LockClaimed(0);
        manager.claimLock(0);

        assertEq(token.balanceOf(address(this)), 1000e18);
    }

    function test_cannotCancelLockIfNotUser() public {
        StakingVault newVault = new StakingVault(
            "Staked Test Token",
            "sTEST",
            IERC20(address(token)),
            address(this),
            REWARD_HALF_LIFE,
            14 days
        );
        UnstakingManager manager = newVault.unstakingManager();

        token.mint(address(this), 1000e18);
        token.approve(address(newVault), 1000e18);

        newVault.deposit(1000e18, address(this));
        vm.expectEmit(true, true, true, true);
        emit UnstakingManager.LockCreated(0, address(this), 1000e18, block.timestamp + newVault.unstakingDelay());
        newVault.redeem(1000e18, address(this), address(this));

        assertEq(token.balanceOf(address(this)), 0);

        vm.prank(ACTOR_BOB);
        vm.expectRevert(UnstakingManager.UnstakingManager__Unauthorized.selector);
        manager.cancelLock(0);
    }

    function test_cannotCancelLockIfAlreadyClaimed() public {
        StakingVault newVault = new StakingVault(
            "Staked Test Token",
            "sTEST",
            IERC20(address(token)),
            address(this),
            REWARD_HALF_LIFE,
            14 days
        );
        UnstakingManager manager = newVault.unstakingManager();

        token.mint(address(this), 1000e18);
        token.approve(address(newVault), 1000e18);

        newVault.deposit(1000e18, address(this));
        vm.expectEmit(true, true, true, true);
        emit UnstakingManager.LockCreated(0, address(this), 1000e18, block.timestamp + newVault.unstakingDelay());
        newVault.redeem(1000e18, address(this), address(this));

        assertEq(token.balanceOf(address(this)), 0);

        vm.warp(block.timestamp + 14 days);
        vm.expectEmit(true, false, false, true);
        emit UnstakingManager.LockClaimed(0);
        manager.claimLock(0);

        assertEq(token.balanceOf(address(this)), 1000e18);

        // Cannot cancel
        vm.expectRevert(UnstakingManager.UnstakingManager__AlreadyClaimed.selector);
        manager.cancelLock(0);
    }

    function test_cannotCreateLockIfNotVault() public {
        UnstakingManager manager = vault.unstakingManager();

        vm.expectRevert(UnstakingManager.UnstakingManager__Unauthorized.selector);
        manager.createLock(ACTOR_ALICE, 100e18, 10000);
    }

    function test_setUnstakingDelay() public {
        assertEq(vault.unstakingDelay(), 0, "wrong unstaking delay");
        uint256 newUnstakingDelay = 1 weeks;
        vm.expectEmit(true, false, false, true);
        emit StakingVault.UnstakingDelaySet(newUnstakingDelay);
        vault.setUnstakingDelay(newUnstakingDelay);
        assertEq(vault.unstakingDelay(), newUnstakingDelay, "wrong unstaking delay");
    }

    function test_cannotSetUnstakingDelayIfNotOwner() public {
        assertEq(vault.unstakingDelay(), 0, "wrong unstaking delay");
        uint256 newUnstakingDelay = 1 weeks;
        vm.prank(ACTOR_ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ACTOR_ALICE));
        vault.setUnstakingDelay(newUnstakingDelay);
    }

    function test_cannotSetUnstakingDelayIfNotValid() public {
        assertEq(vault.unstakingDelay(), 0, "wrong unstaking delay");
        uint256 newUnstakingDelay = 4 weeks + 1; // invalid
        vm.expectRevert(StakingVault.Vault__InvalidUnstakingDelay.selector);
        vault.setUnstakingDelay(newUnstakingDelay);
    }

    function test__StackingVault__ZeroSupply() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        reward.mint(address(vault), 1000e18);
        vault.poke();
        _payoutRewards(1);

        _withdrawAs(ACTOR_ALICE, 1000e18);
        _claimRewardsAs(ACTOR_ALICE);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 500e18, 0.01e18);
        assertApproxEqRel(vault.totalSupply(), 0, 0);

        for (uint256 i = 0; i < 10; i++) {
            // 10 cycles without any supply, but still poking.
            _payoutRewards(1);
            vault.poke();
        }

        _mintAndDepositFor(ACTOR_BOB, 1000e18);
        vault.poke();

        _payoutRewards(1);

        _withdrawAs(ACTOR_BOB, 1000e18);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 250e18, 0.01e18);
    }
}
