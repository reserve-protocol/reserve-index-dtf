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

interface ISelectorRegistryAdminFork_6_0_0 is ISelectorRegistry_6_0_0 {
    function registerSelectors(IOptimisticSelectorRegistry.SelectorData[] calldata selectorData) external;

    function unregisterSelectors(IOptimisticSelectorRegistry.SelectorData[] calldata selectorData) external;
}

abstract contract GenericUpgradeSpell_6_0_0ForkTest is Test {
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    address private constant ROLE_REGISTRY_OWNER = 0xe8259842e71f4E44F2F68D6bfbC15EDA56E63064;

    struct Config {
        Folio folio;
        ISelectorRegistryAdminFork_6_0_0 selectorRegistry;
    }

    UpgradeSpell_6_0_0 internal spell;

    function _setUpSpell(address versionRegistryAddress) internal {
        FolioVersionRegistry versionRegistry = FolioVersionRegistry(versionRegistryAddress);
        if (address(versionRegistry.deployments(VERSION_6_0_0)) == address(0)) {
            FolioDeployer folioDeployer = new FolioDeployer(address(0), versionRegistryAddress, address(0), address(0));
            vm.prank(ROLE_REGISTRY_OWNER);
            versionRegistry.registerVersion(folioDeployer);
        }

        spell = new UpgradeSpell_6_0_0();
    }

    function _runUpgrade(Config memory config) internal {
        Folio folio = config.folio;
        FolioProxyAdmin proxyAdmin = FolioProxyAdmin(address(uint160(uint256(vm.load(address(folio), ADMIN_SLOT)))));
        address timelock = proxyAdmin.owner();

        assertEq(folio.version(), "5.0.0");

        uint256 totalSupply = folio.totalSupply();
        string memory name = folio.name();
        string memory symbol = folio.symbol();

        vm.startPrank(timelock);
        if (address(config.selectorRegistry) != address(0)) {
            assertTrue(config.selectorRegistry.isAllowed(address(folio), START_REBALANCE_5_0_0));

            IOptimisticSelectorRegistry.SelectorData[]
                memory selectorData = new IOptimisticSelectorRegistry.SelectorData[](1);
            bytes4[] memory selectors = new bytes4[](1);
            selectorData[0] = IOptimisticSelectorRegistry.SelectorData({
                target: address(folio),
                selectors: selectors
            });

            selectors[0] = START_REBALANCE_6_0_0;
            config.selectorRegistry.registerSelectors(selectorData);
            selectors[0] = START_REBALANCE_5_0_0;
            config.selectorRegistry.unregisterSelectors(selectorData);
        }

        proxyAdmin.transferOwnership(address(spell));
        spell.cast(folio, proxyAdmin, config.selectorRegistry);
        vm.stopPrank();

        assertEq(folio.version(), "6.0.0", symbol);
        assertEq(folio.lastFolioFeePoke(), block.timestamp, symbol);
        assertEq(folio.totalSupply(), totalSupply, symbol);
        assertEq(folio.name(), name, symbol);
        assertEq(folio.symbol(), symbol, symbol);
        assertEq(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, symbol);
        assertEq(folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), timelock, symbol);
        assertEq(proxyAdmin.owner(), timelock, symbol);

        if (address(config.selectorRegistry) != address(0)) {
            assertFalse(config.selectorRegistry.isAllowed(address(folio), START_REBALANCE_5_0_0), symbol);
            assertTrue(config.selectorRegistry.isAllowed(address(folio), START_REBALANCE_6_0_0), symbol);
        }
    }
}
