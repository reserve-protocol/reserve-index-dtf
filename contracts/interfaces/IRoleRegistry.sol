// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IRoleRegistry {
    function isOwner(address account) external view returns (bool);

    function isOwnerOrEmergencyCouncil(address account) external view returns (bool);
}
