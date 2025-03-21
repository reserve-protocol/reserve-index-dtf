// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// This value should be updated on each release
string constant VERSION = "3.0.0";

/**
 * @title Versioned
 * @notice A mix-in to track semantic versioning uniformly across contracts.
 */
abstract contract Versioned {
    function version() public pure virtual returns (string memory) {
        return VERSION;
    }
}
