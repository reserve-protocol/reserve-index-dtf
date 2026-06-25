// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { IOptimisticVotes } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticVotes.sol";
import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernorDeployer } from "@reserve-protocol/reserve-governor/contracts/interfaces/IDeployer.sol";

import { Folio, IFolio } from "@src/Folio.sol";
import { FolioProxyAdmin, FolioProxy } from "@folio/FolioProxy.sol";
import { AUCTION_LAUNCHER, BRAND_MANAGER, DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER } from "@utils/Constants.sol";
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

        folioImplementation = address(new Folio());
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
        folio.grantRole(DEFAULT_ADMIN_ROLE, owner);

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
            folio.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
        }

        emit FolioDeployed(owner, address(folio), proxyAdmin);
    }

    /// Deploy a Folio instance with new Folio governance using an existing StakingVault
    /// @param stToken Existing StakingVault to use as governance token
    /// @param govRoles.existingBasketManagers Additional accounts to grant REBALANCE_MANAGER on the deployed Folio
    /// @param govParams.optimisticSelectors Selectors to allow optimistically on the deployed Folio
    /// @return folio The deployed Folio instance
    /// @return proxyAdmin The deployed FolioProxyAdmin instance
    function deployGovernedFolio(
        address stToken,
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        IFolio.FolioFlags calldata folioFlags,
        GovParams calldata govParams,
        GovRoles calldata govRoles,
        bytes32 deploymentNonce
    ) external returns (Folio folio, address proxyAdmin) {
        require(stToken != address(0), FolioDeployer__InvalidStToken());
        IOptimisticVotes(stToken).getPastOptimisticVotes(address(0), block.timestamp - 1);

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

        IReserveOptimisticGovernorDeployer.BaseDeploymentParams memory baseParams = IReserveOptimisticGovernorDeployer
            .BaseDeploymentParams({
                optimisticParams: govParams.optimisticParams,
                standardParams: govParams.standardParams,
                selectorData: _folioSelectorData(address(folio), govParams.optimisticSelectors),
                optimisticProposers: govParams.optimisticProposers,
                additionalGuardians: govParams.guardians,
                timelockDelay: govParams.timelockDelay,
                proposalThrottleCapacity: govParams.proposalThrottleCapacity
            });

        (address governor, address timelock, ) = IReserveOptimisticGovernorDeployer(optimisticGovernorDeployer)
            .deployWithExistingStakingVault(baseParams, stToken, deploymentSalt);

        // Configure Folio governance as REBALANCE_MANAGER
        folio.grantRole(REBALANCE_MANAGER, timelock);

        // Swap Folio owner
        folio.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        folio.renounceRole(DEFAULT_ADMIN_ROLE, address(this));

        // Swap proxyAdmin owner
        FolioProxyAdmin(proxyAdmin).transferOwnership(timelock);

        emit GovernedFolioDeployed(stToken, address(folio), governor, timelock, governor, timelock);
    }

    function _folioSelectorData(
        address folio,
        bytes4[] calldata selectors
    ) private pure returns (IOptimisticSelectorRegistry.SelectorData[] memory selectorData) {
        bytes4[] memory optimisticSelectors = new bytes4[](selectors.length);
        for (uint256 i; i < selectors.length; ++i) {
            optimisticSelectors[i] = selectors[i];
        }

        selectorData = new IOptimisticSelectorRegistry.SelectorData[](1);
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData({ target: folio, selectors: optimisticSelectors });
    }
}
