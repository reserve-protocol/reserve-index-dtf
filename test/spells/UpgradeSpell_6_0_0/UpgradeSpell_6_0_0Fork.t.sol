// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";

import { Folio } from "@src/Folio.sol";
import { FolioDeployer } from "@deployer/FolioDeployer.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { FolioVersionRegistry } from "@folio/FolioVersionRegistry.sol";
import { DEFAULT_ADMIN_ROLE } from "@utils/Constants.sol";
import { UpgradeSpell_6_0_0, VERSION_6_0_0, START_REBALANCE_5_0_0, START_REBALANCE_6_0_0, ISelectorRegistry_6_0_0 } from "../../../contracts/spells/upgrades/UpgradeSpell_6_0_0.sol";

interface ISelectorRegistryAdmin_6_0_0 is ISelectorRegistry_6_0_0 {
    function registerSelectors(IOptimisticSelectorRegistry.SelectorData[] calldata selectorData) external;

    function unregisterSelectors(IOptimisticSelectorRegistry.SelectorData[] calldata selectorData) external;
}

contract FakeOptimisticGovernor {
    address public immutable timelock;
    address public selectorRegistry;

    constructor(address _timelock) {
        timelock = _timelock;
    }

    function setSelectorRegistry(address _selectorRegistry) external {
        selectorRegistry = _selectorRegistry;
    }
}

