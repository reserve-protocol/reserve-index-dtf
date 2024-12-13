// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";
import { MockRoleRegistry } from "utils/MockRoleRegistry.sol";
import { FolioDAOFeeRegistry } from "@folio/FolioDAOFeeRegistry.sol";
import { FolioVersionRegistry } from "@folio/FolioVersionRegistry.sol";
import { FolioDeployer } from "@folio/FolioDeployer.sol";
import { GovernanceDeployer } from "@gov/GovernanceDeployer.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";

contract DeployScript is Script {
    string seedPhrase = vm.readFile(".seed");
    uint256 privateKey = vm.deriveKey(seedPhrase, 0);
    address walletAddress = vm.rememberKey(privateKey);

    /// @dev This function should only be used during testing and local deployments!
    function run() external {
        MockRoleRegistry roleRegistry = new MockRoleRegistry();

        runGenesisDeployment(IRoleRegistry(address(roleRegistry)), address(1));
    }

    function runGenesisDeployment(IRoleRegistry roleRegistry, address feeRecipient) public {
        require(address(roleRegistry) != address(0), "undefined role registry");
        require(address(feeRecipient) != address(0), "undefined fee recipient");

        vm.startBroadcast(privateKey);

        FolioDAOFeeRegistry daoFeeRegistry = new FolioDAOFeeRegistry(IRoleRegistry(roleRegistry), feeRecipient);
        FolioVersionRegistry versionRegistry = new FolioVersionRegistry(IRoleRegistry(roleRegistry));

        vm.stopBroadcast();

        require(address(daoFeeRegistry.roleRegistry()) == address(roleRegistry), "wrong role registry");
        (address feeRecipient_, , ) = daoFeeRegistry.getFeeDetails(address(0));
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

        FolioDeployer folioDeployer = new FolioDeployer(
            address(daoFeeRegistry),
            address(versionRegistry),
            governorImplementation,
            timelockImplementation
        );
        GovernanceDeployer governanceDeployer = new GovernanceDeployer(governorImplementation, timelockImplementation);

        console.log("Folio Deployer: %s", address(folioDeployer));
        console.log("Governance Deployer: %s", address(governanceDeployer));

        vm.stopBroadcast();

        require(folioDeployer.daoFeeRegistry() == address(daoFeeRegistry), "wrong dao fee registry");
        require(folioDeployer.versionRegistry() == address(versionRegistry), "wrong version registry");
        require(folioDeployer.governorImplementation() == governorImplementation, "wrong governor implementation");
        require(folioDeployer.timelockImplementation() == timelockImplementation, "wrong timelock implementation");

        require(governanceDeployer.governorImplementation() == governorImplementation, "wrong governor implementation");
        require(governanceDeployer.timelockImplementation() == timelockImplementation, "wrong timelock implementation");
    }
}
