// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FolioDeployer } from "@src/folio/FolioDeployer.sol";

contract FolioDeployerV2 is FolioDeployer {
    constructor(
        address _daoFeeRegistry,
        address _versionRegistry,
        address _governorImplementation,
        address _timelockImplemntation
    ) FolioDeployer(_daoFeeRegistry, _versionRegistry, _governorImplementation, _timelockImplemntation) {}

    function version() public pure override returns (string memory) {
        return "2.0.0";
    }
}
