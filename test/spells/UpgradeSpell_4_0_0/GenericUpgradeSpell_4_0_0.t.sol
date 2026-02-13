// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AUCTION_APPROVER, DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER } from "@utils/Constants.sol";

import { IUpgradeSpell_4_0_0 } from "./IUpgradeSpell_4_0_0.sol";
import "../../base/BaseTest.sol";

abstract contract GenericUpgradeSpell_4_0_0_Test is BaseTest {
    IUpgradeSpell_4_0_0 spell;

    function run_upgradeSpell_400_fork(Folio folio, FolioProxyAdmin proxyAdmin) public {
        assertNotEq(folio.version(), "4.0.0");

        // save AUCTION_APPROVERs

        address[] memory auctionApprovers = new address[](folio.getRoleMemberCount(AUCTION_APPROVER));
        for (uint256 i; i < auctionApprovers.length; i++) {
            auctionApprovers[i] = folio.getRoleMember(AUCTION_APPROVER, i);
        }

        // grant adminships

        address timelock = proxyAdmin.owner();

        vm.startPrank(timelock);
        proxyAdmin.transferOwnership(address(spell));
        folio.grantRole(DEFAULT_ADMIN_ROLE, address(spell));
        vm.stopPrank();

        assertTrue(folio.hasRole(DEFAULT_ADMIN_ROLE, timelock));

        // only timelock should be able to cast spell

        vm.expectRevert("US4: caller not admin");
        spell.cast(address(folio), address(proxyAdmin));

        // cast spell as timelock

        vm.prank(timelock);
        spell.cast(address(folio), address(proxyAdmin));

        // set of REBALANCE_MANAGERs should be the same as old AUCTION_APPROVERs

        uint256 len = folio.getRoleMemberCount(REBALANCE_MANAGER);
        assertEq(len, auctionApprovers.length);
        for (uint256 i; i < len; i++) {
            assert(folio.hasRole(REBALANCE_MANAGER, auctionApprovers[i]));
        }

        // AUCTION_APPROVERs should be revoked

        len = folio.getRoleMemberCount(AUCTION_APPROVER);
        assertEq(len, 0);

        // verify that rebalance control is set correctly
        (bool weightControl, IFolio.PriceControl priceControl) = folio.rebalanceControl();
        assertEq(uint256(priceControl), uint256(IFolio.PriceControl.PARTIAL));
        assertEq(weightControl, !spell.isTrackingDTF(address(folio)));

        // verify that only timelock is admin

        assertEq(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), timelock);

        vm.expectRevert();
        folio.grantRole(DEFAULT_ADMIN_ROLE, address(this));

        // verify that timelock is the only admin

        assertEq(proxyAdmin.owner(), timelock);

        // verify version

        assertEq(folio.version(), "4.0.0");
    }
}
