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
 * This spell upgrades a Folio to 4.0.0. For TRACKING DTFs, only Folios created as of 2025-06-16 are supported.
 * Previously created Folios will be assumed to be NATIVE.
 *
 * A Folio's weightControl is set as a function of whether the DTF is TRACKING or NATIVE, a previously offchain
 * concept that has been encoded in the isTrackingDTF mapping.
 *
 * All Folios must be on 1.0.0 or 2.0.0 before they upgrade. On 4.0.0 they will receive PriceControl.PARTIAL.
 *
 * Any Folio balances held by the Folio will become locked.
 *
 * The spell does not upgrade the staking vault.
 *
 * In order to use the spell:
 *   1. transferOwnership of the proxy admin to this contract
 *   2. grant DEFAULT_ADMIN_ROLE on the Folio to this contract
 *   3. call the spell from the owner timelock, making sure to execute all 3 steps back-to-back
 *
 */
contract UpgradeSpell_4_0_0 is Versioned {
    // this mapping is chain agnostic; by-hand this has been checked to be safe as of 2025-06-16
    mapping(address => bool) public isTrackingDTF;
    mapping(uint256 => address) public fillerRegistryMapping;

    constructor() {
        isTrackingDTF[0x23418De10d422AD71C9D5713a2B8991a9c586443] = true; // BGCI (base)
        isTrackingDTF[0xe8b46b116D3BdFA787CE9CF3f5aCC78dc7cA380E] = true; // MVTT10F (base)
        isTrackingDTF[0xD600e748C17Ca237Fcb5967Fa13d688AFf17Be78] = true; // MVDA25 (base)
        isTrackingDTF[0x188D12Eb13a5Eadd0867074ce8354B1AD6f4790b] = true; // DFX (mainnet)

        fillerRegistryMapping[1] = 0x279ccF56441fC74f1aAC39E7faC165Dec5A88B3A; // mainnet
        fillerRegistryMapping[56] = 0x08424d7C52bf9edd4070701591Ea3FE6dca6449B; // bsc
        fillerRegistryMapping[8453] = 0x72DB5f49D0599C314E2f2FEDf6Fe33E1bA6C7A18; // base
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
        for (int256 i = int256(numApprovers) - 1; i >= 0; i--) {
            address approver = folio.getRoleMember(AUCTION_APPROVER, uint256(i));

            require(approver != address(0), "US4: approver 0");

            folio.revokeRole(AUCTION_APPROVER, approver);
        }

        // set RebalanceControl

        folio.setRebalanceControl(
            IFolio.RebalanceControl({
                weightControl: !isTrackingDTF[address(folio)],
                priceControl: IFolio.PriceControl.PARTIAL
            })
        );

        // set trusted filler registry
        folio.setTrustedFillerRegistry(fillerRegistryMapping[block.chainid], false);

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
