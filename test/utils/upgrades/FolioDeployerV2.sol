// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FolioDeployer } from "@src/folio/FolioDeployer.sol";
import { FolioV2 } from "./FolioV2.sol";

contract FolioDeployerV2 is FolioDeployer {
    constructor(
        address _daoFeeRegistry,
        address _versionRegistry,
        address _governorImplementation,
        address _timelockImplementation
    ) FolioDeployer(_daoFeeRegistry, _versionRegistry, _governorImplementation, _timelockImplementation) {
        daoFeeRegistry = _daoFeeRegistry;
        versionRegistry = _versionRegistry;

        folioImplementation = address(new FolioV2());
        governorImplementation = _governorImplementation;
        timelockImplementation = _timelockImplementation;
    }

    function version() public pure override returns (string memory) {
        return "2.0.0";
    }
}
