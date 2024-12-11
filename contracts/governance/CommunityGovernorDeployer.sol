// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { IFolioDeployer } from "@interfaces/IFolioDeployer.sol";

import { Folio } from "@src/Folio.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import { Versioned } from "@utils/Versioned.sol";

contract CommunityGovernorDeployer is Versioned {
    /// Deploy a staking vault and community governor
    /// @return stToken A staking vault that can be used with multiple governors
    /// @return governor The governor that owns the staking vault
    function deployCommunityGovernor(
        string memory name,
        string memory symbol,
        IERC20 underlying,
        IFolioDeployer.GovernanceParams calldata govParams
    ) external returns (address stToken, address governor) {
        stToken = address(new StakingVault(name, symbol, underlying, address(0))); // TODO return to 4th arg

        address[] memory empty = new address[](0);
        TimelockController timelock = new TimelockController(govParams.timelockDelay, empty, empty, address(this));

        governor = address(
            new FolioGovernor(
                IVotes(stToken),
                timelock,
                govParams.votingDelay,
                govParams.votingPeriod,
                govParams.proposalThreshold,
                govParams.quorumPercent
            )
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0)); // grant executor to everyone
        // TODO no cancellers/guardian?

        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        return (stToken, governor);
    }
}
