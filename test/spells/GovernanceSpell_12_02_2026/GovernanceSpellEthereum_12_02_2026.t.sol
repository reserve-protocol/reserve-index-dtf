// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./GenericGovernanceSpell_12_02_2026.t.sol";
import { REBALANCE_MANAGER } from "@utils/Constants.sol";

contract GovernanceSpellEthereum_12_02_2026_Test is GenericGovernanceSpell_12_02_2026_Test {
    constructor() {
        deploymentData = DeploymentData({
            deploymentType: Deployment.FORK,
            forkTarget: ForkNetwork.ETHEREUM,
            forkBlock: 24505217
        });

        // OPEN
        {
            address[] memory guardians = new address[](1);
            guardians[0] = 0xdE3B1a502a6f25B92434a00C4169B195B2F1528c;

            CONFIGS.push(
                Config({
                    folio: Folio(0x323c03c48660fE31186fa82c289b0766d331Ce21),
                    proxyAdmin: FolioProxyAdmin(0x0b79E381eD8D6d676C772Dba61cbeEA0B2d28c7D),
                    stakingVaultGovernor: IFolioGovernor(0x020d7c4a87485709D91E78AEeB2B2177ebFbaf41),
                    guardians: guardians,
                    joinExistingGovernor: IFolioGovernor(address(0))
                })
            );
        }

        // BED
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x280730d9277EF586d58dB74c277Aa710ca8F87C9;
            guardians[1] = 0xd5fE2780Eb882D1Da78f2136b81c2A4395488C98;

            CONFIGS.push(
                Config({
                    folio: Folio(0x4E3B170DcBe704b248df5f56D488114acE01B1C5),
                    proxyAdmin: FolioProxyAdmin(0xEAa356F6CD6b3fd15B47838d03cF34fa79F7c712),
                    stakingVaultGovernor: IFolioGovernor(0xD2f9c1D649F104e5D6B9453f3817c05911Cf765E),
                    guardians: guardians,
                    joinExistingGovernor: IFolioGovernor(address(0))
                })
            );
        }

        // SMEL
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x280730d9277EF586d58dB74c277Aa710ca8F87C9;
            guardians[1] = 0xd5fE2780Eb882D1Da78f2136b81c2A4395488C98;

            CONFIGS.push(
                Config({
                    folio: Folio(0xF91384484F4717314798E8975BCd904A35fc2BF1),
                    proxyAdmin: FolioProxyAdmin(0xDd885B0F2f97703B94d2790320b30017a17768BF),
                    stakingVaultGovernor: IFolioGovernor(0xD2f9c1D649F104e5D6B9453f3817c05911Cf765E),
                    guardians: guardians,
                    joinExistingGovernor: IFolioGovernor(address(0))
                })
            );
        }

        // mvRWA
        {
            address[] memory guardians = new address[](1);
            guardians[0] = 0x38afC3aA2c76b4cA1F8e1DabA68e998e1F4782DB;

            CONFIGS.push(
                Config({
                    folio: Folio(0xA5cdea03B11042fc10B52aF9eCa48bb17A2107d2),
                    proxyAdmin: FolioProxyAdmin(0x019318674560C233893aA31Bc0A380dc71dc2dDf),
                    stakingVaultGovernor: IFolioGovernor(0x83d070B91aef472CE993BCC25907e7c3959483b4),
                    guardians: guardians,
                    joinExistingGovernor: IFolioGovernor(address(0))
                })
            );
        }

        // DFX
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0xE86399fE6d7007FdEcb08A2ee1434Ee677a04433;
            guardians[1] = 0xd5fE2780Eb882D1Da78f2136b81c2A4395488C98;

            CONFIGS.push(
                Config({
                    folio: Folio(0x188D12Eb13a5Eadd0867074ce8354B1AD6f4790b),
                    proxyAdmin: FolioProxyAdmin(0x0e3B2EF9701d5Ef230CB67Ee8851bA3071cf557C),
                    stakingVaultGovernor: IFolioGovernor(0xCaA7E91E752db5d79912665774be7B9Bf5171b9E),
                    guardians: guardians,
                    joinExistingGovernor: IFolioGovernor(address(0))
                })
            );
        }

        // ixEdel
        {
            address[] memory guardians = new address[](1);
            guardians[0] = 0xe93F01A34B0a1f037e48381b8a9e03AECb2ff77d;

            CONFIGS.push(
                Config({
                    folio: Folio(0xe4a10951f962e6cB93Cb843a4ef05d2F99DB1F94),
                    proxyAdmin: FolioProxyAdmin(0x7a6C7064e0069D60A4D90B16545C1051d3487f63),
                    stakingVaultGovernor: IFolioGovernor(0xB3b141c115203932B6127423D33f60C83cAb3F69),
                    guardians: guardians,
                    joinExistingGovernor: IFolioGovernor(address(0))
                })
            );
        }

        // DGI
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0xf163D77B8EfC151757fEcBa3D463f3BAc7a4D808;
            guardians[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;

            CONFIGS.push(
                Config({
                    folio: Folio(0x9a1741E151233a82Cf69209A2F1bC7442B1fB29C),
                    proxyAdmin: FolioProxyAdmin(0xe24e3DBBEd0db2a9aC2C1d2EA54c6132Dce181b7),
                    stakingVaultGovernor: IFolioGovernor(0xb01C1070E191A3a5535912489Fbff6Cc3f4bb865),
                    guardians: guardians,
                    joinExistingGovernor: IFolioGovernor(address(0))
                })
            );
        }
    }

    // mvDEFI -- joinExistingGovernor

    function test_upgradeFolio_joinExistingGovernance_fork() public override {
        address[] memory mvDefiGuardians = new address[](2);
        mvDefiGuardians[0] = 0x38afC3aA2c76b4cA1F8e1DabA68e998e1F4782DB;
        mvDefiGuardians[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;

        Config memory mvRwaCfg = _configByFolio(0xA5cdea03B11042fc10B52aF9eCa48bb17A2107d2);

        Config memory mvDefiCfg = Config({
            folio: Folio(0x20d81101D254729a6E689418526bE31e2c544290),
            proxyAdmin: FolioProxyAdmin(0x3927882f047944A9c561F29E204C370Dd84852Fd),
            stakingVaultGovernor: IFolioGovernor(0x83d070B91aef472CE993BCC25907e7c3959483b4),
            guardians: mvDefiGuardians,
            joinExistingGovernor: IFolioGovernor(address(0))
        });

        address sharedStakingVault = mvRwaCfg.stakingVaultGovernor.token();
        assertEq(sharedStakingVault, mvDefiCfg.stakingVaultGovernor.token(), "expected shared staking vault");

        address oldStakingVaultOwner = IStakingVault(sharedStakingVault).owner();
        vm.startPrank(oldStakingVaultOwner);
        IOwnableLike(sharedStakingVault).transferOwnership(address(spell));
        GovernanceSpell_12_02_2026.NewDeployment memory dep = spell.upgradeStakingVault(
            mvRwaCfg.stakingVaultGovernor,
            _optimisticParams(),
            new IOptimisticSelectorRegistry.SelectorData[](0),
            new address[](0),
            mvRwaCfg.guardians,
            address(0),
            keccak256("mvRWA-shared-vault")
        );
        vm.stopPrank();

        // First folio using shared staking vault governor
        vm.startPrank(mvRwaCfg.proxyAdmin.owner());
        mvRwaCfg.proxyAdmin.transferOwnership(address(spell));
        mvRwaCfg.folio.grantRole(DEFAULT_ADMIN_ROLE, address(spell));
        spell.upgradeFolio(mvRwaCfg.folio, mvRwaCfg.proxyAdmin, IFolioGovernor(dep.newGovernor));
        vm.stopPrank();

        // Second folio joins the same newly-deployed governor/timelock
        vm.startPrank(mvDefiCfg.proxyAdmin.owner());
        mvDefiCfg.proxyAdmin.transferOwnership(address(spell));
        mvDefiCfg.folio.grantRole(DEFAULT_ADMIN_ROLE, address(spell));
        spell.upgradeFolio(mvDefiCfg.folio, mvDefiCfg.proxyAdmin, IFolioGovernor(dep.newGovernor));
        vm.stopPrank();

        assertEq(mvDefiCfg.proxyAdmin.owner(), dep.newTimelock, "proxy admin owner mismatch");
        assertEq(mvDefiCfg.folio.getRoleMemberCount(REBALANCE_MANAGER), 1, "unexpected rebalance manager count");
        assertEq(mvDefiCfg.folio.getRoleMember(REBALANCE_MANAGER, 0), dep.newTimelock, "rebalance manager mismatch");
        assertEq(mvDefiCfg.folio.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "unexpected admin count");
        assertEq(mvDefiCfg.folio.getRoleMember(DEFAULT_ADMIN_ROLE, 0), dep.newTimelock, "admin mismatch");
    }

    function _configByFolio(address folio) internal view returns (Config memory cfg) {
        for (uint256 i; i < CONFIGS.length; i++) {
            if (address(CONFIGS[i].folio) == folio) return CONFIGS[i];
        }

        revert("CONFIG_NOT_FOUND");
    }
}
