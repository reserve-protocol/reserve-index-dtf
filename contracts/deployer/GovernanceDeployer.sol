// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { IGovernanceDeployer } from "@interfaces/IGovernanceDeployer.sol";
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
        address indexed underlying,
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
    /// @param name Name of the staking vault
    /// @param symbol Symbol of the staking vault
    /// @param underlying Underlying token for the staking vault
    /// @param govParams Governance parameters for the governor
    /// @param deploymentNonce Nonce for the deployment salt
    /// @return stToken A staking vault that can be used with multiple governors
    /// @return governor A governor responsible for the staking vault
    /// @return timelock Timelock for the governor, owns staking vault
    function deployGovernedStakingToken(
        string memory name,
        string memory symbol,
        IERC20 underlying,
        IGovernanceDeployer.GovParams calldata govParams,
        bytes32 deploymentNonce
    ) external returns (StakingVault stToken, address governor, address timelock) {
        bytes32 deploymentSalt = keccak256(
            abi.encode(msg.sender, name, symbol, underlying, govParams, deploymentNonce)
        );

        bytes memory initData = abi.encodeCall(
            StakingVault.initialize,
            (name, symbol, underlying, address(this), DEFAULT_REWARD_PERIOD, DEFAULT_UNSTAKING_DELAY)
        );

        ERC1967Proxy proxy = new ERC1967Proxy{ salt: deploymentSalt }(stakingVaultImplementation, initData);

        stToken = StakingVault(address(proxy));

        (governor, timelock) = deployGovernanceWithTimelock(govParams, IVotes(stToken), deploymentSalt);

        stToken.transferOwnership(timelock);

        emit DeployedGovernedStakingToken(address(underlying), address(stToken), governor, timelock);
    }

    function deployGovernanceWithTimelock(
        IGovernanceDeployer.GovParams calldata govParams,
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
