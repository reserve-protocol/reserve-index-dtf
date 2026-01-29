// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { IGovernanceDeployer } from "@interfaces/IGovernanceDeployer.sol";
import { Folio } from "@src/Folio.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import { Versioned } from "@utils/Versioned.sol";

/**
 * @title Governance Deployer
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 */
contract GovernanceDeployer is IGovernanceDeployer, Versioned {
    uint256 constant DEFAULT_REWARD_PERIOD = 3.5 days;
    uint256 constant DEFAULT_UNSTAKING_DELAY = 1 weeks;

    event DeployedGovernedStakingToken(
        address indexed folio,
        address indexed stToken,
        address governor,
        address timelock
    );
    event DeployedGovernance(address indexed stToken, address governor, address timelock);

    address public immutable governorImplementation;
    address public immutable timelockImplementation;
    address public immutable stakingVaultImplementation;

    constructor(address _governorImplementation, address _timelockImplementation, address _stakingVaultImplementation) {
        governorImplementation = _governorImplementation;
        timelockImplementation = _timelockImplementation;
        stakingVaultImplementation = _stakingVaultImplementation;
    }

    /// Deploys a StakingVault owned by a Governor with Timelock
    /// @param folio Folio token for the vlDTF staking vault
    /// @param govParams Governance parameters for the governor
    /// @param deploymentNonce Nonce for the deployment salt
    /// @return stToken A staking vault that can be used with multiple governors
    /// @return governor A governor responsible for the staking vault
    /// @return timelock Timelock for the governor, owns staking vault
    function deployGovernedStakingToken(
        Folio folio,
        IGovernanceDeployer.GovParams calldata govParams,
        bytes32 deploymentNonce
    ) external returns (StakingVault stToken, address governor, address timelock) {
        string memory name = string(abi.encodePacked("Vote-Locked ", folio.name()));
        string memory symbol = string(abi.encodePacked("vl", folio.symbol()));

        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, name, symbol, folio, govParams, deploymentNonce));

        stToken = StakingVault(Clones.cloneDeterministic(stakingVaultImplementation, deploymentSalt));
        stToken.initialize(name, symbol, folio, address(this), DEFAULT_REWARD_PERIOD, DEFAULT_UNSTAKING_DELAY);

        (governor, timelock) = deployGovernanceWithTimelock(govParams, folio, IVotes(stToken), deploymentSalt);

        stToken.transferOwnership(timelock);

        emit DeployedGovernedStakingToken(address(folio), address(stToken), governor, timelock);
    }

    function deployGovernanceWithTimelock(
        IGovernanceDeployer.GovParams calldata govParams,
        Folio folio,
        IVotes stToken,
        bytes32 deploymentNonce
    ) public returns (address governor, address timelock) {
        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, govParams, stToken, deploymentNonce));

        governor = Clones.cloneDeterministic(governorImplementation, deploymentSalt);
        timelock = Clones.cloneDeterministic(timelockImplementation, deploymentSalt);

        TimelockControllerUpgradeable timelockController = TimelockControllerUpgradeable(payable(timelock));

        FolioGovernor(payable(governor)).initialize(
            stToken,
            timelockController,
            govParams.votingDelay,
            govParams.votingPeriod,
            govParams.proposalThreshold,
            govParams.quorumThreshold
        );

        address[] memory proposersAndExecutors = new address[](1);
        proposersAndExecutors[0] = governor;

        // TODO configure in timelock
        // bytes4[] memory allowlistedSelectors = new bytes4[](11);
        // allowlistedSelectors[0] = Folio.addToBasket.selector;
        // allowlistedSelectors[1] = Folio.removeFromBasket.selector;
        // allowlistedSelectors[2] = Folio.setTVLFee.selector;
        // allowlistedSelectors[3] = Folio.setMintFee.selector;
        // allowlistedSelectors[4] = Folio.setFeeRecipients.selector;
        // allowlistedSelectors[5] = Folio.setAuctionLength.selector;
        // allowlistedSelectors[6] = Folio.setMandate.selector;
        // allowlistedSelectors[7] = Folio.setName.selector;
        // allowlistedSelectors[8] = Folio.setRebalanceControl.selector;
        // allowlistedSelectors[9] = Folio.setBidsEnabled.selector;
        // allowlistedSelectors[10] = Folio.startRebalance.selector;

        timelockController.initialize(
            govParams.timelockDelay,
            proposersAndExecutors, // Proposer Role
            proposersAndExecutors, // Executor Role
            address(this) // temporary admin
        );

        for (uint256 i; i < govParams.guardians.length; i++) {
            timelockController.grantRole(timelockController.CANCELLER_ROLE(), govParams.guardians[i]);
        }

        timelockController.renounceRole(timelockController.DEFAULT_ADMIN_ROLE(), address(this));

        emit DeployedGovernance(address(stToken), governor, timelock);
    }
}
