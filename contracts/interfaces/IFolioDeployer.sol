// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFolioDeployer {
    error FolioDeployer__LengthMismatch();

    struct GovParams {
        uint48 votingDelay; // {s}
        uint32 votingPeriod; // {s}
        uint256 proposalThreshold; // D18{1}
        uint256 quorumPercent; // in percent, e.g 4 for 4%
        uint256 timelockDelay; // {s}
        address guardian; // canceller in timelock
    }

    function folioImplementation() external view returns (address);
}
