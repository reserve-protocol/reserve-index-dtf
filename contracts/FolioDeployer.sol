// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IFolio } from "@src/Folio.sol";
import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { IFolioVersionRegistry } from "@interfaces/IFolioVersionRegistry.sol";
import { IFolioDAOFeeRegistry } from "@interfaces/IFolioDAOFeeRegistry.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";

import { Folio } from "@src/Folio.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { FolioFactory } from "@deployer/FolioFactory.sol";
import { StakingVault } from "@staking/StakingVault.sol";

// TODO should this just be moved into the FolioFactory?
contract FolioDeployer {
    IRoleRegistry public immutable roleRegistry;

    IFolioVersionRegistry public immutable versionRegistry;

    IFolioDAOFeeRegistry public immutable daoFeeRegistry;

    address public immutable daoFeeRecipient;

    FolioFactory public immutable folioFactory;

    constructor(address _roleRegistry, address _versionRegistry, address _daoFeeRegistry, address _daoFeeRecipient) {
        roleRegistry = IRoleRegistry(_roleRegistry);
        versionRegistry = IFolioVersionRegistry(_versionRegistry);
        daoFeeRegistry = IFolioDAOFeeRegistry(_daoFeeRegistry);
        daoFeeRecipient = _daoFeeRecipient;

        folioFactory = new FolioFactory(_daoFeeRegistry, _versionRegistry);
    }

    /// Deploy a staking vault and community governor
    /// @return stToken_ A staking vault that can be used with multiple governors
    /// @return communityGovernor_ The governor that owns the staking vault
    function deployCommunityGovernor(
        string memory name,
        string memory symbol,
        IERC20 underlying,
        IFolioDeployer.FolioGovernanceParams calldata govParams
    ) external returns (address stToken_, address communityGovernor_) {
        IVotes stToken = IVotes(address(new StakingVault(name, symbol, underlying, address(0))));
        // TODO return to 4th arg

        (FolioGovernor communityGovernor, ) = _deployGovernanceWithTimelock(stToken, govParams);

        return (address(stToken), address(communityGovernor));
    }

    /// Deploy a Folio instance
    function deployFolio(
        IVotes stToken,
        IFolio.FolioBasicDetails calldata basicDetails,
        IFolio.FolioAdditionalDetails calldata additionalDetails,
        IFolioDeployer.FolioGovernanceParams calldata ownerGovParams,
        IFolioDeployer.FolioGovernanceParams calldata tradingGovParams,
        address priceCurator
    ) external returns (address folio_, address ownerGovernor_, address tradingGovernor_) {
        (FolioGovernor ownerGovernor, TimelockController ownerTimelock) = _deployGovernanceWithTimelock(
            stToken,
            ownerGovParams
        );

        (FolioGovernor tradingGovernor, TimelockController tradingTimelock) = _deployGovernanceWithTimelock(
            stToken,
            tradingGovParams
        );

        address proxyAdmin; // TODO can we read this off the Folio instead of having FolioFactory return it?
        (folio_, proxyAdmin) = folioFactory.createFolio(basicDetails, additionalDetails, address(this));
        Folio folio = Folio(folio_);

        Ownable(proxyAdmin).transferOwnership(address(ownerTimelock));

        folio.grantRole(Folio(folio).PRICE_CURATOR(), priceCurator);

        folio.grantRole(folio.TRADE_PROPOSER(), address(tradingTimelock));

        folio.grantRole(folio.PRICE_CURATOR(), address(ownerTimelock));
        folio.grantRole(folio.TRADE_PROPOSER(), address(ownerTimelock));
        folio.grantRole(folio.DEFAULT_ADMIN_ROLE(), address(ownerTimelock));

        folio.renounceRole(folio.DEFAULT_ADMIN_ROLE(), address(this));

        return (folio_, address(ownerGovernor), address(tradingGovernor));
    }

    // === Internal ===

    function _deployGovernanceWithTimelock(
        IVotes stToken,
        IFolioDeployer.FolioGovernanceParams calldata govParams
    ) internal returns (FolioGovernor governor, TimelockController timelock) {
        address[] memory empty = new address[](0);
        timelock = new TimelockController(govParams.timelockDelay, empty, empty, address(this));

        governor = new FolioGovernor(
            stToken,
            timelock,
            govParams.votingDelay,
            govParams.votingPeriod,
            govParams.proposalThreshold,
            govParams.quorumPercent
        );

        timelock.grantRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(this));
        // TODO no cancellers?

        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));
    }
}
