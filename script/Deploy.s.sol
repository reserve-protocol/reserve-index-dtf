// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";
import { MockRoleRegistry } from "utils/MockRoleRegistry.sol";
import { FolioDAOFeeRegistry } from "@folio/FolioDAOFeeRegistry.sol";
import { FolioVersionRegistry } from "@folio/FolioVersionRegistry.sol";
import { FolioDeployer } from "@deployer/FolioDeployer.sol";
import { GovernanceDeployer } from "@deployer/GovernanceDeployer.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";

string constant junkSeedPhrase = "test test test test test test test test test test test junk";

contract DeployScript is Script {
    string seedPhrase = block.chainid != 31337 ? vm.readFile(".seed") : junkSeedPhrase;
    uint256 privateKey = vm.deriveKey(seedPhrase, 0);
    address walletAddress = vm.rememberKey(privateKey);

    struct DeploymentParams {
        IRoleRegistry roleRegistry;
        address feeRecipient;
    }

    mapping(uint256 chainId => DeploymentParams) public deploymentParams;

    function setUp() external {
        if (block.chainid == 31337) {
            deploymentParams[31337] = DeploymentParams({
                roleRegistry: IRoleRegistry(address(new MockRoleRegistry())), // Mock Registry for Local Networks
                feeRecipient: address(1)
            });
        }

        deploymentParams[8453] = DeploymentParams({
            roleRegistry: IRoleRegistry(0xBc53d3e1C82F14cf40F69bF58fA4542b55091263), // Canonical Registry for Base
            feeRecipient: 0xcBCa96091f43C024730a020E57515A18b5dC633B // Canonical Fee Recipient for Base
        });
    }

    function run() external {
        DeploymentParams memory params = deploymentParams[block.chainid];

        runGenesisDeployment(params.roleRegistry, params.feeRecipient);
    }

    function runGenesisDeployment(IRoleRegistry roleRegistry, address feeRecipient) public {
        require(address(roleRegistry) != address(0), "undefined role registry");
        require(address(feeRecipient) != address(0), "undefined fee recipient");

        vm.startBroadcast(privateKey);

        FolioDAOFeeRegistry daoFeeRegistry = new FolioDAOFeeRegistry(IRoleRegistry(roleRegistry), feeRecipient);
        FolioVersionRegistry versionRegistry = new FolioVersionRegistry(IRoleRegistry(roleRegistry));

        vm.stopBroadcast();

        require(address(daoFeeRegistry.roleRegistry()) == address(roleRegistry), "wrong role registry");
        (address feeRecipient_, , , ) = daoFeeRegistry.getFeeDetails(address(0));
        require(feeRecipient_ == feeRecipient, "wrong fee recipient");

        require(address(versionRegistry.roleRegistry()) == address(roleRegistry), "wrong role registry");

        runFollowupDeployment(daoFeeRegistry, versionRegistry);
    }

    function runFollowupDeployment(FolioDAOFeeRegistry daoFeeRegistry, FolioVersionRegistry versionRegistry) public {
        require(address(daoFeeRegistry) != address(0), "undefined dao fee registry");
        require(address(versionRegistry) != address(0), "undefined version registry");

        vm.startBroadcast(privateKey);

        address governorImplementation = address(new FolioGovernor());
        address timelockImplementation = address(new TimelockControllerUpgradeable());

        GovernanceDeployer governanceDeployer = new GovernanceDeployer(governorImplementation, timelockImplementation);
        FolioDeployer folioDeployer = new FolioDeployer(
            address(daoFeeRegistry),
            address(versionRegistry),
            governanceDeployer
        );

        vm.stopBroadcast();

        console2.log("Governance Deployer: %s", address(governanceDeployer));
        console2.log("Folio Deployer: %s", address(folioDeployer));

        require(folioDeployer.daoFeeRegistry() == address(daoFeeRegistry), "wrong dao fee registry");
        require(folioDeployer.versionRegistry() == address(versionRegistry), "wrong version registry");
        require(folioDeployer.governanceDeployer() == governanceDeployer, "wrong version registry");
        require(governanceDeployer.governorImplementation() == governorImplementation, "wrong governor implementation");
        require(governanceDeployer.timelockImplementation() == timelockImplementation, "wrong timelock implementation");
    }
}
