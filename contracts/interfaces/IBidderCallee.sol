// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Optional bidder interface for callback
interface IBidderCallee {
    /// @param buyAmount {buyTok}
    function bidCallback(address buyToken, uint256 buyAmount, bytes calldata data) external;
}
