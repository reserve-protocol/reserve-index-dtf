// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBidderCallee } from "@interfaces/IBidderCallee.sol";
import { IFolio } from "@interfaces/IFolio.sol";

import { D18, D27 } from "@utils/Constants.sol";
import { MathLib } from "@utils/MathLib.sol";

library AuctionLib {
    /// Get bid parameters for an ongoing auction
    /// @param totalSupply {share} Current total supply of the Folio
    /// @param timestamp {s} Timestamp to fetch bid for
    /// @param sellBal {sellTok} Folio's available balance of sell token, including any active fills
    /// @param buyBal {buyTok} Folio's available balance of buy token, including any active fills
    /// @param minSellAmount {sellTok} The minimum sell amount the bidder should receive
    /// @param maxSellAmount {sellTok} The maximum sell amount the bidder should receive
    /// @param maxBuyAmount {buyTok} The maximum buy amount the bidder is willing to offer
    /// @return sellAmount {sellTok} The actual sell amount in the bid
    /// @return bidAmount {buyTok} The corresponding buy amount
    /// @return price D27{buyTok/sellTok} The price at the given timestamp as an 27-decimal fixed point
    function getBid(
        IFolio.Auction storage auction,
        uint256 totalSupply,
        uint256 timestamp,
        uint256 sellBal,
        uint256 buyBal,
        uint256 minSellAmount,
        uint256 maxSellAmount,
        uint256 maxBuyAmount
    ) external view returns (uint256 sellAmount, uint256 bidAmount, uint256 price) {
        assert(minSellAmount <= maxSellAmount);

        // checks auction is ongoing
        // D27{buyTok/sellTok}
        price = _price(auction, timestamp);

        // {sellTok} = D27{sellTok/share} * {share} / D27
        uint256 sellLimitBal = Math.mulDiv(auction.sellLimit, totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = sellBal > sellLimitBal ? sellBal - sellLimitBal : 0;

        // {buyTok} = D27{buyTok/share} * {share} / D27
        uint256 buyLimitBal = Math.mulDiv(auction.buyLimit, totalSupply, D27, Math.Rounding.Floor);
        uint256 buyAvailable = buyBal < buyLimitBal ? buyLimitBal - buyBal : 0;

        // {sellTok} = {buyTok} * D27 / D27{buyTok/sellTok}
        uint256 sellAvailableFromBuy = Math.mulDiv(buyAvailable, D27, price, Math.Rounding.Floor);
        sellAvailable = Math.min(sellAvailable, sellAvailableFromBuy);

        // ensure auction is large enough to cover bid
        require(sellAvailable >= minSellAmount, IFolio.Folio__InsufficientSellAvailable());

        // {sellTok}
        sellAmount = Math.min(sellAvailable, maxSellAmount);

        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        bidAmount = Math.mulDiv(sellAmount, price, D27, Math.Rounding.Ceil);
        require(bidAmount != 0 && bidAmount <= maxBuyAmount, IFolio.Folio__SlippageExceeded());
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
        mapping(bytes32 pair => uint256 endTime) storage auctionEnds,
        uint256 totalSupply,
        uint256 sellAmount,
        uint256 bidAmount,
        bool withCallback,
        bytes calldata data
    ) external returns (bool shouldRemoveFromBasket) {
        // pay bidder
        SafeERC20.safeTransfer(auction.sellToken, msg.sender, sellAmount);

        // {sellTok}
        uint256 sellBal = auction.sellToken.balanceOf(address(this));

        // remove sell token from basket at 0 balance
        if (sellBal == 0) {
            shouldRemoveFromBasket = true;
        }

        // D27{sellTok/share} = {sellTok} * D27 / {share}
        uint256 basketPresence = Math.mulDiv(sellBal, D27, totalSupply, Math.Rounding.Ceil);
        assert(basketPresence >= auction.sellLimit); // function-use invariant

        // end auction at sell limit
        // can still be griefed
        // limits may not be reacheable due to limited precision + defensive roundings
        if (basketPresence == auction.sellLimit) {
            auction.endTime = block.timestamp - 1;
            auctionEnds[pairHash(auction.sellToken, auction.buyToken)] = block.timestamp - 1;
        }

        // {buyTok}
        uint256 buyBalBefore = auction.buyToken.balanceOf(address(this));

        // collect payment from bidder
        if (withCallback) {
            IBidderCallee(msg.sender).bidCallback(address(auction.buyToken), bidAmount, data);
        } else {
            SafeERC20.safeTransferFrom(auction.buyToken, msg.sender, address(this), bidAmount);
        }

        require(auction.buyToken.balanceOf(address(this)) - buyBalBefore >= bidAmount, IFolio.Folio__InsufficientBid());
    }

    // ==== Internal ====

    /// @return p D27{buyTok/sellTok}
    function _price(IFolio.Auction storage auction, uint256 timestamp) internal view returns (uint256 p) {
        // ensure auction is ongoing
        require(timestamp >= auction.startTime && timestamp <= auction.endTime, IFolio.Folio__AuctionNotOngoing());

        if (timestamp == auction.startTime) {
            return auction.startPrice;
        }
        if (timestamp == auction.endTime) {
            return auction.endPrice;
        }

        uint256 elapsed = timestamp - auction.startTime;
        uint256 auctionLength = auction.endTime - auction.startTime;

        // D18{1}
        // k = ln(P_0 / P_t) / t
        uint256 k = MathLib.ln((auction.startPrice * D18) / auction.endPrice) / auctionLength;

        // P_t = P_0 * e ^ -kt
        // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
        p = (auction.startPrice * MathLib.exp(-1 * int256(k * elapsed))) / D18;
        if (p < auction.endPrice) {
            p = auction.endPrice;
        }
    }

    /// @return pair The hash of the pair
    function pairHash(IERC20 sellToken, IERC20 buyToken) internal pure returns (bytes32) {
        return
            sellToken > buyToken
                ? keccak256(abi.encode(sellToken, buyToken))
                : keccak256(abi.encode(buyToken, sellToken));
    }
}
