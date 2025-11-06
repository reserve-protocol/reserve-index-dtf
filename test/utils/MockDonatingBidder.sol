// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockBidder } from "utils/MockBidder.sol";

/// @dev MockDonatingBidder contract for testing use only
contract MockDonatingBidder is MockBidder {
    using SafeERC20 for IERC20;

    IERC20 public immutable donationToken;
    uint256 public immutable donationAmount;

    constructor(bool honest_, IERC20 donationToken_, uint256 donationAmount_) MockBidder(honest_) {
        donationToken = donationToken_;
        donationAmount = donationAmount_;
    }

    function bidCallback(address buyToken, uint256 buyAmount, bytes calldata data) public virtual override {
        super.bidCallback(buyToken, buyAmount, data);
        donationToken.safeTransfer(msg.sender, donationAmount);
        // donate back tokens at end of callback
    }
}
