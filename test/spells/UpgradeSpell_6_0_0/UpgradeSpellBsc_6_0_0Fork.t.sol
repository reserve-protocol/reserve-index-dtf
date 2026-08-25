// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Folio } from "@src/Folio.sol";
import { ISelectorRegistryAdminFork_6_0_0, GenericUpgradeSpell_6_0_0ForkTest } from "./GenericUpgradeSpell_6_0_0.t.sol";

contract UpgradeSpellBsc_6_0_0ForkTest is GenericUpgradeSpell_6_0_0ForkTest {
    address private constant VERSION_REGISTRY = 0x79A4E963378AE34fC6c796a24c764322fC6c9390;

    Config[] private configs;

    function setUp() public {
        // The configured public BSC endpoint is not archival, so use latest state.
        vm.createSelectFork(vm.envOr("FORK_RPC_BSC", string("bsc")));
        _setUpSpell(VERSION_REGISTRY);

        // Active Index DTF snapshot: api.reserve.org/discover/dtfs, 2026-08-25
        configs.push(
            Config(
                Folio(0xD7cE7a841310982AcD976D1a6fe7BB6063c5689D),
                ISelectorRegistryAdminFork_6_0_0(0xeFF38e77A193e17352206B6F416441a4001687A1)
            )
        ); // BUILDOUT
        configs.push(
            Config(Folio(0x2f8A339B5889FfaC4c5A956787cdA593b3c36867), ISelectorRegistryAdminFork_6_0_0(address(0)))
        ); // CMC20
        configs.push(
            Config(
                Folio(0xf571Fe3F0d74521Bc7310B111Faea931C748f27B),
                ISelectorRegistryAdminFork_6_0_0(0x68B65996528E294FC95BeB5E278A39d3c0eF975C)
            )
        ); // NEOCLOUD
        configs.push(
            Config(
                Folio(0xa0Fe4e0aEca5479705ce996615B2EACB6b6a10Fb),
                ISelectorRegistryAdminFork_6_0_0(0x285CfA670345eb13c05516252590e81b2eaE43e3)
            )
        ); // PHOTON
        configs.push(
            Config(
                Folio(0x290bCc0Fd5096cC3261AE2021841c7BC67Cb0f51),
                ISelectorRegistryAdminFork_6_0_0(0xE8d03514542f87A4Dc6511ABA98707A864159322)
            )
        ); // POWER
        configs.push(
            Config(
                Folio(0x75617e7653f86f074Cc30b9Fd4eBf52bA9b62247),
                ISelectorRegistryAdminFork_6_0_0(0x3bB11415946aCbB664CA136aF3EA3e7beA31Be67)
            )
        ); // ROBOTS
    }

    function test_upgradeActive5_0_0Folios() public {
        for (uint256 i; i < configs.length; i++) {
            _runUpgrade(configs[i]);
        }
    }
}
