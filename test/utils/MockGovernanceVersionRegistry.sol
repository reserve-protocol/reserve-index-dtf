// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IReserveOptimisticGovernorDeployer } from "@reserve-protocol/reserve-governor/contracts/interfaces/IDeployer.sol";

interface IVersionedLike {
    function version() external view returns (string memory);
}

contract MockGovernanceVersionRegistry {
    IReserveOptimisticGovernorDeployer private _latestDeployer;
    bytes32 private _latestVersionHash;

    function registerVersion(IReserveOptimisticGovernorDeployer deployer) external {
        _latestDeployer = deployer;
        _latestVersionHash = keccak256(bytes(IVersionedLike(address(deployer)).version()));
    }

    function getLatestVersion()
        external
        view
        returns (
            bytes32 versionHash,
            string memory version,
            IReserveOptimisticGovernorDeployer deployer,
            bool deprecated
        )
    {
        deployer = _latestDeployer;
        versionHash = _latestVersionHash;
        version = IVersionedLike(address(deployer)).version();
        deprecated = false;
    }
}
