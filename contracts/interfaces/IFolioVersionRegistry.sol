// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolioFactory } from "@interfaces/IFolioFactory.sol";

interface IFolioVersionRegistry {
    error VersionRegistry__ZeroAddress();
    error VersionRegistry__InvalidRegistration();
    error VersionRegistry__AlreadyDeprecated();
    error VersionRegistry__InvalidCaller();

    event VersionRegistered(bytes32 versionHash, IFolioFactory folioFactory);
    event VersionDeprecated(bytes32 versionHash);

    function getImplementationForVersion(bytes32 versionHash) external view returns (address folio);

    function isDeprecated(bytes32 versionHash) external view returns (bool);
}
