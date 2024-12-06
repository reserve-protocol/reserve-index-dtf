// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FolioFactory } from "@src/deployer/FolioFactory.sol";

contract FolioFactoryV2 is FolioFactory {
    constructor(address _daoFeeRegistry, address _versionRegistry) FolioFactory(_daoFeeRegistry, _versionRegistry) {}

    function version() public pure override returns (string memory) {
        return "2.0.0";
    }
}
