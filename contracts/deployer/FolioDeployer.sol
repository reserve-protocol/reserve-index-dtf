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
    using SafeERC20 for IERC20;

    address public immutable versionRegistry;
    address public immutable daoFeeRegistry;

    address public immutable folioImplementation;

    IGovernanceDeployer public immutable governanceDeployer;

    constructor(address _daoFeeRegistry, address _versionRegistry, IGovernanceDeployer _governanceDeployer) {
        daoFeeRegistry = _daoFeeRegistry;
        versionRegistry = _versionRegistry;

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
        bytes32 deploymentNonce
    ) public returns (Folio folio, address proxyAdmin) {
        require(basicDetails.assets.length == basicDetails.amounts.length, FolioDeployer__LengthMismatch());

        bytes32 deploymentSalt = keccak256(
            abi.encode(
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
            IERC20(basicDetails.assets[i]).safeTransferFrom(msg.sender, address(folio), basicDetails.amounts[i]);
        }

        folio.initialize(basicDetails, additionalDetails, msg.sender, daoFeeRegistry);

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

    /// Deploy a Folio instance with brand new owner + rebalancing governors
    /// @return folio The deployed Folio instance
    /// @return proxyAdmin The deployed FolioProxyAdmin instance
    /// @return ownerGovernor The owner governor with attached timelock
    /// @return ownerTimelock The owner timelock
    /// @return tradingGovernor The rebalancing governor with attached timelock
    /// @return tradingTimelock The trading timelock
    function deployGovernedFolio(
        IVotes stToken,
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        IGovernanceDeployer.GovParams calldata ownerGovParams,
        IGovernanceDeployer.GovParams calldata tradingGovParams,
        IGovernanceDeployer.GovRoles calldata govRoles,
        bytes32 deploymentNonce
    )
        external
        returns (
            Folio folio,
            address proxyAdmin,
            address ownerGovernor,
            address ownerTimelock,
            address tradingGovernor,
            address tradingTimelock
        )
    {
        // Deploy Owner Governance
        (ownerGovernor, ownerTimelock) = governanceDeployer.deployGovernanceWithTimelock(
            ownerGovParams,
            stToken,
            deploymentNonce
        );

        // Deploy Rebalancing Governance
        if (govRoles.existingAuctionApprovers.length == 0) {
            // Flip deployment nonce to avoid timelock/governor collisions
            (tradingGovernor, tradingTimelock) = governanceDeployer.deployGovernanceWithTimelock(
                tradingGovParams,
                stToken,
                ~deploymentNonce
            );

            address[] memory auctionApprovers = new address[](1);
            auctionApprovers[0] = tradingTimelock;

            // Deploy Folio
            (folio, proxyAdmin) = deployFolio(
                basicDetails,
                additionalDetails,
                ownerTimelock,
                auctionApprovers,
                govRoles.auctionLaunchers,
                govRoles.brandManagers,
                deploymentNonce
            );
        } else {
            // Deploy Folio
            (folio, proxyAdmin) = deployFolio(
                basicDetails,
                additionalDetails,
                ownerTimelock,
                govRoles.existingAuctionApprovers,
                govRoles.auctionLaunchers,
                govRoles.brandManagers,
                deploymentNonce
            );
        }

        emit GovernedFolioDeployed(
            address(stToken),
            address(folio),
            ownerGovernor,
            ownerTimelock,
            tradingGovernor,
            tradingTimelock
        );
    }
}
