// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import { MockFillerRegistry } from "@reserve-protocol/trusted-fillers/test/mock/MockFillerRegistry.sol";
import { CowSwapFiller } from "@reserve-protocol/trusted-fillers/contracts/fillers/cowswap/CowSwapFiller.sol";

import { FolioDAOFeeRegistry } from "@folio/FolioDAOFeeRegistry.sol";
import { FolioVersionRegistry } from "@folio/FolioVersionRegistry.sol";

import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";

import { GovernanceDeployer } from "@deployer/GovernanceDeployer.sol";
import { FolioDeployer } from "@deployer/FolioDeployer.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { MockRoleRegistry } from "utils/MockRoleRegistry.sol";

string constant junkSeedPhrase = "test test test test test test test test test test test junk";

contract DeployMocks is Script {
    string seedPhrase = block.chainid != 31337 ? vm.readFile(".seed") : junkSeedPhrase;
    uint256 privateKey = vm.deriveKey(seedPhrase, 0);
    address walletAddress = vm.rememberKey(privateKey);

    function setUp() external {
        console2.log("Chain:", block.chainid);
        console2.log("Wallet:", walletAddress);
    }

    function run() external {
        vm.startBroadcast(privateKey);

        MockRoleRegistry roleRegistry = new MockRoleRegistry();

        FolioDAOFeeRegistry feeRegistry = new FolioDAOFeeRegistry(IRoleRegistry(address(roleRegistry)), msg.sender);

        FolioVersionRegistry versionRegistry = new FolioVersionRegistry(IRoleRegistry(address(roleRegistry)));

        CowSwapFiller cowSwapFiller = new CowSwapFiller();

        MockFillerRegistry fillerRegistry = new MockFillerRegistry();
        fillerRegistry.addTrustedFiller(cowSwapFiller);

        address governorImplementation = address(new FolioGovernor());
        address timelockImplementation = address(new TimelockControllerUpgradeable());

        GovernanceDeployer governanceDeployer = new GovernanceDeployer(governorImplementation, timelockImplementation);

        FolioDeployer folioDeployer = new FolioDeployer(
            address(feeRegistry),
            address(versionRegistry),
            address(fillerRegistry),
            governanceDeployer
        );
        vm.stopBroadcast();

        console2.log("Mock Role Registry: %s", address(roleRegistry));
        console2.log("Fee Registry: %s", address(feeRegistry));
        console2.log("Version Registry: %s", address(versionRegistry));
        console2.log("CowSwap Filler: %s", address(cowSwapFiller));
        console2.log("Mock Filler Registry: %s", address(fillerRegistry));
        console2.log("Governance Deployer: %s", address(governanceDeployer));
        console2.log("Folio Deployer: %s", address(folioDeployer));
    }
}
