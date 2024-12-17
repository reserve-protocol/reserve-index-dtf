// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockControllerUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import { Versioned } from "@utils/Versioned.sol";

/**
 * @title GovernanceDeployer
 */
contract GovernanceDeployer is Versioned {
    uint256 constant REWARD_PERIOD = (60 * 60 * 24 * 7) / 2; // 3.5 days

    address public immutable governorImplementation;
    address public immutable timelockImplementation;

    constructor(address _governorImplementation, address _timelockImplementation) {
        governorImplementation = _governorImplementation;
        timelockImplementation = _timelockImplementation;
    }

    /// Deploy a staking vault and timelocked governor that owns it
    /// BYOT (bring your own token)
    /// @return stToken A staking vault that can be used with multiple governors
    /// @return governor A timelocked governor that owns the staking vault
    function deployGovernedStakingToken(
        string memory name,
        string memory symbol,
        IERC20 underlying,
        IFolioDeployer.GovParams calldata govParams
    ) external returns (address stToken, address governor) {
        address timelock = Clones.clone(timelockImplementation);

        stToken = address(
            new StakingVault(
                name,
                symbol,
                underlying,
                timelock,
                REWARD_PERIOD,
                0 // @todo What should be the default value for unstaking delay?
            )
        );

        governor = Clones.clone(governorImplementation);

        FolioGovernor(payable(governor)).initialize(
            IVotes(stToken),
            TimelockControllerUpgradeable(payable(timelock)),
            govParams.votingDelay,
            govParams.votingPeriod,
            govParams.proposalThreshold,
            govParams.quorumPercent
        );

        address[] memory proposers = new address[](1);
        proposers[0] = governor;
        address[] memory executors = new address[](1);
        // executors[0] = address(0);

        TimelockControllerUpgradeable timelockController = TimelockControllerUpgradeable(payable(timelock));

        timelockController.initialize(govParams.timelockDelay, proposers, executors, address(this));

        if (govParams.guardian != address(0)) {
            timelockController.grantRole(timelockController.CANCELLER_ROLE(), govParams.guardian);
        }

        timelockController.renounceRole(timelockController.DEFAULT_ADMIN_ROLE(), address(this));
    }
}
