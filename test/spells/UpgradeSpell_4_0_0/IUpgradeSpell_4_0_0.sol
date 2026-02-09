// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IUpgradeSpell_4_0_0 {
    function cast(address folio, address proxyAdmin) external;
    function isTrackingDTF(address folio) external view returns (bool);
}