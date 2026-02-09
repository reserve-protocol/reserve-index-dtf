// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { IReserveOptimisticGovernorDeployer } from "@reserve-protocol/reserve-governor/contracts/interfaces/IDeployer.sol";
import { UpgradeSpell_6_0_0 } from "@spells/upgrades/UpgradeSpell_6_0_0.sol";

string constant junkSeedPhrase = "test test test test test test test test test test test junk";

contract DeploySpell is Script {
    string seedPhrase = block.chainid != 31337 ? vm.readFile(".seed") : junkSeedPhrase;
    uint256 privateKey = vm.deriveKey(seedPhrase, 0);
    address walletAddress = vm.rememberKey(privateKey);

    // Set via environment variable: GOVERNOR_DEPLOYER=0x...
    address governorDeployer = vm.envAddress("GOVERNOR_DEPLOYER");

    function setUp() external {
        console2.log("Chain:", block.chainid);
        console2.log("Wallet:", walletAddress);
        console2.log("GovernorDeployer:", governorDeployer);
    }

    function run() external {
        vm.startBroadcast(privateKey);

        UpgradeSpell_6_0_0 spell = new UpgradeSpell_6_0_0(IReserveOptimisticGovernorDeployer(governorDeployer));

        vm.stopBroadcast();

        console2.log("Spell: %s", address(spell));
    }
}
