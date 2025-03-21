// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IFolio } from "../interfaces/IFolio.sol";
import { MathLib } from "@utils/MathLib.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MAX_RATE, MAX_PRICE_RANGE, MAX_TTL, MAX_AUCTION_DELAY, MAX_AUCTION_LENGTH } from "../Folio.sol";
import { D18, D27 } from "../Folio.sol";

library AuctionLib {
    using SafeERC20 for IERC20;

    /// Approve an auction to run
    /// @param sell The token to sell, from the perspective of the Folio
    /// @param buy The token to buy, from the perspective of the Folio
    /// @param sellLimit D27{sellTok/share} min ratio of sell token to shares allowed, inclusive, 1e54 max
    /// @param buyLimit D27{buyTok/share} max balance-ratio to shares allowed, exclusive, 1e54 max
    /// @param prices D27{buyTok/sellTok} Price range
    /// @param ttl {s} How long a auction can exist in an APPROVED state until it can no longer be OPENED
    ///     (once opened, it always finishes).
    ///     Must be >= auctionDelay if intended to be openly available
    ///     Set < auctionDelay to restrict launching to the AUCTION_LAUNCHER
    /// @param runs {runs} How many times the auction can be opened before it is permanently closed
    function approveAuction(
        uint256 nextAuctionId,
        mapping(address token => uint256 timepoint) storage sellEnds,
        mapping(address token => uint256 timepoint) storage buyEnds,
        uint256 auctionDelay,
        IERC20 sell,
        IERC20 buy,
        IFolio.BasketRange calldata sellLimit,
        IFolio.BasketRange calldata buyLimit,
        IFolio.Prices calldata prices,
        uint256 ttl,
        uint256 runs
    ) external returns (IFolio.Auction memory auction) {
        require(
            address(sell) != address(0) && address(buy) != address(0) && address(sell) != address(buy),
            IFolio.Folio__InvalidAuctionTokens()
        );

        require(
            sellLimit.high <= MAX_RATE && sellLimit.low <= sellLimit.spot && sellLimit.high >= sellLimit.spot,
            IFolio.Folio__InvalidSellLimit()
        );

        require(
            buyLimit.low != 0 &&
                buyLimit.high <= MAX_RATE &&
                buyLimit.low <= buyLimit.spot &&
                buyLimit.high >= buyLimit.spot,
            IFolio.Folio__InvalidBuyLimit()
        );

        require(prices.start >= prices.end, IFolio.Folio__InvalidPrices());

        require(ttl <= MAX_TTL, IFolio.Folio__InvalidAuctionTTL());

        require(runs != 0, IFolio.Folio__InvalidAuctionRuns());

        // do not buy and sell the same token simultaneously
        require(
            block.timestamp > sellEnds[address(buy)] && block.timestamp > buyEnds[address(sell)],
            IFolio.Folio__AuctionCollision()
        );

        // {s}
        uint256 launchDeadline = block.timestamp + ttl;

        sellEnds[address(sell)] = Math.max(sellEnds[address(sell)], launchDeadline);
        buyEnds[address(buy)] = Math.max(buyEnds[address(buy)], launchDeadline);

        return
            IFolio.Auction({
                id: nextAuctionId,
                sellToken: sell,
                buyToken: buy,
                sellLimit: sellLimit,
                buyLimit: buyLimit,
                prices: IFolio.Prices(0, 0),
                restrictedUntil: block.timestamp + auctionDelay,
                launchDeadline: launchDeadline,
                startTime: 0,
                endTime: 0,
                k: 0
            });
    }

    /// @param buffer {s} Additional time buffer that must pass from `endTime` before auction can be opened
    function openAuction(
        IFolio.Auction storage auction,
        IFolio.AuctionDetails storage details,
        mapping(address token => uint256 timepoint) storage sellEnds,
        mapping(address token => uint256 timepoint) storage buyEnds,
        uint256 buffer
    ) external {
        // only open APPROVED or expired auctions, with buffer
        require(block.timestamp > auction.endTime + buffer, IFolio.Folio__AuctionCannotBeOpenedYet());

        // do not open auctions that have timed out from ttl
        require(block.timestamp <= auction.launchDeadline, IFolio.Folio__AuctionTimeout());

        // {s}
        uint256 endTime = block.timestamp + 1; // TODO add auctionLength instead of 1

        sellEnds[address(auction.sellToken)] = Math.max(sellEnds[address(auction.sellToken)], endTime);
        buyEnds[address(auction.buyToken)] = Math.max(buyEnds[address(auction.buyToken)], endTime);

        // ensure valid price range (startPrice == endPrice is valid)
        require(
            auction.prices.start >= auction.prices.end &&
                auction.prices.end != 0 &&
                auction.prices.start <= MAX_RATE &&
                auction.prices.start / auction.prices.end <= MAX_PRICE_RANGE,
            IFolio.Folio__InvalidPrices()
        );

        // ensure auction has enough runs remaining
        require(details.availableRuns != 0, IFolio.Folio__InvalidAuctionRuns());
        unchecked {
            details.availableRuns--;
        }

        auction.startTime = block.timestamp;
        auction.endTime = endTime;

        // ensure buy token is in basket since swaps can happen out-of-band
        emit IFolio.AuctionOpened(auction.id, auction, details.availableRuns);

        // D18{1}
        // k = ln(P_0 / P_t) / t
        auction.k = MathLib.ln((auction.prices.start * D18) / auction.prices.end) / 1; // TODO add auctionLength instead of 1
        // gas optimization to avoid recomputing k on every bid
    }

    // /// Bid in an ongoing auction
    // ///   If withCallback is true, caller must adhere to IBidderCallee interface and receives a callback
    // ///   If withCallback is false, caller must have provided an allowance in advance
    // /// @dev Callable by anyone
    // /// @param sellAmount {sellTok} Sell token, the token the bidder receives
    // /// @param maxBuyAmount {buyTok} Max buy token, the token the bidder provides
    // /// @param withCallback If true, caller must adhere to IBidderCallee interface and transfers tokens via callback
    // /// @param data Arbitrary data to pass to the callback
    // /// @return boughtAmt {buyTok} The amount bidder receives
    // function bid(
    //     IFolio.Auction storage auction,
    //     uint256 _totalSupply,
    //     uint256 sellAmount,
    //     uint256 maxBuyAmount,
    //     bool withCallback,
    //     bytes calldata data
    // ) external returns (uint256 boughtAmt) {
    //     // {buyTok}
    //     uint256 buyBalBefore = auction.buyToken.balanceOf(address(this));

    //     // checks auction is ongoing and that sellAmount/maxBuyAmount are valid
    //     (, boughtAmt, ) = _getBid(
    //         auction,
    //         _totalSupply,
    //         block.timestamp,
    //         auction.sellToken.balanceOf(address(this)),
    //         buyBalBefore,
    //         sellAmount,
    //         sellAmount,
    //         maxBuyAmount
    //     );

    //     // pay bidder
    //     auction.sellToken.safeTransfer(msg.sender, sellAmount);

    //     emit IFolio.AuctionBid(auctionId, sellAmount, boughtAmt);

    //     // D27{sellTok/share} = {sellTok} * D27 / {share}
    //     uint256 basketPresence = Math.mulDiv(
    //         auction.sellToken.balanceOf(address(this)),
    //         D27,
    //         _totalSupply,
    //         Math.Rounding.Ceil
    //     );

    //     // adjust basketPresence for dust
    //     basketPresence = basketPresence > dustAmount[address(auction.sellToken)]
    //         ? basketPresence - dustAmount[address(auction.sellToken)]
    //         : 0;

    //     // end auction when below sell limit
    //     if (basketPresence <= auction.sellLimit.spot) {
    //         auction.endTime = block.timestamp - 1;
    //         auctionDetails[auctionId].availableRuns = 0;

    //         // remove sell token from basket at 0
    //         if (basketPresence == 0) {
    //             _removeFromBasket(address(auction.sellToken));
    //         }
    //     }

    //     // collect payment from bidder
    //     if (withCallback) {
    //         IBidderCallee(msg.sender).bidCallback(address(auction.buyToken), boughtAmt, data);
    //     } else {
    //         auction.buyToken.safeTransferFrom(msg.sender, address(this), boughtAmt);
    //     }

    //     require(auction.buyToken.balanceOf(address(this)) - buyBalBefore >= boughtAmt, IFolio.Folio__InsufficientBid());
    // }
}
