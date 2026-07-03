// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ERC1967Proxy, ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IFolioVersionRegistry } from "@interfaces/IFolioVersionRegistry.sol";

/**
 * @title FolioProxyAdmin
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 */
contract FolioProxyAdmin is Ownable {
    address public immutable versionRegistry;

    error VersionDeprecated();
    error InvalidVersion();

    constructor(address initialOwner, address _versionRegistry) Ownable(initialOwner) {
        versionRegistry = _versionRegistry;
    }

    function upgradeToVersion(address proxyTarget, bytes32 versionHash, bytes memory data) external onlyOwner {
        IFolioVersionRegistry folioRegistry = IFolioVersionRegistry(versionRegistry);

        require(!folioRegistry.isDeprecated(versionHash), VersionDeprecated());
        require(address(folioRegistry.deployments(versionHash)) != address(0), InvalidVersion());

        address folioImpl = folioRegistry.getImplementationForVersion(versionHash);

        ITransparentUpgradeableProxy(proxyTarget).upgradeToAndCall(folioImpl, data);
    }
}

/**
 * @title FolioProxy
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @dev Alternate implementation of OpenZeppelin's TransparentUpgradeableProxy pattern. The admin can only call
 *      upgradeToAndCall through the proxy; all other calls from the admin revert.
 */
contract FolioProxy is ERC1967Proxy {
    error ProxyDeniedAdminAccess();

    constructor(address _logic, address _admin) ERC1967Proxy(_logic, "") {
        /**
         * @dev _admin must be the FolioProxyAdmin. Store it in the ERC1967 admin slot for compatibility.
         */
        ERC1967Utils.changeAdmin(_admin);
    }

    function _fallback() internal virtual override {
        if (msg.sender == ERC1967Utils.getAdmin()) {
            require(msg.sig == ITransparentUpgradeableProxy.upgradeToAndCall.selector, ProxyDeniedAdminAccess());

            (address newImplementation, bytes memory data) = abi.decode(msg.data[4:], (address, bytes));

            ERC1967Utils.upgradeToAndCall(newImplementation, data);
        } else {
            super._fallback();
        }
    }
}
