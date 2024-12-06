// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";
import { IFolioFactory } from "@interfaces/IFolioFactory.sol";

import { Versioned } from "@utils/Versioned.sol";

/**
 * @title VersionRegistry for Reserve Folio
 */
contract FolioVersionRegistry {
    IRoleRegistry public immutable roleRegistry;

    mapping(bytes32 => IFolioFactory) public deployments;
    mapping(bytes32 => bool) public isDeprecated;
    bytes32 private latestVersion;

    error VersionRegistry__ZeroAddress();
    error VersionRegistry__InvalidRegistration();
    error VersionRegistry__AlreadyDeprecated();
    error VersionRegistry__InvalidCaller();

    event VersionRegistered(bytes32 versionHash, IFolioFactory folioFactory);
    event VersionDeprecated(bytes32 versionHash);

    constructor(IRoleRegistry _roleRegistry) {
        if (address(_roleRegistry) == address(0)) {
            revert VersionRegistry__ZeroAddress();
        }

        roleRegistry = _roleRegistry;
    }

    function registerVersion(IFolioFactory folioFactory) external {
        if (!roleRegistry.isOwner(msg.sender)) {
            revert VersionRegistry__InvalidCaller();
        }

        if (address(folioFactory) == address(0)) {
            revert VersionRegistry__ZeroAddress();
        }

        string memory version = Versioned(address(folioFactory)).version();
        bytes32 versionHash = keccak256(abi.encodePacked(version));

        if (address(deployments[versionHash]) != address(0)) {
            revert VersionRegistry__InvalidRegistration();
        }

        deployments[versionHash] = folioFactory;
        latestVersion = versionHash;

        emit VersionRegistered(versionHash, folioFactory);
    }

    function deprecateVersion(bytes32 versionHash) external {
        if (!roleRegistry.isOwnerOrEmergencyCouncil(msg.sender)) {
            revert VersionRegistry__InvalidCaller();
        }

        if (isDeprecated[versionHash]) {
            revert VersionRegistry__AlreadyDeprecated();
        }
        isDeprecated[versionHash] = true;

        emit VersionDeprecated(versionHash);
    }

    function getLatestVersion()
        external
        view
        returns (bytes32 versionHash, string memory version, IFolioFactory folioFactory, bool deprecated)
    {
        versionHash = latestVersion;
        folioFactory = deployments[versionHash];
        version = Versioned(address(folioFactory)).version();
        deprecated = isDeprecated[versionHash];
    }

    function getImplementationForVersion(bytes32 versionHash) external view returns (address folio) {
        return deployments[versionHash].folioImplementation();
    }
}
