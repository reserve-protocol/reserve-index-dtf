// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import { GovernanceDeployer } from "@deployer/GovernanceDeployer.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";

import { GovernanceSpell_31_03_2025 } from "@spells/31-03-2025/GovernanceSpell_31_03_2025.sol";

string constant junkSeedPhrase = "test test test test test test test test test test test junk";

contract DeploySpell is Script {
    string seedPhrase = block.chainid != 31337 ? vm.readFile(".seed") : junkSeedPhrase;
    uint256 privateKey = vm.deriveKey(seedPhrase, 0);
    address walletAddress = vm.rememberKey(privateKey);

    function setUp() external {
        console2.log("Chain:", block.chainid);
        console2.log("Wallet:", walletAddress);
    }

    function run() external {
        vm.startBroadcast(privateKey);

        address governorImplementation = address(new FolioGovernor());
        address timelockImplementation = address(new TimelockControllerUpgradeable());

        GovernanceDeployer governanceDeployer = new GovernanceDeployer(governorImplementation, timelockImplementation);
        GovernanceSpell_31_03_2025 governanceSpell = new GovernanceSpell_31_03_2025(governanceDeployer);

        vm.stopBroadcast();

        console2.log("Governance Deployer: %s", address(governanceDeployer));
        console2.log("Governance Spell: %s", address(governanceSpell));
    }
}
