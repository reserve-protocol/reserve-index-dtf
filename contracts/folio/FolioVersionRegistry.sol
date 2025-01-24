// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";
import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { IFolioVersionRegistry } from "@interfaces/IFolioVersionRegistry.sol";

import { Versioned } from "@utils/Versioned.sol";

/**
 * @title FolioVersionRegistry
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice FolioVersionRegistry tracks Folio deployments by their version string
 */
contract FolioVersionRegistry is IFolioVersionRegistry {
    IRoleRegistry public immutable roleRegistry;

    mapping(bytes32 => IFolioDeployer) public deployments;
    mapping(bytes32 => bool) public isDeprecated;
    bytes32 private latestVersion;

    constructor(IRoleRegistry _roleRegistry) {
        require(address(_roleRegistry) != address(0), VersionRegistry__ZeroAddress());

        roleRegistry = _roleRegistry;
    }

    function registerVersion(IFolioDeployer folioDeployer) external {
        require(roleRegistry.isOwner(msg.sender), VersionRegistry__InvalidCaller());

        require(address(folioDeployer) != address(0), VersionRegistry__ZeroAddress());

        string memory version = Versioned(address(folioDeployer)).version();
        bytes32 versionHash = keccak256(abi.encodePacked(version));

        require(address(deployments[versionHash]) == address(0), VersionRegistry__InvalidRegistration());

        deployments[versionHash] = folioDeployer;
        latestVersion = versionHash;

        emit VersionRegistered(versionHash, folioDeployer);
    }

    function deprecateVersion(bytes32 versionHash) external {
        require(roleRegistry.isOwnerOrEmergencyCouncil(msg.sender), VersionRegistry__InvalidCaller());

        require(!isDeprecated[versionHash], VersionRegistry__AlreadyDeprecated());

        isDeprecated[versionHash] = true;

        emit VersionDeprecated(versionHash);
    }

    function getLatestVersion()
        external
        view
        returns (bytes32 versionHash, string memory version, IFolioDeployer folioDeployer, bool deprecated)
    {
        versionHash = latestVersion;
        folioDeployer = deployments[versionHash];

        require(address(folioDeployer) != address(0), VersionRegistry__Unconfigured());

        version = Versioned(address(folioDeployer)).version();
        deprecated = isDeprecated[versionHash];
    }

    function getImplementationForVersion(bytes32 versionHash) external view returns (address folio) {
        return deployments[versionHash].folioImplementation();
    }
}
