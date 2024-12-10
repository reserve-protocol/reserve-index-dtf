// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FolioDeployer } from "@src/deployer/FolioDeployer.sol";

contract FolioDeployerV2 is FolioDeployer {
    constructor(address _daoFeeRegistry, address _versionRegistry) FolioDeployer(_daoFeeRegistry, _versionRegistry) {}

    function version() public pure override returns (string memory) {
        return "2.0.0";
    }
}
