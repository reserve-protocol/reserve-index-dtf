// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./GenericGovernanceSpell_12_02_2026.t.sol";

contract GovernanceSpellEthereum_12_02_2026_Test is GenericGovernanceSpell_12_02_2026_Test {
    constructor() {
        deploymentData = DeploymentData({
            deploymentType: Deployment.FORK,
            forkTarget: ForkNetwork.ETHEREUM,
            forkBlock: 24505217
        });

        // BED
        {
            address[] memory guardians = new address[](1);
            guardians[0] = 0xdE3B1a502a6f25B92434a00C4169B195B2F1528c;

            CONFIGS.push(Config({
                folio: Folio(0x323c03c48660fE31186fa82c289b0766d331Ce21),
                proxyAdmin: FolioProxyAdmin(0x0b79E381eD8D6d676C772Dba61cbeEA0B2d28c7D),
                oldGovernor: IFolioGovernor(0x020d7c4a87485709D91E78AEeB2B2177ebFbaf41),
                oldTradingGovernor: IFolioGovernor(0xEDEbEFE7179C5FC74853ad30147beeCc20860579),
                guardians: guardians,
                joinExistingGovernor: IFolioGovernor(address(0))
            }));
        }
    }
}