contract FakeSelectorRegistry {
    address public immutable governor;

    constructor(address timelock) {
        FakeOptimisticGovernor fakeGovernor = new FakeOptimisticGovernor(timelock);
        governor = address(fakeGovernor);
        fakeGovernor.setSelectorRegistry(address(this));
    }

    function isAllowed(address, bytes4 selector) external pure returns (bool) {
        return selector == START_REBALANCE_6_0_0;
    }
}

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
    address private constant SELECTOR_REGISTRY = 0xA1C763301462411795cB5E320FA48e0622CEAa90;

    address private constant DAO_FEE_REGISTRY = 0x0262E3e15cCFD2221b35D05909222f1f5FCdcd80;
    address private constant VERSION_REGISTRY = 0xA665b273997F70b647B66fa7Ed021287544849dB;
    address private constant TRUSTED_FILLER_REGISTRY = 0x279ccF56441fC74f1aAC39E7faC165Dec5A88B3A;
    address private constant ROLE_REGISTRY_OWNER = 0xe8259842e71f4E44F2F68D6bfbC15EDA56E63064;

    Folio private folio;
    FolioProxyAdmin private proxyAdmin;
    ISelectorRegistryAdmin_6_0_0 private selectorRegistry;
    UpgradeSpell_6_0_0 private spell;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), FORK_BLOCK);

        folio = Folio(FOLIO);
        proxyAdmin = FolioProxyAdmin(PROXY_ADMIN);
        selectorRegistry = ISelectorRegistryAdmin_6_0_0(SELECTOR_REGISTRY);
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

        IOptimisticSelectorRegistry.SelectorData[] memory selectorData = new IOptimisticSelectorRegistry.SelectorData[](
            1
        );
        bytes4[] memory selectors = new bytes4[](1);
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData({ target: address(folio), selectors: selectors });

        vm.startPrank(TIMELOCK);
        selectors[0] = START_REBALANCE_6_0_0;
        selectorRegistry.registerSelectors(selectorData);
        selectors[0] = START_REBALANCE_5_0_0;
        selectorRegistry.unregisterSelectors(selectorData);
        proxyAdmin.transferOwnership(address(spell));
        vm.stopPrank();
    }

    function test_cast() public {
        uint256 totalSupply = folio.totalSupply();
        string memory name = folio.name();
        string memory symbol = folio.symbol();

        vm.prank(TIMELOCK);
        spell.cast(folio, proxyAdmin, selectorRegistry);

        assertEq(folio.version(), "6.0.0");
        assertEq(folio.lastFolioFeePoke(), block.timestamp);
        assertEq(folio.totalSupply(), totalSupply);
        assertEq(folio.name(), name);
        assertEq(folio.symbol(), symbol);
        assertEq(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), TIMELOCK);
        assertEq(proxyAdmin.owner(), TIMELOCK);
        assertFalse(selectorRegistry.isAllowed(address(folio), START_REBALANCE_5_0_0));
        assertTrue(selectorRegistry.isAllowed(address(folio), START_REBALANCE_6_0_0));
    }

    function test_castRevertsUntilNewSelectorIsRegistered() public {
        IOptimisticSelectorRegistry.SelectorData[] memory selectorData = new IOptimisticSelectorRegistry.SelectorData[](
            1
        );
        bytes4[] memory selectors = new bytes4[](1);
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData({ target: address(folio), selectors: selectors });

        vm.startPrank(TIMELOCK);
        selectors[0] = START_REBALANCE_6_0_0;
        selectorRegistry.unregisterSelectors(selectorData);

        vm.expectRevert(abi.encodeWithSelector(UpgradeSpell_6_0_0.UpgradeSpell__Error.selector, 9));
        spell.cast(folio, proxyAdmin, selectorRegistry);
        vm.stopPrank();
    }

    function test_castRevertsUntilOldSelectorIsUnregistered() public {
        IOptimisticSelectorRegistry.SelectorData[] memory selectorData = new IOptimisticSelectorRegistry.SelectorData[](
            1
        );
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = START_REBALANCE_5_0_0;
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData({ target: address(folio), selectors: selectors });

        vm.startPrank(TIMELOCK);
        selectorRegistry.registerSelectors(selectorData);

        vm.expectRevert(abi.encodeWithSelector(UpgradeSpell_6_0_0.UpgradeSpell__Error.selector, 10));
        spell.cast(folio, proxyAdmin, selectorRegistry);
        vm.stopPrank();
    }

    function test_castRejectsMissingSelectorRegistryForOptimisticGovernance() public {
        vm.expectRevert(abi.encodeWithSelector(UpgradeSpell_6_0_0.UpgradeSpell__Error.selector, 6));
        vm.prank(TIMELOCK);
        spell.cast(folio, proxyAdmin, ISelectorRegistry_6_0_0(address(0)));
    }

    function test_castRejectsFakeSelectorRegistry() public {
        ISelectorRegistry_6_0_0 fakeSelectorRegistry = ISelectorRegistry_6_0_0(
            address(new FakeSelectorRegistry(TIMELOCK))
        );

        vm.expectRevert(abi.encodeWithSelector(UpgradeSpell_6_0_0.UpgradeSpell__Error.selector, 7));
        vm.prank(TIMELOCK);
        spell.cast(folio, proxyAdmin, fakeSelectorRegistry);
    }

    function test_castRevertsForShortAuctionLength() public {
        vm.store(address(folio), bytes32(uint256(15)), bytes32(uint256(119))); // auctionLength

        vm.expectRevert(abi.encodeWithSelector(UpgradeSpell_6_0_0.UpgradeSpell__Error.selector, 11));
        vm.prank(TIMELOCK);
        spell.cast(folio, proxyAdmin, selectorRegistry);
    }

    function test_castRevertsForActiveStateChange() public {
        vm.store(
            address(folio),
            bytes32(uint256(19)), // activeTrustedFill
            bytes32(uint256(uint160(address(new ActiveTrustedFill()))))
        );

        vm.expectRevert(abi.encodeWithSelector(UpgradeSpell_6_0_0.UpgradeSpell__Error.selector, 12));
        vm.prank(TIMELOCK);
        spell.cast(folio, proxyAdmin, selectorRegistry);
    }

    function test_castRevertsForActiveRebalance() public {
        vm.store(address(folio), bytes32(uint256(28)), bytes32(block.timestamp + 1)); // rebalance.availableUntil

        vm.expectRevert(abi.encodeWithSelector(UpgradeSpell_6_0_0.UpgradeSpell__Error.selector, 13));
        vm.prank(TIMELOCK);
        spell.cast(folio, proxyAdmin, selectorRegistry);
    }

    function test_castRevertsForActiveAuction() public {
        vm.store(address(folio), bytes32(uint256(31)), bytes32(uint256(1))); // nextAuctionId

        bytes32 auctionSlot = keccak256(abi.encode(uint256(0), uint256(30)));
        vm.store(address(folio), bytes32(uint256(auctionSlot) + 3), bytes32(block.timestamp)); // auction.endTime

        vm.expectRevert(abi.encodeWithSelector(UpgradeSpell_6_0_0.UpgradeSpell__Error.selector, 14));
        vm.prank(TIMELOCK);
        spell.cast(folio, proxyAdmin, selectorRegistry);
    }
}
