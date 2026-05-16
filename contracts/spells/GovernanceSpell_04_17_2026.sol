// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IReserveOptimisticGovernorDeployer } from "@reserve-protocol/reserve-governor/contracts/interfaces/IDeployer.sol";
import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";

import { IFolio, Folio } from "@src/Folio.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER, MAX_FEE_RECIPIENTS } from "@utils/Constants.sol";

bytes32 constant VERSION_1_0_0 = keccak256("1.0.0");
bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

interface IFolioGovernor is IGovernor {
    function token() external view returns (address);
    function timelock() external view returns (address);
}

interface IVersioned {
    function version() external view returns (string memory);
}

interface IStakingVault is IERC5805, IERC4626, IVersioned {}

// old staking vault model
interface IOwnableStakingVault is IStakingVault {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function renounceOwnership() external;
    function setUnstakingDelay(uint256 unstakingDelay) external;
    function setRewardRatio(uint256 rewardHalfLife) external;
}

/**
 * @title GovernanceSpell_04_17_2026
 * @author akshatmittal, julianmrodri, tbrent
 * @notice Optimistic governance upgrade spell for DTFs
 *
 * Upgrade spell to move a StakingVault + Folio onto the optimistic governance system.
 *
 * Each StakingVault and Folio has its own governor/timelock system. A single StakingVault can be used
 *   as the governance token in multiple Folios, but always has its own governor/timelock for its own governance.
 *
 * Upgrade flow:
 *   1. deploySuccessorStakingVault: Permissionlessly deploy a NEW StakingVault with its own NEW
 *      governor/timelock system, isolated from the old vault. No permissions required.
 *   2. upgradeFolio: Deploy NEW Folio governance system on the successor StakingVault; rotate Folio roles
 *      and fee recipients from old StakingVault to new StakingVault. Wait for new stake before calling.
 *        Caller: old timelock of Folio
 *   3. retireOldStakingVault: After every dependent Folio has completed step 2, permanently seal the
 *      old StakingVault (zero unstaking delay, fast reward handout, renounce ownership).
 *        Caller: timelock of old StakingVault
 */
