// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { Folio } from "@src/Folio.sol";
import { Versioned } from "@utils/Versioned.sol";

/**
 * @title UpgradeSpell_3_0_0
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 *
 * This spell a Folio to upgrade to 3.0.0.
 *
 * It does not upgrade the staking vault.
 *
 * In order to use the spell, transferOwnership of the proxy admin to this contract just before calling the spell.
 *
 */
contract UpgradeSpell_3_0_0 is Versioned {
    bytes32 public constant AUCTION_APPROVER = keccak256("AUCTION_APPROVER");
    bytes32 public constant VERSION_3_0_0 = keccak256("3.0.0");

    constructor() {}

    /// Cast spell to upgrade to 3.0.0
    /// @dev Requirements:
    ///      - Caller is owner timelock3
    ///      - Has ownership of the proxy admin
    ///      - Has DEFAULT_ADMIN_ROLE of Folio, as the 2nd admin in addition to the owner timelock
    function cast(Folio folio, FolioProxyAdmin proxyAdmin) external {
        // check privileges / setup

        require(proxyAdmin.owner() == address(this), "GS: not proxy admin owner");
        require(folio.hasRole(folio.DEFAULT_ADMIN_ROLE(), address(this)), "GS: not admin");

        require(folio.hasRole(folio.DEFAULT_ADMIN_ROLE(), msg.sender), "GS: caller not admin");

        // upgrade to 3.0.0

        proxyAdmin.upgradeToVersion(address(folio), VERSION_3_0_0, "");

        require(keccak256(abi.encode(folio.version())) == VERSION_3_0_0, "GS: version mismatch");

        // add all auction approvers to rebalance managers

        uint256 numApprovers = folio.getRoleMemberCount(AUCTION_APPROVER);

        for (uint256 i; i < numApprovers; i++) {
            address approver = folio.getRoleMember(AUCTION_APPROVER, i);

            require(approver != address(0), "GS: approver 0");

            // add to rebalance managers
            folio.grantRole(folio.REBALANCE_MANAGER(), approver);
        }

        // renounce temporary adminship

        folio.renounceRole(folio.DEFAULT_ADMIN_ROLE(), address(this));

        require(!folio.hasRole(folio.DEFAULT_ADMIN_ROLE(), address(this)), "GS: admin after revoke");

        require(folio.getRoleMemberCount(folio.DEFAULT_ADMIN_ROLE()) == 1, "GS: unexpected number of admins");

        // only admin left must be the timelock

        address timelock = folio.getRoleMember(folio.DEFAULT_ADMIN_ROLE(), 0);

        require(timelock != msg.sender, "GS: timelock not caller");

        // transfer proxyAdmin back to timelock

        proxyAdmin.transferOwnership(timelock);

        require(proxyAdmin.owner() == timelock, "GS: proxy admin not transferred");
    }
}
