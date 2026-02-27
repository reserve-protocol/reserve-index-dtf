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
import { REBALANCE_MANAGER } from "@utils/Constants.sol";

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
        address[] guardians;
        IFolioGovernor joinExistingGovernor;
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
            address oldStakingVaultOwner = IOwnableStakingVault(oldStakingVault).owner();
            address optimisticProposer = makeAddr(string.concat("new-opt-", vm.toString(i)));
            address standardProposer = makeAddr(string.concat("new-std-", vm.toString(i)));

            vm.startPrank(oldStakingVaultOwner);
            IOwnableStakingVault(oldStakingVault).transferOwnership(address(spell));
            GovernanceSpell_12_02_2026.NewDeployment memory dep = spell.upgradeStakingVault(
                cfg.stakingVaultGovernor,
                _optimisticParams(),
                _selectorDataForFolio(cfg.folio, optimisticProposer),
                _singleAddressArray(optimisticProposer),
                cfg.guardians,
                address(cfg.folio),
                keccak256(abi.encode(i, "proposal-new"))
            );
            vm.stopPrank();

            assertTrue(dep.newStakingVault != cfg.stakingVaultGovernor.token(), "expected new staking vault path");
            assertEq(IStakingVault(dep.newStakingVault).asset(), address(cfg.folio), "new vault should be vlDTF");
            assertEq(IFolioGovernor(dep.newGovernor).timelock(), dep.newTimelock, "governor timelock mismatch");
            assertTrue(
                IAccessControlEnumerable(dep.newStakingVault).hasRole(DEFAULT_ADMIN_ROLE, dep.newTimelock),
                "new vault admin mismatch"
            );
            assertEq(IOwnableStakingVault(oldStakingVault).owner(), address(0), "old vault should be deprecated");

            vm.startPrank(cfg.proxyAdmin.owner());
            cfg.proxyAdmin.transferOwnership(address(spell));
            cfg.folio.grantRole(DEFAULT_ADMIN_ROLE, address(spell));
            spell.upgradeFolio(cfg.folio, cfg.proxyAdmin, IFolioGovernor(dep.newGovernor));
            vm.stopPrank();

            assertEq(cfg.proxyAdmin.owner(), dep.newTimelock, "proxy admin owner mismatch");
            assertEq(cfg.folio.getRoleMemberCount(REBALANCE_MANAGER), 1, "unexpected rebalance manager count");
            assertEq(cfg.folio.getRoleMember(REBALANCE_MANAGER, 0), dep.newTimelock, "rebalance manager mismatch");
            assertEq(cfg.folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "unexpected admin count");
            assertEq(cfg.folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), dep.newTimelock, "admin mismatch");

            _assertCanCreateBothProposalTypes(
                IReserveOptimisticGovernorLike(dep.newGovernor),
                IStakingVault(dep.newStakingVault),
                cfg.folio,
                standardProposer,
                optimisticProposer
            );
        }
    }

    function test_upgradeFolio_joinExistingGovernance_fork() public virtual {
        for (uint256 i; i < CONFIGS.length; i++) {
            Config memory cfg = CONFIGS[i];
            if (address(cfg.joinExistingGovernor) == address(0)) continue;
            _logFolioSymbol(cfg.folio);

            address joinExistingTimelock = cfg.joinExistingGovernor.timelock();
            address joinExistingStakingVault = cfg.joinExistingGovernor.token();
            assertTrue(
                IAccessControlEnumerable(joinExistingStakingVault).hasRole(DEFAULT_ADMIN_ROLE, joinExistingTimelock),
                "join-existing vault admin mismatch"
            );

            vm.startPrank(cfg.proxyAdmin.owner());
            cfg.proxyAdmin.transferOwnership(address(spell));
            cfg.folio.grantRole(DEFAULT_ADMIN_ROLE, address(spell));
            spell.upgradeFolio(cfg.folio, cfg.proxyAdmin, cfg.joinExistingGovernor);
            vm.stopPrank();

            assertEq(cfg.proxyAdmin.owner(), joinExistingTimelock, "proxy admin owner mismatch");
            assertEq(cfg.folio.getRoleMemberCount(REBALANCE_MANAGER), 1, "unexpected rebalance manager count");
            assertEq(cfg.folio.getRoleMember(REBALANCE_MANAGER, 0), joinExistingTimelock, "rebalance manager mismatch");
            assertEq(cfg.folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "unexpected admin count");
            assertEq(cfg.folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), joinExistingTimelock, "admin mismatch");
        }
    }

    // === Internal ===

    function _logFolioSymbol(Folio folio) internal view {
        console2.log("Folio symbol", folio.symbol());
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
        address proposer
    ) internal pure returns (IOptimisticSelectorRegistry.SelectorData[] memory selectorData) {
        selectorData = new IOptimisticSelectorRegistry.SelectorData[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Folio.setName.selector;
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData({
            proposer: proposer,
            target: address(folio),
            selectors: selectors
        });
    }

    function _singleAddressArray(address value) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = value;
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
