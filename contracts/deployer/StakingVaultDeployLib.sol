// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { StakingVault } from "@staking/StakingVault.sol";

library StakingVaultDeployLib {
    function deployStakingVault(
        string memory name,
        string memory symbol,
        IERC20 underlying,
        address initialOwner,
        uint256 rewardPeriod,
        uint256 unstakingDelay,
        bytes32 deploymentSalt
    ) external returns (StakingVault stakingVault) {
        stakingVault = new StakingVault{ salt: deploymentSalt }(
            name,
            symbol,
            underlying,
            initialOwner,
            rewardPeriod,
            unstakingDelay
        );
    }
}
