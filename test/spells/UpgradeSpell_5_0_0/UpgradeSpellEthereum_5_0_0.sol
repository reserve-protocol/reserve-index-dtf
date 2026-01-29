// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./GenericUpgradeSpell_5_0_0.t.sol";

contract UpgradeSpellEthereum_5_0_0_Test is GenericUpgradeSpell_5_0_0_Test {
    struct Config {
        Folio folio;
        FolioProxyAdmin proxyAdmin;
    }

    Config[] public CONFIGS;

    constructor() {
        deploymentData = DeploymentData({
            deploymentType: Deployment.FORK,
            forkTarget: ForkNetwork.ETHEREUM,
            forkBlock: 24336535
        });

        // BED
        CONFIGS.push(
            Config({
                folio: Folio(0x4E3B170DcBe704b248df5f56D488114acE01B1C5),
                proxyAdmin: FolioProxyAdmin(0xEAa356F6CD6b3fd15B47838d03cF34fa79F7c712)
            })
        );

        // DGI
        CONFIGS.push(
            Config({
                folio: Folio(0x9a1741E151233a82Cf69209A2F1bC7442B1fB29C),
                proxyAdmin: FolioProxyAdmin(0xe24e3DBBEd0db2a9aC2C1d2EA54c6132Dce181b7)
            })
        );

        // DFX
        CONFIGS.push(
            Config({
                folio: Folio(0x188D12Eb13a5Eadd0867074ce8354B1AD6f4790b),
                proxyAdmin: FolioProxyAdmin(0x0e3B2EF9701d5Ef230CB67Ee8851bA3071cf557C)
            })
        );

        // mvDEFI
        CONFIGS.push(
            Config({
                folio: Folio(0x20d81101D254729a6E689418526bE31e2c544290),
                proxyAdmin: FolioProxyAdmin(0x3927882f047944A9c561F29E204C370Dd84852Fd)
            })
        );

        // SMEL
        CONFIGS.push(
            Config({
                folio: Folio(0xF91384484F4717314798E8975BCd904A35fc2BF1),
                proxyAdmin: FolioProxyAdmin(0xDd885B0F2f97703B94d2790320b30017a17768BF)
            })
        );

        // mvRWA
        CONFIGS.push(
            Config({
                folio: Folio(0xA5cdea03B11042fc10B52aF9eCa48bb17A2107d2),
                proxyAdmin: FolioProxyAdmin(0x019318674560C233893aA31Bc0A380dc71dc2dDf)
            })
        );
    }

    function _setUp() public virtual override {
        super._setUp();

        spell = new UpgradeSpell_5_0_0();
    }

    function test_upgradeSpell_500_fork_ethereum() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            run_upgradeSpell_500_fork(CONFIGS[i].folio, CONFIGS[i].proxyAdmin);
        }
    }
}
