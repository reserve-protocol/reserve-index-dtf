// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";

import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { Folio, IFolio } from "@src/Folio.sol";
import { FolioProxyAdmin, FolioProxy } from "@deployer/FolioProxy.sol";
import { Versioned } from "@utils/Versioned.sol";

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

        address folioAdmin = address(new FolioProxyAdmin(owner, versionRegistry)); // TODO switch to UUPS?
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
    /// @return folio_ The deployed Folio instance
    /// @return ownerGovernor_ The owner governor with attached timelock
    /// @return tradingGovernor_ The trading governor with attached timelock
    function deployFolioWithGovernance(
        IVotes stToken,
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        GovernanceParams calldata ownerGovParams,
        GovernanceParams calldata tradingGovParams,
        address[] memory priceCurators
    ) external returns (address folio_, address ownerGovernor_, address tradingGovernor_) {
        // Deploy governances and timelocks

        (address ownerGovernor, address ownerTimelock) = _deployTimelockedGovernance(stToken, ownerGovParams);

        (address tradingGovernor, address tradingTimelock) = _deployTimelockedGovernance(stToken, tradingGovParams);
        address[] memory tradeProposers = new address[](1);
        tradeProposers[0] = tradingTimelock;

        // Deploy Folio

        folio_ = deployFolio(basicDetails, additionalDetails, ownerTimelock, tradeProposers, priceCurators);

        return (folio_, ownerGovernor, tradingGovernor);
    }

    /// === Internal ===

    function _deployTimelockedGovernance(
        IVotes stToken,
        GovernanceParams calldata govParams
    ) internal returns (address governor_, address timelock_) {
        address[] memory empty = new address[](0);
        TimelockController timelock = new TimelockController(govParams.timelockDelay, empty, empty, address(this));

        FolioGovernor governor = new FolioGovernor(
            stToken,
            timelock,
            govParams.votingDelay,
            govParams.votingPeriod,
            govParams.proposalThreshold,
            govParams.quorumPercent
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0)); // grant executor to everyone
        // TODO no cancellers?

        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        return (address(governor), address(timelock));
    }
}
