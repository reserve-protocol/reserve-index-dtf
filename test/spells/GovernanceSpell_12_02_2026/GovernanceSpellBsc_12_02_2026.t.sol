// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./GenericGovernanceSpell_12_02_2026.t.sol";

contract GovernanceSpellBsc_12_02_2026_Test is GenericGovernanceSpell_12_02_2026_Test {
    constructor() {
        deploymentData = DeploymentData({
            deploymentType: Deployment.FORK,
            forkTarget: ForkNetwork.BSC,
            forkBlock: 82987668
        });

        // CMC20
        {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x7f7bf1d0B4bb7395bb68E99e20C732f3AEFFfe47;
            guardians[1] = 0xF49BCA9c5119e340E01Af83E452F0A27A5321898;

            CONFIGS.push(
                Config({
                    folio: Folio(0x2f8A339B5889FfaC4c5A956787cdA593b3c36867),
                    proxyAdmin: FolioProxyAdmin(0x91a42b577189A52F211E830b73dc5479D611579A),
                    stakingVaultGovernor: IFolioGovernor(0x3D047aBc5b95BC9989904c557789C1bCf3057d99),
                    guardians: guardians,
                    joinExistingGovernor: IFolioGovernor(address(0))
                })
            );
        }
    }
}
