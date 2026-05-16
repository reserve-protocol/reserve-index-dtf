// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./GenericGovernanceSpell_04_17_2026.t.sol";

contract GovernanceSpellBase_04_17_2026_Test is GenericGovernanceSpell_04_17_2026_Test {
    constructor() {
        deploymentData = DeploymentData({
            deploymentType: Deployment.FORK,
            forkTarget: ForkNetwork.BASE,
            forkBlock: 46051387
        });

        // LCAP
        {
            address[] memory guardians = new address[](1);
            guardians[0] = 0x718841C68eab4038EF389C154f8e91f9923b2fdA;

            CONFIGS.push(
                Config({
                    folio: Folio(0x4dA9A0f397dB1397902070f93a4D6ddBC0E0E6e8),
                    proxyAdmin: FolioProxyAdmin(0xf6Db82f6b5F343d74A1D88af9e58fA1d2D89562e),
                    stakingVaultGovernor: IFolioGovernor(0x2DEE428BD8131FAa4288750d707De6F3901AfE3c),
                    oldFolioGovernor: IFolioGovernor(0x719eDEd05c7a6468E44AcFBBD19b2DF2EED7759E),
                    guardians: guardians
                })
            );
        }

        // VLONE
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x82a28b41DF407a99Eb13F975856AaeEb757B98f4;
            guardians[1] = 0x7f7bf1d0B4bb7395bb68E99e20C732f3AEFFfe47;

            CONFIGS.push(
                Config({
                    folio: Folio(0xe00CFa595841fb331105b93C19827797C925E3E4),
                    proxyAdmin: FolioProxyAdmin(0x17747f766e375a73959EBc0dBc623A174D4DB317),
                    stakingVaultGovernor: IFolioGovernor(0x42F72247FeFe2a4702e7E7aa71E3e1784c46f6Ae),
                    oldFolioGovernor: IFolioGovernor(0xA4556436cc4547F07DC3E61474Ae5E839fF3D150),
                    guardians: guardians
                })
            );
        }

        // BGCI
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
            guardians[1] = 0xD8B0F4e54a8dac04E0A57392f5A630cEdb99C940;

            CONFIGS.push(
                Config({
                    folio: Folio(0x23418De10d422AD71C9D5713a2B8991a9c586443),
                    proxyAdmin: FolioProxyAdmin(0x2330a29DE3238b07b4a1Db70a244A25b8f21ab91),
                    stakingVaultGovernor: IFolioGovernor(0xbe8DDD7A3ad097DFa84EaBF4D57a879d0c41a148),
                    oldFolioGovernor: IFolioGovernor(0x858c2C08B4984AD4f045F8Bf6D85B916b723ed5b),
                    guardians: guardians
                })
            );
        }

        // CLANKER
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x1eaf444ebDf6495C57aD52A04C61521bBf564ace;
            guardians[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;

            CONFIGS.push(
                Config({
                    folio: Folio(0x44551CA46Fa5592bb572E20043f7C3D54c85cAD7),
                    proxyAdmin: FolioProxyAdmin(0x4472F1f3aD832Bed3FDeF75ace6540c2f3E5a187),
                    stakingVaultGovernor: IFolioGovernor(0xa83E456ebC4bCED953e64F085c8A8C4E2a8a5Fa0),
                    oldFolioGovernor: IFolioGovernor(0x1C58617D79daeE2F51DA6c98186334431D338721),
                    guardians: guardians
                })
            );
        }

        // ABX
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x9F7f914F53Ee403A7a5725f34fE8E6406A4f84cD;
            guardians[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;

            CONFIGS.push(
                Config({
                    folio: Folio(0xeBcda5b80f62DD4DD2A96357b42BB6Facbf30267),
                    proxyAdmin: FolioProxyAdmin(0xF3345fca866673BfB58b50F00691219a62Dd6Dc8),
                    stakingVaultGovernor: IFolioGovernor(0xcdd675d848372596E5eCc1B0FE9e88C1CBc609Af),
                    oldFolioGovernor: IFolioGovernor(0x6dFF5971cc446479450e51b5f939A250b11F5Ef5),
                    guardians: guardians
                })
            );
        }

        // MVTT10F
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0xD8B0F4e54a8dac04E0A57392f5A630cEdb99C940;
            guardians[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;

            CONFIGS.push(
                Config({
                    folio: Folio(0xe8b46b116D3BdFA787CE9CF3f5aCC78dc7cA380E),
                    proxyAdmin: FolioProxyAdmin(0xBe278Be45C265A589BD0bf8cDC6C9e5a04B3397D),
                    stakingVaultGovernor: IFolioGovernor(0xa29D5B7DACf13f417a87F9B5FF7C63d86e48F689),
                    oldFolioGovernor: IFolioGovernor(0x3d14EE40A64F30F3a3515FCA9Cf6787aCA1925b5),
                    guardians: guardians
                })
            );
        }
    }
}
