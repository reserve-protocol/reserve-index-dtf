// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Versioned } from "./utils/Versioned.sol";
import { IRoleRegistry } from "./interfaces/IRoleRegistry.sol";

/**
 * @title VersionRegistry
 */
contract VersionRegistry {
    IRoleRegistry public immutable roleRegistry;

    mapping(bytes32 => address) public deployments;
    mapping(bytes32 => bool) public isDeprecated;
    bytes32 private latestVersion;

    error VersionRegistry__ZeroAddress();
    error VersionRegistry__InvalidRegistration();
    error VersionRegistry__AlreadyDeprecated();
    error VersionRegistry__InvalidCaller();

    event VersionRegistered(bytes32 versionHash, address folioImplementation);
    event VersionDeprecated(bytes32 versionHash);

    constructor(IRoleRegistry _roleRegistry) {
        if (address(_roleRegistry) == address(0)) {
            revert VersionRegistry__ZeroAddress();
        }

        roleRegistry = _roleRegistry;
    }

    function registerVersion(address folioImpl) external {
        if (!roleRegistry.isOwner(msg.sender)) {
            revert VersionRegistry__InvalidCaller();
        }

        if (address(folioImpl) == address(0)) {
            revert VersionRegistry__ZeroAddress();
        }

        string memory version = Versioned(folioImpl).version();
        bytes32 versionHash = keccak256(abi.encodePacked(version));

        if (address(deployments[versionHash]) != address(0)) {
            revert VersionRegistry__InvalidRegistration();
        }

        deployments[versionHash] = folioImpl;
        latestVersion = versionHash;

        emit VersionRegistered(versionHash, folioImpl);
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
        returns (bytes32 versionHash, string memory version, address folio, bool deprecated)
    {
        versionHash = latestVersion;
        folio = deployments[versionHash];
        version = Versioned(folio).version();
        deprecated = isDeprecated[versionHash];
    }

    function getImplementationForVersion(bytes32 versionHash) external view returns (address folio) {
        return deployments[versionHash];
    }
}
