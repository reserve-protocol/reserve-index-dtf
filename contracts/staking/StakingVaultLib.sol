// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { StakingVault } from "@staking/StakingVault.sol";

/**
 * @title StakingVaultLib
 */
library StakingVaultLib {
    /// @return New StakingVault instance
    function deployStakingVault(
        string memory name,
        string memory symbol,
        IERC20 underlying,
        address initialOwner,
        uint256 rewardPeriod
    ) external returns (address) {
        return address(new StakingVault(name, symbol, underlying, initialOwner, rewardPeriod));
    }
}
