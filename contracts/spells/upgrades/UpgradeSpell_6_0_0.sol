// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { IReserveOptimisticGovernorDeployer } from "@reserve-protocol/reserve-governor/contracts/interfaces/IDeployer.sol";
import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";
import { IStakingVault } from "@reserve-protocol/reserve-governor/contracts/interfaces/IStakingVault.sol";

/// @dev Extended interface for governor with timelock methods
interface IGovernorWithTimelock is IGovernor {
    function timelock() external view returns (address);
    function quorumNumerator() external view returns (uint256);
}

/// @dev Extended interface for staking vault with clock method
interface IStakingVaultWithClock is IStakingVault {
    function clock() external view returns (uint48);
}

import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { Folio } from "@src/Folio.sol";
import { Versioned } from "@utils/Versioned.sol";
import { DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER, CANCELLER_ROLE } from "@utils/Constants.sol";

bytes32 constant VERSION_1_0_0 = keccak256("1.0.0");
bytes32 constant VERSION_5_0_0 = keccak256("5.0.0");
bytes32 constant VERSION_5_1_0 = keccak256("5.1.0");

/**
 * @title UpgradeSpell_6_0_0
 * @author akshatmittal, julianmrodri, tbrent
 *
 * This spell adds optimistic governance to a Folio through the addition of a new StakingVault.
 *
 * The Folio must be on 5.0.0 before the upgrade.
 *
 * In order to use the spell:
 *   1. transferOwnership of the proxy admin to this contract
 *   2. grant DEFAULT_ADMIN_ROLE on the Folio to this contract
 *   3. call the spell from the owner timelock, making sure to execute all 3 steps back-to-back
 */
contract UpgradeSpell_6_0_0 is Versioned {
    error UpgradeError(uint256 code);

    IReserveOptimisticGovernorDeployer public immutable governorDeployer;

    constructor(IReserveOptimisticGovernorDeployer _governorDeployer) {
        require(keccak256(bytes(_governorDeployer.version())) == VERSION_1_0_0, UpgradeError(0));

        governorDeployer = _governorDeployer;
    }

    /// Cast spell to upgrade from 5.0.0 -> 5.1.0 and add vlDTF optimistic governance
    /// @dev Requirements:
    ///      - Caller is owner timelock of the Folio
    ///      - Spell has ownership of the proxy admin
    ///      - Spell has DEFAULT_ADMIN_ROLE of Folio (as the 2nd admin in addition to the owner timelock)
    /// @param guardians Must be a subset of the old guardians, and nonempty
    function cast(
        Folio folio,
        FolioProxyAdmin proxyAdmin,
        IGovernorWithTimelock oldGovernor,
        address[] calldata guardians,
        IStakingVaultWithClock oldStakingVault,
        address tradingTimelock,
        bytes32 deploymentNonce
    ) external {
        // nonReentrancy checks
        {
            folio.poke();

            (bool syncStateChangeActive, bool asyncStateChangeActive) = folio.stateChangeActive();
            require(!syncStateChangeActive && !asyncStateChangeActive, UpgradeError(1));
        }

        // confirm caller is old owner timelock
        require(msg.sender == oldGovernor.timelock(), UpgradeError(14));
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), UpgradeError(4));

        // confirm self has DEFAULT_ADMIN_ROLE
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, address(this)), UpgradeError(3));

        // check Folio version is 5.0.0
        require(keccak256(bytes(folio.version())) == VERSION_5_0_0, UpgradeError(2));

        // upgrade Folio to 5.1.0
        proxyAdmin.upgradeToVersion(address(folio), VERSION_5_1_0, "");
        require(keccak256(bytes(folio.version())) == VERSION_5_1_0, UpgradeError(5));

        // prepare DeploymentParams for new ReserveOptimisticGovernor
        IReserveOptimisticGovernorDeployer.DeploymentParams memory deployParams;
        {
            // Standard governance params from old governor
            uint256 votingDelay = oldGovernor.votingDelay();
            require(votingDelay <= type(uint48).max, UpgradeError(10));

            uint256 votingPeriod = oldGovernor.votingPeriod();
            require(votingPeriod <= type(uint32).max, UpgradeError(11));

            uint256 proposalThresholdWithSupply = oldGovernor.proposalThreshold();
            uint256 pastSupply = oldStakingVault.getPastTotalSupply(oldStakingVault.clock() - 1);
            uint256 proposalThreshold = (proposalThresholdWithSupply * 1e18 + pastSupply - 1) / pastSupply;
            require(proposalThreshold >= 0.0001e18 && proposalThreshold <= 0.1e18, UpgradeError(13));

            uint256 quorumNumerator = oldGovernor.quorumNumerator();
            require(quorumNumerator >= 0.01e18 && quorumNumerator <= 0.25e18, UpgradeError(19));

            deployParams.standardParams = IReserveOptimisticGovernor.StandardGovernanceParams({
                votingDelay: uint48(votingDelay),
                votingPeriod: uint32(votingPeriod),
                voteExtension: 0,
                proposalThreshold: proposalThreshold,
                quorumNumerator: quorumNumerator
            });

            // Optimistic governance params - use defaults for upgrade
            deployParams.optimisticParams = IReserveOptimisticGovernor.OptimisticGovernanceParams({
                vetoPeriod: 3 days,
                vetoThreshold: 0.15e18, // 15%
                slashingPercentage: 0,
                numParallelProposals: 3
            });

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
            deployParams.underlying = IERC20Metadata(address(folio));
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
