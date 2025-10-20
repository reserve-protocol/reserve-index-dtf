// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { UpgradeSpell_5_0_0 } from "@spells/upgrades/UpgradeSpell_5_0_0.sol";
import "../../base/BaseTest.sol";

abstract contract GenericUpgradeSpell_5_0_0_Test is BaseTest {
    UpgradeSpell_5_0_0 spell;

    function run_upgradeSpell_500_fork(Folio folio, FolioProxyAdmin proxyAdmin) public {
        assertNotEq(folio.version(), "5.0.0");

        // save name + symbol

        string memory name = folio.name();
        string memory symbol = folio.symbol();

        // grant adminships

        address timelock = proxyAdmin.owner();

        vm.startPrank(timelock);
        proxyAdmin.transferOwnership(address(spell));
        folio.grantRole(DEFAULT_ADMIN_ROLE, address(spell));
        vm.stopPrank();

        assertTrue(folio.hasRole(DEFAULT_ADMIN_ROLE, timelock));

        // only timelock should be able to cast spell

        vm.expectRevert("US4: caller not admin");
        spell.cast(folio, proxyAdmin);

        // cast spell as timelock

        vm.prank(timelock);
        spell.cast(folio, proxyAdmin);

        // name + symbol should be same as before

        assertEq(folio.name(), name);
        assertEq(folio.symbol(), symbol);

        // permissionless bids should be enabled

        assertEq(folio.bidsEnabled(), true);

        // verify that only timelock is admin

        assertEq(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), timelock);

        vm.expectRevert();
        folio.grantRole(DEFAULT_ADMIN_ROLE, address(this));

        // verify that timelock is the only admin

        assertEq(proxyAdmin.owner(), timelock);

        // verify version

        assertEq(folio.version(), "5.0.0");
    }
}
