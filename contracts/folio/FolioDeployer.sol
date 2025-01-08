// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";

import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { Folio, IFolio } from "@src/Folio.sol";
import { FolioProxyAdmin, FolioProxy } from "@folio/FolioProxy.sol";
import { Versioned } from "@utils/Versioned.sol";

/**
 * @title FolioDeployer
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 */
contract FolioDeployer is IFolioDeployer, Versioned {
    using SafeERC20 for IERC20;

    address public immutable versionRegistry;
    address public immutable daoFeeRegistry;

    address public immutable folioImplementation;
    address public immutable governorImplementation;
    address public immutable timelockImplementation;

    constructor(
        address _daoFeeRegistry,
        address _versionRegistry,
        address _governorImplementation,
        address _timelockImplementation
    ) {
        daoFeeRegistry = _daoFeeRegistry;
        versionRegistry = _versionRegistry;

        folioImplementation = address(new Folio());
        governorImplementation = _governorImplementation;
        timelockImplementation = _timelockImplementation;
    }

    /// Deploy a raw Folio instance with previously defined roles
    /// @return folio_ The deployed Folio instance
    /// @return folioAdmin_ The deployed FolioProxyAdmin instance
    function deployFolio(
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        address owner,
        address[] memory tradeProposers,
        address[] memory priceCurators
    ) public returns (address folio_, address folioAdmin_) {
        // Checks

        if (basicDetails.assets.length != basicDetails.amounts.length) {
            revert FolioDeployer__LengthMismatch();
        }

        // Deploy Folio

        folioAdmin_ = address(new FolioProxyAdmin(owner, versionRegistry));
        Folio folio = Folio(address(new FolioProxy(folioImplementation, folioAdmin_)));

        for (uint256 i; i < basicDetails.assets.length; i++) {
            IERC20(basicDetails.assets[i]).safeTransferFrom(msg.sender, address(folio), basicDetails.amounts[i]);
        }

        folio.initialize(basicDetails, additionalDetails, msg.sender, daoFeeRegistry);

        // Setup roles

        folio.grantRole(folio.DEFAULT_ADMIN_ROLE(), owner);

        for (uint256 i; i < tradeProposers.length; i++) {
            folio.grantRole(folio.TRADE_PROPOSER(), tradeProposers[i]);
        }

        for (uint256 i; i < priceCurators.length; i++) {
            folio.grantRole(folio.PRICE_CURATOR(), priceCurators[i]);
        }

        // Renounce adminship

        folio.renounceRole(folio.DEFAULT_ADMIN_ROLE(), address(this));

        folio_ = address(folio);
    }

    /// Deploy a Folio instance with brand new owner/trading governances
    /// @return folio The deployed Folio instance
    /// @return proxyAdmin The deployed FolioProxyAdmin instance
    /// @return ownerGovernor The owner governor with attached timelock
    /// @return tradingGovernor The trading governor with attached timelock
    function deployGovernedFolio(
        IVotes stToken,
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        IFolioDeployer.GovParams calldata ownerGovParams,
        IFolioDeployer.GovParams calldata tradingGovParams,
        address[] memory priceCurators
    ) external returns (address folio, address proxyAdmin, address ownerGovernor, address tradingGovernor) {
        // Deploy owner governor + timelock

        address ownerTimelock;
        (ownerGovernor, ownerTimelock) = _deployTimelockedGovernance(ownerGovParams, stToken);

        // Deploy trading governor + timelock

        address tradingTimelock;
        (tradingGovernor, tradingTimelock) = _deployTimelockedGovernance(tradingGovParams, stToken);

        // Deploy Folio

        address[] memory tradeProposers = new address[](1);
        tradeProposers[0] = tradingTimelock;
        (folio, proxyAdmin) = deployFolio(
            basicDetails,
            additionalDetails,
            ownerTimelock,
            tradeProposers,
            priceCurators
        );
    }

    // ==== Internal ====

    function _deployTimelockedGovernance(
        IFolioDeployer.GovParams calldata govParams,
        IVotes stToken
    ) internal returns (address governor, address timelock) {
        timelock = Clones.clone(timelockImplementation);

        governor = Clones.clone(governorImplementation);

        FolioGovernor(payable(governor)).initialize(
            stToken,
            TimelockControllerUpgradeable(payable(timelock)),
            govParams.votingDelay,
            govParams.votingPeriod,
            govParams.proposalThreshold,
            govParams.quorumPercent
        );

        address[] memory proposers = new address[](1);
        proposers[0] = governor;
        address[] memory executors = new address[](1);
        executors[0] = governor;

        TimelockControllerUpgradeable timelockController = TimelockControllerUpgradeable(payable(timelock));

        timelockController.initialize(govParams.timelockDelay, proposers, executors, address(this));

        if (govParams.guardian != address(0)) {
            timelockController.grantRole(timelockController.CANCELLER_ROLE(), govParams.guardian);
        }

        timelockController.renounceRole(timelockController.DEFAULT_ADMIN_ROLE(), address(this));
    }
}
