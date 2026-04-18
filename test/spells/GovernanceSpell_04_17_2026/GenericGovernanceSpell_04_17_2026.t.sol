// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../base/BaseTest.sol";

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IAccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import { console2 } from "forge-std/console2.sol";

import { GovernanceSpell_04_17_2026, IFolioGovernor, IOwnableStakingVault, IStakingVault } from "@spells/GovernanceSpell_04_17_2026.sol";
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

interface IRetiredStakingVaultLike is IOwnableStakingVault {
    function unstakingDelay() external view returns (uint256);
}

interface IRewardedStakingVaultLike is IStakingVault {
    function getAllRewardTokens() external view returns (address[] memory);
}

abstract contract GenericGovernanceSpell_04_17_2026_Test is BaseTest {
    struct Config {
        Folio folio;
        FolioProxyAdmin proxyAdmin;
        IFolioGovernor stakingVaultGovernor;
        IFolioGovernor oldFolioGovernor;
        address[] guardians;
    }

    struct SuccessorDeployment {
        address newStakingVault;
        address newGovernor;
        address newTimelock;
        address newSelectorRegistry;
    }

    Config[] public CONFIGS;
    GovernanceSpell_04_17_2026 public spell;

    function _setUp() public virtual override {
        super._setUp();
        spell = new GovernanceSpell_04_17_2026(optimisticGovernanceDeployer);
    }

    function test_upgradeFlow_fork() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            Config memory cfg = CONFIGS[i];
            _logFolioSymbol(cfg.folio);
            _runUpgradeFlowCase(cfg, i);
        }
    }

    // === Internal ===

    function _logFolioSymbol(Folio folio) internal view {
        console2.log("Folio symbol", folio.symbol());
    }

    function _upgradeFolio(
        Config memory cfg,
        IStakingVault newStakingVault,
        address optimisticProposer,
        bytes32 deploymentNonce
    ) internal returns (GovernanceSpell_04_17_2026.NewDeployment memory dep) {
        address oldFolioTimelock = cfg.oldFolioGovernor.timelock();
        assertEq(cfg.proxyAdmin.owner(), oldFolioTimelock, "old folio timelock should own proxy admin");

        vm.startPrank(oldFolioTimelock);
        cfg.proxyAdmin.transferOwnership(address(spell));
        cfg.folio.grantRole(DEFAULT_ADMIN_ROLE, address(spell));
        dep = spell.upgradeFolio(
            cfg.folio,
            cfg.proxyAdmin,
            newStakingVault,
            cfg.oldFolioGovernor,
            _optimisticParams(),
            _selectorDataForFolio(cfg.folio, optimisticProposer),
            _singleAddressArray(optimisticProposer),
            cfg.guardians,
            deploymentNonce
        );
        vm.stopPrank();
    }

    function _runUpgradeFlowCase(Config memory cfg, uint256 configIndex) internal {
        uint256 snapshot = vm.snapshotState();
        IOwnableStakingVault oldStakingVault = IOwnableStakingVault(cfg.stakingVaultGovernor.token());
        SuccessorDeployment memory stakingVaultDep;

        {
            address oldStakingVaultOwner = oldStakingVault.owner();
            address newUnderlying = IStakingVault(address(oldStakingVault)).asset();
            address[] memory expectedRewardTokens = _rewardTokensForUnderlying(
                newUnderlying,
                _singleAddressArray(address(cfg.folio))
            );

            stakingVaultDep = _deploySuccessorStakingVault(
                cfg,
                _singleAddressArray(address(cfg.folio)),
                new address[](0),
                keccak256(abi.encode(configIndex, "proposal-new"))
            );

            assertEq(oldStakingVault.owner(), oldStakingVaultOwner, "step 1 should not alter old vault owner");
            _assertSuccessorStakingVaultDeployment(address(oldStakingVault), stakingVaultDep, newUnderlying, expectedRewardTokens);
        }

        {
            address oldFolioStakingVault = cfg.oldFolioGovernor.token();
            address folioOptimisticProposer = makeAddr(string.concat("new-folio-opt-", vm.toString(configIndex)));
            address standardProposer = makeAddr(string.concat("new-std-", vm.toString(configIndex)));
            uint96 oldVaultFeePortionBefore = _feeRecipientPortion(cfg.folio, oldFolioStakingVault);
            uint96 newVaultFeePortionBefore = _feeRecipientPortion(cfg.folio, stakingVaultDep.newStakingVault);
            assertGt(uint256(oldVaultFeePortionBefore), 0, "old vault should receive folio fees");

            GovernanceSpell_04_17_2026.NewDeployment memory folioDep = _upgradeFolio(
                cfg,
                IStakingVault(stakingVaultDep.newStakingVault),
                folioOptimisticProposer,
                keccak256(abi.encode(configIndex, "folio-new"))
            );

            assertEq(folioDep.stakingVault, stakingVaultDep.newStakingVault, "folio upgrade should return new vault");
            assertTrue(folioDep.newGovernor != stakingVaultDep.newGovernor, "folio governor should be distinct");
            assertTrue(folioDep.newTimelock != stakingVaultDep.newTimelock, "folio timelock should be distinct");
            assertEq(IFolioGovernor(folioDep.newGovernor).timelock(), folioDep.newTimelock, "admin mismatch");
            assertEq(
                IFolioGovernor(folioDep.newGovernor).token(),
                stakingVaultDep.newStakingVault,
                "folio governor should use the upgraded staking vault"
            );
            _assertFolioGovernanceInstalled(cfg, folioDep.newTimelock);
            _assertFeeRecipientMigrated(
                cfg.folio,
                oldFolioStakingVault,
                stakingVaultDep.newStakingVault,
                oldVaultFeePortionBefore,
                newVaultFeePortionBefore
            );

            _assertCanCreateBothProposalTypes(
                IReserveOptimisticGovernorLike(folioDep.newGovernor),
                IStakingVault(stakingVaultDep.newStakingVault),
                cfg.folio,
                standardProposer,
                folioOptimisticProposer
            );
        }

        _retireOldStakingVault(oldStakingVault);

        vm.revertToState(snapshot);
    }

    function _deploySuccessorStakingVault(
        Config memory cfg,
        address[] memory folios,
        address[] memory optimisticProposers,
        bytes32 deploymentNonce
    ) internal returns (SuccessorDeployment memory dep) {
        address newUnderlying = IStakingVault(cfg.stakingVaultGovernor.token()).asset();
        address[] memory rewardTokens = _rewardTokensForUnderlying(newUnderlying, folios);
        _registerRewardTokens(rewardTokens);

        address permissionlessCaller = makeAddr("permissionless-step1-caller");
        GovernanceSpell_04_17_2026.NewDeployment memory newDeployment;
        vm.prank(permissionlessCaller);
        newDeployment = spell.deploySuccessorStakingVault(
            cfg.stakingVaultGovernor,
            _optimisticParams(),
            _selectorDataForStartRebalanceFolios(folios),
            optimisticProposers,
            cfg.guardians,
            rewardTokens,
            deploymentNonce
        );

        dep = SuccessorDeployment({
            newStakingVault: newDeployment.stakingVault,
            newGovernor: newDeployment.newGovernor,
            newTimelock: newDeployment.newTimelock,
            newSelectorRegistry: newDeployment.newSelectorRegistry
        });
    }

    function _assertSuccessorStakingVaultDeployment(
        address oldStakingVault,
        SuccessorDeployment memory dep,
        address newUnderlying,
        address[] memory expectedRewardTokens
    ) internal view {
        assertTrue(dep.newStakingVault != oldStakingVault, "expected new staking vault path");
        assertEq(IStakingVault(dep.newStakingVault).asset(), newUnderlying, "new vault asset mismatch");
        assertEq(keccak256(bytes(IStakingVault(dep.newStakingVault).version())), keccak256(bytes("1.0.0")), "new vault version mismatch");
        assertEq(IFolioGovernor(dep.newGovernor).timelock(), dep.newTimelock, "governor timelock mismatch");
        assertEq(
            IAccessControlEnumerable(dep.newStakingVault).getRoleMemberCount(DEFAULT_ADMIN_ROLE),
            1,
            "unexpected new vault admin count"
        );
        assertTrue(
            IAccessControlEnumerable(dep.newStakingVault).hasRole(DEFAULT_ADMIN_ROLE, dep.newTimelock),
            "new vault admin mismatch"
        );
        _assertRewardTokens(dep.newStakingVault, expectedRewardTokens);
    }

    function _assertFolioGovernanceInstalled(Config memory cfg, address expectedTimelock) internal view {
        assertEq(cfg.proxyAdmin.owner(), expectedTimelock, "proxy admin owner mismatch");
        assertEq(cfg.folio.getRoleMemberCount(REBALANCE_MANAGER), 1, "unexpected rebalance manager count");
        assertEq(cfg.folio.getRoleMember(REBALANCE_MANAGER, 0), expectedTimelock, "rebalance manager mismatch");
        assertEq(cfg.folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "unexpected admin count");
        assertEq(cfg.folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), expectedTimelock, "admin mismatch");
    }

    function _assertRewardTokens(address stakingVault, address[] memory expectedRewardTokens) internal view {
        address[] memory rewardTokens = IRewardedStakingVaultLike(stakingVault).getAllRewardTokens();
        assertEq(rewardTokens.length, expectedRewardTokens.length, "unexpected reward token count");

        for (uint256 i; i < expectedRewardTokens.length; i++) {
            assertEq(rewardTokens[i], expectedRewardTokens[i], "reward token mismatch");
        }
    }

    function _retireOldStakingVault(IOwnableStakingVault oldStakingVault) internal {
        address oldStakingVaultOwner = oldStakingVault.owner();
        assertTrue(oldStakingVaultOwner != address(0), "old vault should still be owned");

        vm.startPrank(oldStakingVaultOwner);
        oldStakingVault.transferOwnership(address(spell));
        spell.retireOldStakingVault(oldStakingVault);
        vm.stopPrank();

        assertEq(oldStakingVault.owner(), address(0), "old vault should be retired");
        assertEq(IRetiredStakingVaultLike(address(oldStakingVault)).unstakingDelay(), 0, "old vault should unlock");
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

    function _assertCanCreateOptimisticStartRebalanceProposal(
        IReserveOptimisticGovernorLike governor,
        Folio folio,
        address optimisticProposer,
        string memory description
    ) internal {
        (
            address[] memory optimisticTargets,
            uint256[] memory optimisticValues,
            bytes[] memory optimisticCalldatas
        ) = _singleCall(address(folio), 0, _startRebalanceCalldata());

        vm.prank(optimisticProposer);
        uint256 optimisticProposalId = governor.proposeOptimistic(
            optimisticTargets,
            optimisticValues,
            optimisticCalldatas,
            description
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

    function _selectorDataForStartRebalanceFolios(address[] memory folios)
        internal
        pure
        returns (IOptimisticSelectorRegistry.SelectorData[] memory selectorData)
    {
        selectorData = new IOptimisticSelectorRegistry.SelectorData[](folios.length);

        for (uint256 i; i < folios.length; i++) {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = Folio.startRebalance.selector;
            selectorData[i] = IOptimisticSelectorRegistry.SelectorData({
                target: folios[i],
                selectors: selectors
            });
        }
    }

    function _rewardTokensForUnderlying(address newUnderlying, address[] memory folios)
        internal
        pure
        returns (address[] memory rewardTokens)
    {
        uint256 rewardTokenCount;
        address[] memory uniqueRewardTokens = new address[](folios.length);

        for (uint256 i; i < folios.length; i++) {
            address folio = folios[i];
            if (folio == address(0) || folio == newUnderlying) continue;

            bool alreadyAdded;
            for (uint256 j; j < rewardTokenCount; j++) {
                if (uniqueRewardTokens[j] == folio) {
                    alreadyAdded = true;
                    break;
                }
            }
            if (alreadyAdded) continue;

            uniqueRewardTokens[rewardTokenCount] = folio;
            rewardTokenCount++;
        }

        rewardTokens = new address[](rewardTokenCount);
        for (uint256 i; i < rewardTokenCount; i++) {
            rewardTokens[i] = uniqueRewardTokens[i];
        }
    }

    function _singleAddressArray(address value) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = value;
    }

    function _doubleAddressArray(address first, address second) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = first;
        arr[1] = second;
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

    function _startRebalanceCalldata() internal pure returns (bytes memory calldata_) {
        IFolio.TokenRebalanceParams[] memory tokens = new IFolio.TokenRebalanceParams[](0);
        IFolio.RebalanceLimits memory limits = IFolio.RebalanceLimits({ low: 1, spot: 1, high: 1 });
        calldata_ = abi.encodeCall(Folio.startRebalance, (tokens, limits, 0, 1));
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
