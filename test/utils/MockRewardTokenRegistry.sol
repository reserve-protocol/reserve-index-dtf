// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract MockRewardTokenRegistry {
    function isRegistered(address) external pure returns (bool) {
        return true;
    }
}
