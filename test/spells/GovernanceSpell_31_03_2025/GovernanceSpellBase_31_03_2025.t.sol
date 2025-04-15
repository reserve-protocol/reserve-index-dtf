// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./GenericGovernanceSpell_31_03_2025.t.sol";

contract GovernanceSpellBase_31_03_2025_Test is GovernanceSpell_31_03_2025_Test {
    constructor() {
        deploymentData = DeploymentData({
            deploymentType: Deployment.FORK,
            forkTarget: ForkNetwork.BASE,
            forkBlock: 28331720
        });

        address[] memory guardians = new address[](1);

        // BGCI
        guardians[0] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        CONFIGS.push(
            Config({
                folio: Folio(0x23418De10d422AD71C9D5713a2B8991a9c586443),
                proxyAdmin: FolioProxyAdmin(0x2330a29DE3238b07b4a1Db70a244A25b8f21ab91),
                ownerGovernor: FolioGovernor(payable(0x858c2C08B4984AD4f045F8Bf6D85B916b723ed5b)),
                tradingGovernor: FolioGovernor(payable(0xc94A762854D7D3a0252E6c00a23C9360978ccB57)),
                stakingVaultGovernor: FolioGovernor(payable(0xbe8DDD7A3ad097DFa84EaBF4D57a879d0c41a148)),
                guardians: guardians
            })
        );

        // CLX
        guardians[0] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        CONFIGS.push(
            Config({
                folio: Folio(0x44551CA46Fa5592bb572E20043f7C3D54c85cAD7),
                proxyAdmin: FolioProxyAdmin(0x4472F1f3aD832Bed3FDeF75ace6540c2f3E5a187),
                ownerGovernor: FolioGovernor(payable(0x1C58617D79daeE2F51DA6c98186334431D338721)),
                tradingGovernor: FolioGovernor(payable(0x106F0302d12A51691B278bD04b1b447ccE4a9943)),
                stakingVaultGovernor: FolioGovernor(payable(0xa83E456ebC4bCED953e64F085c8A8C4E2a8a5Fa0)),
                guardians: guardians
            })
        );

        // ABX
        guardians[0] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        CONFIGS.push(
            Config({
                folio: Folio(0xeBcda5b80f62DD4DD2A96357b42BB6Facbf30267),
                proxyAdmin: FolioProxyAdmin(0xF3345fca866673BfB58b50F00691219a62Dd6Dc8),
                ownerGovernor: FolioGovernor(payable(0x6dFF5971cc446479450e51b5f939A250b11F5Ef5)),
                tradingGovernor: FolioGovernor(payable(0x0e7049f86D7EF4F724104A1c62290f8b7FC9Ac38)),
                stakingVaultGovernor: FolioGovernor(payable(0xcdd675d848372596E5eCc1B0FE9e88C1CBc609Af)),
                guardians: guardians
            })
        );

        // MVTT10F
        guardians[0] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        CONFIGS.push(
            Config({
                folio: Folio(0xe8b46b116D3BdFA787CE9CF3f5aCC78dc7cA380E),
                proxyAdmin: FolioProxyAdmin(0xBe278Be45C265A589BD0bf8cDC6C9e5a04B3397D),
                ownerGovernor: FolioGovernor(payable(0x3d14EE40A64F30F3a3515FCA9Cf6787aCA1925b5)),
                tradingGovernor: FolioGovernor(payable(0x65e90CbF1e03150273808506A4d16e32AC50eC7f)),
                stakingVaultGovernor: FolioGovernor(payable(0xa29D5B7DACf13f417a87F9B5FF7C63d86e48F689)),
                guardians: guardians
            })
        );

        // VTF
        guardians[0] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        CONFIGS.push(
            Config({
                folio: Folio(0x47686106181b3CEfe4eAf94C4c10b48Ac750370b),
                proxyAdmin: FolioProxyAdmin(0x7C1fAFfc7F3a52aa9Dbd265E5709202eeA3A8A48),
                ownerGovernor: FolioGovernor(payable(0xA8Ce43762De703D285B019fAC8829148e3013442)),
                tradingGovernor: FolioGovernor(payable(0xc570368439B4E26e30e6fB8A51122b1D33c3b3BA)),
                stakingVaultGovernor: FolioGovernor(payable(0xD8f869c8d9EE22f4dD786EA37eFcd236810F9942)),
                guardians: guardians
            })
        );

        // BDTF
        guardians[0] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        CONFIGS.push(
            Config({
                folio: Folio(0xb8753941196692E322846cfEE9C14C97AC81928A),
                proxyAdmin: FolioProxyAdmin(0xADC76fB0A5ae3495443E8df8D411FD37a836F763),
                ownerGovernor: FolioGovernor(payable(0x0D5a4a0FEe1c4f0422938608400d00B9E0037684)),
                tradingGovernor: FolioGovernor(payable(0x9B4f0C49C63387Ca448101cA4c73009a525e7d45)),
                stakingVaultGovernor: FolioGovernor(payable(0xAD3e49d114F193583c1904f93EF25784C381874b)),
                guardians: guardians
            })
        );

        // AI
        guardians[0] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        CONFIGS.push(
            Config({
                folio: Folio(0xfe45EDa533e97198d9f3dEEDA9aE6c147141f6F9),
                proxyAdmin: FolioProxyAdmin(0x456219b7897384217ca224f735DBbC30c395C87F),
                ownerGovernor: FolioGovernor(payable(0x26305E88587ecFde34a9DCE37D7CB292a3b51B02)),
                tradingGovernor: FolioGovernor(payable(0x854D046c9335e278799F747a51EF18e2B47CE585)),
                stakingVaultGovernor: FolioGovernor(payable(0x61FA1b18F37A361E961c5fB07D730EE37DC0dC4d)),
                guardians: guardians
            })
        );

        // MVDA25
        guardians[0] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
        CONFIGS.push(
            Config({
                folio: Folio(0xD600e748C17Ca237Fcb5967Fa13d688AFf17Be78),
                proxyAdmin: FolioProxyAdmin(0xb467947f35697FadB46D10f36546E99A02088305),
                ownerGovernor: FolioGovernor(payable(0x9C799BB988679E5caB0D7e8b5480a4015E25F403)),
                tradingGovernor: FolioGovernor(payable(0xe74A96b2E334a213c20a7f42f524D114E50B0988)),
                stakingVaultGovernor: FolioGovernor(payable(0xa29D5B7DACf13f417a87F9B5FF7C63d86e48F689)),
                guardians: guardians
            })
        );
    }
}
