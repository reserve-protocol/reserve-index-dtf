// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ICowSettlement {
    function domainSeparator() external view returns (bytes32);
}

ICowSettlement constant COW_SETTLEMENT = ICowSettlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);
// TODO is this universal across chains?
