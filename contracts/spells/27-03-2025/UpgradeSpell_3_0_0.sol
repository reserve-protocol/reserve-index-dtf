// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IGovernanceDeployer } from "@interfaces/IGovernanceDeployer.sol";
import { FolioDeployer } from "@deployer/FolioDeployer.sol";
import { FolioProxyAdmin } from "@folio/FolioProxy.sol";
import { FolioGovernor } from "@gov/FolioGovernor.sol";
import { Folio } from "@src/Folio.sol";
import { Versioned } from "@utils/Versioned.sol";

/**
 * @title GovernanceUpgrader
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 *
 * The 1.0.0 governors were all deployed with 100x the proposal threshold due to a frontend bug. This spell enables
 * easy upgrade of the Folios and replacement of the governors/timelocks.
 *
 * It should work for upgrading Folios to EITHER 2.0.0 and 3.0.0.
 *
 * See dev comments below for details on how to use each function.
 */
contract UpgradeSpell_3_0_0 is Versioned {
    bytes32 constant VERSION_2_0_0 = keccak256("2.0.0");
    bytes32 constant VERSION_3_0_0 = keccak256("3.0.0");

    bytes32 public immutable folioVersionHash;

    FolioDeployer public immutable folioDeployer;
    IGovernanceDeployer public immutable governanceDeployer;

    constructor(FolioDeployer _folioDeployer, IGovernanceDeployer _governanceDeployer) {
        folioVersionHash = keccak256(bytes(_folioDeployer.version()));
        bytes32 govVersion = keccak256(bytes(Versioned(address(_governanceDeployer)).version()));

        require(folioVersionHash == VERSION_2_0_0 || folioVersionHash == VERSION_3_0_0, "invalid folio version");
        require(govVersion == VERSION_2_0_0 || govVersion == VERSION_3_0_0, "invalid governance version");

        folioDeployer = _folioDeployer;
        governanceDeployer = _governanceDeployer;
    }

    /// @dev Expected use: governance atomically transfers ownership of the StakingVault to this contract pre-call
    /// @dev Do not leave space after transferring ownership for others to interact with this contract!
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

    /// @dev Expected use: governance atomically grants DEFAULT_ADMIN_ROLE to this contract AND
    ///                    transfers ownership of the proxy admin to this contract, pre-call.
    /// @dev Do not leave space after granting adminships for others to interact with this contract!
    function upgradeFolioPlusGovernance(
        Folio folio,
        FolioProxyAdmin proxyAdmin,
        FolioGovernor oldOwnerGovernor,
        FolioGovernor oldTradingGovernor,
        address[] calldata guardians,
        bytes32 deploymentNonce
    ) external returns (address newOwnerGovernor, address newTradingGovernor) {
        address oldOwnerTimelock = oldOwnerGovernor.timelock();
        require(oldOwnerTimelock != address(0), "owner timelock 0");

        address oldTradingTimelock = oldTradingGovernor.timelock();
        require(oldTradingTimelock != address(0), "trading timelock 0");

        // check privileges / setup

        require(proxyAdmin.owner() == address(this), "not proxy admin owner");
        require(folio.getRoleMemberCount(folio.DEFAULT_ADMIN_ROLE()) == 2, "unexpected number of admins");
        require(folio.getRoleMemberCount(folio.AUCTION_APPROVER()) == 1, "unexpected number of traders");

        require(folio.hasRole(folio.DEFAULT_ADMIN_ROLE(), address(this)), "not admin");
        require(folio.hasRole(folio.DEFAULT_ADMIN_ROLE(), oldOwnerTimelock), "old owner timelock not admin");
        require(folio.hasRole(folio.AUCTION_APPROVER(), oldTradingTimelock), "old trading timelock not trader");

        // upgrade Folio

        if (folioVersionHash == VERSION_2_0_0) {
            proxyAdmin.upgradeToVersion(address(folio), VERSION_2_0_0, "");
        } else {
            bytes memory data = abi.encodeWithSelector(
                Folio.setTrustedFillerRegistry.selector,
                folioDeployer.trustedFillerRegistry(),
                true
            );
            proxyAdmin.upgradeToVersion(address(folio), folioVersionHash, data);
        }

        // deploy replacement governors + timelocks

        address newOwnerTimelock;
        (newOwnerGovernor, newOwnerTimelock) = _deployReplacementGovernance(
            oldOwnerGovernor,
            guardians,
            deploymentNonce
        );

        address newTradingTimelock;
        (newTradingGovernor, newTradingTimelock) = _deployReplacementGovernance(
            oldTradingGovernor,
            guardians,
            deploymentNonce
        );

        // upgrade roles and owners

        proxyAdmin.transferOwnership(newOwnerTimelock);

        folio.grantRole(folio.DEFAULT_ADMIN_ROLE(), newOwnerTimelock);
        folio.grantRole(folio.AUCTION_APPROVER(), newTradingTimelock);

        folio.revokeRole(folio.AUCTION_APPROVER(), oldTradingTimelock);
        folio.revokeRole(folio.DEFAULT_ADMIN_ROLE(), oldOwnerTimelock);
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
    ///   - EXACTLY preserve the guardians
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

        uint256 proposalThreshold = oldGovernor.proposalThreshold() / 100; // lower by factor of 100
        require(proposalThreshold >= 1e14 && proposalThreshold <= 1e17, "proposal threshold not in expected range");

        uint256 quorumThreshold = oldGovernor.quorumNumerator() * 1e16; // multiply by 1e16 to convert raw percent to D18{1}
        require(quorumThreshold != 0 && quorumThreshold <= 2e17, "quorum threshold not in expected range");

        // stack-too-deep
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
            IVotes(address(oldGovernor.token())),
            deploymentNonce
        );

        // post validation

        assert(newGovernor != address(0));
        assert(newTimelock != address(0));
        assert(FolioGovernor(payable(newGovernor)).timelock() == newTimelock);

        TimelockController _newTimelock = TimelockController(payable(newTimelock));

        assert(_newTimelock.hasRole(_newTimelock.PROPOSER_ROLE(), newGovernor));
        assert(_newTimelock.hasRole(_newTimelock.EXECUTOR_ROLE(), newGovernor));

        assert(!_newTimelock.hasRole(_newTimelock.PROPOSER_ROLE(), address(oldGovernor)));
        assert(!_newTimelock.hasRole(_newTimelock.EXECUTOR_ROLE(), address(oldGovernor)));
        assert(!_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), address(oldGovernor)));

        assert(!_newTimelock.hasRole(_newTimelock.PROPOSER_ROLE(), address(0)));
        assert(!_newTimelock.hasRole(_newTimelock.EXECUTOR_ROLE(), address(0)));

        assert(!_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), newGovernor));
        assert(!_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), address(0)));

        for (uint256 i; i < guardians.length; i++) {
            assert(_newTimelock.hasRole(_newTimelock.CANCELLER_ROLE(), guardians[i]));
        }
    }
}
