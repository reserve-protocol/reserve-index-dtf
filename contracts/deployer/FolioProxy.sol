// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ERC1967Proxy, ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IFolioVersionRegistry } from "@interfaces/IFolioVersionRegistry.sol";

/**
 * @dev Custom ProxyAdmin for upgrade functionality.
 */
contract FolioProxyAdmin is Ownable {
    address immutable upgradeController; // @todo sync with version/upgrade manager

    error VersionDeprecated();

    constructor(address initialOwner, address _upgradeController) Ownable(initialOwner) {
        upgradeController = _upgradeController;
    }

    function upgradeToVersion(address proxyTarget, bytes32 versionHash) external onlyOwner {
        IFolioVersionRegistry folioRegistry = IFolioVersionRegistry(upgradeController);

        if (folioRegistry.isDeprecated(versionHash)) {
            revert VersionDeprecated();
        }

        address folioImpl = folioRegistry.getImplementationForVersion(versionHash);

        ITransparentUpgradeableProxy(proxyTarget).upgradeToAndCall(folioImpl, "");
    }
}

/**
 * @dev This is an alternate implementation of the TransparentUpgradeableProxy contract, please read through
 *      their considerations and limitations before using this contract.
 */
contract FolioProxy is ERC1967Proxy {
    error ProxyDeniedAdminAccess();

    constructor(address _logic, address _admin) ERC1967Proxy(_logic, "") {
        /**
         * @dev _admin must be proxyAdmin
         * @notice Yes, admin can be an immutable variable. Doing this way to honor ERC1967 spec.
         */
        ERC1967Utils.changeAdmin(_admin);
    }

    function _fallback() internal virtual override {
        if (msg.sender == ERC1967Utils.getAdmin()) {
            if (msg.sig != ITransparentUpgradeableProxy.upgradeToAndCall.selector) {
                revert ProxyDeniedAdminAccess();
            } else {
                (address newImplementation, bytes memory data) = abi.decode(msg.data[4:], (address, bytes));

                ERC1967Utils.upgradeToAndCall(newImplementation, data);
            }
        } else {
            super._fallback();
        }
    }
}
