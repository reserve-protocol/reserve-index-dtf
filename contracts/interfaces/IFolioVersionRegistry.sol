// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFolioVersionRegistry {
    function getImplementationForVersion(bytes32 versionHash) external view returns (address folio);

    function isDeprecated(bytes32 versionHash) external view returns (bool);
}
