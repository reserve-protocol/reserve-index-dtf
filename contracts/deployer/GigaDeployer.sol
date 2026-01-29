// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract GigaDeployer {
    address public immutable optimisticGovDeployer;

    constructor(address _optimisticGovDeployer) {
        optimisticGovDeployer = _optimisticGovDeployer;
    }

    function deployFolio() public {}
}
