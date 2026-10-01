// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Folio } from "@src/Folio.sol";
import { ISelectorRegistryAdminFork_6_0_0, GenericUpgradeSpell_6_0_0ForkTest } from "./GenericUpgradeSpell_6_0_0.t.sol";

contract UpgradeSpellEthereum_6_0_0ForkTest is GenericUpgradeSpell_6_0_0ForkTest {
    uint256 private constant FORK_BLOCK = 25_834_864;
    address private constant VERSION_REGISTRY = 0xA665b273997F70b647B66fa7Ed021287544849dB;

    Config[] private configs;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_MAINNET", string("mainnet")), FORK_BLOCK);
        _setUpSpell(VERSION_REGISTRY);

        // Active Index DTF snapshot: api.reserve.org/discover/dtfs, 2026-08-25
        configs.push(
            Config(Folio(0x188D12Eb13a5Eadd0867074ce8354B1AD6f4790b), ISelectorRegistryAdminFork_6_0_0(address(0)))
        ); // DFX
        configs.push(
            Config(Folio(0xe4a10951f962e6cB93Cb843a4ef05d2F99DB1F94), ISelectorRegistryAdminFork_6_0_0(address(0)))
        ); // ixEdel
    }

    function test_upgradeActive5_0_0Folios() public {
        for (uint256 i; i < configs.length; i++) {
            _runUpgrade(configs[i]);
        }
    }

    function test_activeFoliosNotYetEligibleFor6_0_0() public view {
        assertEq(Folio(0x9a1741E151233a82Cf69209A2F1bC7442B1fB29C).version(), "4.0.0"); // DGI
        assertEq(Folio(0x323c03c48660fE31186fa82c289b0766d331Ce21).version(), "4.0.0"); // OPEN
    }
}
