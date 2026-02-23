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
                    oldGovernor: IFolioGovernor(0x719eDEd05c7a6468E44AcFBBD19b2DF2EED7759E),
                    oldTradingGovernor: IFolioGovernor(0xF9EdB4491fBd5E1185e05ecbA2d69251Dd869096),
                    guardians: guardians,
                    joinExistingGovernor: IFolioGovernor(address(0))
                })
            );
        }
    }
}
