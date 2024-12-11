// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";

/**
 * @title GovernorLib
 */
library GovernorLib {
    struct Params {
        address stToken;
        uint48 votingDelay; // {s}
        uint32 votingPeriod; // {s}
        uint256 proposalThreshold; // D18{1}
        uint256 quorumPercent; // in percent, e.g 4 for 4%
        uint256 timelockDelay; // {s}
    }

    function deployGovernor(
        Params calldata params,
        TimelockController timelockController
    ) public returns (address governor) {
        governor = address(
            new FolioGovernor(
                IVotes(params.stToken),
                timelockController,
                params.votingDelay,
                params.votingPeriod,
                params.proposalThreshold,
                params.quorumPercent
            )
        );
    }
}
