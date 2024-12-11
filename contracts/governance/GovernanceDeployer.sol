// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { GovernorLib } from "@utils/GovernorLib.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import { StakingVaultLib } from "@staking/StakingVaultLib.sol";
import { Versioned } from "@utils/Versioned.sol";

/**
 * @title GovernanceDeployer
 */
contract GovernanceDeployer is Versioned {
    uint256 constant REWARD_PERIOD = (60 * 60 * 24 * 7) / 2; // 3.5 days

    /// Deploy a staking vault and timelocked governor that owns it
    /// BYOT (bring your own token)
    /// @return stToken A staking vault that can be used with multiple governors
    /// @return governor A timelocked governor that owns the staking vault
    function deployGovernedStakingToken(
        string memory name,
        string memory symbol,
        IERC20 underlying,
        GovernorLib.Params calldata govParams
    ) external returns (address stToken, address governor) {
        address[] memory empty = new address[](0);
        address[] memory executors = new address[](1);

        TimelockController timelockController = new TimelockController(
            govParams.timelockDelay,
            empty,
            executors,
            address(this)
        );

        stToken = StakingVaultLib.deployStakingVault(
            name,
            symbol,
            underlying,
            address(timelockController),
            REWARD_PERIOD
        );

        governor = GovernorLib.deployGovernor(govParams, IVotes(stToken), timelockController);

        timelockController.grantRole(timelockController.PROPOSER_ROLE(), address(governor));

        // TODO no cancellers/guardian?

        timelockController.renounceRole(timelockController.DEFAULT_ADMIN_ROLE(), address(this));
    }
}
