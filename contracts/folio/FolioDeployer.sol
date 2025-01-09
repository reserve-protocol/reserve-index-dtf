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
 * @title FolioDeployer
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
    /// @return folio_ The deployed Folio instance
    /// @return folioAdmin_ The deployed FolioProxyAdmin instance
    function deployFolio(
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        address owner,
        address[] memory tradeProposers,
        address[] memory priceCurators,
        address[] memory vibesOfficers
    ) public returns (address folio_, address folioAdmin_) {
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

        // Setup Roles
        folio.grantRole(folio.DEFAULT_ADMIN_ROLE(), owner);

        for (uint256 i; i < tradeProposers.length; i++) {
            folio.grantRole(folio.TRADE_PROPOSER(), tradeProposers[i]);
        }
        for (uint256 i; i < priceCurators.length; i++) {
            folio.grantRole(folio.PRICE_CURATOR(), priceCurators[i]);
        }
        for (uint256 i; i < vibesOfficers.length; i++) {
            folio.grantRole(folio.VIBES_OFFICER(), vibesOfficers[i]);
        }

        // Renounce Ownership
        folio.renounceRole(folio.DEFAULT_ADMIN_ROLE(), address(this));

        folio_ = address(folio);

        emit FolioDeployed(owner, folio_, folioAdmin_);
    }

    /// Deploy a Folio instance with brand new owner + trading governors
    /// @return folio The deployed Folio instance
    /// @return proxyAdmin The deployed FolioProxyAdmin instance
    /// @return ownerGovernor The owner governor with attached timelock
    /// @return ownerTimelock The owner timelock
    /// @return tradingGovernor The trading governor with attached timelock
    /// @return tradingTimelock The trading timelock
    function deployGovernedFolio(
        IVotes stToken,
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        IGovernanceDeployer.GovParams calldata ownerGovParams,
        IGovernanceDeployer.GovParams calldata tradingGovParams,
        address[] memory priceCurators,
        address[] memory vibesOfficers
    )
        external
        returns (
            address folio,
            address proxyAdmin,
            address ownerGovernor,
            address ownerTimelock,
            address tradingGovernor,
            address tradingTimelock
        )
    {
        // Deploy Owner Governance
        (ownerGovernor, ownerTimelock) = governanceDeployer.deployGovernanceWithTimelock(ownerGovParams, stToken);

        // Deploy Trading Governance
        (tradingGovernor, tradingTimelock) = governanceDeployer.deployGovernanceWithTimelock(tradingGovParams, stToken);

        // Deploy Folio
        address[] memory tradeProposers = new address[](1);
        tradeProposers[0] = tradingTimelock;
        (folio, proxyAdmin) = deployFolio(
            basicDetails,
            additionalDetails,
            ownerTimelock,
            tradeProposers,
            priceCurators,
            vibesOfficers
        );

        emit GovernedFolioDeployed(
            address(stToken),
            folio,
            ownerGovernor,
            ownerTimelock,
            tradingGovernor,
            tradingTimelock
        );
    }
}
