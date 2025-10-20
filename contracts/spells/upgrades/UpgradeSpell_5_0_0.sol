// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { Folio } from "@src/Folio.sol";
import { Versioned } from "@utils/Versioned.sol";
import { DEFAULT_ADMIN_ROLE } from "@utils/Constants.sol";

bytes32 constant VERSION_4_0_0 = keccak256("4.0.0");
bytes32 constant VERSION_4_0_1 = keccak256("4.0.1");
bytes32 constant VERSION_5_0_0 = keccak256("5.0.0");

/**
 * @title UpgradeSpell_5_0_0
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 *
 * This spell upgrades a Folio to 5.0.0.
 *
 * All Folios must be on 4.0.0 or 4.0.1 before they upgrade.
 *
 *  In order to use the spell:
 *   1. transferOwnership of the proxy admin to this contract
 *   2. grant DEFAULT_ADMIN_ROLE on the Folio to this contract
 *   3. call the spell from the owner timelock, making sure to execute all 3 steps back-to-back
 *
 */
contract UpgradeSpell_5_0_0 is Versioned {
    constructor() {}

    /// Cast spell to upgrade from 4.0.0 or 4.0.1 -> 5.0.0
    /// @dev Requirements:
    ///      - Caller is owner timelock
    ///      - Has ownership of the proxy admin
    ///      - Has DEFAULT_ADMIN_ROLE of Folio, as the 2nd admin in addition to the owner timelock
    function cast(Folio folio, FolioProxyAdmin proxyAdmin) external {
        require(
            keccak256(bytes(folio.version())) == VERSION_4_0_0 || keccak256(bytes(folio.version())) == VERSION_4_0_1,
            "US4: invalid version"
        );

        // check privileges / setup

        require(proxyAdmin.owner() == address(this), "US4: not proxy admin owner");
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "US4: not admin");
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "US4: caller not admin");

        // upgrade to 5.0.0

        proxyAdmin.upgradeToVersion(address(folio), VERSION_5_0_0, "");

        require(keccak256(bytes(folio.version())) == VERSION_5_0_0, "US4: version mismatch");

        // enable permissionless bids

        folio.setBidsEnabled(true);

        // renounce temporary admin role

        folio.renounceRole(DEFAULT_ADMIN_ROLE, address(this));

        require(!folio.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "US4: admin after revoke");

        require(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1, "US4: unexpected number of admins");

        // only admin left must be the timelock

        address remainingOwner = folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0);

        require(remainingOwner == msg.sender, "US4: lost adminship");

        // transfer proxyAdmin back to timelock

        proxyAdmin.transferOwnership(remainingOwner);

        require(proxyAdmin.owner() == remainingOwner, "US4: proxy admin not transferred");
    }
}
