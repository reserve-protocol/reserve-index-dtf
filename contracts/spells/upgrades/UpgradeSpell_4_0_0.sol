// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { Folio } from "@src/Folio.sol";
import { Versioned } from "@utils/Versioned.sol";
import { AUCTION_APPROVER, DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER } from "@utils/Constants.sol";
import { IFolio } from "@interfaces/IFolio.sol";

bytes32 constant VERSION_1_0_0 = keccak256("1.0.0");
bytes32 constant VERSION_2_0_0 = keccak256("2.0.0");
bytes32 constant VERSION_4_0_0 = keccak256("4.0.0");

/**
 * @title UpgradeSpell_4_0_0
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 *
 * This spell a Folio to upgrade to 4.0.0.
 *
 * All Folios are assumed to be PriceControl.PARTIAL.
 *
 * Folios' weightControl is set as a function of whether the DTF is TRACKING or NATIVE.
 *
 * It does not upgrade the staking vault.
 *
 * In order to use the spell, transferOwnership of the proxy admin to this contract just before calling the spell.
 *
 */
contract UpgradeSpell_4_0_0 is Versioned {
    mapping(address => bool) public isNativeDTF;

    constructor() {
        // TODO add native DTFs
    }

    /// Cast spell to upgrade from 1.0.0 or 2.0.0 -> 4.0.0
    /// @dev Requirements:
    ///      - Caller is owner timelock
    ///      - Has ownership of the proxy admin
    ///      - Has DEFAULT_ADMIN_ROLE of Folio, as the 2nd admin in addition to the owner timelock
    function cast(Folio folio, FolioProxyAdmin proxyAdmin) external {
        require(
            keccak256(bytes(folio.version())) == VERSION_1_0_0 || keccak256(bytes(folio.version())) == VERSION_2_0_0,
            "US4: invalid version"
        );

        // check privileges / setup

        require(proxyAdmin.owner() == address(this), "US4: not proxy admin owner");
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "US4: not admin");
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "US4: caller not admin");

        // upgrade to 4.0.0

        proxyAdmin.upgradeToVersion(address(folio), VERSION_4_0_0, "");

        require(keccak256(bytes(folio.version())) == VERSION_4_0_0, "US4: version mismatch");

        // convert all auction approvers to rebalance managers

        uint256 numApprovers = folio.getRoleMemberCount(AUCTION_APPROVER);

        for (uint256 i; i < numApprovers; i++) {
            address approver = folio.getRoleMember(AUCTION_APPROVER, i);

            require(approver != address(0), "US4: approver 0");

            // add to rebalance managers
            folio.grantRole(REBALANCE_MANAGER, approver);
        }

        // revoke AUCTION_APPROVERs

        for (uint256 i; i < numApprovers; i++) {
            address approver = folio.getRoleMember(AUCTION_APPROVER, i);

            require(approver != address(0), "US4: approver 0");

            folio.revokeRole(AUCTION_APPROVER, approver);
        }

        // set RebalanceControl

        folio.setRebalanceControl(
            IFolio.RebalanceControl({
                weightControl: isNativeDTF[address(folio)],
                priceControl: IFolio.PriceControl.PARTIAL
            })
        );

        // renounce temporary adminship

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
