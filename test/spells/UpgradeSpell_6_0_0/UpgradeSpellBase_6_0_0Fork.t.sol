// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Folio } from "@src/Folio.sol";
import { ISelectorRegistryAdminFork_6_0_0, GenericUpgradeSpell_6_0_0ForkTest } from "./GenericUpgradeSpell_6_0_0.t.sol";

contract UpgradeSpellBase_6_0_0ForkTest is GenericUpgradeSpell_6_0_0ForkTest {
    uint256 private constant FORK_BLOCK = 50_451_750;
    address private constant VERSION_REGISTRY = 0xA665b273997F70b647B66fa7Ed021287544849dB;

    Config[] private configs;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_BASE", string("base")), FORK_BLOCK);
        _setUpSpell(VERSION_REGISTRY);

        // Active Index DTF snapshot: api.reserve.org/discover/dtfs, 2026-08-25
        configs.push(
            Config(Folio(0x23418De10d422AD71C9D5713a2B8991a9c586443), ISelectorRegistryAdminFork_6_0_0(address(0)))
        ); // BGCI
        configs.push(
            Config(Folio(0x44551CA46Fa5592bb572E20043f7C3D54c85cAD7), ISelectorRegistryAdminFork_6_0_0(address(0)))
        ); // CLX
        configs.push(
            Config(Folio(0x4dA9A0f397dB1397902070f93a4D6ddBC0E0E6e8), ISelectorRegistryAdminFork_6_0_0(address(0)))
        ); // LCAP
        configs.push(
            Config(
                Folio(0xCEF8Db49E456f872E288E1C042F916E9ceD7c781),
                ISelectorRegistryAdminFork_6_0_0(0xA5977360e7bd8EF6dB8992F1Dc68B5415995Fa75)
            )
        ); // MAG7
        configs.push(
            Config(Folio(0xe8b46b116D3BdFA787CE9CF3f5aCC78dc7cA380E), ISelectorRegistryAdminFork_6_0_0(address(0)))
        ); // MVTT10F
        configs.push(
            Config(Folio(0xe00CFa595841fb331105b93C19827797C925E3E4), ISelectorRegistryAdminFork_6_0_0(address(0)))
        ); // VLONE
    }

    function test_upgradeActive5_0_0Folios() public {
        for (uint256 i; i < configs.length; i++) {
            _runUpgrade(configs[i]);
        }
    }

    function test_activeFoliosNotYetEligibleFor6_0_0() public view {
        assertEq(Folio(0xeBcda5b80f62DD4DD2A96357b42BB6Facbf30267).version(), "4.0.0"); // ABX
        assertEq(Folio(0xb8753941196692E322846cfEE9C14C97AC81928A).version(), "2.0.0"); // BDTF
    }
}
