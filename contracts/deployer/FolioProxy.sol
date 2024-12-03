// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ERC1967Proxy, ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @dev This is an alternate implementation of the TransparentUpgradeableProxy contract, please read through
 *      their considerations and limitations before using this contract.
 */
contract FolioProxy is ERC1967Proxy {
    error ProxyDeniedAdminAccess();

    address immutable upgradeController; // @todo sync with version/upgrade manager

    constructor(address _logic, address _admin, address _upgradeController) ERC1967Proxy(_logic, "") {
        ERC1967Utils.changeAdmin(_admin); // @dev _admin must be proxyAdmin

        upgradeController = _upgradeController;
    }

    function _fallback() internal virtual override {
        if (msg.sender == ERC1967Utils.getAdmin()) {
            if (msg.sig != ITransparentUpgradeableProxy.upgradeToAndCall.selector) {
                revert ProxyDeniedAdminAccess();
            } else {
                (address newImplementation, bytes memory data) = abi.decode(msg.data[4:], (address, bytes));
                // @todo There are two options:
                //       1. We limit and check the newImplementation here; or
                //       2. We add a custom function to upgrade using our upgrade manager
                //
                //       I like option 2 better, because the entire fallback is simplified.

                ERC1967Utils.upgradeToAndCall(newImplementation, data);
            }
        } else {
            super._fallback();
        }
    }
}
