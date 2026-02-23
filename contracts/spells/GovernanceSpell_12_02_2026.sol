// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IReserveOptimisticGovernorDeployer } from "@reserve-protocol/reserve-governor/contracts/interfaces/IDeployer.sol";
import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";

import { Folio } from "@src/Folio.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER, CANCELLER_ROLE, DEFAULT_REWARD_PERIOD, DEFAULT_UNSTAKING_DELAY } from "@utils/Constants.sol";

bytes32 constant VERSION_1_0_0 = keccak256("1.0.0");

interface IFolioGovernor is IGovernor {
    function token() external view returns (address);
    function timelock() external view returns (address);
    function quorumNumerator() external view returns (uint256);
    function quorumDenominator() external view returns (uint256);
}

interface IStakingVault is IERC5805, IERC4626 {
    function owner() external view returns (address);
}

interface IVersioned {
    function version() external view returns (string memory);
}

/**
 * @title GovernanceSpell_12_02_2026
 * @author akshatmittal, julianmrodri, tbrent
 * @notice Optimistic governance upgrade spell for DTFs
 *
 * Three use-cases:
 *   A. vlDTF: NEW StakingVault + NEW governance (2-steps)
 *     1. deployGovernance(vlDTF=false): deploy NEW governor/timelock on NEW vlDTF staking vault
 *     2. castTransferRoles(): transfer Folio roles to NEW timelock
 *   B. vlToken: EXISTING StakingVault + NEW governance (2-steps)
 *     1. deployGovernance(vlDTF=true): deploy NEW governor/timelock on EXISTING staking vault
 *     2. castTransferRoles(): transfer Folio roles to NEW timelock
 *   C. Join pre-existing vlToken governance: EXISTING StakingVault + EXISTING governance (1-step)
 *     1. castTransferRoles(): transfer Folio roles to EXISTING timelock
 *
 * `deployGovernance()` should be executed permissionlessly in advance to prep the `castTransferRoles()` spell cast.
 *
 * In case (A), wait to cast `castTransferRoles()` until the new staking vault is secure (has enough deposits).
 *
 * In case (B), wait to cast `castTransferRoles()` until the staking vault's owner is transferred to the new timelock.
 */
