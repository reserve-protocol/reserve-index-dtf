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

import { DeploymentParams, junkSeedPhrase } from "./Deploy.s.sol";

contract DeployMocks is Script {
    string seedPhrase = block.chainid != 31337 ? vm.readFile(".seed") : junkSeedPhrase;
    uint256 privateKey = vm.deriveKey(seedPhrase, 0);
    address walletAddress = vm.rememberKey(privateKey);

    mapping(uint256 chainId => DeploymentParams) public deploymentParams;

    function setUp() external {
        console2.log("Chain:", block.chainid);
        console2.log("Wallet:", walletAddress);

        // Base Mainnet - Mock Parameters
        // DO NOT USE IN PRODUCTION
        deploymentParams[8453] = DeploymentParams({
            rsrToken: 0xaB36452DbAC151bE02b16Ca17d8919826072f64a,
            roleRegistry: 0xE5a1da41af2919A43daC3ea22C2Bdd230a3E19f5,
            folioFeeRegistry: 0x43Dca440BC160562173cb24E87F6fe39c62E9f0B,
            feeRecipient: 0xa31d555b08fAA0701cb0a8B2A334f7fC629984CF,
            folioVersionRegistry: 0x8a01936B12bcbEEC394ed497600eDe41D409a83F,
            trustedFillerRegistry: 0x60C384e226b120d93f3e0F4C502957b2B9C32B15
        });
    }

    function run() external {
        DeploymentParams memory params = deploymentParams[block.chainid];

        vm.startBroadcast(privateKey);

        address governorImplementation = address(new FolioGovernor());
        address timelockImplementation = address(new TimelockControllerUpgradeable());

        GovernanceDeployer governanceDeployer = new GovernanceDeployer(governorImplementation, timelockImplementation);

        FolioDeployer folioDeployer = new FolioDeployer(
            address(params.folioFeeRegistry),
            address(params.folioVersionRegistry),
            address(params.trustedFillerRegistry),
            governanceDeployer
        );

        CowSwapFiller cowSwapFiller = new CowSwapFiller();
        vm.stopBroadcast();

        console2.log("Mock Role Registry: %s", address(params.roleRegistry));
        console2.log("Mock Fee Registry: %s", address(params.folioFeeRegistry));
        console2.log("Mock Version Registry: %s", address(params.folioVersionRegistry));
        console2.log("Mock Filler Registry: %s", address(params.trustedFillerRegistry));

        console2.log("Governance Deployer: %s", address(governanceDeployer));
        console2.log("Folio Deployer: %s", address(folioDeployer));
        console2.log("CowSwap Filler: %s", address(cowSwapFiller));
    }
}
