// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBidderCallee } from "@interfaces/IBidderCallee.sol";
import { IFolio } from "@interfaces/IFolio.sol";

import { D18, D27, MAX_RATE, MAX_PRICE_RANGE, MAX_TTL } from "@utils/Constants.sol";
import { MathLib } from "@utils/MathLib.sol";

library AuctionLib {
    struct ApproveAuctionParams {
        uint256 auctionDelay;
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 ttl;
        uint256 runs;
    }

    /// Approve an auction to run
    /// @param params.auctionDelay {s} Delay during which only the AUCTION_LAUNCHER can open the auction
    /// @param params.sellTokenToken The token to sell from the perspective of the Folio
    /// @param params.buyTokenToken The token to buy from the perspective of the Folio
    /// @param params.ttl {s} How long a auction can exist in an APPROVED state until it can no longer be OPENED
    /// @param params.runs {runs} How many times the auction can be opened before it is permanently closed
    /// @param sellLimit D27{sellTok/share} min ratio of sell token to shares allowed, inclusive, 1e54 max
    /// @param buyLimit D27{buyTok/share} max balance-ratio to shares allowed, exclusive, 1e54 max
    /// @param prices D27{buyTok/sellTok} Price range
    ///     (once opened, it always finishes).
    ///     Must be >= auctionDelay if intended to be openly available
    ///     Set < auctionDelay to restrict launching to the AUCTION_LAUNCHER
    /// @return auctionId The newly created auctionId
    function approveAuction(
        IFolio.Auction[] storage auctions,
        mapping(uint256 auctionId => IFolio.AuctionDetails) storage auctionDetails,
        mapping(address token => uint256 timepoint) storage sellEnds,
        mapping(address token => uint256 timepoint) storage buyEnds,
        ApproveAuctionParams calldata params,
        IFolio.BasketRange calldata sellLimit,
        IFolio.BasketRange calldata buyLimit,
        IFolio.Prices calldata prices
    ) external returns (uint256 auctionId) {
        require(
            address(params.sellToken) != address(0) &&
                address(params.buyToken) != address(0) &&
                address(params.sellToken) != address(params.buyToken),
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

        require(params.ttl <= MAX_TTL, IFolio.Folio__InvalidAuctionTTL());

        require(params.runs != 0, IFolio.Folio__InvalidAuctionRuns());

        // do not buy and sell the same token simultaneously
        require(
            block.timestamp > sellEnds[address(params.buyToken)] &&
                block.timestamp > buyEnds[address(params.sellToken)],
            IFolio.Folio__AuctionCollision()
        );

        // {s}
        uint256 launchDeadline = block.timestamp + params.ttl;

        sellEnds[address(params.sellToken)] = Math.max(sellEnds[address(params.sellToken)], launchDeadline);
        buyEnds[address(params.buyToken)] = Math.max(buyEnds[address(params.buyToken)], launchDeadline);

        auctionId = auctions.length;

        IFolio.Auction memory auction = IFolio.Auction({
            id: auctionId,
            sellToken: params.sellToken,
            buyToken: params.buyToken,
            sellLimit: sellLimit,
            buyLimit: buyLimit,
            prices: IFolio.Prices(0, 0),
            restrictedUntil: block.timestamp + params.auctionDelay,
            launchDeadline: launchDeadline,
            startTime: 0,
            endTime: 0,
            k: 0
        });
        auctions.push(auction);

        IFolio.AuctionDetails memory details = IFolio.AuctionDetails({
            initialPrices: prices,
            availableRuns: params.runs
        });
        auctionDetails[auctionId] = details;

        emit IFolio.AuctionApproved(auctionId, address(params.sellToken), address(params.buyToken), auction, details);
    }

    /// @param buffer {s} Additional time buffer that must pass from `endTime` before auction can be opened
    function openAuction(
        IFolio.Auction storage auction,
        IFolio.AuctionDetails storage details,
        mapping(address token => uint256 timepoint) storage sellEnds,
        mapping(address token => uint256 timepoint) storage buyEnds,
        uint256 auctionLength,
        uint256 buffer
    ) external {
        // only open APPROVED or expired auctions, with buffer
        require(block.timestamp > auction.endTime + buffer, IFolio.Folio__AuctionCannotBeOpenedYet());

        // do not open auctions that have timed out from ttl
        require(block.timestamp <= auction.launchDeadline, IFolio.Folio__AuctionTimeout());

        // {s}
        uint256 endTime = block.timestamp + auctionLength;

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
        auction.k = MathLib.ln((auction.prices.start * D18) / auction.prices.end) / auctionLength;
        // gas optimization to avoid recomputing k on every bid
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
        IFolio.AuctionDetails storage auctionDetails,
        mapping(address token => uint256 amount) storage dustAmount,
        uint256 _totalSupply,
        uint256 sellAmount,
        uint256 bidAmount,
        bool withCallback,
        bytes calldata data
    ) external returns (bool shouldRemoveFromBasket) {
        // pay bidder
        SafeERC20.safeTransfer(auction.sellToken, msg.sender, sellAmount);

        emit IFolio.AuctionBid(auction.id, sellAmount, bidAmount);

        // D27{sellTok/share} = {sellTok} * D27 / {share}
        uint256 basketPresence = Math.mulDiv(
            auction.sellToken.balanceOf(address(this)),
            D27,
            _totalSupply,
            Math.Rounding.Ceil
        );

        // adjust basketPresence for dust
        basketPresence = basketPresence > dustAmount[address(auction.sellToken)]
            ? basketPresence - dustAmount[address(auction.sellToken)]
            : 0;

        // end auction when below sell limit
        if (basketPresence <= auction.sellLimit.spot) {
            auction.endTime = block.timestamp - 1;
            auctionDetails.availableRuns = 0;

            // remove sell token from basket at 0
            if (basketPresence == 0) {
                shouldRemoveFromBasket = true;
            }
        }

        // collect payment from bidder
        if (withCallback) {
            IBidderCallee(msg.sender).bidCallback(address(auction.buyToken), bidAmount, data);
        } else {
            SafeERC20.safeTransferFrom(auction.buyToken, msg.sender, address(this), bidAmount);
        }
    }

    /// Get bid parameters for an ongoing auction
    /// @param _totalSupply {share} Current total supply of the Folio
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
        uint256 _totalSupply,
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
        uint256 sellLimit = Math.mulDiv(auction.sellLimit.spot, _totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = sellBal > sellLimit ? sellBal - sellLimit : 0;

        // {buyTok} = D27{buyTok/share} * {share} / D27
        uint256 buyLimit = Math.mulDiv(auction.buyLimit.spot, _totalSupply, D27, Math.Rounding.Floor);
        uint256 buyAvailable = buyBal < buyLimit ? buyLimit - buyBal : 0;

        // {sellTok} = {buyTok} * D27 / D27{buyTok/sellTok}
        uint256 sellAvailableFromBuy = Math.mulDiv(buyAvailable, D27, price, Math.Rounding.Floor);
        sellAvailable = Math.min(sellAvailable, sellAvailableFromBuy);

        // ensure auction is large enough to cover bid
        require(sellAvailable >= minSellAmount, IFolio.Folio__InsufficientBalance());

        // {sellTok}
        sellAmount = Math.min(sellAvailable, maxSellAmount);

        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        bidAmount = Math.mulDiv(sellAmount, price, D27, Math.Rounding.Ceil);
        require(bidAmount != 0 && bidAmount <= maxBuyAmount, IFolio.Folio__SlippageExceeded());
    }

    // ==== Internal ====

    /// @return p D27{buyTok/sellTok}
    function _price(IFolio.Auction storage auction, uint256 timestamp) internal view returns (uint256 p) {
        // ensure auction is ongoing
        require(timestamp >= auction.startTime && timestamp <= auction.endTime, IFolio.Folio__AuctionNotOngoing());

        if (timestamp == auction.startTime) {
            return auction.prices.start;
        }
        if (timestamp == auction.endTime) {
            return auction.prices.end;
        }

        uint256 elapsed = timestamp - auction.startTime;

        // P_t = P_0 * e ^ -kt
        // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
        p = (auction.prices.start * MathLib.exp(-1 * int256(auction.k * elapsed))) / D18;
        if (p < auction.prices.end) {
            p = auction.prices.end;
        }
    }
}
