import { IFolio } from "@interfaces/IFolio.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { D18, D27 } from "@utils/Constants.sol";
import { MathLib } from "@utils/MathLib.sol";


library RebalancingLibHarness {
    /// Get the price of a token pair within an auction at the current timestamp
    /// If startTime == endTime, startPrice is used.
    /// @return p D27{buyTok/sellTok}
    function _priceSimplified(
        IFolio.Rebalance storage rebalance,
        IFolio.Auction storage auction,
        address sellToken,
        address buyToken
    ) external view returns (uint256 p) {
        IFolio.PriceRange memory sellPrices = auction.prices[address(sellToken)];
        IFolio.PriceRange memory buyPrices = auction.prices[address(buyToken)];

        // ensure auction is ongoing and token pair is in it
        require(
            auction.rebalanceNonce == rebalance.nonce &&
                sellToken != buyToken &&
                rebalance.details[address(sellToken)].inRebalance &&
                rebalance.details[address(buyToken)].inRebalance &&
                sellPrices.low != 0 && // in auction check
                buyPrices.low != 0 && // in auction check
                block.timestamp >= auction.startTime &&
                block.timestamp <= auction.endTime,
            IFolio.Folio__AuctionNotOngoing()
        );

        // D27{buyTok/sellTok} = D27{UoA/sellTok} * D27 / D27{UoA/buyTok}
        uint256 startPrice = Math.mulDiv(sellPrices.high, D27, buyPrices.low, Math.Rounding.Ceil);
        if (block.timestamp == auction.startTime) {
            return startPrice;
        }

        // D27{buyTok/sellTok} = D27{UoA/sellTok} * D27 / D27{UoA/buyTok}
        uint256 endPrice = Math.mulDiv(sellPrices.low, D27, buyPrices.high, Math.Rounding.Ceil);
        if (block.timestamp == auction.endTime) {
            return endPrice;
        }

        // {s}
        uint256 elapsed = block.timestamp - auction.startTime;
        uint256 auctionLength = auction.endTime - auction.startTime;

        p = _interpolatePrice(startPrice, endPrice, elapsed, auctionLength);

        if (p < endPrice) {
            p = endPrice;
        }
    }

    function _interpolatePrice(uint256 startPrice, uint256 endPrice, uint256 elapsed, uint256 auctionLength) internal pure returns (uint256 p) {
        // D18{1}
        // k = ln(P_0 / P_t) / t
        uint256 k = MathLib.ln(Math.mulDiv(startPrice, D18, endPrice)) / auctionLength;

        // P_t = P_0 * e ^ -kt
        // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
        p = Math.mulDiv(startPrice, MathLib.exp(-1 * int256(k * elapsed)), D18, Math.Rounding.Ceil);
    }

    function _priceConstant(
        IFolio.Rebalance storage rebalance,
        IFolio.Auction storage auction,
        address sellToken,
        address buyToken
    ) external returns (uint256) {
        IFolio.PriceRange memory sellPrices = auction.prices[address(sellToken)];
        IFolio.PriceRange memory buyPrices = auction.prices[address(buyToken)];

        // ensure auction is ongoing and token pair is in it
        require(
            auction.rebalanceNonce == rebalance.nonce &&
                sellToken != buyToken &&
                rebalance.details[address(sellToken)].inRebalance &&
                rebalance.details[address(buyToken)].inRebalance &&
                sellPrices.low != 0 && // in auction check
                buyPrices.low != 0 && // in auction check
                block.timestamp >= auction.startTime &&
                block.timestamp <= auction.endTime,
            IFolio.Folio__AuctionNotOngoing()
        );

        uint256 endPrice = Math.mulDiv(sellPrices.low, D27, buyPrices.high, Math.Rounding.Ceil);
        return endPrice;
    }
}
