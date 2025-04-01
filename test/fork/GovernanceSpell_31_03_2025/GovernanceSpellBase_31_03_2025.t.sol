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
    }
}
