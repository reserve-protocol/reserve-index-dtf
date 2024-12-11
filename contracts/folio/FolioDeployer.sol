// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";

import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { FolioGovernorLib } from "@gov/FolioGovernorLib.sol";
import { Folio, IFolio } from "@src/Folio.sol";
import { FolioProxyAdmin, FolioProxy } from "@folio/FolioProxy.sol";
import { Versioned } from "@utils/Versioned.sol";

/**
 * @title FolioDeployer
 */
contract FolioDeployer is IFolioDeployer, Versioned {
    using SafeERC20 for IERC20;

    address public immutable versionRegistry;
    address public immutable daoFeeRegistry;

    address public immutable folioImplementation;

    constructor(address _daoFeeRegistry, address _versionRegistry) {
        daoFeeRegistry = _daoFeeRegistry;
        versionRegistry = _versionRegistry;

        folioImplementation = address(new Folio());
    }

    /// Deploy a raw Folio instance with previously defined roles
    /// @return The deployed Folio instance
    function deployFolio(
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        address owner,
        address[] memory tradeProposers,
        address[] memory priceCurators
    ) public returns (address) {
        // Checks

        if (basicDetails.assets.length != basicDetails.amounts.length) {
            revert FolioDeployer__LengthMismatch();
        }

        // Deploy Folio

        address folioAdmin = address(new FolioProxyAdmin(owner, versionRegistry));
        Folio folio = Folio(address(new FolioProxy(folioImplementation, folioAdmin)));

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

        return address(folio);
    }

    /// Deploy a Folio instance with brand new owner/trading governances
    /// @return folio The deployed Folio instance
    /// @return ownerGovernor The owner governor with attached timelock
    /// @return tradingGovernor The trading governor with attached timelock
    function deployGovernedFolio(
        IVotes stToken,
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        FolioGovernorLib.Params calldata ownerGovParams,
        FolioGovernorLib.Params calldata tradingGovParams,
        address[] memory priceCurators
    ) external returns (address folio, address ownerGovernor, address tradingGovernor) {
        // Deploy owner governor + timelock

        address ownerTimelock;
        (ownerGovernor, ownerTimelock) = _deployTimelockedGovernance(ownerGovParams, stToken);

        // Deploy trading governor + timelock

        address tradingTimelock;
        (tradingGovernor, tradingTimelock) = _deployTimelockedGovernance(tradingGovParams, stToken);

        // Deploy Folio

        address[] memory tradeProposers = new address[](1);
        tradeProposers[0] = tradingTimelock;
        folio = deployFolio(basicDetails, additionalDetails, ownerTimelock, tradeProposers, priceCurators);
    }

    // ==== Internal ====

    function _deployTimelockedGovernance(
        FolioGovernorLib.Params calldata govParams,
        IVotes stToken
    ) internal returns (address governor, address timelock) {
        address[] memory empty = new address[](0);
        address[] memory executors = new address[](1);

        TimelockController timelockController = new TimelockController(
            govParams.timelockDelay,
            empty,
            executors,
            address(this)
        );

        governor = FolioGovernorLib.deployGovernor(govParams, stToken, timelockController);

        timelockController.grantRole(timelockController.PROPOSER_ROLE(), address(governor));

        if (govParams.guardian != address(0)) {
            timelockController.grantRole(timelockController.CANCELLER_ROLE(), govParams.guardian);
        }

        timelockController.renounceRole(timelockController.DEFAULT_ADMIN_ROLE(), address(this));

        timelock = address(timelockController);
    }
}
