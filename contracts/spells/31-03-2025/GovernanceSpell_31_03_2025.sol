// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Votes } from "@openzeppelin/contracts/governance/utils/Votes.sol";

import { IGovernanceDeployer } from "@interfaces/IGovernanceDeployer.sol";
import { FolioDeployer } from "@deployer/FolioDeployer.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { Folio } from "@src/Folio.sol";
import { Versioned } from "@utils/Versioned.sol";

/**
 * @title GovernanceSpell_31_03_2025
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 *
 * This spell enables governors/timelocks associated with 1.0.0 Folio deployment to upgrade to new instances,
 * with 2 changes:
 *   - proposal threshold lowered by factor of 100
 *   - quorum numerator and denominator converted from whole percent to D18{1} (without changing relative values)
 *
 * It does NOT upgrade the Folio itself.
 *
 * See dev comments below for details on how to use each function.
 */
contract GovernanceSpell_31_03_2025 is Versioned {
    IGovernanceDeployer public immutable governanceDeployer;

    constructor(IGovernanceDeployer _governanceDeployer) {
        // can be any-of 1.0.0, 2.0.0, or 3.0.0 GovernanceDeployers
        // context: the bug that resulted in 100x proposal thresholds was in the frontend, not the contracts
        governanceDeployer = _governanceDeployer;
    }

    /// @dev Expected use: pre-call, governance atomically transfers ownership of the StakingVault to this contract
    /// @dev Do not leave space after transferring ownership for others to interact with this contract!
    /// @dev Requirments:
    ///      - Has ownership of the StakingVault
    ///      - Supplied guardians MUST be a subset of the previous guardians, and nonempty
    function upgradeStakingVaultGovernance(
        Ownable stakingVault,
        FolioGovernor oldGovernor,
        address[] calldata guardians,
        bytes32 deploymentNonce
    ) external returns (address newGovernor) {
        require(stakingVault.owner() == address(this), "not staking vault owner");

        address newTimelock;
        (newGovernor, newTimelock) = _deployReplacementGovernance(oldGovernor, guardians, deploymentNonce);

        stakingVault.transferOwnership(newTimelock);
        assert(stakingVault.owner() == newTimelock);
    }

    /// @dev Expected use: pre-call, governance atomically grants DEFAULT_ADMIN_ROLE to this contract AND
    ///                    transfers ownership of the proxy admin to this contract
    /// @dev Do not leave space after granting adminships for others to interact with this contract!
    /// @dev Requirments:
    ///      - Has ownership of the proxy admin
    ///      - Has DEFAULT_ADMIN_ROLE of Folio, as the 2nd admin in addition to the old owner timelock
    ///      - Old trading timelock should be the sole AUCTION_APPROVER
    ///      - Supplied guardians MUST be a subset of the previous guardians, and nonempty
    function upgradeFolioGovernance(
        Folio folio,
        FolioProxyAdmin proxyAdmin,
        FolioGovernor oldOwnerGovernor,
        FolioGovernor oldTradingGovernor,
        address[] calldata ownerGuardians,
        address[] calldata tradingGuardians,
        bytes32 deploymentNonce
    ) external returns (address newOwnerGovernor, address newTradingGovernor) {
        require(oldOwnerGovernor.timelock() != address(0), "owner timelock 0");
        require(oldTradingGovernor.timelock() != address(0), "trading timelock 0");

        // check privileges / setup

        require(proxyAdmin.owner() == address(this), "not proxy admin owner");
        require(folio.getRoleMemberCount(folio.DEFAULT_ADMIN_ROLE()) == 2, "unexpected number of admins");
        require(folio.getRoleMemberCount(folio.AUCTION_APPROVER()) == 1, "unexpected number of traders");

        require(folio.hasRole(folio.DEFAULT_ADMIN_ROLE(), address(this)), "not admin");
        require(folio.hasRole(folio.DEFAULT_ADMIN_ROLE(), oldOwnerGovernor.timelock()), "old owner timelock not admin");
        require(
            folio.hasRole(folio.AUCTION_APPROVER(), oldTradingGovernor.timelock()),
            "old trading timelock not trader"
        );

        // deploy replacement governors + timelocks

        address newOwnerTimelock;
        (newOwnerGovernor, newOwnerTimelock) = _deployReplacementGovernance(
            oldOwnerGovernor,
            ownerGuardians,
            deploymentNonce
        );

        address newTradingTimelock;
        (newTradingGovernor, newTradingTimelock) = _deployReplacementGovernance(
            oldTradingGovernor,
            tradingGuardians,
            deploymentNonce
        );

        // upgrade roles and owners

        proxyAdmin.transferOwnership(newOwnerTimelock);

        folio.grantRole(folio.DEFAULT_ADMIN_ROLE(), newOwnerTimelock);
        folio.grantRole(folio.AUCTION_APPROVER(), newTradingTimelock);

        folio.revokeRole(folio.AUCTION_APPROVER(), oldTradingGovernor.timelock());
        folio.revokeRole(folio.DEFAULT_ADMIN_ROLE(), oldOwnerGovernor.timelock());
        folio.renounceRole(folio.DEFAULT_ADMIN_ROLE(), address(this));

        // post validation

        assert(proxyAdmin.owner() == newOwnerTimelock);
        assert(folio.hasRole(folio.DEFAULT_ADMIN_ROLE(), newOwnerTimelock));
        assert(folio.hasRole(folio.AUCTION_APPROVER(), newTradingTimelock));
        assert(folio.getRoleMemberCount(folio.DEFAULT_ADMIN_ROLE()) == 1);
        assert(folio.getRoleMemberCount(folio.AUCTION_APPROVER()) == 1);
    }

    // ==== Internal ====

    /// Deploys a replacement governance + timelock
    /// Should:
    ///   - Lower proposal threshold by factor of 100
    ///   - Convert quorum numerator from whole percent to D18{1}
    ///   - Use provided guardians, which must be a subset of the old guardians
    function _deployReplacementGovernance(
        FolioGovernor oldGovernor,
        address[] calldata guardians,
        bytes32 deploymentNonce
    ) internal returns (address newGovernor, address newTimelock) {
        // verify current governor looks old: 1.0.0 governors used a quorum denominator of 100 instead of 1e18

        require(oldGovernor.quorumDenominator() == 100, "not old governor");
        // the proposal thresholds should be 100x their correct value too, but no way to check for that

        // validate gov params

        uint256 votingDelay = oldGovernor.votingDelay();
        require(votingDelay != 0, "voting delay 0");
        require(votingDelay <= type(uint48).max, "voting delay too large");

        uint256 votingPeriod = oldGovernor.votingPeriod();
        require(votingPeriod != 0, "voting period 0");
        require(votingPeriod <= type(uint32).max, "voting period too large");

        // lower proposalThreshold by factor of 100
        uint256 proposalThreshold;
        {
            uint256 proposalThresholdWithSupply = oldGovernor.proposalThreshold();
            Votes stakingVault = Votes(address(oldGovernor.token()));
            uint256 pastSupply = stakingVault.getPastTotalSupply(stakingVault.clock() - 1);
            require(pastSupply != 0, "past supply 0");

            proposalThreshold = ((proposalThresholdWithSupply * 1e18) / pastSupply) / 100;
            require(proposalThreshold >= 1e14 && proposalThreshold <= 1e17, "proposal threshold not in expected range");
        }

        uint256 quorumThreshold = oldGovernor.quorumNumerator() * 1e16; // multiply by 1e16 to convert raw percent to D18{1}
        require(quorumThreshold != 0 && quorumThreshold <= 2e17, "quorum threshold not in expected range");

        uint256 timelockDelay;
        {
            TimelockController oldTimelock = TimelockController(payable(oldGovernor.timelock()));

            timelockDelay = oldTimelock.getMinDelay();
            require(timelockDelay != 0, "timelock delay 0");

            require(guardians.length != 0, "guardians empty");
            for (uint256 i; i < guardians.length; i++) {
                require(guardians[i] != address(0), "guardian 0");
                require(
                    oldTimelock.hasRole(oldTimelock.CANCELLER_ROLE(), guardians[i]),
                    "guardian not on old timelock"
                );
            }
        }

        IGovernanceDeployer.GovParams memory govParams = IGovernanceDeployer.GovParams({
            votingDelay: uint48(votingDelay),
            votingPeriod: uint32(votingPeriod),
            proposalThreshold: proposalThreshold,
            quorumThreshold: quorumThreshold,
            timelockDelay: timelockDelay,
            guardians: guardians
        });

        // deploy new governor + timelock

        (newGovernor, newTimelock) = governanceDeployer.deployGovernanceWithTimelock(
            govParams,
            Votes(address(oldGovernor.token())),
            deploymentNonce
        );

        // post validation

        assert(newGovernor != address(0));
        assert(newTimelock != address(0));
        assert(FolioGovernor(payable(newGovernor)).timelock() == newTimelock);

        TimelockController _newTimelock = TimelockController(payable(newTimelock));

        assert(_newTimelock.hasRole(_newTimelock.PROPOSER_ROLE(), newGovernor));
        assert(_newTimelock.hasRole(_newTimelock.EXECUTOR_ROLE(), newGovernor));
        assert(_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), newGovernor));

        assert(!_newTimelock.hasRole(_newTimelock.PROPOSER_ROLE(), address(oldGovernor)));
        assert(!_newTimelock.hasRole(_newTimelock.EXECUTOR_ROLE(), address(oldGovernor)));
        assert(!_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), address(oldGovernor)));

        assert(!_newTimelock.hasRole(_newTimelock.PROPOSER_ROLE(), address(0)));
        assert(!_newTimelock.hasRole(_newTimelock.EXECUTOR_ROLE(), address(0)));

        assert(!_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), address(0)));
        for (uint256 i; i < guardians.length; i++) {
            assert(_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), guardians[i]));
        }
    }
}
