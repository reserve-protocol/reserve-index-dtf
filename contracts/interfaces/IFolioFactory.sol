// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @dev Must also inherit from Versioned
 */
interface IFolioFactory {
    error FolioFactory__LengthMismatch();
    error FolioFactory__EmptyAssets();

    event FolioCreated(address indexed folio, address indexed folioAdmin);

    function folioImplementation() external view returns (address);
}