contract GovernanceSpell_04_17_2026 {
    error UpgradeError(uint256 code);

    event NewGovernanceDeployment(NewDeployment newDeployment);
    event StakingVaultRetired(address oldStakingVault);

    struct NewDeployment {
        address stakingVault;
        address newGovernor;
        address newTimelock;
        address newSelectorRegistry;
    }

    IReserveOptimisticGovernorDeployer public immutable governorDeployer;

    constructor(IReserveOptimisticGovernorDeployer _governorDeployer) {
        require(keccak256(bytes(IVersioned(address(_governorDeployer)).version())) == VERSION_1_0_0, UpgradeError(0));

        governorDeployer = _governorDeployer;
    }

    /// Deploy a successor StakingVault with a fresh optimistic governance system
    /// @dev Permissionless: does not require or change any ownership on the old staking vault
    /// @param guardians Must be a subset of the old staking vault timelock's CANCELLER_ROLE members
    function deploySuccessorStakingVault(
        IFolioGovernor stakingVaultGovernor,
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata optimisticParams,
        address[] calldata guardians,
        address[] calldata rewardTokens,
        bytes32 deploymentNonce
    ) public returns (NewDeployment memory newDeployment) {
        IStakingVault oldStakingVault = IStakingVault(stakingVaultGovernor.token());
        address newUnderlying = oldStakingVault.asset();
        require(newUnderlying != address(0), UpgradeError(21));

        IReserveOptimisticGovernorDeployer.BaseDeploymentParams memory baseParams = _baseDeploymentParams(
            stakingVaultGovernor,
            optimisticParams,
            new address[](0),
            guardians
        );
        IReserveOptimisticGovernorDeployer.NewStakingVaultParams
            memory newStakingVaultParams = IReserveOptimisticGovernorDeployer.NewStakingVaultParams({
                underlying: IERC20Metadata(newUnderlying),
                rewardTokens: rewardTokens,
                rewardHalfLife: 3.5 days,
                unstakingDelay: 1 weeks
            });

        (
            newDeployment.stakingVault,
            newDeployment.newGovernor,
            newDeployment.newTimelock,
            newDeployment.newSelectorRegistry
        ) = governorDeployer.deployWithNewStakingVault(
            baseParams,
            newStakingVaultParams,
            keccak256(abi.encode(deploymentNonce, msg.sender))
        );

        require(newDeployment.newTimelock != address(0), UpgradeError(22));
        require(IStakingVault(newDeployment.stakingVault).asset() == newUnderlying, UpgradeError(23));
        require(newDeployment.stakingVault != address(oldStakingVault), UpgradeError(24));
        require(
            IAccessControlEnumerable(newDeployment.stakingVault).getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1,
            UpgradeError(26)
        );
        require(
            IAccessControlEnumerable(newDeployment.stakingVault).getRoleMember(DEFAULT_ADMIN_ROLE, 0) ==
                newDeployment.newTimelock,
            UpgradeError(27)
        );

        emit NewGovernanceDeployment(newDeployment);
    }

    /// Deploy a new Folio governor/timelock on an existing staking vault and transfer Folio ownership/roles
    /// @dev Requirements:
    ///      - Caller is old Folio timelock
    ///      - Self is Folio admin
    ///      - Self is FolioProxyAdmin owner
    /// @dev IMPORTANT: Do not call until the `newStakingVault` has been sufficiently populated by new stake
    /// @dev New Governance system will use standard 2-3-2 day voting independent of previous voting settings
    /// @dev It is not verified that the new StakingVault is already configured to handout the Folio as reward token. 
    ///      This is an accepted limitation to reduce the overall number of blocking steps in the upgrade sequence.
    /// @param newStakingVault New staking vault to use for the new governor
    /// @param oldFolioGovernor Governor currently attached to the Folio being upgraded
    /// @param optimisticProposers Use empty set to disable optimistic governance altogether
    /// @param guardians Must be a subset of the old Folio timelock's CANCELLER_ROLE members
    ///                  The shared Guardian contract will be included as a CANCELLER_ROLE member by default
    function upgradeFolio(
        Folio folio,
        FolioProxyAdmin folioProxyAdmin,
        IStakingVault newStakingVault,
        IFolioGovernor oldFolioGovernor,
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata optimisticParams,
        address[] calldata optimisticProposers,
        address[] calldata guardians,
        bytes32 deploymentNonce
    ) public returns (NewDeployment memory newDeployment) {
        require(oldFolioGovernor.timelock() == msg.sender, UpgradeError(1));

        IReserveOptimisticGovernorDeployer.BaseDeploymentParams memory baseParams = _baseDeploymentParams(
            oldFolioGovernor,
            optimisticParams,
            optimisticProposers,
            guardians
        );
        baseParams.selectorData = _startRebalanceSelectorData(folio);

        newDeployment.stakingVault = address(newStakingVault);
        (newDeployment.newGovernor, newDeployment.newTimelock, newDeployment.newSelectorRegistry) = governorDeployer
            .deployWithExistingStakingVault(baseParams, address(newStakingVault), deploymentNonce);
        require(newDeployment.newTimelock != address(0), UpgradeError(2));

        // newStakingVault must not be the old immmutable kind, must be new and upgradeable
        require(keccak256(bytes(IVersioned(address(newStakingVault)).version())) == VERSION_1_0_0, UpgradeError(3));

        // confirm Folio admins are self + old timelock
        require(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 2, UpgradeError(4));
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, address(this)), UpgradeError(5));
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), UpgradeError(6));

        // rotate Folio fee recipients from old staking vault to new staking vault
        _rotateFeeRecipients(folio, oldFolioGovernor.token(), address(newStakingVault));

        // rotate Folio REBALANCE_MANAGERs
        {
            for (uint256 i = folio.getRoleMemberCount(REBALANCE_MANAGER); i > 0; i--) {
                address rebalanceManager = folio.getRoleMember(REBALANCE_MANAGER, i - 1);
                folio.revokeRole(REBALANCE_MANAGER, rebalanceManager);
            }
        }
        folio.grantRole(REBALANCE_MANAGER, newDeployment.newTimelock);
        require(folio.getRoleMemberCount(REBALANCE_MANAGER) == 1, UpgradeError(7));
        require(folio.getRoleMember(REBALANCE_MANAGER, 0) == newDeployment.newTimelock, UpgradeError(8));

        // transfer Folio proxy admin ownership
        require(folioProxyAdmin.owner() == address(this), UpgradeError(9));
        folioProxyAdmin.transferOwnership(newDeployment.newTimelock);
        require(folioProxyAdmin.owner() == newDeployment.newTimelock, UpgradeError(10));

        // rotate Folio DEFAULT_ADMIN_ROLE
        folio.revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        folio.grantRole(DEFAULT_ADMIN_ROLE, newDeployment.newTimelock);
        folio.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
        require(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1, UpgradeError(11));
        require(folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0) == newDeployment.newTimelock, UpgradeError(12));

        emit NewGovernanceDeployment(newDeployment);
    }

    /// Permanently retire an old StakingVault after every dependent Folio has upgraded
    /// @dev IMPORTANT: Current governance must transfer ownership of `oldStakingVault` to this spell contract first
    /// @dev Enumeration of dependent Folios is off-chain: current governance is responsible for
    ///      confirming no Folio governor still uses this StakingVault as its voting token.
    function retireOldStakingVault(IOwnableStakingVault oldStakingVault) public {
        require(oldStakingVault.owner() == address(this), UpgradeError(13));

        oldStakingVault.setUnstakingDelay(0);
        oldStakingVault.setRewardRatio(1 days);
        oldStakingVault.renounceOwnership();
        require(oldStakingVault.owner() == address(0), UpgradeError(14));

        emit StakingVaultRetired(address(oldStakingVault));
    }

    // === Internal ===

    function _baseDeploymentParams(
        IFolioGovernor oldGovernor,
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata optimisticParams,
        address[] memory optimisticProposers,
        address[] calldata guardians
    ) internal view returns (IReserveOptimisticGovernorDeployer.BaseDeploymentParams memory baseParams) {
        // Optimistic governance params
        baseParams.optimisticParams = optimisticParams;

        // Standard governance params
        baseParams.standardParams.votingDelay = 2 days;
        baseParams.standardParams.votingPeriod = 3 days;
        baseParams.standardParams.voteExtension = 2 days;
        baseParams.standardParams.proposalThreshold = 0.001e18; // 0.1%
        baseParams.standardParams.quorumNumerator = 0.1e18; // 10%
        // hard-coded long standard governance params to unify across DTFs

        // Optimistic whitelists
        baseParams.selectorData = new IOptimisticSelectorRegistry.SelectorData[](0);
        baseParams.optimisticProposers = optimisticProposers;

        // Guardians
        _validateGuardians(oldGovernor, guardians);
        baseParams.additionalGuardians = guardians;

        // Timelock delay
        baseParams.timelockDelay = 2 days;

        // Proposal throttle
        baseParams.proposalThrottleCapacity = 3;
    }

    function _startRebalanceSelectorData(
        Folio folio
    ) internal pure returns (IOptimisticSelectorRegistry.SelectorData[] memory selectorData) {
        selectorData = new IOptimisticSelectorRegistry.SelectorData[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Folio.startRebalance.selector;
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData({ target: address(folio), selectors: selectors });
    }

    /// Require `guardians` is a subset of the old timelock's CANCELLER_ROLE members (excl old governor)
    /// @dev Does NOT confirm `guardians` is the complete set of CANCELLER_ROLE members
    function _validateGuardians(IFolioGovernor oldGovernor, address[] memory guardians) internal view {
        TimelockController oldTimelock = TimelockController(payable(oldGovernor.timelock()));

        for (uint256 i; i < guardians.length; i++) {
            require(guardians[i] != address(0) && guardians[i] != address(oldGovernor), UpgradeError(17));
            require(oldTimelock.hasRole(CANCELLER_ROLE, guardians[i]), UpgradeError(18));
        }
    }

    /// Rotate the fee recipient entry for the old StakingVault to the new StakingVault
    function _rotateFeeRecipients(Folio folio, address oldStakingVault, address newStakingVault) internal {
        IFolio.FeeRecipient[] memory recipients = _feeRecipients(folio);
        uint256 oldStakingVaultRecipientCount;
        uint256 oldStakingVaultRecipientIndex;

        for (uint256 i; i < recipients.length; i++) {
            address recipient = recipients[i].recipient;

            if (recipient == oldStakingVault) {
                oldStakingVaultRecipientCount++;
                oldStakingVaultRecipientIndex = i;
            }

            require(recipient != newStakingVault, UpgradeError(19));
        }

        require(oldStakingVaultRecipientCount == 1, UpgradeError(20));

        recipients[oldStakingVaultRecipientIndex].recipient = newStakingVault;
        _sortFeeRecipients(recipients);
        folio.setFeeRecipients(recipients);
    }

    function _feeRecipients(Folio folio) internal view returns (IFolio.FeeRecipient[] memory recipients) {
        // no accessor for feeRecipients.length
        uint256 length;
        for (; length < MAX_FEE_RECIPIENTS; length++) {
            try folio.feeRecipients(length) returns (address, uint96) {
                // no-op
            } catch {
                break;
            }
        }

        recipients = new IFolio.FeeRecipient[](length);
        for (uint256 i; i < length; i++) {
            (address recipient, uint96 portion) = folio.feeRecipients(i);
            recipients[i] = IFolio.FeeRecipient({ recipient: recipient, portion: portion });
        }
    }

    function _sortFeeRecipients(IFolio.FeeRecipient[] memory recipients) internal pure {
        for (uint256 i = 1; i < recipients.length; i++) {
            IFolio.FeeRecipient memory recipient = recipients[i];
            uint256 j = i;
            while (j > 0 && uint160(recipients[j - 1].recipient) > uint160(recipient.recipient)) {
                recipients[j] = recipients[j - 1];
                j--;
            }
            recipients[j] = recipient;
        }
    }
}
