// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";
import { MockRoleRegistry } from "utils/MockRoleRegistry.sol";
import { FolioDAOFeeRegistry } from "@folio/FolioDAOFeeRegistry.sol";
import { FolioVersionRegistry } from "@folio/FolioVersionRegistry.sol";
import { FolioDeployer, IERC20, IFolio } from "@deployer/FolioDeployer.sol";
import { GovernanceDeployer, IGovernanceDeployer } from "@deployer/GovernanceDeployer.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { StakingVault } from "@staking/StakingVault.sol";

string constant junkSeedPhrase = "test test test test test test test test test test test junk";

contract DeployScript is Script {
    string seedPhrase = block.chainid != 31337 ? vm.readFile(".seed") : junkSeedPhrase;
    uint256 privateKey = vm.deriveKey(seedPhrase, 0);
    address walletAddress = vm.rememberKey(privateKey);

    struct DeploymentParams {
        address rsrToken;
        // Role Registry Stuff
        address roleRegistry;
        // Fee Registry Stuff
        address folioFeeRegistry;
        address feeRecipient;
        // Version Registry Stuff
        address folioVersionRegistry;
    }

    mapping(uint256 chainId => DeploymentParams) public deploymentParams;

    function setUp() external {
        console2.log("Wallet:", walletAddress);

        if (block.chainid == 31337) {
            deploymentParams[31337] = DeploymentParams({
                rsrToken: 0xd2877702675e6cEb975b4A1dFf9fb7BAF4C91ea9, // Garbage token that just exists on Junk Address
                roleRegistry: address(new MockRoleRegistry()), // Mock Registry for Local Networks
                folioFeeRegistry: address(0),
                feeRecipient: address(1), // Burn fees for Local Networks
                folioVersionRegistry: address(0)
            });
        }

        // Base Mainnet - Canonical Parameters
        deploymentParams[8453] = DeploymentParams({
            rsrToken: 0xaB36452DbAC151bE02b16Ca17d8919826072f64a,
            roleRegistry: 0xE1eC57C8EE970280f237863910B606059e9641C9,
            folioFeeRegistry: 0x0262E3e15cCFD2221b35D05909222f1f5FCdcd80,
            feeRecipient: 0xcBCa96091f43C024730a020E57515A18b5dC633B,
            folioVersionRegistry: 0xA665b273997F70b647B66fa7Ed021287544849dB
        });

        // Ethereum Mainnet - Canonical Parameters
        deploymentParams[1] = DeploymentParams({
            rsrToken: 0x320623b8E4fF03373931769A31Fc52A4E78B5d70,
            roleRegistry: 0xE1eC57C8EE970280f237863910B606059e9641C9,
            folioFeeRegistry: 0x0262E3e15cCFD2221b35D05909222f1f5FCdcd80,
            feeRecipient: 0xcBCa96091f43C024730a020E57515A18b5dC633B,
            folioVersionRegistry: 0xA665b273997F70b647B66fa7Ed021287544849dB
        });
    }

    function run() external {
        DeploymentParams memory params = deploymentParams[block.chainid];

        require(address(params.roleRegistry) != address(0), "undefined role registry");

        runGenesisDeployment(params);
    }

    function runGenesisDeployment(DeploymentParams memory deployParams) public {
        require(address(deployParams.roleRegistry) != address(0), "undefined role registry");
        require(address(deployParams.feeRecipient) != address(0), "undefined fee recipient");

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

        vm.stopBroadcast();

        console2.log("Folio Fee Registry: %s", address(deployParams.folioFeeRegistry));
        console2.log("Folio Version Registry: %s", address(deployParams.folioVersionRegistry));

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
        require(address(deployParams.folioFeeRegistry) != address(0), "undefined dao fee registry");
        require(address(deployParams.folioVersionRegistry) != address(0), "undefined version registry");

        vm.startBroadcast(privateKey);

        address governorImplementation = address(new FolioGovernor());
        address timelockImplementation = address(new TimelockControllerUpgradeable());

        GovernanceDeployer governanceDeployer = new GovernanceDeployer(governorImplementation, timelockImplementation);
        FolioDeployer folioDeployer = new FolioDeployer(
            address(deployParams.folioFeeRegistry),
            address(deployParams.folioVersionRegistry),
            governanceDeployer
        );

        vm.stopBroadcast();

        console2.log("Governance Deployer: %s", address(governanceDeployer));
        console2.log("Folio Deployer: %s", address(folioDeployer));

        require(folioDeployer.daoFeeRegistry() == address(deployParams.folioFeeRegistry), "wrong dao fee registry");
        require(
            folioDeployer.versionRegistry() == address(deployParams.folioVersionRegistry),
            "wrong version registry"
        );
        require(folioDeployer.governanceDeployer() == governanceDeployer, "wrong version registry");
        require(governanceDeployer.governorImplementation() == governorImplementation, "wrong governor implementation");
        require(governanceDeployer.timelockImplementation() == timelockImplementation, "wrong timelock implementation");

        runJunkFolioDeployment(deployParams, folioDeployer, governanceDeployer);
    }

    function runJunkFolioDeployment(
        DeploymentParams memory deployParams,
        FolioDeployer folioDeployer,
        GovernanceDeployer governanceDeployer
    ) public {
        // Deploys an unusable Folio in order to verify it using the scripts.

        vm.startBroadcast(privateKey);

        governanceDeployer.deployGovernedStakingToken(
            "vlJunk",
            "vlJUNK",
            IERC20(deployParams.rsrToken),
            IGovernanceDeployer.GovParams({
                votingDelay: 1,
                votingPeriod: 1 hours,
                proposalThreshold: 0.0001e18,
                quorumPercent: 1,
                timelockDelay: 1 hours,
                guardians: new address[](0)
            }),
            bytes32(0)
        );

        address[] memory assets = new address[](1);
        assets[0] = deployParams.rsrToken;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        IERC20(deployParams.rsrToken).approve(address(folioDeployer), 1);
        folioDeployer.deployFolio(
            IFolio.FolioBasicDetails({
                name: "Junk",
                symbol: "JUNK",
                assets: assets,
                amounts: amounts,
                initialShares: 1e18
            }),
            IFolio.FolioAdditionalDetails({
                auctionDelay: 1,
                auctionLength: 1 weeks,
                feeRecipients: new IFolio.FeeRecipient[](0),
                tvlFee: 0,
                mintFee: 0,
                mandate: ""
            }),
            address(1),
            new address[](0),
            new address[](0),
            new address[](0),
            bytes32(0)
        );

        vm.stopBroadcast();
    }
}
