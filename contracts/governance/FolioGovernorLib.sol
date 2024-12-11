// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { FolioGovernor } from "@gov/FolioGovernor.sol";

/**
 * @title FolioGovernorLib
 */
library FolioGovernorLib {
    struct Params {
        uint48 votingDelay; // {s}
        uint32 votingPeriod; // {s}
        uint256 proposalThreshold; // D18{1}
        uint256 quorumPercent; // in percent, e.g 4 for 4%
        uint256 timelockDelay; // {s}
    }

    function deployGovernor(
        Params calldata params,
        IVotes stToken,
        TimelockController timelockController
    ) external returns (address governor) {
        governor = address(
            new FolioGovernor(
                stToken,
                timelockController,
                params.votingDelay,
                params.votingPeriod,
                params.proposalThreshold,
                params.quorumPercent
            )
        );
    }
}
