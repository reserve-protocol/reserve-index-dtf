// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./GenericGovernanceSpell_12_02_2026.t.sol";

contract GovernanceSpellBase_12_02_2026_Test is GenericGovernanceSpell_12_02_2026_Test {
    constructor() {
        deploymentData = DeploymentData({
            deploymentType: Deployment.FORK,
            forkTarget: ForkNetwork.BASE,
            forkBlock: 42440100
        });

        // LCAP
        {
            address[] memory guardians = new address[](3);
            guardians[0] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
            guardians[1] = 0x5e6EF4cFd64e29981fB3a8703a584DDE407032d2;
            guardians[2] = 0x718841C68eab4038EF389C154f8e91f9923b2fdA;

            CONFIGS.push(
                Config({
                    folio: Folio(0x4dA9A0f397dB1397902070f93a4D6ddBC0E0E6e8),
                    proxyAdmin: FolioProxyAdmin(0xf6Db82f6b5F343d74A1D88af9e58fA1d2D89562e),
                    stakingVaultGovernor: IFolioGovernor(0x2DEE428BD8131FAa4288750d707De6F3901AfE3c),
                    guardians: guardians,
                    joinExistingGovernor: IFolioGovernor(address(0))
                })
            );
        }

        // VLONE
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x82a28b41DF407a99Eb13F975856AaeEb757B98f4;
            guardians[1] = 0x7f7bf1d0B4bb7395bb68E99e20C732f3AEFFfe47;

            CONFIGS.push(Config({
                folio: Folio(0xe00CFa595841fb331105b93C19827797C925E3E4),
                proxyAdmin: FolioProxyAdmin(0x17747f766e375a73959EBc0dBc623A174D4DB317),
                stakingVaultGovernor: IFolioGovernor(0x42F72247FeFe2a4702e7E7aa71E3e1784c46f6Ae),
                guardians: guardians,
                joinExistingGovernor: IFolioGovernor(address(0))
            }));
        }

        // BGCI
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;
            guardians[1] = 0xD8B0F4e54a8dac04E0A57392f5A630cEdb99C940;

            CONFIGS.push(Config({
                folio: Folio(0x23418De10d422AD71C9D5713a2B8991a9c586443),
                proxyAdmin: FolioProxyAdmin(0x2330a29DE3238b07b4a1Db70a244A25b8f21ab91),
                stakingVaultGovernor: IFolioGovernor(0xbe8DDD7A3ad097DFa84EaBF4D57a879d0c41a148),
                guardians: guardians,
                joinExistingGovernor: IFolioGovernor(address(0))
            }));
        }

        // ZORA
        {
            address[] memory guardians = new address[](3);
            guardians[0] = 0x6BC2F0cefE18ec4e5AFEB8f810c7063BeD3f92B9;
            guardians[1] = 0x12808Cfbf64BE76aca0B13c523985BBb88015401;
            guardians[2] = 0x7f7bf1d0B4bb7395bb68E99e20C732f3AEFFfe47;

            CONFIGS.push(Config({
                folio: Folio(0x160c18476F6f5099f374033fbc695c9234Cda495),
                proxyAdmin: FolioProxyAdmin(0xE6179EEF5312487e6caB447356c855eEE805781E),
                stakingVaultGovernor: IFolioGovernor(0xE54C0534D71BAaCdeC2B9D0C576d73D76fef0869),
                guardians: guardians,
                joinExistingGovernor: IFolioGovernor(address(0))
            }));
        }

        // AIndex
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x5edB66B4c01355B07dF3Ea9e4c2508e4Cc542c6a;
            guardians[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;

            CONFIGS.push(Config({
                folio: Folio(0xfe45EDa533e97198d9f3dEEDA9aE6c147141f6F9),
                proxyAdmin: FolioProxyAdmin(0x456219b7897384217ca224f735DBbC30c395C87F),
                stakingVaultGovernor: IFolioGovernor(0x61FA1b18F37A361E961c5fB07D730EE37DC0dC4d),
                guardians: guardians,
                joinExistingGovernor: IFolioGovernor(address(0))
            }));
        }

        // CLANKER
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x1eaf444ebDf6495C57aD52A04C61521bBf564ace;
            guardians[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;

            CONFIGS.push(Config({
                folio: Folio(0x44551CA46Fa5592bb572E20043f7C3D54c85cAD7),
                proxyAdmin: FolioProxyAdmin(0x4472F1f3aD832Bed3FDeF75ace6540c2f3E5a187),
                stakingVaultGovernor: IFolioGovernor(0xa83E456ebC4bCED953e64F085c8A8C4E2a8a5Fa0),
                guardians: guardians,
                joinExistingGovernor: IFolioGovernor(address(0))
            }));
        }

        // VIRTUALS
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x50B7a52556e0746F190663fc58a8133427fB6be2;
            guardians[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;

            CONFIGS.push(Config({
                folio: Folio(0x47686106181b3CEfe4eAf94C4c10b48Ac750370b),
                proxyAdmin: FolioProxyAdmin(0x7C1fAFfc7F3a52aa9Dbd265E5709202eeA3A8A48),
                stakingVaultGovernor: IFolioGovernor(0xD8f869c8d9EE22f4dD786EA37eFcd236810F9942),
                guardians: guardians,
                joinExistingGovernor: IFolioGovernor(address(0))
            }));
        }

        // BDTF
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0xA80149d051764f9e4854ee83B197bAD648046d51;
            guardians[1] = 0x6f1D6b86d4ad705385e751e6e88b0FdFDBAdf298;

            CONFIGS.push(Config({
                folio: Folio(0xb8753941196692E322846cfEE9C14C97AC81928A),
                proxyAdmin: FolioProxyAdmin(0xADC76fB0A5ae3495443E8df8D411FD37a836F763),
                stakingVaultGovernor: IFolioGovernor(0xAD3e49d114F193583c1904f93EF25784C381874b),
                guardians: guardians,
                joinExistingGovernor: IFolioGovernor(address(0))
            }));
        }
    }
}
