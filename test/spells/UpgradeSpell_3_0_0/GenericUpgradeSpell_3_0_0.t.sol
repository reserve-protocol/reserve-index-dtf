// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { UpgradeSpell_3_0_0 } from "@spells/upgrades/UpgradeSpell_3_0_0.sol";
import "../../base/BaseTest.sol";

abstract contract GenericUpgradeSpell_3_0_0_Test is BaseTest {
    struct Config {
        Folio folio;
        FolioProxyAdmin proxyAdmin;
    }

    Config[] public CONFIGS;

    UpgradeSpell_3_0_0 spell;

    function _setUp() public virtual override {
        super._setUp();

        // TODO remove after spell deployed

        spell = new UpgradeSpell_3_0_0();
    }

    function test_upgradeSpell_31_03_2025_fork() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            folio = CONFIGS[i].folio;
            proxyAdmin = CONFIGS[i].proxyAdmin;

            assertNotEq(folio.version(), "3.0.0");

            address timelock = proxyAdmin.owner();

            // grant adminships

            vm.startPrank(timelock);
            proxyAdmin.transferOwnership(address(spell));
            folio.grantRole(folio.DEFAULT_ADMIN_ROLE(), address(spell));
            vm.stopPrank();

            // only timelock should be able to cast spell

            vm.expectRevert();
            spell.cast(folio, proxyAdmin);

            // cast spell as timelock

            vm.prank(timelock);
            spell.cast(folio, proxyAdmin);

            // verify upgrade

            assertEq(folio.version(), "3.0.0");

            // set of REBALANCE_MANAGERs should be the same as the set of AUCTION_APPROVERs

            uint256 len = folio.getRoleMemberCount(keccak256("AUCTION_APPROVER"));
            assertEq(folio.getRoleMemberCount(folio.REBALANCE_MANAGER()), len);
            for (uint256 j; i < len; j++) {
                assert(folio.hasRole(folio.REBALANCE_MANAGER(), folio.getRoleMember(keccak256("AUCTION_APPROVER"), j)));
            }

            // verify that only timelock is admin

            assertEq(folio.getRoleMemberCount(folio.DEFAULT_ADMIN_ROLE()), 1);
            assertEq(folio.getRoleMember(folio.DEFAULT_ADMIN_ROLE(), 0), timelock);

            vm.expectRevert();
            folio.grantRole(folio.DEFAULT_ADMIN_ROLE(), address(this));

            // verify that timelock is the only admin

            assertEq(proxyAdmin.owner(), timelock);
        }
    }
}
