// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Votes } from "@openzeppelin/contracts/governance/utils/Votes.sol";

import { IGovernanceDeployer } from "@interfaces/IGovernanceDeployer.sol";
import { GovernanceDeployer } from "@deployer/GovernanceDeployer.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { Folio } from "@src/Folio.sol";
import { DEFAULT_ADMIN_ROLE, AUCTION_APPROVER } from "@utils/Constants.sol";
import { Versioned } from "@utils/Versioned.sol";

/**
 * @title GovernanceSpell_31_03_2025
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 *
 * This spell enables governor/timelock pairs associated with 1.0.0 Folio deployment to upgrade to new instances,
 * with 2 changes:
 *   - proposal threshold lowered by factor of 100
 *   - quorum numerator and denominator converted from whole percent to D18{1}, without changing numerator / denominator
 *
 * It does NOT upgrade the Folio itself.
 *
 * See dev comments below for details on how to use each function.
 */
contract GovernanceSpell_31_03_2025 is Versioned {
    GovernanceDeployer public immutable governanceDeployer;

    constructor(GovernanceDeployer _governanceDeployer) {
        // expect governance deployer 3.0.0
        require(
            keccak256(bytes(_governanceDeployer.version())) == keccak256(bytes(version())),
            "GS: invalid gov deployer"
        );
        governanceDeployer = _governanceDeployer;
    }

    /// @dev Expected use: pre-call, governance atomically transfers ownership of the StakingVault to this contract
    /// @dev Do not leave a gap after transferring ownership to this contract for others to frontrun!
    /// @dev Requirements:
    ///      - Has ownership of the StakingVault
    ///      - Supplied guardians MUST be a subset of the previous guardians, and nonempty
    function upgradeStakingVaultGovernance(
        Ownable stakingVault,
        FolioGovernor oldGovernor,
        address[] calldata guardians,
        bytes32 deploymentNonce
    ) external returns (address newGovernor) {
        require(stakingVault.owner() == address(this), "GS: not staking vault owner");

        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, deploymentNonce));

        address newTimelock;
        (newGovernor, newTimelock) = _deployReplacementGovernance(oldGovernor, guardians, deploymentSalt);

        stakingVault.transferOwnership(newTimelock);
        assert(stakingVault.owner() == newTimelock);
    }

    /// @dev Expected use: pre-call, governance atomically grants DEFAULT_ADMIN_ROLE to this contract AND
    ///                    transfers ownership of the proxy admin to this contract
    /// @dev Do not leave a gap after transferring ownerships to this contract for others to frontrun!
    /// @dev Requirements:
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
        require(oldOwnerGovernor.timelock() != address(0), "GS: owner timelock 0");
        require(oldTradingGovernor.timelock() != address(0), "GS: trading timelock 0");

        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, deploymentNonce));

        // check privileges / setup

        require(proxyAdmin.owner() == address(this), "GS: not proxy admin owner");
        require(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 2, "GS: unexpected number of admins");
        require(folio.getRoleMemberCount(AUCTION_APPROVER) == 1, "GS: unexpected number of traders");

        require(folio.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "GS: not admin");
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, oldOwnerGovernor.timelock()), "GS: old owner timelock not admin");
        require(folio.hasRole(AUCTION_APPROVER, oldTradingGovernor.timelock()), "GS: old trading timelock not trader");

        // deploy replacement governors + timelocks

        address newOwnerTimelock;
        (newOwnerGovernor, newOwnerTimelock) = _deployReplacementGovernance(
            oldOwnerGovernor,
            ownerGuardians,
            deploymentSalt
        );

        address newTradingTimelock;
        (newTradingGovernor, newTradingTimelock) = _deployReplacementGovernance(
            oldTradingGovernor,
            tradingGuardians,
            deploymentSalt
        );

        // upgrade roles and owners

        proxyAdmin.transferOwnership(newOwnerTimelock);

        folio.grantRole(DEFAULT_ADMIN_ROLE, newOwnerTimelock);
        folio.grantRole(AUCTION_APPROVER, newTradingTimelock);

        folio.revokeRole(AUCTION_APPROVER, oldTradingGovernor.timelock());
        folio.revokeRole(DEFAULT_ADMIN_ROLE, oldOwnerGovernor.timelock());
        folio.renounceRole(DEFAULT_ADMIN_ROLE, address(this));

        // post validation

        require(proxyAdmin.owner() == newOwnerTimelock, "GS: 1");
        require(folio.hasRole(DEFAULT_ADMIN_ROLE, newOwnerTimelock), "GS: 2");
        require(folio.hasRole(AUCTION_APPROVER, newTradingTimelock), "GS: 3");
        require(folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1, "GS: 4");
        require(folio.getRoleMemberCount(AUCTION_APPROVER) == 1, "GS: 5");
    }

    // ==== Internal ====

    /// Deploy a replacement governance + timelock
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

        require(oldGovernor.quorumDenominator() == 100, "GS: not old governor");
        // the proposal thresholds should be 100x their correct value too, but no way to check for that

        // validate gov params

        uint256 votingDelay = oldGovernor.votingDelay();
        require(votingDelay != 0, "GS: voting delay 0");
        require(votingDelay <= type(uint48).max, "GS: voting delay too large");

        uint256 votingPeriod = oldGovernor.votingPeriod();
        require(votingPeriod != 0, "GS: voting period 0");
        require(votingPeriod <= type(uint32).max, "GS: voting period too large");

        // lower proposalThreshold by factor of 100
        uint256 proposalThreshold;
        {
            uint256 proposalThresholdWithSupply = oldGovernor.proposalThreshold();
            Votes stakingVault = Votes(address(oldGovernor.token()));
            uint256 pastSupply = stakingVault.getPastTotalSupply(stakingVault.clock() - 1);
            require(pastSupply != 0, "GS: past supply 0");

            proposalThreshold = ((proposalThresholdWithSupply * 1e18 + pastSupply - 1) / pastSupply) / 100;
            require(
                proposalThreshold >= 1e14 && proposalThreshold <= 1e17,
                "GS: proposal threshold not in expected range"
            );
        }

        uint256 quorumThreshold = oldGovernor.quorumNumerator() * 1e16; // multiply by 1e16 to convert raw percent to D18{1}
        require(quorumThreshold >= 1e16 && quorumThreshold <= 2e17, "GS: quorum threshold not in expected range");

        uint256 timelockDelay;
        {
            TimelockController oldTimelock = TimelockController(payable(oldGovernor.timelock()));

            timelockDelay = oldTimelock.getMinDelay();
            require(timelockDelay != 0, "GS: timelock delay 0");

            require(guardians.length != 0, "GS: guardians empty");
            for (uint256 i; i < guardians.length; i++) {
                require(guardians[i] != address(0), "GS: guardian 0");
                require(
                    oldTimelock.hasRole(oldTimelock.CANCELLER_ROLE(), guardians[i]),
                    "GS: guardian not on old timelock"
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

        require(newGovernor != address(0), "GS: 6");
        require(newTimelock != address(0), "GS: 7");
        require(FolioGovernor(payable(newGovernor)).timelock() == newTimelock, "GS: 8");
        require(FolioGovernor(payable(newGovernor)).quorumDenominator() == 1e18, "GS: 8.1");

        // check quorum > proposal threshold
        {
            Votes stakingVault = Votes(address(FolioGovernor(payable(newGovernor)).token()));
            uint256 pastSupply = stakingVault.getPastTotalSupply(stakingVault.clock() - 1);
            uint256 _proposalThreshold = (FolioGovernor(payable(newGovernor)).proposalThreshold() *
                1e18 +
                pastSupply -
                1) / pastSupply;

            require(FolioGovernor(payable(newGovernor)).quorumNumerator() > _proposalThreshold, "GS: 8.2");
        }

        TimelockController _newTimelock = TimelockController(payable(newTimelock));

        require(_newTimelock.hasRole(_newTimelock.PROPOSER_ROLE(), newGovernor), "GS: 9");
        require(_newTimelock.hasRole(_newTimelock.EXECUTOR_ROLE(), newGovernor), "GS: 10");
        require(_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), newGovernor), "GS: 11");

        require(!_newTimelock.hasRole(_newTimelock.PROPOSER_ROLE(), address(oldGovernor)), "GS: 12");
        require(!_newTimelock.hasRole(_newTimelock.EXECUTOR_ROLE(), address(oldGovernor)), "GS: 13");
        require(!_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), address(oldGovernor)), "GS: 14");

        require(!_newTimelock.hasRole(_newTimelock.PROPOSER_ROLE(), address(0)), "GS: 15");
        require(!_newTimelock.hasRole(_newTimelock.EXECUTOR_ROLE(), address(0)), "GS: 16");

        require(!_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), address(0)), "GS: 17");
        for (uint256 i; i < guardians.length; i++) {
            require(_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), guardians[i]), "GS: 18");
        }
    }
}
