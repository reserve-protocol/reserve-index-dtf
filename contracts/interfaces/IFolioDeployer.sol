// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFolioDeployer {
    error FolioDeployer__LengthMismatch();

    event GovernanceDeployed(bytes32 indexed role, address indexed stToken, address governor, address timelock);
    event FolioDeployed(address indexed folio, address folioAdmin, address folioOwner);

    function folioImplementation() external view returns (address);
}
