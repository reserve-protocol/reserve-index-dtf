// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { IReserveOptimisticGovernorDeployer } from "@reserve-protocol/reserve-governor/contracts/interfaces/IDeployer.sol";
import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";

import { Folio, IFolio } from "@src/Folio.sol";
import { FolioProxyAdmin, FolioProxy } from "@folio/FolioProxy.sol";
import { AUCTION_LAUNCHER, BRAND_MANAGER, DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER, DEFAULT_REWARD_PERIOD, DEFAULT_UNSTAKING_DELAY } from "@utils/Constants.sol";
import { Versioned } from "@utils/Versioned.sol";

/**
 * @title Folio Deployer
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 */
contract FolioDeployer is IFolioDeployer, Versioned {
    address public immutable daoFeeRegistry;
    address public immutable versionRegistry;
    address public immutable trustedFillerRegistry;
    address public immutable optimisticGovernorDeployer;
    
    address public immutable folioImplementation;

    constructor(
        address _daoFeeRegistry,
        address _versionRegistry,
        address _trustedFillerRegistry,
        address _optimisticGovernorDeployer
    ) {
        daoFeeRegistry = _daoFeeRegistry;
        versionRegistry = _versionRegistry;
        trustedFillerRegistry = _trustedFillerRegistry;
        optimisticGovernorDeployer = _optimisticGovernorDeployer;

        folioImplementation = address(new Folio()); // TODO pass-in?
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
    ) public returns (address folio, address proxyAdmin) {
        require(basicDetails.assets.length == basicDetails.amounts.length, FolioDeployer__LengthMismatch());

        bytes32 deploymentSalt = keccak256(
            abi.encode(
                msg.sender,
                keccak256(
                    abi.encode(
                        basicDetails,
                        additionalDetails,
                        folioFlags,
                        owner,
                        basketManagers,
                        auctionLaunchers,
                        brandManagers
                    )
                ),
                deploymentNonce
            )
        );

        // Deploy Folio
        proxyAdmin = address(new FolioProxyAdmin{ salt: deploymentSalt }(owner, versionRegistry));
        folio = address(new FolioProxy{ salt: deploymentSalt }(folioImplementation, proxyAdmin));

        for (uint256 i; i < basicDetails.assets.length; i++) {
            SafeERC20.safeTransferFrom(
                IERC20(basicDetails.assets[i]),
                msg.sender,
                address(folio),
                basicDetails.amounts[i]
            );
        }

        Folio(folio).initialize(
            basicDetails,
            additionalDetails,
            IFolio.FolioRegistryIndex({ daoFeeRegistry: daoFeeRegistry, trustedFillerRegistry: trustedFillerRegistry }),
            folioFlags,
            msg.sender
        );

        // Setup Roles
        Folio(folio).grantRole(DEFAULT_ADMIN_ROLE, owner);

        for (uint256 i; i < basketManagers.length; i++) {
            Folio(folio).grantRole(REBALANCE_MANAGER, basketManagers[i]);
        }
        for (uint256 i; i < auctionLaunchers.length; i++) {
            Folio(folio).grantRole(AUCTION_LAUNCHER, auctionLaunchers[i]);
        }
        for (uint256 i; i < brandManagers.length; i++) {
            Folio(folio).grantRole(BRAND_MANAGER, brandManagers[i]);
        }

        // Renounce Ownership
        if (owner != address(this)) {
            Folio(folio).renounceRole(DEFAULT_ADMIN_ROLE, address(this));
        }

        emit FolioDeployed(owner, folio, proxyAdmin);
    }

    /// Deploy a Folio instance with brand new owner + trading governors
    /// @param govRoles.existingBasketManagers Pass empty array to setup optimistic governance as REBALANCE_MANAGER
    /// @param govParams.underlying Pass address(0) to use vlDTF config
    /// @return stToken The deployed StakingVault address
    /// @return folio The deployed Folio instance
    /// @return proxyAdmin The deployed FolioProxyAdmin instance
    /// @return governor The deployed optimistic governor
    /// @return timelock The deployed optimistic timelock
    /// @return selectorRegistry The deployed optimistic selector registry
    function deployGovernedFolio(
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        IFolio.FolioFlags calldata folioFlags,
        GovParams calldata govParams,
        GovRoles calldata govRoles,
        bytes32 deploymentNonce
    )
        external
        returns (
            address stToken,
            address folio,
            address proxyAdmin,
            address governor,
            address timelock,
            address selectorRegistry
        )
    {
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

        // Deploy StakingVault, Governor, Timelock, Selector Registry
        {
            IReserveOptimisticGovernorDeployer.DeploymentParams memory deploymentParams = IReserveOptimisticGovernorDeployer.DeploymentParams({
                optimisticParams: govParams.optimisticParams,
                standardParams: govParams.standardParams,
                selectorData: govParams.optimisticSelectorData,
                optimisticProposers: govParams.optimisticProposers,
                guardians: govParams.guardians,
                timelockDelay: govParams.timelockDelay,
                underlying: IERC20Metadata(folio),
                rewardTokens: new address[](0),
                rewardHalfLife: DEFAULT_REWARD_PERIOD,
                unstakingDelay: DEFAULT_UNSTAKING_DELAY
            });

            // non-vlDTF config
            if (govParams.underlying != address(0)) {
                deploymentParams.underlying = IERC20Metadata(govParams.underlying);

                deploymentParams.rewardTokens = new address[](1);
                deploymentParams.rewardTokens[0] = folio;
            }

            (stToken, governor, timelock, selectorRegistry) = IReserveOptimisticGovernorDeployer(optimisticGovernorDeployer).deploy(
                deploymentParams,
                deploymentSalt
            );
        }

        // If no basket managers are provided, configure timelock as REBALANCE_MANAGER
        if (govRoles.existingBasketManagers.length == 0) {
            Folio(folio).grantRole(REBALANCE_MANAGER, timelock);
        }

        // Swap Folio owner
        Folio(folio).grantRole(DEFAULT_ADMIN_ROLE, timelock);
        Folio(folio).renounceRole(DEFAULT_ADMIN_ROLE, address(this));

        // Swap proxyAdmin owner
        FolioProxyAdmin(proxyAdmin).transferOwnership(timelock);

        emit GovernedFolioDeployed(
            stToken,
            folio,
            governor,
            timelock,
            governor,
            timelock
        );
    }
}
