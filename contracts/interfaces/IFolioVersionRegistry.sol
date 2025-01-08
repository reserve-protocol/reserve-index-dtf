// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";

interface IFolioVersionRegistry {
    error VersionRegistry__ZeroAddress();
    error VersionRegistry__InvalidRegistration();
    error VersionRegistry__AlreadyDeprecated();
    error VersionRegistry__InvalidCaller();
    error VersionRegistry__Unconfigured();

    event VersionRegistered(bytes32 versionHash, IFolioDeployer folioDeployer);
    event VersionDeprecated(bytes32 versionHash);

    function getImplementationForVersion(bytes32 versionHash) external view returns (address folio);

    function isDeprecated(bytes32 versionHash) external view returns (bool);

    function deployments(bytes32 versionHash) external view returns (IFolioDeployer);
}
