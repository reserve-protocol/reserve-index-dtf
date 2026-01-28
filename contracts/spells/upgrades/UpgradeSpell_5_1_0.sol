// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { IGovernanceDeployer } from "@interfaces/IGovernanceDeployer.sol";
import { GovernanceDeployer } from "@deployer/GovernanceDeployer.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { Folio } from "@src/Folio.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import { Versioned } from "@utils/Versioned.sol";
import { DEFAULT_ADMIN_ROLE, REBALANCE_MANAGER, CANCELLER_ROLE } from "@utils/Constants.sol";

bytes32 constant VERSION_5_0_0 = keccak256("5.0.0");
bytes32 constant VERSION_5_1_0 = keccak256("5.1.0");

/**
 * @title UpgradeSpell_5_1_0
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
contract UpgradeSpell_5_1_0 is Versioned {
    error UpgradeError(uint256 code);

    GovernanceDeployer public immutable governanceDeployer;

    constructor(GovernanceDeployer _governanceDeployer) {
        require(keccak256(bytes(_governanceDeployer.version())) == VERSION_5_1_0, UpgradeError(0));

        governanceDeployer = _governanceDeployer;
    }

    /// Cast spell to upgrade from 5.0.0 -> 5.1.0
    /// @dev Requirements:
    ///      - Caller is owner timelock (of the Folio)
    ///      - Has ownership of the proxy admin
    ///      - Has DEFAULT_ADMIN_ROLE of Folio, as the 2nd admin in addition to the owner timelock
    function cast(
        Folio folio,
        FolioProxyAdmin proxyAdmin,
        FolioGovernor oldGovernor,
        address[] calldata guardians,
        StakingVault oldStakingVault,
        address tradingTimelock,
        bytes32 deploymentNonce
    ) external {
        // confirm caller is old owner timelock

        require(msg.sender == oldGovernor.timelock(), UpgradeError(14));

        // nonReentrancy checks

        folio.poke();

        (bool syncStateChangeActive, bool asyncStateChangeActive) = folio.stateChangeActive();
        require(!syncStateChangeActive && !asyncStateChangeActive, UpgradeError(1));

        // check Folio version is 5.0.0

        require(keccak256(bytes(folio.version())) == VERSION_5_0_0, UpgradeError(2));

        // check old Governor

        require(oldGovernor.quorumDenominator() == 1e18, UpgradeError(12));

        // check privileges / setup

        require(folio.hasRole(DEFAULT_ADMIN_ROLE, address(this)), UpgradeError(3));
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, msg.sender), UpgradeError(4));

        // upgrade Folio to 5.1.0

        proxyAdmin.upgradeToVersion(address(folio), VERSION_5_1_0, "");

        require(keccak256(bytes(folio.version())) == VERSION_5_1_0, UpgradeError(5));

        // prepare GovParams

        IGovernanceDeployer.GovParams memory govParams;
        {
            uint256 votingDelay = oldGovernor.votingDelay();
            require(votingDelay <= type(uint48).max, UpgradeError(10));
            govParams.votingDelay = uint48(votingDelay);

            uint256 votingPeriod = oldGovernor.votingPeriod();
            require(votingPeriod <= type(uint32).max, UpgradeError(11));
            govParams.votingPeriod = uint32(votingPeriod);

            uint256 proposalThresholdWithSupply = oldGovernor.proposalThreshold();
            uint256 pastSupply = oldStakingVault.getPastTotalSupply(oldStakingVault.clock() - 1);
            govParams.proposalThreshold = (proposalThresholdWithSupply * 1e18 + pastSupply - 1) / pastSupply;
            require(
                govParams.proposalThreshold >= 0.0001e18 && govParams.proposalThreshold <= 0.1e18,
                UpgradeError(13)
            );

            govParams.quorumThreshold = oldGovernor.quorumNumerator();
            require(govParams.quorumThreshold >= 0.01e18 && govParams.quorumThreshold <= 0.25e18, UpgradeError(19));

            govParams.timelockDelay = TimelockController(payable(msg.sender)).getMinDelay();
            require(govParams.timelockDelay != 0, UpgradeError(21));

            require(guardians.length != 0, UpgradeError(22));
            for (uint256 i; i < guardians.length; i++) {
                require(guardians[i] != address(0), UpgradeError(23));
                require(
                    TimelockController(payable(msg.sender)).hasRole(CANCELLER_ROLE, guardians[i]),
                    UpgradeError(24)
                );
            }
            govParams.guardians = guardians;
        }

        // TODO pass to deployGovernedStakingToken()
        bytes4[] memory allowlistedSelectors = new bytes4[](11);
        allowlistedSelectors[0] = Folio.addToBasket.selector;
        allowlistedSelectors[1] = Folio.removeFromBasket.selector;
        allowlistedSelectors[2] = Folio.setTVLFee.selector;
        allowlistedSelectors[3] = Folio.setMintFee.selector;
        allowlistedSelectors[4] = Folio.setFeeRecipients.selector;
        allowlistedSelectors[5] = Folio.setAuctionLength.selector;
        allowlistedSelectors[6] = Folio.setMandate.selector;
        allowlistedSelectors[7] = Folio.setName.selector;
        allowlistedSelectors[8] = Folio.setRebalanceControl.selector;
        allowlistedSelectors[9] = Folio.setBidsEnabled.selector;
        allowlistedSelectors[10] = Folio.startRebalance.selector;

        // deploy new StakingVault + ReserveOptimisticGovernor + TimelockControllerOptimistic

        (StakingVault newStakingVault, address newGovernor, address newTimelock) = governanceDeployer
            .deployGovernedStakingToken(
                oldStakingVault.name(),
                oldStakingVault.symbol(),
                IERC20(oldStakingVault.asset()),
                govParams,
                deploymentNonce
            );
        // require(ReserveOptimisticGovernor(payable(newGovernor)).token() == address(newStakingVault), UpgradeError(20));
        // require(ReserveOptimisticGovernor(payable(newGovernor)).timelock() == newTimelock, UpgradeError(20));

        // check new rewardRatio matches old StakingVault's rewardRatio

        require(newStakingVault.rewardRatio() == oldStakingVault.rewardRatio(), UpgradeError(9));

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
