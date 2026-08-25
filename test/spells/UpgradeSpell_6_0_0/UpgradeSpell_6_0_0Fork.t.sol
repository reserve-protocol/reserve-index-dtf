// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { Folio } from "@src/Folio.sol";
import { FolioDeployer } from "@deployer/FolioDeployer.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { FolioVersionRegistry } from "@folio/FolioVersionRegistry.sol";
import { DEFAULT_ADMIN_ROLE } from "@utils/Constants.sol";
import { UpgradeSpell_6_0_0, VERSION_6_0_0 } from "../../../contracts/spells/upgrades/UpgradeSpell_6_0_0.sol";

contract ActiveTrustedFill {
    function swapActive() external pure returns (bool) {
        return true;
    }
}

contract UpgradeSpell_6_0_0ForkTest is Test {
    uint256 private constant FORK_BLOCK = 25_282_010;

    address private constant FOLIO = 0x5039ECE83DC4E0621eBEc391128339Bd859a84d0;
    address private constant PROXY_ADMIN = 0x5f272F35654d72eA7e87C35BdE585a2d2d75BfEC;
    address private constant TIMELOCK = 0x5b7310B7f17048AafdD34767ef447764B0072c8c;

    address private constant DAO_FEE_REGISTRY = 0x0262E3e15cCFD2221b35D05909222f1f5FCdcd80;
    address private constant VERSION_REGISTRY = 0xA665b273997F70b647B66fa7Ed021287544849dB;
    address private constant TRUSTED_FILLER_REGISTRY = 0x279ccF56441fC74f1aAC39E7faC165Dec5A88B3A;
    address private constant ROLE_REGISTRY_OWNER = 0xe8259842e71f4E44F2F68D6bfbC15EDA56E63064;

    Folio private folio;
    FolioProxyAdmin private proxyAdmin;
    UpgradeSpell_6_0_0 private spell;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), FORK_BLOCK);

        folio = Folio(FOLIO);
        proxyAdmin = FolioProxyAdmin(PROXY_ADMIN);
        spell = new UpgradeSpell_6_0_0();

        FolioVersionRegistry versionRegistry = FolioVersionRegistry(VERSION_REGISTRY);
        if (address(versionRegistry.deployments(VERSION_6_0_0)) == address(0)) {
            FolioDeployer folioDeployer = new FolioDeployer(
                DAO_FEE_REGISTRY,
                VERSION_REGISTRY,
                TRUSTED_FILLER_REGISTRY,
                address(0)
            );
            vm.prank(ROLE_REGISTRY_OWNER);
            versionRegistry.registerVersion(folioDeployer);
        }

        vm.prank(TIMELOCK);
        proxyAdmin.transferOwnership(address(spell));
    }

    function test_cast() public {
        uint256 totalSupply = folio.totalSupply();
        string memory name = folio.name();
        string memory symbol = folio.symbol();

        vm.prank(TIMELOCK);
        spell.cast(folio, proxyAdmin);

        assertEq(folio.version(), "6.0.0");
        assertEq(folio.lastFolioFeePoke(), block.timestamp);
        assertEq(folio.totalSupply(), totalSupply);
        assertEq(folio.name(), name);
        assertEq(folio.symbol(), symbol);
        assertEq(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), TIMELOCK);
        assertEq(proxyAdmin.owner(), TIMELOCK);
    }

    function test_castRevertsForActiveStateChange() public {
        vm.store(
            address(folio),
            bytes32(uint256(19)), // activeTrustedFill
            bytes32(uint256(uint160(address(new ActiveTrustedFill()))))
        );

        vm.expectRevert(UpgradeSpell_6_0_0.StateChangeActive.selector);
        vm.prank(TIMELOCK);
        spell.cast(folio, proxyAdmin);
    }

    function test_castRevertsForActiveRebalance() public {
        vm.store(address(folio), bytes32(uint256(28)), bytes32(block.timestamp + 1)); // rebalance.availableUntil

        vm.expectRevert(UpgradeSpell_6_0_0.ActiveRebalance.selector);
        vm.prank(TIMELOCK);
        spell.cast(folio, proxyAdmin);
    }

    function test_castRevertsForActiveAuction() public {
        vm.store(address(folio), bytes32(uint256(31)), bytes32(uint256(1))); // nextAuctionId

        bytes32 auctionSlot = keccak256(abi.encode(uint256(0), uint256(30)));
        vm.store(address(folio), bytes32(uint256(auctionSlot) + 3), bytes32(block.timestamp)); // auction.endTime

        vm.expectRevert(UpgradeSpell_6_0_0.ActiveAuction.selector);
        vm.prank(TIMELOCK);
        spell.cast(folio, proxyAdmin);
    }
}
