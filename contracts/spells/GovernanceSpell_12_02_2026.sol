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

// TODO create in reserve-governor repo?
interface IStakingVault is IERC5805, IERC4626 {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function renounceOwnership() external;
    function setUnstakingDelay(uint256 unstakingDelay) external;
    function setRewardRatio(uint256 rewardHalfLife) external;
}

interface IVersioned {
    function version() external view returns (string memory);
}

/**
 * @title GovernanceSpell_12_02_2026
 * @author akshatmittal, julianmrodri, tbrent
 * @notice Optimistic governance upgrade spell for DTFs
 *
 * Two-part optimistic governance upgrade spell to upgrade a Folio + StakingVault to optimistic governance.
 *   A single StakingVault can govern multiple Folios.
 *   A single StakingVault can only have 1 governor/timelock that must be shared with all its Folios.
 *
 * Three intended use-cases:
 *   A. New StakingVault + Governance [2-steps]
 *     1. upgradeStakingVault(newUnderlying!=address(0)): deploy NEW staking vault attached to NEW governor/timelock
 *     2. upgradeFolio(): attach Folio to governance
 *   B. New Governance only [2-steps]
 *     1. upgradeStakingVault(newUnderlying=address(0)): attach EXISTING staking vault to NEW governor/timelock
 *     2. upgradeFolio(): attach Folio to governance
 *   C. Attach Folio to existing governance (1-step)
 *     1. upgradeFolio(): attach Folio to governance
 *
 * Callers:
 *   - upgradeStakingVault(): timelock of StakingVault
 *   - upgradeFolio(): timelock of Folio
 *
 * IMPORTANT: In case (A), wait to cast `upgradeFolio()` until the new staking vault is populated with stake.
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
    /// @dev Caller: SHOULD be StakingVault owner, but this cannot be enforced
    ///      IMPORTANT: StakingVault timelock must transfer ownership to this spell contract
    ///      and atomically execute upgradeStakingVault() without allowing other execution in between.
    /// @param optimisticSelectorData Include Folio.startRebalance.selector if optimistic rebalancing should be enabled
    /// @param optimisticProposers Use empty set to disable optimistic governance
    /// @param guardians Must be a subset of the old owner timelock's CANCELLER_ROLE members
    /// @param newUnderlying Provide address(0) to keep existing staking vault
    function upgradeStakingVault(
        IFolioGovernor stakingVaultGovernor,
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata optimisticParams,
        IOptimisticSelectorRegistry.SelectorData[] calldata optimisticSelectorData,
        address[] calldata optimisticProposers,
        address[] calldata guardians,
        address newUnderlying,
        uint48 voteExtension,
        bytes32 deploymentNonce
    ) public returns (NewDeployment memory newDeployment) {
        IStakingVault stakingVault = IStakingVault(stakingVaultGovernor.token());

        // spell contract must have ownership of old staking vault
        require(stakingVault.owner() == address(this), UpgradeError(1));

        IReserveOptimisticGovernorDeployer.BaseDeploymentParams memory baseDeployParams;
        {
            // Optimistic governance params
            baseDeployParams.optimisticParams = optimisticParams;

            // Standard governance params
            (baseDeployParams.standardParams, baseDeployParams.timelockDelay) = _deriveStandardParams(
                stakingVault,
                stakingVaultGovernor,
                voteExtension
            );

            // Optimistic whitelists
            baseDeployParams.selectorData = optimisticSelectorData;
            baseDeployParams.optimisticProposers = optimisticProposers;

            // Guardians
            _validateGuardians(stakingVaultGovernor.timelock(), guardians);
            baseDeployParams.guardians = guardians;
        }

        if (newUnderlying != address(0)) {
            // deploy NEW ReserveOptimisticGovernor + TimelockControllerOptimistic on NEW vlDTF StakingVault

            IReserveOptimisticGovernorDeployer.NewStakingVaultParams
                memory newStakingVaultParams = IReserveOptimisticGovernorDeployer.NewStakingVaultParams({
                    underlying: IERC20Metadata(newUnderlying),
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

            require(IStakingVault(newDeployment.newStakingVault).asset() == newUnderlying, UpgradeError(3));
            require(address(stakingVault) != newDeployment.newStakingVault, UpgradeError(4));

            // deprecate old StakingVault

            stakingVault.setUnstakingDelay(0);
            stakingVault.setRewardRatio(1 days);
            stakingVault.renounceOwnership();
        } else {
            // deploy NEW ReserveOptimisticGovernor + TimelockControllerOptimistic on EXISTING staking vault

            (
                newDeployment.newStakingVault,
                newDeployment.newGovernor,
                newDeployment.newTimelock,
                newDeployment.newSelectorRegistry
            ) = governorDeployer.deployWithExistingStakingVault(
                baseDeployParams,
                address(stakingVault),
                deploymentNonce
            );

            require(address(stakingVault) == newDeployment.newStakingVault, UpgradeError(5));

            // transfer StakingVault ownership to new timelock

            stakingVault.transferOwnership(newDeployment.newTimelock);
        }

        require(IStakingVault(newDeployment.newStakingVault).owner() == newDeployment.newTimelock, UpgradeError(6));

        emit NewGovernanceDeployment(newDeployment);
    }

    /// Transfer Folio ownership/roles to an already-live governance system
    /// @dev Requirements:
    ///      - Caller is owner timelock
    ///      - Self has ownership of the proxy admin
    ///      - Self has DEFAULT_ADMIN_ROLE of Folio, as the 2nd admin in addition to the owner timelock
    function upgradeFolio(Folio folio, FolioProxyAdmin folioProxyAdmin, IFolioGovernor newGovernor) public {
        address newTimelock = newGovernor.timelock();
        require(newTimelock != address(0), UpgradeError(7));

        // confirm owner of new staking vault is new timelock
        require(IStakingVault(newGovernor.token()).owner() == newTimelock, UpgradeError(8));

        // confirm Folio owners are msg.sender/self
        require(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 2, UpgradeError(9));
        address firstAdmin = folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0);
        address secondAdmin = folio.getRoleMember(DEFAULT_ADMIN_ROLE, 1);
        require(firstAdmin == address(this) || secondAdmin == address(this), UpgradeError(10));
        require(firstAdmin == msg.sender || secondAdmin == msg.sender, UpgradeError(11));

        // rotate Folio REBALANCE_MANAGERs
        uint256 rebalanceManagerCount = folio.getRoleMemberCount(REBALANCE_MANAGER);
        for (uint256 i = rebalanceManagerCount; i > 0; i--) {
            folio.revokeRole(REBALANCE_MANAGER, folio.getRoleMember(REBALANCE_MANAGER, i - 1));
        }
        folio.grantRole(REBALANCE_MANAGER, newTimelock);
        require(folio.getRoleMemberCount(REBALANCE_MANAGER) == 1, UpgradeError(12));
        require(folio.getRoleMember(REBALANCE_MANAGER, 0) == newTimelock, UpgradeError(13));

        // transfer proxy admin ownership
        require(folioProxyAdmin.owner() == address(this), UpgradeError(14));
        folioProxyAdmin.transferOwnership(newTimelock);
        require(folioProxyAdmin.owner() == newTimelock, UpgradeError(15));

        // rotate Folio DEFAULT_ADMIN_ROLE
        folio.revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        folio.grantRole(DEFAULT_ADMIN_ROLE, newTimelock);
        folio.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
        require(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1, UpgradeError(16));
        require(folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0) == newTimelock, UpgradeError(17));
    }

    // === Internal ===

    /// Derive standard governance params from old governor
    function _deriveStandardParams(
        IStakingVault stakingVault,
        IFolioGovernor oldGovernor,
        uint48 voteExtension
    )
        internal
        view
        returns (IReserveOptimisticGovernor.StandardGovernanceParams memory standardParams, uint256 timelockDelay)
    {
        uint256 pastSupply = stakingVault.getPastTotalSupply(stakingVault.clock() - 1);

        // {tok}
        uint256 proposalThresholdWithSupply = oldGovernor.proposalThreshold();

        // D18{1} = {tok} * D18{1} / {tok}
        uint256 proposalThreshold = (proposalThresholdWithSupply * 1e18 + pastSupply - 1) / pastSupply;
        require(proposalThreshold >= 0.0001e18 && proposalThreshold <= 0.1e18, UpgradeError(18));

        uint256 quorumDenominator = oldGovernor.quorumDenominator();

        // D18{1}
        uint256 quorumNumerator = (oldGovernor.quorumNumerator() * 1e18 + quorumDenominator - 1) / quorumDenominator;
        require(quorumNumerator >= 0.01e18 && quorumNumerator <= 0.25e18, UpgradeError(19));

        // {s}
        uint256 votingDelay = oldGovernor.votingDelay();
        uint256 votingPeriod = oldGovernor.votingPeriod();

        standardParams = IReserveOptimisticGovernor.StandardGovernanceParams({
            votingDelay: SafeCast.toUint48(votingDelay),
            votingPeriod: SafeCast.toUint32(votingPeriod),
            voteExtension: voteExtension,
            proposalThreshold: proposalThreshold,
            quorumNumerator: quorumNumerator,
            proposalThrottleCapacity: 10
        });

        // Timelock delay
        uint256 minDelay = TimelockController(payable(oldGovernor.timelock())).getMinDelay();
        require(minDelay != 0, UpgradeError(2));
        timelockDelay = SafeCast.toUint48(minDelay);
    }

    /// Require `guardians` is a subset of the old timelock's CANCELLER_ROLE members
    /// @dev Does NOT confirm `guardians` is the complete set of CANCELLER_ROLE members
    function _validateGuardians(address oldTimelock, address[] memory guardians) internal view {
        require(guardians.length != 0, UpgradeError(20));

        TimelockController oldTimelockController = TimelockController(payable(oldTimelock));
        for (uint256 i; i < guardians.length; i++) {
            require(guardians[i] != address(0), UpgradeError(21));
            require(oldTimelockController.hasRole(CANCELLER_ROLE, guardians[i]), UpgradeError(22));
        }
    }
}
