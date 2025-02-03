// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

interface IGovernanceDeployer {
    struct GovParams {
        // Basic Parameters
        uint48 votingDelay; // {s}
        uint32 votingPeriod; // {s}
        uint256 proposalThreshold; // D18{1}
        uint256 quorumPercent; // in percent, e.g 4 for 4%
        uint256 timelockDelay; // {s}
        // Roles
        address[] guardians; // Canceller Role
    }

    struct GovRoles {
        address[] existingAuctionApprovers;
        address[] auctionLaunchers;
        address[] brandManagers;
    }

    function deployGovernanceWithTimelock(
        IGovernanceDeployer.GovParams calldata govParams,
        IVotes stToken,
        bytes32 deploymentNonce
    ) external returns (address governor, address timelock);
}
