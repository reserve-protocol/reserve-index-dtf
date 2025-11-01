// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { StakingVault } from "@staking/StakingVault.sol";

interface IGovernanceDeployer {
    struct GovParams {
        // Basic Parameters
        uint48 votingDelay; // {s}
        uint32 votingPeriod; // {s}
        uint256 proposalThreshold; // D18{1}
        uint256 quorumThreshold; // D18{1}
        uint256 timelockDelay; // {s}
        // Roles
        address[] guardians; // Canceller Role
    }

    function deployGovernedStakingToken(
        string memory name,
        string memory symbol,
        IERC20 underlying,
        IGovernanceDeployer.GovParams calldata govParams,
        bytes32 deploymentNonce
    ) external returns (StakingVault stToken, address governor, address timelock);

    function deployGovernanceWithTimelock(
        IGovernanceDeployer.GovParams calldata govParams,
        IVotes stToken,
        bytes32 deploymentNonce
    ) external returns (address governor, address timelock);
}
