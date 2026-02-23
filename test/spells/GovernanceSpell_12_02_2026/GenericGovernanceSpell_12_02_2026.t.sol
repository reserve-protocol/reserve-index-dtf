// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../base/BaseTest.sol";

import { GovernanceSpell_12_02_2026, IFolioGovernor, IStakingVault } from "@spells/GovernanceSpell_12_02_2026.sol";
import { IReserveOptimisticGovernor } from "@reserve-protocol/reserve-governor/contracts/interfaces/IReserveOptimisticGovernor.sol";
import { IOptimisticSelectorRegistry } from "@reserve-protocol/reserve-governor/contracts/interfaces/IOptimisticSelectorRegistry.sol";
import { REBALANCE_MANAGER } from "@utils/Constants.sol";

interface IOwnableLike {
    function transferOwnership(address newOwner) external;
}

abstract contract GenericGovernanceSpell_12_02_2026_Test is BaseTest {
    struct Config {
        Folio folio;
        FolioProxyAdmin proxyAdmin;
        IFolioGovernor oldGovernor;
        IFolioGovernor oldTradingGovernor;
        address[] guardians;
        IFolioGovernor joinExistingGovernor;
    }

    Config[] public CONFIGS;
    GovernanceSpell_12_02_2026 public spell;

    function _setUp() public virtual override {
        super._setUp();
        
        spell = new GovernanceSpell_12_02_2026(optimisticGovernanceDeployer);
    }

    function test_deployGovernance_existingStakingVault_fork() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            Config memory cfg = CONFIGS[i];

            vm.prank(user2); // permissionless
            GovernanceSpell_12_02_2026.NewDeployment memory dep = spell.deployGovernance(
                cfg.folio,
                cfg.oldGovernor,
                3 days,
                _optimisticParams(),
                new IOptimisticSelectorRegistry.SelectorData[](0),
                new address[](0),
                cfg.guardians,
                false,
                bytes32(i)
            );

            assertEq(dep.newStakingVault, cfg.oldGovernor.token(), "expected existing staking vault path");
            assertEq(IFolioGovernor(dep.newGovernor).token(), cfg.oldGovernor.token(), "governor token mismatch");
            assertTrue(dep.newTimelock != address(0), "timelock should be set");
        }
    }

    function test_deployGovernance_newStakingVault_fork() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            Config memory cfg = CONFIGS[i];

            vm.prank(user2); // permissionless
            GovernanceSpell_12_02_2026.NewDeployment memory dep = spell.deployGovernance(
                cfg.folio,
                cfg.oldGovernor,
                3 days,
                _optimisticParams(),
                new IOptimisticSelectorRegistry.SelectorData[](0),
                new address[](0),
                cfg.guardians,
                true,
                bytes32(~i)
            );

            assertTrue(dep.newStakingVault != cfg.oldGovernor.token(), "expected new staking vault path");
            assertEq(IStakingVault(dep.newStakingVault).asset(), address(cfg.folio), "new vault should be vlDTF");
            assertEq(IStakingVault(dep.newStakingVault).owner(), dep.newTimelock, "new vault owner mismatch");
        }
    }

    function test_castTransferRoles_afterExistingVaultDeploy_fork() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            Config memory cfg = CONFIGS[i];

            vm.prank(user2); // permissionless
            GovernanceSpell_12_02_2026.NewDeployment memory dep = spell.deployGovernance(
                cfg.folio,
                cfg.oldGovernor,
                3 days,
                _optimisticParams(),
                new IOptimisticSelectorRegistry.SelectorData[](0),
                new address[](0),
                cfg.guardians,
                false,
                keccak256(abi.encode(i, "transfer"))
            );

            address stakingVault = cfg.oldGovernor.token();
            address stakingVaultOwner = IStakingVault(stakingVault).owner();
            vm.prank(stakingVaultOwner);
            IOwnableLike(stakingVault).transferOwnership(dep.newTimelock);

            vm.startPrank(cfg.oldGovernor.timelock());
            cfg.proxyAdmin.transferOwnership(address(spell));
            cfg.folio.grantRole(DEFAULT_ADMIN_ROLE, address(spell));
            spell.castTransferRoles(
                cfg.folio,
                cfg.proxyAdmin,
                cfg.oldGovernor,
                cfg.oldTradingGovernor,
                IFolioGovernor(dep.newGovernor)
            );
            vm.stopPrank();

            assertEq(cfg.proxyAdmin.owner(), dep.newTimelock, "proxy admin owner mismatch");
            assertEq(cfg.folio.getRoleMemberCount(REBALANCE_MANAGER), 1, "unexpected rebalance manager count");
            assertEq(cfg.folio.getRoleMember(REBALANCE_MANAGER, 0), dep.newTimelock, "rebalance manager mismatch");
            assertEq(cfg.folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "unexpected admin count");
            assertEq(cfg.folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), dep.newTimelock, "admin mismatch");
        }
    }

    function test_castTransferRoles_joinExistingGovernance_fork() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            Config memory cfg = CONFIGS[i];
            if (address(cfg.joinExistingGovernor) == address(0)) continue;

            address joinExistingTimelock = cfg.joinExistingGovernor.timelock();
            address joinExistingStakingVault = cfg.joinExistingGovernor.token();
            address stakingVaultOwner = IStakingVault(joinExistingStakingVault).owner();
            vm.prank(stakingVaultOwner);
            IOwnableLike(joinExistingStakingVault).transferOwnership(joinExistingTimelock);

            vm.startPrank(cfg.oldGovernor.timelock());
            cfg.proxyAdmin.transferOwnership(address(spell));
            cfg.folio.grantRole(DEFAULT_ADMIN_ROLE, address(spell));
            spell.castTransferRoles(
                cfg.folio,
                cfg.proxyAdmin,
                cfg.oldGovernor,
                cfg.oldTradingGovernor,
                cfg.joinExistingGovernor
            );
            vm.stopPrank();

            assertEq(cfg.proxyAdmin.owner(), joinExistingTimelock, "proxy admin owner mismatch");
            assertEq(cfg.folio.getRoleMemberCount(REBALANCE_MANAGER), 1, "unexpected rebalance manager count");
            assertEq(
                cfg.folio.getRoleMember(REBALANCE_MANAGER, 0),
                joinExistingTimelock,
                "rebalance manager mismatch"
            );
            assertEq(cfg.folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "unexpected admin count");
            assertEq(cfg.folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), joinExistingTimelock, "admin mismatch");
        }
    }

    function _optimisticParams()
        internal
        pure
        returns (IReserveOptimisticGovernor.OptimisticGovernanceParams memory)
    {
        return IReserveOptimisticGovernor.OptimisticGovernanceParams({
            vetoDelay: 1 seconds,
            vetoPeriod: 1 days,
            vetoThreshold: 0.05e18
        });
    }
}
