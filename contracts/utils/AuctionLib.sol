// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBidderCallee } from "@interfaces/IBidderCallee.sol";
import { IFolio } from "@interfaces/IFolio.sol";

import { D18, D27, MAX_AUCTION_PRICE, MAX_AUCTION_PRICE_RANGE, MAX_TOKEN_BALANCE } from "@utils/Constants.sol";
import { MathLib } from "@utils/MathLib.sol";

library AuctionLib {
    // stack-too-deep
    struct AuctionArgs {
        uint256 auctionId;
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 sellLimit;
        uint256 buyLimit;
        uint256 startPrice;
        uint256 endPrice;
        uint256 auctionBuffer;
    }

    /// Open a new auction
    function openAuction(
        IFolio.Rebalance storage rebalance,
        mapping(uint256 auctionId => IFolio.Auction auction) storage auctions,
        mapping(uint256 rebalanceNonce => mapping(bytes32 pair => uint256 endTime)) storage auctionEnds,
        uint256 totalSupply,
        uint256 auctionLength,
        AuctionArgs memory args
    ) external {
        IFolio.RebalanceDetails storage sellDetails = rebalance.details[address(args.sellToken)];
        IFolio.RebalanceDetails storage buyDetails = rebalance.details[address(args.buyToken)];

        // confirm rebalance ongoing
        require(
            block.timestamp >= rebalance.startedAt + args.auctionBuffer && block.timestamp < rebalance.availableUntil,
            IFolio.Folio__NotRebalancing()
        );

        // confirm tokens are in rebalance
        require(sellDetails.inRebalance && buyDetails.inRebalance, IFolio.Folio__NotRebalancing());

        // confirm no auction collision on token pair
        {
            bytes32 pair = AuctionLib.pairHash(args.sellToken, args.buyToken);
            require(
                block.timestamp > auctionEnds[rebalance.nonce][pair] + args.auctionBuffer,
                IFolio.Folio__AuctionCollision()
            );

            auctionEnds[rebalance.nonce][pair] = block.timestamp + auctionLength;
        }

        // preserve limits relative ordering
        require(
            args.sellLimit >= sellDetails.limits.low && args.sellLimit <= sellDetails.limits.high,
            IFolio.Folio__InvalidSellLimit()
        );
        require(
            args.buyLimit >= buyDetails.limits.low && args.buyLimit <= buyDetails.limits.high,
            IFolio.Folio__InvalidBuyLimit()
        );

        // confirm sellToken is in surplus and buyToken is in deficit
        {
            // {sellTok} = D27{sellTok/share} * {share} / D27
            uint256 sellBalLimit = Math.mulDiv(args.sellLimit, totalSupply, D27, Math.Rounding.Ceil);
            require(args.sellToken.balanceOf(address(this)) > sellBalLimit, IFolio.Folio__InvalidSellLimit());

            // {buyTok} = D27{buyTok/share} * {share} / D27
            uint256 buyBalLimit = Math.mulDiv(args.buyLimit, totalSupply, D27, Math.Rounding.Floor);
            require(args.buyToken.balanceOf(address(this)) < buyBalLimit, IFolio.Folio__InvalidBuyLimit());
        }

        // ensure valid price range (startPrice == endPrice is valid)
        require(
            args.startPrice >= args.endPrice &&
                args.endPrice != 0 &&
                args.startPrice <= MAX_AUCTION_PRICE &&
                args.startPrice / args.endPrice <= MAX_AUCTION_PRICE_RANGE,
            IFolio.Folio__InvalidPrices()
        );

        // update spot limits to prevent double trading in the future by openAuctionUnrestricted()
        sellDetails.limits.spot = args.sellLimit;
        buyDetails.limits.spot = args.buyLimit;

        // update low/high limits to prevent double trading in the future by openAuction()
        sellDetails.limits.high = args.sellLimit;
        buyDetails.limits.low = args.buyLimit;
        // by lowering the high sell limit the AUCTION_LAUNCHER cannot backtrack and later buy the sellToken
        // by raising the low buy limit the AUCTION_LAUNCHER cannot backtrack and later sell the buyToken
        // intentional: by leaving the other 2 limits unchanged (sell.low and buy.high) there can be future
        //              auctions to trade FURTHER, incase current auctions go better than expected

        IFolio.Auction memory auction = IFolio.Auction({
            rebalanceNonce: rebalance.nonce,
            sellToken: args.sellToken,
            buyToken: args.buyToken,
            sellLimit: args.sellLimit,
            buyLimit: args.buyLimit,
            startPrice: args.startPrice,
            endPrice: args.endPrice,
            startTime: block.timestamp,
            endTime: block.timestamp + auctionLength
        });
        auctions[args.auctionId] = auction;

        emit IFolio.AuctionOpened(args.auctionId, auction);
    }

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

        // maximum valid token balance is 1e36; do not try to buy more than this
        buyAvailable = Math.min(buyAvailable, MAX_TOKEN_BALANCE);

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

        // D27{sellTok/share}
        uint256 sellBasketPresence;
        {
            // {sellTok}
            uint256 sellBal = auction.sellToken.balanceOf(address(this));

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
            uint256 buyBalBefore = auction.buyToken.balanceOf(address(this));

            // collect payment from bidder
            if (withCallback) {
                IBidderCallee(msg.sender).bidCallback(address(auction.buyToken), bidAmount, data);
            } else {
                SafeERC20.safeTransferFrom(auction.buyToken, msg.sender, address(this), bidAmount);
            }

            uint256 buyBalAfter = auction.buyToken.balanceOf(address(this));

            require(buyBalAfter - buyBalBefore >= bidAmount, IFolio.Folio__InsufficientBid());

            // D27{buyTok/share} = {buyTok} * D27 / {share}
            buyBasketPresence = Math.mulDiv(buyBalAfter, D27, totalSupply, Math.Rounding.Floor);
        }

        // end auction at limits
        // can still be griefed
        // limits may not be reacheable due to limited precision + defensive roundings
        if (sellBasketPresence == auction.sellLimit || buyBasketPresence >= auction.buyLimit) {
            auction.endTime = block.timestamp - 1;
            auctionEnds[pairHash(auction.sellToken, auction.buyToken)] = block.timestamp - 1;
        }
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
        uint256 k = MathLib.ln(Math.mulDiv(auction.startPrice, D18, auction.endPrice)) / auctionLength;

        // P_t = P_0 * e ^ -kt
        // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
        p = Math.mulDiv(auction.startPrice, MathLib.exp(-1 * int256(k * elapsed)), D18);
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
