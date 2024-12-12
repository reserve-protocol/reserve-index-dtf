// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFolioDeployer {
    error FolioDeployer__LengthMismatch();

    function folioImplementation() external view returns (address);
}
