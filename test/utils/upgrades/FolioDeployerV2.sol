// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FolioDeployer, IGovernanceDeployer } from "@src/folio/FolioDeployer.sol";

contract FolioDeployerV2 is FolioDeployer {
    constructor(
        address _folioImplementation,
        address _daoFeeRegistry,
        address _versionRegistry,
        IGovernanceDeployer _governanceDeployer
    ) FolioDeployer(_daoFeeRegistry, _versionRegistry, _governanceDeployer) {
        folioImplementation = _folioImplementation;
    }

    function version() public pure override returns (string memory) {
        return "2.0.0";
    }
}
