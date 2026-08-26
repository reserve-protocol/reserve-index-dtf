// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { RebalancingLibHarness } from "./RebalancingLibHarness.sol";

/**
 * @title InterpolatePriceHarness
 * @notice Harness to expose RebalancingLibHarness._interpolatePrice for Certora verification
 */
contract InterpolatePriceHarness {
    /// @notice Exponential price interpolation used by RebalancingLibHarness._priceSimplified
    /// @return p D27{buyTok/sellTok}
    function interpolatePrice(
        uint256 startPrice,
        uint256 endPrice,
        uint256 elapsed,
        uint256 auctionLength
    ) external pure returns (uint256 p) {
        return RebalancingLibHarness._interpolatePrice(startPrice, endPrice, elapsed, auctionLength);
    }
}
