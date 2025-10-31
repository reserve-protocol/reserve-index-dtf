// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBidderCallee } from "@interfaces/IBidderCallee.sol";
import { IFolio } from "@interfaces/IFolio.sol";

import { AUCTION_WARMUP, D18, D27, MAX_TOKEN_BUY_AMOUNT, MAX_LIMIT, MAX_WEIGHT, MAX_TOKEN_PRICE, MAX_TOKEN_PRICE_RANGE, MAX_TTL } from "@utils/Constants.sol";
import { MathLib } from "@utils/MathLib.sol";

/**
 * @title RebalancingLib
 * @notice Library for rebalancing/auction operations
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 *
 * startRebalance() -> openAuction() -> getBid() -> bid()
 */
library RebalancingLib {
    function startRebalance(
        address[] calldata oldTokens,
        IFolio.RebalanceControl storage rebalanceControl,
        IFolio.Rebalance storage rebalance,
        IFolio.TokenRebalanceParams[] calldata tokens,
        IFolio.RebalanceLimits calldata limits,
        uint256 auctionLauncherWindow,
        uint256 ttl,
        bool bidsEnabled
    ) external {
        // remove old tokens from rebalance while keeping them in the basket
        for (uint256 i; i < oldTokens.length; i++) {
            delete rebalance.details[oldTokens[i]];
        }

        // ====

        require(ttl >= auctionLauncherWindow && ttl <= MAX_TTL, IFolio.Folio__InvalidTTL());

        // enforce limits are internally consistent
        require(
            limits.low != 0 && limits.low <= limits.spot && limits.spot <= limits.high && limits.high <= MAX_LIMIT,
            IFolio.Folio__InvalidLimits()
        );

        uint256 count = 0;
        uint256 len = tokens.length;

        // set new rebalance details and prices
        for (uint256 i; i < len; i++) {
            IFolio.TokenRebalanceParams calldata params = tokens[i];

            if (!params.inRebalance) {
                continue;
            }
            count++;

            // enforce valid token
            require(params.token != address(0) && params.token != address(this), IFolio.Folio__InvalidAsset());

            // enforce no duplicates
            require(rebalance.details[params.token].initialPrices.low == 0, IFolio.Folio__DuplicateAsset());

            if (!rebalanceControl.weightControl) {
                // weights must be fixed
                require(
                    params.weight.low == params.weight.spot &&
                        params.weight.spot == params.weight.high &&
                        params.weight.high <= MAX_WEIGHT,
                    IFolio.Folio__InvalidWeights()
                );
            } else {
                // weights can be revised within bounds
                require(
                    params.weight.low <= params.weight.spot &&
                        params.weight.spot <= params.weight.high &&
                        params.weight.high <= MAX_WEIGHT,
                    IFolio.Folio__InvalidWeights()
                );
            }

            // enforce prices are internally consistent
            require(
                params.price.low != 0 &&
                    params.price.low < params.price.high &&
                    params.price.high <= MAX_TOKEN_PRICE &&
                    params.price.high <= MAX_TOKEN_PRICE_RANGE * params.price.low,
                IFolio.Folio__InvalidPrices()
            );

            rebalance.details[params.token] = IFolio.RebalanceDetails({
                inRebalance: true,
                weights: params.weight,
                initialPrices: params.price,
                maxAuctionSize: params.maxAuctionSize
            });
        }

        require(count > 1, IFolio.Folio__EmptyRebalance());

        rebalance.nonce++;
        rebalance.limits = limits;
        rebalance.startedAt = block.timestamp;
        rebalance.restrictedUntil = block.timestamp + auctionLauncherWindow;
        rebalance.availableUntil = block.timestamp + ttl;
        rebalance.priceControl = rebalanceControl.priceControl;
        rebalance.bidsEnabled = bidsEnabled;

        emit IFolio.RebalanceStarted(
            rebalance.nonce,
            rebalance.priceControl,
            tokens,
            limits,
            block.timestamp,
            block.timestamp + auctionLauncherWindow,
            block.timestamp + ttl,
            bidsEnabled
        );
    }

    /// Open a new auction
    function openAuction(
        IFolio.Rebalance storage rebalance,
        mapping(uint256 auctionId => IFolio.Auction) storage auctions,
        uint256 auctionId,
        address[] memory tokens,
        IFolio.WeightRange[] memory weights,
        IFolio.PriceRange[] calldata prices,
        IFolio.RebalanceLimits calldata limits,
        uint256 auctionLength
    ) external {
        uint256 len = tokens.length;
        require(len != 0 && len == weights.length && len == prices.length, IFolio.Folio__InvalidArrayLengths());

        // narrow rebalance limits
        {
            IFolio.RebalanceLimits storage rebalanceLimits = rebalance.limits;

            // enforce new limits are valid
            require(
                rebalanceLimits.low <= limits.low &&
                    limits.low <= limits.spot &&
                    limits.spot <= limits.high &&
                    limits.high <= rebalanceLimits.high,
                IFolio.Folio__InvalidLimits()
            );

            rebalanceLimits.low = limits.low;
            rebalanceLimits.spot = limits.spot;
            rebalanceLimits.high = limits.high;
        }

        IFolio.Auction storage auction = auctions[auctionId];

        // use first tokens as anchor for atomic swap check
        bool allAtomicSwaps = prices[0].low == prices[0].high;

        // all tokens must have constant prices or none can
        require(
            !allAtomicSwaps || rebalance.priceControl == IFolio.PriceControl.ATOMIC_SWAP,
            IFolio.Folio__InvalidPrices()
        );

        // update basket weights + auction prices
        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];

            // enforce unique
            require(auction.prices[token].high == 0, IFolio.Folio__DuplicateAsset());

            IFolio.RebalanceDetails storage rebalanceDetails = rebalance.details[token];

            // enforce valid token
            require(
                token != address(0) && token != address(this) && rebalanceDetails.inRebalance,
                IFolio.Folio__InvalidAsset()
            );

            // update weights
            {
                require(
                    rebalanceDetails.weights.low <= weights[i].low &&
                        weights[i].low <= weights[i].spot &&
                        weights[i].spot <= weights[i].high &&
                        weights[i].high <= rebalanceDetails.weights.high,
                    IFolio.Folio__InvalidWeights()
                );
                rebalanceDetails.weights = weights[i];
            }

            // save auction prices
            {
                if (rebalance.priceControl == IFolio.PriceControl.NONE) {
                    // prices must be exactly the initial prices

                    require(
                        prices[i].low == rebalanceDetails.initialPrices.low &&
                            prices[i].high == rebalanceDetails.initialPrices.high,
                        IFolio.Folio__InvalidPrices()
                    );
                } else {
                    // prices can be revised within the bounds of the initial prices

                    require(
                        prices[i].low >= rebalanceDetails.initialPrices.low &&
                            prices[i].high <= rebalanceDetails.initialPrices.high &&
                            prices[i].high >= prices[i].low,
                        IFolio.Folio__InvalidPrices()
                    );

                    // everything must be an atomic swap or nothing can be
                    require(allAtomicSwaps == (prices[i].low == prices[i].high), IFolio.Folio__MixedAtomicSwaps());
                }

                auction.prices[token] = prices[i];
            }
        }

        // save auction
        auction.rebalanceNonce = rebalance.nonce;

        if (allAtomicSwaps) {
            // atomic swaps start and end at same timestamp
            auction.startTime = block.timestamp;
            auction.endTime = block.timestamp;
        } else {
            // auctions begin after a 30s warmup period
            auction.startTime = block.timestamp + AUCTION_WARMUP;
            auction.endTime = block.timestamp + AUCTION_WARMUP + auctionLength;
        }

        emit IFolio.AuctionOpened(
            rebalance.nonce,
            auctionId,
            tokens,
            weights,
            prices,
            limits,
            auction.startTime,
            auction.endTime
        );
    }

    /// @dev stack-too-deep
    /// @param totalSupply {share} Current total supply of the Folio
    /// @param sellBal {sellTok} Folio's available balance of sell token, including any active fills
    /// @param buyBal {buyTok} Folio's available balance of buy token, including any active fills
    /// @param minSellAmount {sellTok} The minimum sell amount the bidder should receive
    /// @param maxSellAmount {sellTok} The maximum sell amount the bidder should receive
    /// @param maxBuyAmount {buyTok} The maximum buy amount the bidder is willing to offer
    struct GetBidParams {
        uint256 totalSupply;
        uint256 sellBal;
        uint256 buyBal;
        uint256 minSellAmount;
        uint256 maxSellAmount;
        uint256 maxBuyAmount;
    }

    /// Get bid parameters for an ongoing auction at the current timestamp
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

        IFolio.RebalanceDetails memory sellDetails = rebalance.details[address(sellToken)];

        // checks auction is ongoing and part of rebalance
        // D27{buyTok/sellTok}
        price = _price(rebalance, auction, sellToken, buyToken);

        uint256 sellAvailable;
        {
            // sell down to the high BU limit and high weight
            // D27{sellTok/share} = D18{BU/share} * D27{sellTok/BU} / D18
            uint256 sellLimit = Math.mulDiv(rebalance.limits.high, sellDetails.weights.high, D18, Math.Rounding.Ceil);

            // {sellTok} = D27{sellTok/share} * {share} / D27
            uint256 sellLimitBal = Math.mulDiv(sellLimit, params.totalSupply, D27, Math.Rounding.Ceil);
            sellAvailable = params.sellBal > sellLimitBal ? params.sellBal - sellLimitBal : 0;
        }

        uint256 buyAvailable;
        {
            // buy up to the low BU limit and low weight
            // D27{buyTok/share} = D18{BU/share} * D27{buyTok/BU} / D18
            uint256 buyLimit = Math.mulDiv(
                rebalance.limits.low,
                rebalance.details[address(buyToken)].weights.low,
                D18,
                Math.Rounding.Floor
            );

            // {buyTok} = D27{buyTok/share} * {share} / D27
            uint256 buyLimitBal = Math.mulDiv(buyLimit, params.totalSupply, D27, Math.Rounding.Floor);
            buyAvailable = params.buyBal < buyLimitBal ? buyLimitBal - params.buyBal : 0;
        }

        // maximum valid token purchase is 1e36; do not try to buy more than this
        buyAvailable = Math.min(buyAvailable, MAX_TOKEN_BUY_AMOUNT);

        // {sellTok} = {buyTok} * D27 / D27{buyTok/sellTok}
        uint256 sellAvailableFromBuy = Math.mulDiv(buyAvailable, D27, price, Math.Rounding.Floor);
        sellAvailable = Math.min(sellAvailable, sellAvailableFromBuy);

        // {sellTok}
        uint256 sellRemaining = sellDetails.maxAuctionSize > auction.sold[address(sellToken)]
            ? sellDetails.maxAuctionSize - auction.sold[address(sellToken)]
            : 0;
        sellAvailable = Math.min(sellAvailable, sellRemaining);

        // ensure auction is large enough to cover bid
        require(sellAvailable >= params.minSellAmount, IFolio.Folio__InsufficientSellAvailable());

        // {sellTok}
        sellAmount = Math.min(sellAvailable, params.maxSellAmount);

        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        bidAmount = Math.mulDiv(sellAmount, price, D27, Math.Rounding.Ceil);
        require(bidAmount <= params.maxBuyAmount, IFolio.Folio__SlippageExceeded());
    }

    /// Bid in an ongoing auction
    ///   If withCallback is true, caller must adhere to IBidderCallee interface and receives a callback
    ///   If withCallback is false, caller must have provided an allowance in advance
    /// @param sellAmount {sellTok} Sell amount as returned by getBid
    /// @param bidAmount {buyTok} Bid amount as returned by getBid
    /// @param withCallback If true, caller must adhere to IBidderCallee interface and transfers tokens via callback
    /// @param data Arbitrary data to pass to the callback
    /// @return shouldRemoveFromBasket If true, the auction's sell token should be removed from the basket after
    function bid(
        IFolio.Auction storage auction,
        uint256 auctionId,
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 sellAmount,
        uint256 bidAmount,
        bool withCallback,
        bytes calldata data
    ) external returns (bool shouldRemoveFromBasket) {
        require(bidAmount != 0, IFolio.Folio__InsufficientBuyAvailable());

        // track sold amt
        auction.sold[address(sellToken)] += sellAmount;

        uint256 sellBalBefore = sellToken.balanceOf(address(this));

        // pay bidder
        SafeERC20.safeTransfer(sellToken, msg.sender, sellAmount);

        // {buyTok}
        uint256 buyBalBefore = buyToken.balanceOf(address(this));

        // collect payment from bidder
        if (withCallback) {
            IBidderCallee(msg.sender).bidCallback(address(buyToken), bidAmount, data);
        } else {
            SafeERC20.safeTransferFrom(buyToken, msg.sender, address(this), bidAmount);
        }

        uint256 buyDelta = buyToken.balanceOf(address(this)) - buyBalBefore;
        require(buyDelta >= bidAmount, IFolio.Folio__InsufficientBid());

        uint256 sellBal = sellToken.balanceOf(address(this));
        uint256 sellDelta = sellBalBefore > sellBal ? sellBalBefore - sellBal : 0;

        emit IFolio.AuctionBid(auctionId, address(sellToken), address(buyToken), sellDelta, buyDelta);

        // shouldRemoveFromBasket
        return sellBal == 0;
    }

    // ==== Internal ====

    /// Get the price of a token pair within an auction at the current timestamp
    /// If startTime == endTime, startPrice is used.
    /// @return p D27{buyTok/sellTok}
    function _price(
        IFolio.Rebalance storage rebalance,
        IFolio.Auction storage auction,
        IERC20 sellToken,
        IERC20 buyToken
    ) internal view returns (uint256 p) {
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

        // D18{1}
        // k = ln(P_0 / P_t) / t
        uint256 k = MathLib.ln(Math.mulDiv(startPrice, D18, endPrice)) / auctionLength;

        // P_t = P_0 * e ^ -kt
        // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
        p = Math.mulDiv(startPrice, MathLib.exp(-1 * int256(k * elapsed)), D18, Math.Rounding.Ceil);
        if (p < endPrice) {
            p = endPrice;
        }
    }
}
