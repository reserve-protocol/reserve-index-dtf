// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./GenericGovernanceSpell_31_03_2025.t.sol";

contract GovernanceSpellEthereum_31_03_2025_Test is GovernanceSpell_31_03_2025_Test {
    constructor() {
        deploymentData = DeploymentData({
            deploymentType: Deployment.FORK,
            forkTarget: ForkNetwork.ETHEREUM,
            forkBlock: 22169163
        });

        address[] memory guardians = new address[](1);

        // BED
        guardians[0] = 0x280730d9277EF586d58dB74c277Aa710ca8F87C9;
        CONFIGS.push(
            Config({
                folio: Folio(0x4E3B170DcBe704b248df5f56D488114acE01B1C5),
                proxyAdmin: FolioProxyAdmin(0xEAa356F6CD6b3fd15B47838d03cF34fa79F7c712),
                ownerGovernor: FolioGovernor(payable(0x9a7Dc78a458D76a9f6C87A41185F95643eb4C96C)),
                tradingGovernor: FolioGovernor(payable(0x8d9e57FB8063bA9bAe45Db29BBEFe6dc0BA3543a)),
                stakingVaultGovernor: FolioGovernor(payable(0xD2f9c1D649F104e5D6B9453f3817c05911Cf765E)),
                guardians: guardians
            })
        );

        // DGI
        guardians[0] = 0xf163D77B8EfC151757fEcBa3D463f3BAc7a4D808;
        CONFIGS.push(
            Config({
                folio: Folio(0x9a1741E151233a82Cf69209A2F1bC7442B1fB29C),
                proxyAdmin: FolioProxyAdmin(0xe24e3DBBEd0db2a9aC2C1d2EA54c6132Dce181b7),
                ownerGovernor: FolioGovernor(payable(0xDd36672d48caA6c8c45E49e83DB266568446EEfe)),
                tradingGovernor: FolioGovernor(payable(0x665339C6E5168A0F23e5a1aDAB568027E8df2673)),
                stakingVaultGovernor: FolioGovernor(payable(0xb01C1070E191A3a5535912489Fbff6Cc3f4bb865)),
                guardians: guardians
            })
        );

        // DFX
        guardians[0] = 0xE86399fE6d7007FdEcb08A2ee1434Ee677a04433;
        CONFIGS.push(
            Config({
                folio: Folio(0x188D12Eb13a5Eadd0867074ce8354B1AD6f4790b),
                proxyAdmin: FolioProxyAdmin(0x0e3B2EF9701d5Ef230CB67Ee8851bA3071cf557C),
                ownerGovernor: FolioGovernor(payable(0x404859dE65229b7596Fe58784b6572bB3732DfAc)),
                tradingGovernor: FolioGovernor(payable(0x1742b681cabE3111598E1bE2A9313C787FE906C6)),
                stakingVaultGovernor: FolioGovernor(payable(0xCaA7E91E752db5d79912665774be7B9Bf5171b9E)),
                guardians: guardians
            })
        );

        // mvDEFI
        guardians[0] = 0x38afC3aA2c76b4cA1F8e1DabA68e998e1F4782DB;
        CONFIGS.push(
            Config({
                folio: Folio(0x20d81101D254729a6E689418526bE31e2c544290),
                proxyAdmin: FolioProxyAdmin(0x3927882f047944A9c561F29E204C370Dd84852Fd),
                ownerGovernor: FolioGovernor(payable(0xa5168b7b5c081a2098420892c9DA26B6B30fc496)),
                tradingGovernor: FolioGovernor(payable(0x5AaA18F0F1449A43f4de5E4C175885Da4f70AF04)),
                stakingVaultGovernor: FolioGovernor(payable(0x83d070B91aef472CE993BCC25907e7c3959483b4)),
                guardians: guardians
            })
        );

        // SMEL
        guardians[0] = 0x280730d9277EF586d58dB74c277Aa710ca8F87C9;
        CONFIGS.push(
            Config({
                folio: Folio(0xF91384484F4717314798E8975BCd904A35fc2BF1),
                proxyAdmin: FolioProxyAdmin(0xDd885B0F2f97703B94d2790320b30017a17768BF),
                ownerGovernor: FolioGovernor(payable(0x9b579a9ae9447b5afe23f9a0914Ec728eCA38057)),
                tradingGovernor: FolioGovernor(payable(0xe54BfD225C18AB118D252bf8e850106c5A83908E)),
                stakingVaultGovernor: FolioGovernor(payable(0xD2f9c1D649F104e5D6B9453f3817c05911Cf765E)),
                guardians: guardians
            })
        );

        // mvRWA
        guardians[0] = 0x38afC3aA2c76b4cA1F8e1DabA68e998e1F4782DB;
        CONFIGS.push(
            Config({
                folio: Folio(0xA5cdea03B11042fc10B52aF9eCa48bb17A2107d2),
                proxyAdmin: FolioProxyAdmin(0x019318674560C233893aA31Bc0A380dc71dc2dDf),
                ownerGovernor: FolioGovernor(payable(0x58e72A9a9E9Dc5209D02335d5Ac67eD28a86EAe9)),
                tradingGovernor: FolioGovernor(payable(0x87A7CD8EC8D6e3A87aC57Ef1BEC3B5f3C72080F7)),
                stakingVaultGovernor: FolioGovernor(payable(0x83d070B91aef472CE993BCC25907e7c3959483b4)),
                guardians: guardians
            })
        );
    }
}
