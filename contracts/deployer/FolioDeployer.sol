// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { IGovernanceDeployer } from "@interfaces/IGovernanceDeployer.sol";

import { Folio, IFolio } from "@src/Folio.sol";
import { FolioProxyAdmin, FolioProxy } from "@folio/FolioProxy.sol";
import { AUCTION_LAUNCHER, BRAND_MANAGER, DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER } from "@utils/Constants.sol";
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
        IFolio.FolioFlags calldata folioFlags,
        address owner,
        address[] memory basketManagers,
        address[] memory auctionLaunchers,
        address[] memory brandManagers,
        bytes32 deploymentNonce
    ) public returns (Folio folio, address proxyAdmin) {
        require(basicDetails.assets.length == basicDetails.amounts.length, FolioDeployer__LengthMismatch());

        bytes32 deploymentSalt = keccak256(
            abi.encode(
                msg.sender,
                keccak256(
                    abi.encode(basicDetails, additionalDetails, owner, basketManagers, auctionLaunchers, brandManagers)
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
            IFolio.FolioRegistryIndex({ daoFeeRegistry: daoFeeRegistry, trustedFillerRegistry: trustedFillerRegistry }),
            folioFlags,
            msg.sender
        );

        // Setup Roles
        folio.grantRole(folio.DEFAULT_ADMIN_ROLE(), owner);

        for (uint256 i; i < basketManagers.length; i++) {
            folio.grantRole(REBALANCE_MANAGER, basketManagers[i]);
        }
        for (uint256 i; i < auctionLaunchers.length; i++) {
            folio.grantRole(AUCTION_LAUNCHER, auctionLaunchers[i]);
        }
        for (uint256 i; i < brandManagers.length; i++) {
            folio.grantRole(BRAND_MANAGER, brandManagers[i]);
        }

        // Renounce Ownership
        if (owner != address(this)) {
            folio.renounceRole(folio.DEFAULT_ADMIN_ROLE(), address(this));
        }

        emit FolioDeployed(owner, address(folio), proxyAdmin);
    }

    // internal-only struct for stack-too-deep
    struct GovernancePair {
        address governor;
        address timelock;
    }

    /// Deploy a Folio instance with brand new owner + trading governors
    /// @param stToken The staking vault for the staking token, pass address(0) to self-govern
    /// @param ownerGovParams Re-used for stToken when self-governed
    /// @param govRoles.existingBasketManagers Pass empty array to deploy a trading governor
    /// @return folio The deployed Folio instance
    /// @return proxyAdmin The deployed FolioProxyAdmin instance
    function deployGovernedFolio(
        IVotes stToken,
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        IFolio.FolioFlags calldata folioFlags,
        IGovernanceDeployer.GovParams calldata ownerGovParams,
        IGovernanceDeployer.GovParams calldata tradingGovParams,
        GovRoles calldata govRoles,
        bytes32 deploymentNonce
    ) external returns (Folio folio, address proxyAdmin) {
        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, deploymentNonce));

        // Deploy Folio
        (folio, proxyAdmin) = deployFolio(
            basicDetails,
            additionalDetails,
            folioFlags,
            address(this), // temporary owner
            govRoles.existingBasketManagers,
            govRoles.auctionLaunchers,
            govRoles.brandManagers,
            deploymentSalt
        );

        GovernancePair[] memory govPairs = new GovernancePair[](2);
        // govPairs[0] is owner governor
        // govPairs[1] is trading governor

        if (address(stToken) == address(0)) {
            // Self-govern
            (stToken, govPairs[0].governor, govPairs[0].timelock) = governanceDeployer.deployGovernedStakingToken(
                string(abi.encodePacked("Vote-Locked ", basicDetails.name)),
                string(abi.encodePacked("VL", basicDetails.symbol)),
                folio,
                ownerGovParams,
                deploymentSalt
            );
        } else {
            // Deploy separate owner governance
            (govPairs[0].governor, govPairs[0].timelock) = governanceDeployer.deployGovernanceWithTimelock(
                ownerGovParams,
                stToken,
                deploymentSalt
            );
        }

        // Deploy trading Governance if basket managers are not provided
        if (govRoles.existingBasketManagers.length == 0) {
            // Invert deployment nonce to avoid timelock/governor collisions
            (govPairs[1].governor, govPairs[1].timelock) = governanceDeployer.deployGovernanceWithTimelock(
                tradingGovParams,
                stToken,
                ~deploymentSalt
            );

            folio.grantRole(REBALANCE_MANAGER, govPairs[1].timelock);
        }

        // Swap Folio owner
        folio.grantRole(DEFAULT_ADMIN_ROLE, govPairs[0].timelock);
        folio.renounceRole(DEFAULT_ADMIN_ROLE, address(this));

        // Swap proxyAdmin owner
        FolioProxyAdmin(payable(proxyAdmin)).transferOwnership(govPairs[0].timelock);

        emit GovernedFolioDeployed(
            address(stToken),
            address(folio),
            govPairs[0].governor,
            govPairs[0].timelock,
            govPairs[1].governor,
            govPairs[1].timelock
        );
    }
}