contract GovernanceSpell_12_02_2026 {
    error UpgradeError(uint256 code);

    event NewGovernanceDeployment(NewDeployment newDeployment);

    struct NewDeployment {
        address newStakingVault;
        address newGovernor;
        address newTimelock;
        address newSelectorRegistry;
    }

    IReserveOptimisticGovernorDeployer public immutable governorDeployer;

    constructor(IReserveOptimisticGovernorDeployer _governorDeployer) {
        require(keccak256(bytes(IVersioned(address(_governorDeployer)).version())) == VERSION_1_0_0, UpgradeError(0));

        governorDeployer = _governorDeployer;
    }

    /// Deploy a new governor/timelock
    /// @dev Not a spell; can be executed permissionlessly in advance
    function deployGovernance(
        Folio folio,
        IFolioGovernor oldGovernor,
        uint48 voteExtension,
        IReserveOptimisticGovernor.OptimisticGovernanceParams memory optimisticParams,
        IOptimisticSelectorRegistry.SelectorData[] memory selectorData,
        address[] memory optimisticProposers,
        address[] memory guardians,
        bool vlDTF,
        bytes32 deploymentNonce
    ) public returns (NewDeployment memory newDeployment) {
        address oldTimelock = oldGovernor.timelock();

        // `oldGovernor.timelock()` MUST be the Folio's owner timelock, not trading timelock
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, oldTimelock), UpgradeError(36));

        IReserveOptimisticGovernorDeployer.BaseDeploymentParams memory baseDeployParams;
        {
            // Optimistic governance params
            baseDeployParams.optimisticParams = optimisticParams;

            // Standard governance params
            baseDeployParams.standardParams = _deriveStandardParams(oldGovernor, voteExtension);

            // Optimistic whitelists
            baseDeployParams.selectorData = selectorData;
            baseDeployParams.optimisticProposers = optimisticProposers;

            // Guardians
            _validateGuardians(oldTimelock, guardians);
            baseDeployParams.guardians = guardians;

            // Timelock delay
            uint256 minDelay = TimelockController(payable(oldTimelock)).getMinDelay();
            require(minDelay != 0, UpgradeError(21));
            baseDeployParams.timelockDelay = minDelay;
        }

        if (vlDTF) {
            // deploy NEW ReserveOptimisticGovernor + TimelockControllerOptimistic on NEW vlDTF StakingVault

            IReserveOptimisticGovernorDeployer.NewStakingVaultParams
                memory newStakingVaultParams = IReserveOptimisticGovernorDeployer.NewStakingVaultParams({
                    underlying: IERC20Metadata(address(folio)),
                    rewardTokens: new address[](0),
                    rewardHalfLife: DEFAULT_REWARD_PERIOD,
                    unstakingDelay: DEFAULT_UNSTAKING_DELAY
                });

            (
                newDeployment.newStakingVault,
                newDeployment.newGovernor,
                newDeployment.newTimelock,
                newDeployment.newSelectorRegistry
            ) = governorDeployer.deployWithNewStakingVault(baseDeployParams, newStakingVaultParams, deploymentNonce);

            require(IStakingVault(newDeployment.newStakingVault).asset() == address(folio), UpgradeError(26));
            require(
                IStakingVault(newDeployment.newStakingVault).owner() == newDeployment.newTimelock,
                UpgradeError(27)
            );
        } else {
            // deploy NEW ReserveOptimisticGovernor + TimelockControllerOptimistic on EXISTING staking vault

            (
                newDeployment.newStakingVault,
                newDeployment.newGovernor,
                newDeployment.newTimelock,
                newDeployment.newSelectorRegistry
            ) = governorDeployer.deployWithExistingStakingVault(baseDeployParams, oldGovernor.token(), deploymentNonce);

            require(newDeployment.newStakingVault == oldGovernor.token(), UpgradeError(30));
        }

        emit NewGovernanceDeployment(newDeployment);
    }

    /// Spell cast to finalize governance upgrade to new timelock
    /// @dev Requirements:
    ///      - Caller is owner timelock
    ///      - Self has ownership of the proxy admin
    ///      - Self has DEFAULT_ADMIN_ROLE of Folio, as the 2nd admin in addition to the owner timelock
    ///      - StakingVault of `newGovernor` is ALREADY owned by `newGovernor.timelock()`
    function castTransferRoles(
        Folio folio,
        FolioProxyAdmin folioProxyAdmin,
        IFolioGovernor oldGovernor,
        IFolioGovernor oldTradingGovernor,
        IFolioGovernor newGovernor
    ) public {
        address oldTradingTimelock = oldTradingGovernor.timelock();
        address newTimelock = newGovernor.timelock();
        require(newTimelock != address(0), UpgradeError(32));

        // confirm staking vault owner is new timelock
        require(IStakingVault(newGovernor.token()).owner() == newTimelock, UpgradeError(37));

        // confirm caller is old owner timelock
        require(msg.sender == oldGovernor.timelock(), UpgradeError(14));
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), UpgradeError(4));

        // confirm self has DEFAULT_ADMIN_ROLE
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, address(this)), UpgradeError(3));

        // rotate Folio REBALANCE_MANAGER
        require(folio.hasRole(REBALANCE_MANAGER, oldTradingTimelock), UpgradeError(16));
        folio.revokeRole(REBALANCE_MANAGER, oldTradingTimelock);
        folio.grantRole(REBALANCE_MANAGER, newTimelock);
        require(folio.getRoleMemberCount(REBALANCE_MANAGER) == 1, UpgradeError(17));
        require(folio.getRoleMember(REBALANCE_MANAGER, 0) == newTimelock, UpgradeError(18));

        // transfer proxy admin ownership
        require(folioProxyAdmin.owner() == address(this), UpgradeError(34));
        folioProxyAdmin.transferOwnership(newTimelock);
        require(folioProxyAdmin.owner() == newTimelock, UpgradeError(35));

        // rotate Folio DEFAULT_ADMIN_ROLE
        folio.revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        folio.grantRole(DEFAULT_ADMIN_ROLE, newTimelock);
        folio.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
        require(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1, UpgradeError(7));
        require(folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0) == newTimelock, UpgradeError(8));
    }

    // === Internal ===

    /// Derive standard governance params from old governor
    function _deriveStandardParams(
        IFolioGovernor oldGovernor,
        uint48 voteExtension
    ) internal view returns (IReserveOptimisticGovernor.StandardGovernanceParams memory standardParams) {
        IERC5805 oldStakingVault = IERC5805(oldGovernor.token());
        uint256 pastSupply = oldStakingVault.getPastTotalSupply(oldStakingVault.clock() - 1);

        // {tok}
        uint256 proposalThresholdWithSupply = oldGovernor.proposalThreshold();

        // D18{1} = {tok} * D18{1} / {tok}
        uint256 proposalThreshold = (proposalThresholdWithSupply * 1e18 + pastSupply - 1) / pastSupply;
        require(proposalThreshold >= 0.0001e18 && proposalThreshold <= 0.1e18, UpgradeError(13));

        uint256 quorumDenominator = oldGovernor.quorumDenominator();

        // D18{1}
        uint256 quorumNumerator = (oldGovernor.quorumNumerator() * 1e18 + quorumDenominator - 1) / quorumDenominator;
        require(quorumNumerator >= 0.01e18 && quorumNumerator <= 0.25e18, UpgradeError(19));

        standardParams = IReserveOptimisticGovernor.StandardGovernanceParams({
            votingDelay: SafeCast.toUint48(oldGovernor.votingDelay()),
            votingPeriod: SafeCast.toUint32(oldGovernor.votingPeriod()),
            voteExtension: voteExtension,
            proposalThreshold: proposalThreshold,
            quorumNumerator: quorumNumerator,
            proposalThrottleCapacity: 10
        });
    }

    /// Require `guardians` is a subset of the old timelock's CANCELLER_ROLE members
    /// @dev Does NOT confirm `guardians` is the complete set of CANCELLER_ROLE members
    function _validateGuardians(address oldTimelock, address[] memory guardians) internal view {
        require(guardians.length != 0, UpgradeError(22));

        TimelockController oldTimelockController = TimelockController(payable(oldTimelock));
        for (uint256 i; i < guardians.length; i++) {
            require(guardians[i] != address(0), UpgradeError(23));
            require(oldTimelockController.hasRole(CANCELLER_ROLE, guardians[i]), UpgradeError(24));
        }
    }
}
