// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAverageVotes {
    error AverageVotes__InvalidTimeRange();

    /// @notice Returns average delegated votes over [start, end), rounded down.
    function getPastAverageVotes(address account, uint256 start, uint256 end) external view returns (uint256);
}
