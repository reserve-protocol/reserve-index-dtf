// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.25;

interface IVersioned {
    function version() external view returns (string memory);
}
