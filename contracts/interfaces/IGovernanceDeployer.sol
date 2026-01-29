// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { Folio } from "@src/Folio.sol";
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
        Folio folio,
        IGovernanceDeployer.GovParams calldata govParams,
        bytes32 deploymentNonce
    ) external returns (StakingVault stToken, address governor, address timelock);

    function deployGovernanceWithTimelock(
        IGovernanceDeployer.GovParams calldata govParams,
        Folio folio,
        IVotes stToken,
        bytes32 deploymentNonce
    ) external returns (address governor, address timelock);
}
