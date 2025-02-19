// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISwap {
    function initialize(
        address _beneficiary,
        IERC20 _sell,
        IERC20 _buy,
        uint256 _sellAmount,
        uint256 _minBuyAmount
    ) external;

    function isValidSignature(bytes32 _hash, bytes calldata signature) external view returns (bytes4);

    function close() external;
}
