// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { TrustedFillerRegistry } from "@reserve-protocol/trusted-fillers/contracts/TrustedFillerRegistry.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";
import { MockRoleRegistry } from "utils/MockRoleRegistry.sol";
import { FolioDAOFeeRegistry } from "@folio/FolioDAOFeeRegistry.sol";
import { FolioVersionRegistry } from "@folio/FolioVersionRegistry.sol";
import { FolioDeployer, IERC20, IFolio } from "@deployer/FolioDeployer.sol";
import { GovernanceDeployer, IGovernanceDeployer } from "@deployer/GovernanceDeployer.sol";
import { CowSwapFiller } from "@reserve-protocol/trusted-fillers/contracts/fillers/cowswap/CowSwapFiller.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { StakingVault } from "@staking/StakingVault.sol";

string constant junkSeedPhrase = "test test test test test test test test test test test junk";

struct DeploymentParams {
    // Role Registry Stuff
    address roleRegistry;
    // Fee Registry Stuff
    address folioFeeRegistry;
    address feeRecipient;
    // Version Registry Stuff
    address folioVersionRegistry;
    // Trusted Filler Stuff
    address trustedFillerRegistry;
}

enum DeploymentMode {
    Production,
    Testing
}

contract DeployScript is Script {
    string seedPhrase = block.chainid != 31337 ? vm.readFile(".seed") : junkSeedPhrase;
    uint256 privateKey = vm.deriveKey(seedPhrase, 0);
    address walletAddress = vm.rememberKey(privateKey);

    mapping(uint256 chainId => DeploymentParams) public deploymentParams;

    // Deployment Mode: Production or Testing
    // Change this before deployment!
    DeploymentMode public deploymentMode = DeploymentMode.Testing;

    function setUp() external {
        console2.log("Chain:", block.chainid);
        console2.log("Wallet:", walletAddress);

        if (block.chainid == 31337) {
            deploymentParams[31337] = DeploymentParams({
                roleRegistry: address(new MockRoleRegistry()), // Mock Registry for Local Networks
                folioFeeRegistry: address(0),
                feeRecipient: address(1), // Burn fees for Local Networks
                folioVersionRegistry: address(0),
                trustedFillerRegistry: address(0)
            });
        }

        if (deploymentMode == DeploymentMode.Production) {
            console2.log("Deployment Mode: Production");
        } else {
            console2.log("Deployment Mode: Testing");
        }

        if (deploymentMode == DeploymentMode.Production) {
            // Base Mainnet - Canonical Parameters
            deploymentParams[8453] = DeploymentParams({
                roleRegistry: 0xE1eC57C8EE970280f237863910B606059e9641C9,
                folioFeeRegistry: 0x0262E3e15cCFD2221b35D05909222f1f5FCdcd80,
                feeRecipient: 0xcBCa96091f43C024730a020E57515A18b5dC633B,
                folioVersionRegistry: 0xA665b273997F70b647B66fa7Ed021287544849dB,
                trustedFillerRegistry: address(0) // TODO
            });

            // Ethereum Mainnet - Canonical Parameters
            deploymentParams[1] = DeploymentParams({
                roleRegistry: 0xE1eC57C8EE970280f237863910B606059e9641C9,
                folioFeeRegistry: 0x0262E3e15cCFD2221b35D05909222f1f5FCdcd80,
                feeRecipient: 0xcBCa96091f43C024730a020E57515A18b5dC633B,
                folioVersionRegistry: 0xA665b273997F70b647B66fa7Ed021287544849dB,
                trustedFillerRegistry: address(0) // TODO
            });

            // BNB Smart Chain Mainnet - Canonical Parameters
            deploymentParams[56] = DeploymentParams({
                roleRegistry: 0xE1eC57C8EE970280f237863910B606059e9641C9,
                folioFeeRegistry: 0xF5733751C0b6fFa63ddb2e3EBe98FBBB691c399E,
                feeRecipient: 0xcBCa96091f43C024730a020E57515A18b5dC633B,
                folioVersionRegistry: 0x79A4E963378AE34fC6c796a24c764322fC6c9390,
                trustedFillerRegistry: address(0) // TODO
            });
        } else {
            // Base Mainnet - Testing Parameters
            deploymentParams[8453] = DeploymentParams({
                roleRegistry: 0x100E0eFDd7a4f67825E1BE5f0493F8D2AEAc00bb,
                folioFeeRegistry: 0x6Acb6F241d5Ca0A048dA3d324C06B98f237EBD7b,
                feeRecipient: 0xD4fda2C612dDc8822206446C81927936A63368E5,
                folioVersionRegistry: 0x135437333990f799293F6AD19fE45032Ba68285e,
                trustedFillerRegistry: 0x279ccF56441fC74f1aAC39E7faC165Dec5A88B3A
            });

            // BNB Smart Chain Mainnet - Testing Parameters
            deploymentParams[56] = DeploymentParams({
                roleRegistry: 0xCB061c96Ff76E027ea99F73ddEe9108Dd6F0c212,
                folioFeeRegistry: 0x91bc364B47992981a7a05C22c3F48b67De8aA61C,
                feeRecipient: 0xD4fda2C612dDc8822206446C81927936A63368E5,
                folioVersionRegistry: 0xA29A30307ff1ff2a071E74Ba7d07c59a37b46D56,
                trustedFillerRegistry: 0xdBd9C5a83A3684E80D51fd1c00Af4A1fbfE03D14
            });
        }
    }

    function run() external {
        DeploymentParams memory params = deploymentParams[block.chainid];

        require(address(params.roleRegistry) != address(0), "Deployer: Role Registry Required");
        require(address(params.feeRecipient) != address(0), "Deployer: Fee Recipient Required");

        runGenesisDeployment(params);
    }

    function runGenesisDeployment(DeploymentParams memory deployParams) public {
        console2.log("Running Genesis Deployment...");
        vm.startBroadcast(privateKey);

        if (deployParams.folioFeeRegistry == address(0)) {
            deployParams.folioFeeRegistry = address(
                new FolioDAOFeeRegistry(IRoleRegistry(deployParams.roleRegistry), deployParams.feeRecipient)
            );

            (address feeRecipient_, , , ) = FolioDAOFeeRegistry(deployParams.folioFeeRegistry).getFeeDetails(
                address(0)
            );
            require(feeRecipient_ == deployParams.feeRecipient, "wrong fee recipient");
        }

        if (deployParams.folioVersionRegistry == address(0)) {
            deployParams.folioVersionRegistry = address(
                new FolioVersionRegistry(IRoleRegistry(deployParams.roleRegistry))
            );
        }

        if (deployParams.trustedFillerRegistry == address(0)) {
            deployParams.trustedFillerRegistry = address(new TrustedFillerRegistry(deployParams.roleRegistry));
        }

        vm.stopBroadcast();

        console2.log("Folio Fee Registry: %s", address(deployParams.folioFeeRegistry));
        console2.log("Folio Version Registry: %s", address(deployParams.folioVersionRegistry));
        console2.log("Trusted Filler Registry: %s", address(deployParams.trustedFillerRegistry));

        require(
            address(FolioDAOFeeRegistry(deployParams.folioFeeRegistry).roleRegistry()) == deployParams.roleRegistry,
            "wrong role registry"
        );
        require(
            address(FolioVersionRegistry(deployParams.folioVersionRegistry).roleRegistry()) ==
                deployParams.roleRegistry,
            "wrong role registry"
        );

        runFollowupDeployment(deployParams);
    }

    function runFollowupDeployment(DeploymentParams memory deployParams) public {
        console2.log("Running Followup Deployment...");

        require(deployParams.folioFeeRegistry != address(0), "undefined dao fee registry");
        require(deployParams.folioVersionRegistry != address(0), "undefined version registry");
        require(deployParams.trustedFillerRegistry != address(0), "undefined trusted filler registry");

        vm.startBroadcast(privateKey);

        address governorImplementation = address(new FolioGovernor());
        address timelockImplementation = address(new TimelockControllerUpgradeable());

        GovernanceDeployer governanceDeployer = new GovernanceDeployer(governorImplementation, timelockImplementation);
        FolioDeployer folioDeployer = new FolioDeployer(
            deployParams.folioFeeRegistry,
            deployParams.folioVersionRegistry,
            deployParams.trustedFillerRegistry,
            governanceDeployer
        );

        CowSwapFiller cowSwapFiller = new CowSwapFiller();

        if (deploymentMode == DeploymentMode.Testing) {
            // For testing, we can set the filler in the registry directly
            TrustedFillerRegistry(deployParams.trustedFillerRegistry).addTrustedFiller(cowSwapFiller);
        }

        vm.stopBroadcast();

        console2.log("Governance Deployer: %s", address(governanceDeployer));
        console2.log("Folio Deployer: %s", address(folioDeployer));
        console2.log("CowSwap Filler: %s", address(cowSwapFiller));

        require(folioDeployer.daoFeeRegistry() == deployParams.folioFeeRegistry, "wrong dao fee registry");
        require(folioDeployer.versionRegistry() == deployParams.folioVersionRegistry, "wrong version registry");
        require(folioDeployer.governanceDeployer() == governanceDeployer, "wrong version registry");
        require(folioDeployer.trustedFillerRegistry() == deployParams.trustedFillerRegistry, "wrong filler registry");
        require(governanceDeployer.governorImplementation() == governorImplementation, "wrong governor implementation");
        require(governanceDeployer.timelockImplementation() == timelockImplementation, "wrong timelock implementation");
    }
}
