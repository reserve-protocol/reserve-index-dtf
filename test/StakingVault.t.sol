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

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18);
        reward = new MockERC20("Reward Token", "REWARD", 18);
        vm.label(address(token), "Test Token");
        vm.label(address(reward), "Reward Token");

        vault = new StakingVault("Staked Test Token", "sTEST", IERC20(address(token)), address(this));

        token.mint(address(this), 1000 * 1e18);
        token.approve(address(vault), 1000 * 1e18);
        vault.deposit(1000 * 1e18, address(this));

        vault.registerRewardToken(address(reward));
        // vault.poke();
    }

    function test_check() public {
        reward.mint(address(vault), 1000 * 1e18);

        vm.warp(block.timestamp + 3 days);

        vault.poke();

        vm.warp(block.timestamp + 3 days);

        vault.poke();
    }
}
