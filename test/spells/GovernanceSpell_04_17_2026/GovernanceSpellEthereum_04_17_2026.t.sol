// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./GenericGovernanceSpell_04_17_2026.t.sol";

contract GovernanceSpellEthereum_04_17_2026_Test is GenericGovernanceSpell_04_17_2026_Test {
    constructor() {
        deploymentData = DeploymentData({
            deploymentType: Deployment.FORK,
            forkTarget: ForkNetwork.ETHEREUM,
            forkBlock: 25104004
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
                    oldFolioGovernor: IFolioGovernor(0x020d7c4a87485709D91E78AEeB2B2177ebFbaf41),
                    guardians: guardians
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
                    oldFolioGovernor: IFolioGovernor(0xFaD4823Ae478637fD8FfdafB6c912f63c8cd1Dd7),
                    guardians: guardians
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
                    oldFolioGovernor: IFolioGovernor(0x622c0b5aD82a2A47F330D4a2061a0e3562F583b0),
                    guardians: guardians
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
                    oldFolioGovernor: IFolioGovernor(0x404859dE65229b7596Fe58784b6572bB3732DfAc),
                    guardians: guardians
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
                    oldFolioGovernor: IFolioGovernor(0x8F56a509f39F16D30Da576C10B1a52908cA6ac4d),
                    guardians: guardians
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
                    oldFolioGovernor: IFolioGovernor(0xDd36672d48caA6c8c45E49e83DB266568446EEfe),
                    guardians: guardians
                })
            );
        }
    }

    function test_upgradeFlow_sharedNewStakingVault_fork() public {
        _runSharedNewStakingVaultFlow(
            _configByFolio(0x4E3B170DcBe704b248df5f56D488114acE01B1C5),
            _configByFolio(0xF91384484F4717314798E8975BCd904A35fc2BF1),
            "BED",
            "SMEL"
        );
    }

    function _runSharedNewStakingVaultFlow(
        Config memory firstCfg,
        Config memory secondCfg,
        string memory firstLabel,
        string memory secondLabel
    ) internal {
        address sharedStakingVault = firstCfg.stakingVaultGovernor.token();
        address oldSharedStakingVaultOwner = IOwnableStakingVault(sharedStakingVault).owner();
        assertEq(sharedStakingVault, secondCfg.stakingVaultGovernor.token(), "expected shared staking vault");

        address newUnderlying = IStakingVault(sharedStakingVault).asset();
        SuccessorDeployment memory stakingVaultDep = _deploySuccessorStakingVault(
            firstCfg,
            _doubleAddressArray(address(firstCfg.folio), address(secondCfg.folio)),
            keccak256(abi.encode(firstLabel, secondLabel, "shared-vault"))
        );

        assertEq(
            IOwnableStakingVault(sharedStakingVault).owner(),
            oldSharedStakingVaultOwner,
            "step 1 should not alter shared vault owner"
        );
        assertTrue(stakingVaultDep.newStakingVault != sharedStakingVault, "expected new staking vault path");
        assertEq(IStakingVault(stakingVaultDep.newStakingVault).asset(), newUnderlying, "new vault asset mismatch");
        _assertRewardTokens(
            stakingVaultDep.newStakingVault,
            _rewardTokensForUnderlying(
                newUnderlying,
                _doubleAddressArray(address(firstCfg.folio), address(secondCfg.folio))
            )
        );

        uint96 firstOldVaultFeePortionBefore = _feeRecipientPortion(firstCfg.folio, sharedStakingVault);
        uint96 firstNewVaultFeePortionBefore = _feeRecipientPortion(firstCfg.folio, stakingVaultDep.newStakingVault);
        assertGt(
            uint256(firstOldVaultFeePortionBefore),
            0,
            string.concat(firstLabel, " old vault should receive folio fees")
        );
        GovernanceSpell_04_17_2026.NewDeployment memory firstFolioDep = _upgradeFolio(
            firstCfg,
            IStakingVault(stakingVaultDep.newStakingVault),
            makeAddr(string.concat(firstLabel, "-folio-opt")),
            keccak256(abi.encode(firstLabel, "folio"))
        );
        assertEq(
            firstFolioDep.stakingVault,
            stakingVaultDep.newStakingVault,
            string.concat(firstLabel, " returned vault mismatch")
        );
        _assertFeeRecipientMigrated(
            firstCfg.folio,
            sharedStakingVault,
            stakingVaultDep.newStakingVault,
            firstOldVaultFeePortionBefore,
            firstNewVaultFeePortionBefore
        );
        _assertFolioGovernanceInstalled(firstCfg, firstFolioDep.newTimelock);
        assertEq(
            IFolioGovernor(firstFolioDep.newGovernor).token(),
            stakingVaultDep.newStakingVault,
            string.concat(firstLabel, " folio governor should use the upgraded staking vault")
        );

        uint96 secondOldVaultFeePortionBefore = _feeRecipientPortion(secondCfg.folio, sharedStakingVault);
        uint96 secondNewVaultFeePortionBefore = _feeRecipientPortion(secondCfg.folio, stakingVaultDep.newStakingVault);
        assertGt(
            uint256(secondOldVaultFeePortionBefore),
            0,
            string.concat(secondLabel, " old vault should receive folio fees")
        );
        GovernanceSpell_04_17_2026.NewDeployment memory secondFolioDep = _upgradeFolio(
            secondCfg,
            IStakingVault(stakingVaultDep.newStakingVault),
            makeAddr(string.concat(secondLabel, "-folio-opt")),
            keccak256(abi.encode(secondLabel, "folio"))
        );
        assertEq(
            secondFolioDep.stakingVault,
            stakingVaultDep.newStakingVault,
            string.concat(secondLabel, " returned vault mismatch")
        );
        _assertFeeRecipientMigrated(
            secondCfg.folio,
            sharedStakingVault,
            stakingVaultDep.newStakingVault,
            secondOldVaultFeePortionBefore,
            secondNewVaultFeePortionBefore
        );
        _assertFolioGovernanceInstalled(secondCfg, secondFolioDep.newTimelock);
        assertEq(
            IFolioGovernor(secondFolioDep.newGovernor).token(),
            stakingVaultDep.newStakingVault,
            string.concat(secondLabel, " folio governor should use the upgraded staking vault")
        );
        assertTrue(
            firstFolioDep.newGovernor != stakingVaultDep.newGovernor,
            string.concat(firstLabel, " folio governor should be distinct from staking vault governance")
        );
        assertTrue(
            secondFolioDep.newGovernor != stakingVaultDep.newGovernor,
            string.concat(secondLabel, " folio governor should be distinct from staking vault governance")
        );
        assertTrue(firstFolioDep.newGovernor != secondFolioDep.newGovernor, "folios should not share a governor");
        assertTrue(firstFolioDep.newTimelock != secondFolioDep.newTimelock, "folios should not share a timelock");

        _assertCannotCreateOptimisticStartRebalanceProposal(
            IReserveOptimisticGovernorLike(stakingVaultDep.newGovernor),
            firstCfg.folio,
            makeAddr("shared-staking-vault-opt"),
            string.concat(firstLabel, " optimistic start rebalance")
        );
        _assertCannotCreateOptimisticStartRebalanceProposal(
            IReserveOptimisticGovernorLike(stakingVaultDep.newGovernor),
            secondCfg.folio,
            makeAddr("shared-staking-vault-opt"),
            string.concat(secondLabel, " optimistic start rebalance")
        );

        _retireOldStakingVault(IOwnableStakingVault(sharedStakingVault));
    }

    function _configByFolio(address folio) internal view returns (Config memory cfg) {
        for (uint256 i; i < CONFIGS.length; i++) {
            if (address(CONFIGS[i].folio) == folio) return CONFIGS[i];
        }

        revert("CONFIG_NOT_FOUND");
    }
}
