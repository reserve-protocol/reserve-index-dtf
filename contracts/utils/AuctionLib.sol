// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBidderCallee } from "@interfaces/IBidderCallee.sol";
import { IFolio } from "@interfaces/IFolio.sol";

import { D18, D27, MAX_TOKEN_BALANCE } from "@utils/Constants.sol";
import { MathLib } from "@utils/MathLib.sol";

library AuctionLib {
    /// Open a new auction
    /// @param auctionLength {s} The amount of time the auction is open for
    /// @param sellLimit D18{BU/share} Level to sell down to, inclusive
    /// @param buyLimit D18{BU/share} Level to buy up to, inclusive, 1e36 max
    /// @param auctionBuffer {s} The amount of time the auction is open for
    function openAuction(
        IFolio.Rebalance storage rebalance,
        uint256 rebalanceNonce,
        uint256 auctionLength,
        uint256 sellLimit,
        uint256 buyLimit,
        uint256 auctionBuffer
    ) external returns (IFolio.Auction memory auction) {
        IFolio.Range storage sellRange = rebalance.sellLimit;
        IFolio.Range storage buyRange = rebalance.buyLimit;

        // confirm right rebalance
        require(rebalanceNonce == rebalance.nonce, IFolio.Folio__InvalidRebalanceNonce());

        // confirm rebalance ongoing
        require(
            block.timestamp >= rebalance.startedAt + auctionBuffer && block.timestamp < rebalance.availableUntil,
            IFolio.Folio__NotRebalancing()
        );

        // confirm valid limits
        require(sellLimit >= sellRange.low && sellLimit <= sellRange.high, IFolio.Folio__InvalidSellLimit());
        require(buyLimit >= buyRange.low && buyLimit <= buyRange.high, IFolio.Folio__InvalidBuyLimit());

        // update spot limits to prevent double trading in the future by openAuctionUnrestricted()
        sellRange.spot = sellLimit;
        buyRange.spot = buyLimit;

        // update low/high limits to prevent double trading in the future by openAuction()
        sellRange.high = sellLimit;
        buyRange.low = buyLimit;
        // by lowering the high sell limit the AUCTION_LAUNCHER cannot backtrack by re-buying sell assets in the future
        // by raising the low buy limit the AUCTION_LAUNCHER cannot backtrack by re-selling buy assets in the future
        // intentional: by leaving the other 2 limits unchanged (sellLimit.low and buyLimit.high) there can be future
        //              auctions to trade FURTHER, incase current auction goes better than expected

        auction = IFolio.Auction({
            rebalanceNonce: rebalance.nonce,
            sellLimit: sellLimit,
            buyLimit: buyLimit,
            startTime: block.timestamp,
            endTime: block.timestamp + auctionLength
        });
    }

    /// @param totalSupply {share} Current total supply of the Folio
    /// @param timestamp {s} Timestamp to fetch bid for
    /// @param sellBal {sellTok} Folio's available balance of sell token, including any active fills
    /// @param buyBal {buyTok} Folio's available balance of buy token, including any active fills
    /// @param minSellAmount {sellTok} The minimum sell amount the bidder should receive
    /// @param maxSellAmount {sellTok} The maximum sell amount the bidder should receive
    /// @param maxBuyAmount {buyTok} The maximum buy amount the bidder is willing to offer
    struct GetBidParams {
        uint256 totalSupply;
        uint256 timestamp;
        uint256 sellBal;
        uint256 buyBal;
        uint256 minSellAmount;
        uint256 maxSellAmount;
        uint256 maxBuyAmount;
    }

    /// Get bid parameters for an ongoing auction
    /// @return sellAmount {sellTok} The actual sell amount in the bid
    /// @return bidAmount {buyTok} The corresponding buy amount
    /// @return price D27{buyTok/sellTok} The price at the given timestamp as an 27-decimal fixed point
    function getBid(
        IFolio.Rebalance storage rebalance,
        IFolio.Auction storage auction,
        IERC20 sellToken,
        IERC20 buyToken,
        GetBidParams memory params
    ) external view returns (uint256 sellAmount, uint256 bidAmount, uint256 price) {
        assert(params.minSellAmount <= params.maxSellAmount);

        IFolio.RebalanceDetails storage sellDetails = rebalance.details[address(sellToken)];
        IFolio.RebalanceDetails storage buyDetails = rebalance.details[address(buyToken)];

        require(sellDetails.inRebalance && buyDetails.inRebalance, IFolio.Folio__TokenNotInRebalance());

        // checks auction is ongoing
        // D27{buyTok/sellTok}
        price = _price(auction, sellDetails, buyDetails, params.timestamp);

        // {sellTok} = D27{sellTok/share} * {share} / D27
        uint256 sellLimitBal = Math.mulDiv(auction.sellLimit, params.totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = params.sellBal > sellLimitBal ? params.sellBal - sellLimitBal : 0;

        // {buyTok} = D27{buyTok/share} * {share} / D27
        uint256 buyLimitBal = Math.mulDiv(auction.buyLimit, params.totalSupply, D27, Math.Rounding.Floor);
        uint256 buyAvailable = params.buyBal < buyLimitBal ? buyLimitBal - params.buyBal : 0;

        // maximum valid token balance is 1e36; do not try to buy more than this
        buyAvailable = Math.min(buyAvailable, MAX_TOKEN_BALANCE);

        // {sellTok} = {buyTok} * D27 / D27{buyTok/sellTok}
        uint256 sellAvailableFromBuy = Math.mulDiv(buyAvailable, D27, price, Math.Rounding.Floor);
        sellAvailable = Math.min(sellAvailable, sellAvailableFromBuy);

        // ensure auction is large enough to cover bid
        require(sellAvailable >= params.minSellAmount, IFolio.Folio__InsufficientSellAvailable());

        // {sellTok}
        sellAmount = Math.min(sellAvailable, params.maxSellAmount);

        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        bidAmount = Math.mulDiv(sellAmount, price, D27, Math.Rounding.Ceil);
        require(bidAmount != 0 && bidAmount <= params.maxBuyAmount, IFolio.Folio__SlippageExceeded());
    }

    /// Bid in an ongoing auction
    ///   If withCallback is true, caller must adhere to IBidderCallee interface and receives a callback
    ///   If withCallback is false, caller must have provided an allowance in advance
    /// @dev Callable by anyone
    /// @param sellAmount {sellTok} Sell amount as returned by getBid
    /// @param bidAmount {buyTok} Bid amount as returned by getBid
    /// @param withCallback If true, caller must adhere to IBidderCallee interface and transfers tokens via callback
    /// @param data Arbitrary data to pass to the callback
    /// @return shouldRemoveFromBasket If true, the auction's sell token should be removed from the basket after
    function bid(
        IFolio.Auction storage auction,
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 totalSupply,
        uint256 sellAmount,
        uint256 bidAmount,
        bool withCallback,
        bytes calldata data
    ) external returns (bool shouldRemoveFromBasket) {
        // pay bidder
        SafeERC20.safeTransfer(sellToken, msg.sender, sellAmount);

        // D27{sellTok/share}
        uint256 sellBasketPresence;
        {
            // {sellTok}
            uint256 sellBal = sellToken.balanceOf(address(this));

            // remove sell token from basket at 0 balance
            if (sellBal == 0) {
                shouldRemoveFromBasket = true;
            }

            // D27{sellTok/share} = {sellTok} * D27 / {share}
            sellBasketPresence = Math.mulDiv(sellBal, D27, totalSupply, Math.Rounding.Ceil);
            assert(sellBasketPresence >= auction.sellLimit); // function-use invariant
        }

        // D27{buyTok/share}
        uint256 buyBasketPresence;
        {
            // {buyTok}
            uint256 buyBalBefore = buyToken.balanceOf(address(this));

            // collect payment from bidder
            if (withCallback) {
                IBidderCallee(msg.sender).bidCallback(address(buyToken), bidAmount, data);
            } else {
                SafeERC20.safeTransferFrom(buyToken, msg.sender, address(this), bidAmount);
            }

            uint256 buyBalAfter = buyToken.balanceOf(address(this));

            require(buyBalAfter - buyBalBefore >= bidAmount, IFolio.Folio__InsufficientBid());

            // D27{buyTok/share} = {buyTok} * D27 / {share}
            buyBasketPresence = Math.mulDiv(buyBalAfter, D27, totalSupply, Math.Rounding.Floor);
        }

        // end auction at limits
        // can still be griefed
        // limits may not be reacheable due to limited precision + defensive roundings
        if (sellBasketPresence == auction.sellLimit || buyBasketPresence >= auction.buyLimit) {
            auction.endTime = block.timestamp - 1;
        }
    }

    // ==== Internal ====

    /// @return p D27{buyTok/sellTok}
    function _price(
        IFolio.Auction storage auction,
        IFolio.RebalanceDetails storage sellDetails,
        IFolio.RebalanceDetails storage buyDetails,
        uint256 timestamp
    ) internal view returns (uint256 p) {
        // ensure auction is ongoing
        require(timestamp >= auction.startTime && timestamp <= auction.endTime, IFolio.Folio__AuctionNotOngoing());

        // D27{buyTok/sellTok} = D27{UoA/sellTok} * D27 / D27{UoA/buyTok}
        uint256 startPrice = Math.mulDiv(sellDetails.prices.high, D27, buyDetails.prices.low, Math.Rounding.Ceil);
        if (timestamp == auction.startTime) {
            return startPrice;
        }

        // D27{buyTok/sellTok} = D27{UoA/sellTok} * D27 / D27{UoA/buyTok}
        uint256 endPrice = Math.mulDiv(sellDetails.prices.low, D27, buyDetails.prices.high, Math.Rounding.Floor);
        if (timestamp == auction.endTime) {
            return endPrice;
        }

        // {s}
        uint256 elapsed = timestamp - auction.startTime;
        uint256 auctionLength = auction.endTime - auction.startTime;

        // D18{1}
        // k = ln(P_0 / P_t) / t
        uint256 k = MathLib.ln(Math.mulDiv(startPrice, D18, endPrice)) / auctionLength;

        // P_t = P_0 * e ^ -kt
        // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
        p = Math.mulDiv(startPrice, MathLib.exp(-1 * int256(k * elapsed)), D18);
        if (p < endPrice) {
            p = endPrice;
        }
    }
}
