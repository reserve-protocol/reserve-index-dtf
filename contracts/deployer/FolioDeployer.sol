// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { IGovernanceDeployer } from "@interfaces/IGovernanceDeployer.sol";

import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { Folio, IFolio } from "@src/Folio.sol";
import { FolioProxyAdmin, FolioProxy } from "@folio/FolioProxy.sol";
import { Versioned } from "@utils/Versioned.sol";

/**
 * @title Folio Deployer
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 */
contract FolioDeployer is IFolioDeployer, Versioned {
    address public immutable versionRegistry;
    address public immutable daoFeeRegistry;
    address public immutable trustedFillerRegistry;

    address public immutable folioImplementation;

    IGovernanceDeployer public immutable governanceDeployer;

    constructor(
        address _daoFeeRegistry,
        address _versionRegistry,
        address _trustedFillerRegistry,
        IGovernanceDeployer _governanceDeployer
    ) {
        daoFeeRegistry = _daoFeeRegistry;
        versionRegistry = _versionRegistry;
        trustedFillerRegistry = _trustedFillerRegistry;

        folioImplementation = address(new Folio());
        governanceDeployer = _governanceDeployer;
    }

    /// Deploy a raw Folio instance with previously defined roles
    /// @return folio The deployed Folio instance
    /// @return proxyAdmin The deployed FolioProxyAdmin instance
    function deployFolio(
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        address owner,
        address[] memory auctionApprovers,
        address[] memory auctionLaunchers,
        address[] memory brandManagers,
        bool trustedFillerEnabled,
        bytes32 deploymentNonce
    ) public returns (Folio folio, address proxyAdmin) {
        require(basicDetails.assets.length == basicDetails.amounts.length, FolioDeployer__LengthMismatch());

        bytes32 deploymentSalt = keccak256(
            abi.encode(
                msg.sender,
                keccak256(
                    abi.encode(
                        basicDetails,
                        additionalDetails,
                        owner,
                        auctionApprovers,
                        auctionLaunchers,
                        brandManagers
                    )
                ),
                deploymentNonce
            )
        );

        // Deploy Folio
        proxyAdmin = address(new FolioProxyAdmin{ salt: deploymentSalt }(owner, versionRegistry));
        folio = Folio(address(new FolioProxy{ salt: deploymentSalt }(folioImplementation, proxyAdmin)));

        for (uint256 i; i < basicDetails.assets.length; i++) {
            SafeERC20.safeTransferFrom(
                IERC20(basicDetails.assets[i]),
                msg.sender,
                address(folio),
                basicDetails.amounts[i]
            );
        }

        folio.initialize(
            basicDetails,
            additionalDetails,
            msg.sender,
            daoFeeRegistry,
            trustedFillerRegistry,
            trustedFillerEnabled
        );

        // Setup Roles
        folio.grantRole(folio.DEFAULT_ADMIN_ROLE(), owner);

        for (uint256 i; i < auctionApprovers.length; i++) {
            folio.grantRole(folio.AUCTION_APPROVER(), auctionApprovers[i]);
        }
        for (uint256 i; i < auctionLaunchers.length; i++) {
            folio.grantRole(folio.AUCTION_LAUNCHER(), auctionLaunchers[i]);
        }
        for (uint256 i; i < brandManagers.length; i++) {
            folio.grantRole(folio.BRAND_MANAGER(), brandManagers[i]);
        }

        // Renounce Ownership
        folio.renounceRole(folio.DEFAULT_ADMIN_ROLE(), address(this));

        emit FolioDeployed(owner, address(folio), proxyAdmin);
    }

    // internal-only struct for stack-too-deep
    struct GovernancePair {
        address governor;
        address timelock;
    }

    /// Deploy a Folio instance with brand new owner + rebalancing governors
    /// @return folio The deployed Folio instance
    /// @return proxyAdmin The deployed FolioProxyAdmin instance
    function deployGovernedFolio(
        IVotes stToken,
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        IGovernanceDeployer.GovParams calldata ownerGovParams,
        IGovernanceDeployer.GovParams calldata tradingGovParams,
        IGovernanceDeployer.GovRoles calldata govRoles,
        bool trustedFillerEnabled,
        bytes32 deploymentNonce
    ) external returns (Folio folio, address proxyAdmin) {
        GovernancePair memory ownerGovernance;
        GovernancePair memory tradingGovernance;

        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, deploymentNonce));

        // Deploy Owner Governance
        (ownerGovernance.governor, ownerGovernance.timelock) = governanceDeployer.deployGovernanceWithTimelock(
            ownerGovParams,
            stToken,
            deploymentSalt
        );

        address[] memory auctionApprovers = govRoles.existingAuctionApprovers;

        // Deploy trading Governance if auction approvers are not provided
        if (govRoles.existingAuctionApprovers.length == 0) {
            // Flip deployment nonce to avoid timelock/governor collisions
            (tradingGovernance.governor, tradingGovernance.timelock) = governanceDeployer.deployGovernanceWithTimelock(
                tradingGovParams,
                stToken,
                ~deploymentSalt
            );

            auctionApprovers = new address[](1);
            auctionApprovers[0] = tradingGovernance.timelock;
        }

        // Deploy Folio
        (folio, proxyAdmin) = deployFolio(
            basicDetails,
            additionalDetails,
            ownerGovernance.timelock,
            auctionApprovers,
            govRoles.auctionLaunchers,
            govRoles.brandManagers,
            trustedFillerEnabled,
            deploymentSalt
        );

        emit GovernedFolioDeployed(
            address(stToken),
            address(folio),
            ownerGovernance.governor,
            ownerGovernance.timelock,
            tradingGovernance.governor,
            tradingGovernance.timelock
        );
    }
}
