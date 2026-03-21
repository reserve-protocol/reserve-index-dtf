// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../base/BaseTest.sol";

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IAccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import { console2 } from "forge-std/console2.sol";

import { GovernanceSpell_12_02_2026, IFolioGovernor, IOwnableStakingVault, IStakingVault } from "@spells/GovernanceSpell_12_02_2026.sol";
import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";
import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";
import { REBALANCE_MANAGER, MAX_FEE_RECIPIENTS } from "@utils/Constants.sol";

interface IReserveOptimisticGovernorLike is IFolioGovernor {
    function proposeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256);

    function isOptimistic(uint256 proposalId) external view returns (bool);
}

abstract contract GenericGovernanceSpell_12_02_2026_Test is BaseTest {
    struct Config {
        Folio folio;
        FolioProxyAdmin proxyAdmin;
        IFolioGovernor stakingVaultGovernor;
        IFolioGovernor oldFolioGovernor;
        address[] guardians;
    }

    Config[] public CONFIGS;
    GovernanceSpell_12_02_2026 public spell;

    function _setUp() public virtual override {
        super._setUp();
        spell = new GovernanceSpell_12_02_2026(optimisticGovernanceDeployer);
    }

    function test_upgradeFolio_newStakingVault_fork() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            Config memory cfg = CONFIGS[i];
            _logFolioSymbol(cfg.folio);

            address oldStakingVault = cfg.stakingVaultGovernor.token();
            address oldFolioStakingVault = cfg.oldFolioGovernor.token();
            address oldStakingVaultOwner = IOwnableStakingVault(oldStakingVault).owner();
            address folioOptimisticProposer = makeAddr(string.concat("new-folio-opt-", vm.toString(i)));
            address standardProposer = makeAddr(string.concat("new-std-", vm.toString(i)));

            vm.startPrank(oldStakingVaultOwner);
            IOwnableStakingVault(oldStakingVault).transferOwnership(address(spell));
            GovernanceSpell_12_02_2026.NewDeployment memory stakingVaultDep = spell.upgradeStakingVault(
                cfg.stakingVaultGovernor,
                _optimisticParams(),
                new IOptimisticSelectorRegistry.SelectorData[](0),
                new address[](0),
                cfg.guardians,
                address(cfg.folio),
                keccak256(abi.encode(i, "proposal-new"))
            );
            vm.stopPrank();

            assertTrue(
                stakingVaultDep.newStakingVault != cfg.stakingVaultGovernor.token(),
                "expected new staking vault path"
            );
            assertEq(
                IStakingVault(stakingVaultDep.newStakingVault).asset(),
                address(cfg.folio),
                "new vault should be vlDTF"
            );
            assertEq(
                IFolioGovernor(stakingVaultDep.newGovernor).timelock(),
                stakingVaultDep.newTimelock,
                "governor timelock mismatch"
            );
            assertTrue(
                IAccessControlEnumerable(stakingVaultDep.newStakingVault).hasRole(
                    DEFAULT_ADMIN_ROLE,
                    stakingVaultDep.newTimelock
                ),
                "new vault admin mismatch"
            );
            assertEq(IOwnableStakingVault(oldStakingVault).owner(), address(0), "old vault should be deprecated");

            uint96 oldVaultFeePortionBefore = _feeRecipientPortion(cfg.folio, oldFolioStakingVault);
            uint96 newVaultFeePortionBefore = _feeRecipientPortion(cfg.folio, stakingVaultDep.newStakingVault);
            assertGt(uint256(oldVaultFeePortionBefore), 0, "old vault should receive folio fees");

            GovernanceSpell_12_02_2026.NewDeployment memory folioDep = _upgradeFolio(
                cfg,
                IFolioGovernor(stakingVaultDep.newGovernor),
                folioOptimisticProposer,
                keccak256(abi.encode(i, "folio-new"))
            );

            assertEq(
                folioDep.newStakingVault,
                stakingVaultDep.newStakingVault,
                "folio governor should use the upgraded staking vault"
            );
            assertTrue(folioDep.newGovernor != stakingVaultDep.newGovernor, "folio governor should be distinct");
            assertTrue(folioDep.newTimelock != stakingVaultDep.newTimelock, "folio timelock should be distinct");
            assertEq(IFolioGovernor(folioDep.newGovernor).timelock(), folioDep.newTimelock, "admin mismatch");
            assertEq(IFolioGovernor(folioDep.newGovernor).token(), folioDep.newStakingVault, "token mismatch");
            _assertFolioGovernanceInstalled(cfg, folioDep.newTimelock);
            _assertFeeRecipientMigrated(
                cfg.folio,
                oldFolioStakingVault,
                folioDep.newStakingVault,
                oldVaultFeePortionBefore,
                newVaultFeePortionBefore
            );

            _assertCanCreateBothProposalTypes(
                IReserveOptimisticGovernorLike(folioDep.newGovernor),
                IStakingVault(folioDep.newStakingVault),
                cfg.folio,
                standardProposer,
                folioOptimisticProposer
            );
        }
    }

    function test_upgradeFolio_existingStakingVault_fork() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            Config memory cfg = CONFIGS[i];
            _logFolioSymbol(cfg.folio);

            address existingStakingVault = cfg.stakingVaultGovernor.token();
            address oldStakingVault = cfg.oldFolioGovernor.token();
            address optimisticProposer = makeAddr(string.concat("existing-opt-", vm.toString(i)));
            address standardProposer = makeAddr(string.concat("existing-std-", vm.toString(i)));

            uint96 oldVaultFeePortionBefore = _feeRecipientPortion(cfg.folio, oldStakingVault);
            uint96 newVaultFeePortionBefore = _feeRecipientPortion(cfg.folio, existingStakingVault);
            if (oldStakingVault != existingStakingVault) {
                assertGt(uint256(oldVaultFeePortionBefore), 0, "old vault should receive folio fees");
            }

            GovernanceSpell_12_02_2026.NewDeployment memory dep = _upgradeFolio(
                cfg,
                cfg.stakingVaultGovernor,
                optimisticProposer,
                keccak256(abi.encode(i, "folio-existing"))
            );

            assertEq(dep.newStakingVault, existingStakingVault, "expected existing staking vault path");
            assertEq(IFolioGovernor(dep.newGovernor).token(), existingStakingVault, "governor token mismatch");
            assertEq(IFolioGovernor(dep.newGovernor).timelock(), dep.newTimelock, "governor timelock mismatch");
            assertTrue(dep.newGovernor != address(cfg.stakingVaultGovernor), "folio governor should be distinct");
            assertTrue(dep.newGovernor != address(cfg.oldFolioGovernor), "folio governor should be newly deployed");
            _assertFolioGovernanceInstalled(cfg, dep.newTimelock);

            if (oldStakingVault != existingStakingVault) {
                _assertFeeRecipientMigrated(
                    cfg.folio,
                    oldStakingVault,
                    existingStakingVault,
                    oldVaultFeePortionBefore,
                    newVaultFeePortionBefore
                );
            } else {
                assertEq(
                    _feeRecipientPortion(cfg.folio, existingStakingVault),
                    newVaultFeePortionBefore,
                    "existing vault fee share should be unchanged"
                );
            }

            _assertCanCreateBothProposalTypes(
                IReserveOptimisticGovernorLike(dep.newGovernor),
                IStakingVault(dep.newStakingVault),
                cfg.folio,
                standardProposer,
                optimisticProposer
            );
        }
    }

    // === Internal ===

    function _logFolioSymbol(Folio folio) internal view {
        console2.log("Folio symbol", folio.symbol());
    }

    function _upgradeFolio(
        Config memory cfg,
        IFolioGovernor existingStakingVaultGovernor,
        address optimisticProposer,
        bytes32 deploymentNonce
    ) internal returns (GovernanceSpell_12_02_2026.NewDeployment memory dep) {
        address oldFolioTimelock = cfg.oldFolioGovernor.timelock();
        assertEq(cfg.proxyAdmin.owner(), oldFolioTimelock, "old folio timelock should own proxy admin");

        vm.startPrank(oldFolioTimelock);
        cfg.proxyAdmin.transferOwnership(address(spell));
        cfg.folio.grantRole(DEFAULT_ADMIN_ROLE, address(spell));
        dep = spell.upgradeFolio(
            cfg.folio,
            cfg.proxyAdmin,
            existingStakingVaultGovernor,
            cfg.oldFolioGovernor,
            _optimisticParams(),
            _selectorDataForFolio(cfg.folio, optimisticProposer),
            _singleAddressArray(optimisticProposer),
            cfg.guardians,
            deploymentNonce
        );
        vm.stopPrank();
    }

    function _assertFolioGovernanceInstalled(Config memory cfg, address expectedTimelock) internal view {
        assertEq(cfg.proxyAdmin.owner(), expectedTimelock, "proxy admin owner mismatch");
        assertEq(cfg.folio.getRoleMemberCount(REBALANCE_MANAGER), 1, "unexpected rebalance manager count");
        assertEq(cfg.folio.getRoleMember(REBALANCE_MANAGER, 0), expectedTimelock, "rebalance manager mismatch");
        assertEq(cfg.folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "unexpected admin count");
        assertEq(cfg.folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), expectedTimelock, "admin mismatch");
    }

    function _assertCanCreateBothProposalTypes(
        IReserveOptimisticGovernorLike governor,
        IStakingVault stakingVault,
        Folio folio,
        address standardProposer,
        address optimisticProposer
    ) internal {
        uint256 proposalThreshold = governor.proposalThreshold();
        _seedVotes(address(stakingVault), standardProposer, proposalThreshold + 1e18);

        // Standard proposal (pessimistic path)
        (
            address[] memory standardTargets,
            uint256[] memory standardValues,
            bytes[] memory standardCalldatas
        ) = _singleCall(address(folio), 0, abi.encodeCall(Folio.setName, ("standard proposal")));

        vm.prank(standardProposer);
        uint256 standardProposalId = governor.propose(
            standardTargets,
            standardValues,
            standardCalldatas,
            "standard proposal"
        );
        assertEq(uint256(governor.state(standardProposalId)), uint256(IGovernor.ProposalState.Pending));
        assertFalse(governor.isOptimistic(standardProposalId));

        // Optimistic proposal (fast path)
        (
            address[] memory optimisticTargets,
            uint256[] memory optimisticValues,
            bytes[] memory optimisticCalldatas
        ) = _singleCall(address(folio), 0, abi.encodeCall(Folio.setName, ("optimistic proposal")));

        vm.prank(optimisticProposer);
        uint256 optimisticProposalId = governor.proposeOptimistic(
            optimisticTargets,
            optimisticValues,
            optimisticCalldatas,
            "optimistic proposal"
        );
        assertEq(uint256(governor.state(optimisticProposalId)), uint256(IGovernor.ProposalState.Pending));
        assertTrue(governor.isOptimistic(optimisticProposalId));
    }

    function _seedVotes(address stakingVault, address voter, uint256 amount) internal {
        deal(stakingVault, voter, amount, true);
        vm.prank(voter);
        IVotes(stakingVault).delegate(voter);
        vm.warp(block.timestamp + 1);
    }

    function _selectorDataForFolio(
        Folio folio,
        address
    ) internal pure returns (IOptimisticSelectorRegistry.SelectorData[] memory selectorData) {
        selectorData = new IOptimisticSelectorRegistry.SelectorData[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Folio.setName.selector;
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData({
            target: address(folio),
            selectors: selectors
        });
    }

    function _singleAddressArray(address value) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = value;
    }

    function _feeRecipientPortion(Folio folio, address recipient) internal view returns (uint96 portion) {
        for (uint256 i; i < MAX_FEE_RECIPIENTS; i++) {
            try folio.feeRecipients(i) returns (address feeRecipient, uint96 feePortion) {
                if (feeRecipient == recipient) portion += feePortion;
            } catch {
                break;
            }
        }
    }

    function _assertFeeRecipientMigrated(
        Folio folio,
        address oldStakingVault,
        address newStakingVault,
        uint96 oldVaultFeePortionBefore,
        uint96 newVaultFeePortionBefore
    ) internal view {
        assertEq(_feeRecipientPortion(folio, oldStakingVault), 0, "old vault should not receive folio fees");
        assertEq(
            _feeRecipientPortion(folio, newStakingVault),
            oldVaultFeePortionBefore + newVaultFeePortionBefore,
            "new vault should receive migrated folio fee share"
        );
    }

    function _singleCall(
        address target,
        uint256 value,
        bytes memory calldata_
    ) internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        values[0] = value;
        calldatas[0] = calldata_;
    }

    function _optimisticParams() internal pure returns (IReserveOptimisticGovernor.OptimisticGovernanceParams memory) {
        return
            IReserveOptimisticGovernor.OptimisticGovernanceParams({
                vetoDelay: 1 seconds,
                vetoPeriod: 1 days,
                vetoThreshold: 0.05e18
            });
    }
}
