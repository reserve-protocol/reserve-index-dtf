// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @dev Must also inherit from Versioned
 */
interface IFolioFactory {
    function folioImplementation() external view returns (address);
}
