// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FolioDeployer, IGovernanceDeployer } from "@deployer/FolioDeployer.sol";
import { FolioV2 } from "./FolioV2.sol";

contract FolioDeployerV2 is FolioDeployer {
    constructor(
        address _daoFeeRegistry,
        address _versionRegistry,
        address _trustedFillerRegistry,
        IGovernanceDeployer _governanceDeployer
    ) FolioDeployer(_daoFeeRegistry, _versionRegistry, _trustedFillerRegistry, _governanceDeployer) {
        folioImplementation = address(new FolioV2());
    }

    function version() public pure override returns (string memory) {
        return "10.0.0";
    }
}
