// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev MockBidder contract for testing use only
contract MockBidder {
    using SafeERC20 for IERC20;

    bool public immutable honest;

    constructor(bool honest_) {
        honest = honest_;
    }

    function bidCallback(address buyToken, uint256 buyAmount, bytes calldata) external {
        if (honest) {
            IERC20(buyToken).safeTransfer(msg.sender, buyAmount);
        } else {
            IERC20(buyToken).safeTransfer(msg.sender, buyAmount - 1);
        }
    }
}
