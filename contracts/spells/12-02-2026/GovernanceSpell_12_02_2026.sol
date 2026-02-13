// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";

import { IReserveOptimisticGovernorDeployer } from "@reserve-protocol/reserve-governor/contracts/interfaces/IDeployer.sol";
import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";


import { Folio } from "@src/Folio.sol";
import { DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER, CANCELLER_ROLE } from "@utils/Constants.sol";

bytes32 constant VERSION_1_0_0 = keccak256("1.0.0");
bytes32 constant VERSION_5_0_0 = keccak256("5.0.0");
bytes32 constant VERSION_5_1_0 = keccak256("5.1.0");

interface IFolioGovernor is IGovernor {
    function timelock() external view returns (address);
    function quorumNumerator() external view returns (uint256);
}

interface IStakingVault is IERC5805 {
    function owner() external view returns (address);
    function asset() external view returns (address);
    function rewardRatio() external view returns (uint256);
    function unstakingDelay() external view returns (uint256);
}

/**
 * @title GovernanceSpell_12_02_2026
 * @author akshatmittal, julianmrodri, tbrent
 *
 * This spell adds optimistic governance through the addition of a new StakingVault and optimistic governor.
 *
 * In order to use the spell:
 *   1. grant DEFAULT_ADMIN_ROLE on the Folio to this contract
 *   2. call the spell from the owner timelock, making sure to execute this step back-to-back
 */
contract GovernanceSpell_12_02_2026 {
    error UpgradeError(uint256 code);

    IReserveOptimisticGovernorDeployer public immutable governorDeployer;

    constructor(IReserveOptimisticGovernorDeployer _governorDeployer) {
        require(keccak256(bytes(_governorDeployer.version())) == VERSION_1_0_0, UpgradeError(0));

        governorDeployer = _governorDeployer;
    }

    /// Cast spell to upgrade to optimistic governance
    /// @dev Requirements:
    ///      - Caller is owner timelock of the Folio
    ///      - Spell has DEFAULT_ADMIN_ROLE of Folio (as the 2nd admin in addition to the owner timelock)
    /// @param guardians Must be a subset of the old guardians, and nonempty
    /// @param rotateStakingVaultToVLDTF Whether the StakingVault should be rotated to a vlDTF vault
    function cast(
        Folio folio,
        IFolioGovernor oldGovernor,
        address[] calldata guardians,
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata optimisticParams,
        IStakingVault oldStakingVault,
        bool rotateStakingVaultToVLDTF,
        address tradingTimelock,
        bytes32 deploymentNonce
    ) external {
        // confirm caller is old owner timelock
        require(msg.sender == oldGovernor.timelock(), UpgradeError(14));
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), UpgradeError(4));

        // confirm self has DEFAULT_ADMIN_ROLE
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, address(this)), UpgradeError(3));

        // prepare DeploymentParams for new ReserveOptimisticGovernor
        IReserveOptimisticGovernorDeployer.DeploymentParams memory deployParams;
        {
            // Standard governance params from old governor
            uint256 proposalThresholdWithSupply = oldGovernor.proposalThreshold();
            uint256 pastSupply = oldStakingVault.getPastTotalSupply(oldStakingVault.clock() - 1);
            uint256 proposalThreshold = (proposalThresholdWithSupply * 1e18 + pastSupply - 1) / pastSupply;
            require(proposalThreshold >= 0.0001e18 && proposalThreshold <= 0.1e18, UpgradeError(13));

            uint256 quorumNumerator = oldGovernor.quorumNumerator();
            require(quorumNumerator >= 0.01e18 && quorumNumerator <= 0.25e18, UpgradeError(19));

            deployParams.standardParams = IReserveOptimisticGovernor.StandardGovernanceParams({
                votingDelay: SafeCast.toUint48(oldGovernor.votingDelay()),
                votingPeriod: SafeCast.toUint32(oldGovernor.votingPeriod()),
                voteExtension: 0,
                proposalThreshold: proposalThreshold,
                quorumNumerator: quorumNumerator,
                proposalThrottleCapacity: 10
            });

            // Optimistic governance params
            deployParams.optimisticParams = optimisticParams;

            // Guardians validation
            require(guardians.length != 0, UpgradeError(22));
            for (uint256 i; i < guardians.length; i++) {
                require(guardians[i] != address(0), UpgradeError(23));
                require(
                    TimelockController(payable(msg.sender)).hasRole(CANCELLER_ROLE, guardians[i]),
                    UpgradeError(24)
                );
            }
            deployParams.guardians = guardians;

            // Timelock delay
            deployParams.timelockDelay = TimelockController(payable(msg.sender)).getMinDelay();
            require(deployParams.timelockDelay != 0, UpgradeError(21));

            // Staking vault params from old staking vault
            deployParams.underlying = IERC20Metadata(rotateStakingVaultToVLDTF ? address(folio) : oldStakingVault.asset());
            deployParams.rewardHalfLife = oldStakingVault.rewardRatio();
            deployParams.unstakingDelay = oldStakingVault.unstakingDelay();
        }

        // deploy new StakingVault + ReserveOptimisticGovernor + TimelockControllerOptimistic
        (address newStakingVaultAddr, , address newTimelock, ) = governorDeployer.deploy(deployParams, deploymentNonce);
        IStakingVault newStakingVault = IStakingVault(newStakingVaultAddr);

        // validate new StakingVault
        require(newStakingVault.asset() == address(folio), UpgradeError(26));
        require(newStakingVault.owner() == newTimelock, UpgradeError(27));
        require(newStakingVault.rewardRatio() == oldStakingVault.rewardRatio(), UpgradeError(9));
        require(newStakingVault.unstakingDelay() == oldStakingVault.unstakingDelay(), UpgradeError(25));

        // rotate Folio DEFAULT_ADMIN_ROLE
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), UpgradeError(15));
        folio.revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        folio.grantRole(DEFAULT_ADMIN_ROLE, newTimelock);

        // rotate Folio REBALANCE_MANAGER
        require(folio.hasRole(REBALANCE_MANAGER, tradingTimelock), UpgradeError(16));
        folio.revokeRole(REBALANCE_MANAGER, tradingTimelock);
        folio.grantRole(REBALANCE_MANAGER, newTimelock);
        require(folio.getRoleMemberCount(REBALANCE_MANAGER) == 1, UpgradeError(17));
        require(folio.getRoleMember(REBALANCE_MANAGER, 0) == newTimelock, UpgradeError(18));

        // renounce temp DEFAULT_ADMIN_ROLE
        folio.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
        require(!folio.hasRole(DEFAULT_ADMIN_ROLE, address(this)), UpgradeError(6));
        require(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1, UpgradeError(7));
        require(folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0) == newTimelock, UpgradeError(8));
    }
}
