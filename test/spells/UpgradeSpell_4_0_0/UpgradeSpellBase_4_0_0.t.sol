// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./GenericUpgradeSpell_4_0_0.t.sol";

contract UpgradeSpellBase_4_0_0_Test is GenericUpgradeSpell_4_0_0_Test {
    struct Config {
        Folio folio;
        FolioProxyAdmin proxyAdmin;
    }

    Config[] public CONFIGS;

    constructor() {
        deploymentData = DeploymentData({
            deploymentType: Deployment.FORK,
            forkTarget: ForkNetwork.BASE,
            forkBlock: 30831054 // TODO update block after 4.0.0 is registered
        });

        // BGCI
        CONFIGS.push(
            Config({
                folio: Folio(0x23418De10d422AD71C9D5713a2B8991a9c586443),
                proxyAdmin: FolioProxyAdmin(0x2330a29DE3238b07b4a1Db70a244A25b8f21ab91)
            })
        );

        // CLX
        CONFIGS.push(
            Config({
                folio: Folio(0x44551CA46Fa5592bb572E20043f7C3D54c85cAD7),
                proxyAdmin: FolioProxyAdmin(0x4472F1f3aD832Bed3FDeF75ace6540c2f3E5a187)
            })
        );

        // ABX
        CONFIGS.push(
            Config({
                folio: Folio(0xeBcda5b80f62DD4DD2A96357b42BB6Facbf30267),
                proxyAdmin: FolioProxyAdmin(0xF3345fca866673BfB58b50F00691219a62Dd6Dc8)
            })
        );

        // MVTT10F
        CONFIGS.push(
            Config({
                folio: Folio(0xe8b46b116D3BdFA787CE9CF3f5aCC78dc7cA380E),
                proxyAdmin: FolioProxyAdmin(0xBe278Be45C265A589BD0bf8cDC6C9e5a04B3397D)
            })
        );

        // VTF
        CONFIGS.push(
            Config({
                folio: Folio(0x47686106181b3CEfe4eAf94C4c10b48Ac750370b),
                proxyAdmin: FolioProxyAdmin(0x7C1fAFfc7F3a52aa9Dbd265E5709202eeA3A8A48)
            })
        );

        // BDTF
        CONFIGS.push(
            Config({
                folio: Folio(0xb8753941196692E322846cfEE9C14C97AC81928A),
                proxyAdmin: FolioProxyAdmin(0xADC76fB0A5ae3495443E8df8D411FD37a836F763)
            })
        );

        // AI
        CONFIGS.push(
            Config({
                folio: Folio(0xfe45EDa533e97198d9f3dEEDA9aE6c147141f6F9),
                proxyAdmin: FolioProxyAdmin(0x456219b7897384217ca224f735DBbC30c395C87F)
            })
        );

        // MVDA25
        CONFIGS.push(
            Config({
                folio: Folio(0xD600e748C17Ca237Fcb5967Fa13d688AFf17Be78),
                proxyAdmin: FolioProxyAdmin(0xb467947f35697FadB46D10f36546E99A02088305)
            })
        );
    }

    function test_upgradeSpell_400_fork_base() public {
        for (uint256 i; i < CONFIGS.length; i++) {
            run_upgradeSpell_400_fork(CONFIGS[i].folio, CONFIGS[i].proxyAdmin);
        }
    }
}
