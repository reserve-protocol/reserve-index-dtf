// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBidderCallee } from "@interfaces/IBidderCallee.sol";
import { IFolio } from "@interfaces/IFolio.sol";

import { D18, D27, MAX_LIMIT, MAX_TOKEN_BALANCE, MAX_TOKEN_PRICE, MAX_TOKEN_PRICE_RANGE, MAX_TTL, MAX_WEIGHT, RESTRICTED_AUCTION_BUFFER } from "@utils/Constants.sol";
import { MathLib } from "@utils/MathLib.sol";

library RebalancingLib {
    struct StartRebalanceParams {
        IFolio.IndexType indexType;
        IFolio.PriceControl priceControl;
        uint256 auctionLauncherWindow; // {s}
        uint256 ttl; // {s}
    }

    /// Start a new rebalance
    function startRebalance(
        IFolio.Rebalance storage rebalance,
        address[] calldata tokens,
        IFolio.WeightRange[] calldata weights,
        IFolio.PriceRange[] calldata prices,
        IFolio.RebalanceLimits calldata limits,
        StartRebalanceParams calldata params
    ) external {
        require(params.ttl >= params.auctionLauncherWindow && params.ttl <= MAX_TTL, IFolio.Folio__InvalidTTL());

        uint256 len = tokens.length;
        require(len != 0 && len == weights.length && len == prices.length, IFolio.Folio__InvalidArrayLengths());

        // check limits and weights
        if (params.indexType == IFolio.IndexType.TRACKING) {
            // TRACKING DTFs have variable limits and constant weights

            _checkTrackingDTF(limits, weights);
        } else {
            // NATIVE DTFs have constant limits and variable weights

            _checkNativeDTF(limits, weights);
        }

        // set new rebalance details and prices
        for (uint256 i; i < len; i++) {
            address token = tokens[i];

            // enforce no duplicates
            require(!rebalance.details[token].inRebalance, IFolio.Folio__DuplicateAsset());

            // enforce weights are all 0 or all non-zero
            require(
                (weights[i].low == 0 && weights[i].high == 0) || (weights[i].low != 0 && weights[i].high != 0),
                IFolio.Folio__InvalidWeights()
            );

            // enforce prices are internally consistent
            require(
                prices[i].low != 0 &&
                    prices[i].low <= prices[i].high &&
                    prices[i].high <= MAX_TOKEN_PRICE &&
                    prices[i].high <= MAX_TOKEN_PRICE_RANGE * prices[i].low,
                IFolio.Folio__InvalidPrices()
            );

            rebalance.details[token] = IFolio.RebalanceDetails({
                inRebalance: true,
                weights: weights[i],
                prices: prices[i],
                initialPrices: prices[i]
            });
        }

        rebalance.nonce++;
        rebalance.limits = limits;
        rebalance.startedAt = block.timestamp;
        rebalance.restrictedUntil = block.timestamp + params.auctionLauncherWindow;
        rebalance.availableUntil = block.timestamp + params.ttl;
        rebalance.priceControl = params.priceControl;

        emit IFolio.RebalanceStarted(
            rebalance.nonce,
            params.priceControl,
            tokens,
            weights,
            prices,
            limits,
            block.timestamp + params.auctionLauncherWindow,
            block.timestamp + params.ttl
        );
    }

    /// Open a new auction
    /// @param auctionLength {s} The amount of time the auction is open for
    /// @param auctionBuffer {s} The amount of time the auction is open for
    function openAuction(
        IFolio.Rebalance storage rebalance,
        mapping(uint256 auctionId => IFolio.Auction) storage auctions,
        uint256 auctionId,
        address[] memory tokens,
        uint256[] memory weights,
        IFolio.RebalanceLimits calldata limits,
        uint256 totalSupply,
        uint256 auctionLength,
        uint256 auctionBuffer
    ) external {
        uint256 len = tokens.length;
        require(len == weights.length, IFolio.Folio__InvalidWeights());

        // enforce rebalance ongoing
        require(
            block.timestamp >= rebalance.startedAt + auctionBuffer && block.timestamp < rebalance.availableUntil,
            IFolio.Folio__NotRebalancing()
        );

        // enforce auction not ongoing, if unrestricted
        // AUCTION_LAUNCHER can overwrite an existing auction
        if (auctionId != 0) {
            IFolio.Auction storage lastAuction = auctions[auctionId - 1];

            if (auctionBuffer != 0) {
                // restricted caller case

                require(
                    lastAuction.endTime + auctionBuffer < block.timestamp ||
                        lastAuction.rebalanceNonce != rebalance.nonce,
                    IFolio.Folio__AuctionCannotBeOpenedWithoutRestriction()
                );
            } else {
                // AUCTION_LAUNCHER case

                // close existing auction
                lastAuction.endTime = block.timestamp - 1;
                emit IFolio.AuctionClosed(auctionId - 1);
            }
        }

        // update rebalance limits
        {
            IFolio.RebalanceLimits storage rebalanceLimits = rebalance.limits;

            // enforce valid limits
            require(
                rebalanceLimits.low <= limits.low &&
                    limits.low <= limits.spot &&
                    limits.spot <= limits.high &&
                    limits.high <= rebalanceLimits.high,
                IFolio.Folio__InvalidLimits()
            );

            rebalanceLimits.low = limits.low; // to buy up to
            rebalanceLimits.spot = limits.spot; // for future unrestricted auctions
            rebalanceLimits.high = limits.high; // to sell down to
        }

        IFolio.Auction storage auction = auctions[auctionId];

        // update basket weights
        for (uint256 i = 0; i < len; i++) {
            IFolio.RebalanceDetails storage details = rebalance.details[address(tokens[i])];

            // only include tokens from rebalance
            if (!details.inRebalance) {
                tokens[i] = address(0); // imperfect but ok, only impacts event
                weights[i] = 0;
                continue;
            }

            // add token to auction
            require(!auction.inAuction[tokens[i]], IFolio.Folio__DuplicateAsset());
            auction.inAuction[tokens[i]] = true;

            // update spot weight
            require(
                details.weights.low <= weights[i] && weights[i] <= details.weights.high,
                IFolio.Folio__InvalidWeights()
            );
            details.weights.spot = weights[i];

            // narrow high/low weights
            {
                // D27{tok/share} = D27 * {tok} / {share}
                uint256 tokenCurrent = Math.mulDiv(
                    D27,
                    IERC20(tokens[i]).balanceOf(address(this)),
                    totalSupply,
                    Math.Rounding.Floor
                );

                // D27{tok/share} = D27{tok/BU} * D18{BU/share} / D18
                uint256 tokenSellLimit = Math.mulDiv(weights[i], limits.high, D18, Math.Rounding.Ceil);

                // D27{tok/share} = D27{tok/BU} * D18{BU/share} / D18
                uint256 tokenBuyLimit = Math.mulDiv(weights[i], limits.low, D18, Math.Rounding.Floor);

                // prevent future double trading
                if (tokenCurrent > tokenSellLimit) {
                    // surplus scenario: prevent trading in the future towards a higher weight
                    details.weights.high = weights[i];
                } else if (tokenCurrent < tokenBuyLimit) {
                    // deficit scenario: prevent trading in the future towards a lower weight
                    details.weights.low = weights[i];
                }
            }
        }

        // save auction
        auction.rebalanceNonce = rebalance.nonce;
        auction.startTime = block.timestamp;
        auction.endTime = block.timestamp + auctionLength;

        emit IFolio.AuctionOpened(
            rebalance.nonce,
            auctionId,
            tokens,
            weights,
            limits,
            block.timestamp,
            block.timestamp + auctionLength
        );

        // bump rebalance deadlines if permissioned caller needs more time
        if (auctionBuffer == 0) {
            uint256 delta = auctionLength + RESTRICTED_AUCTION_BUFFER * 2; // {s}

            // give AUCTION_LAUNCHER more time to act if it is within their isolated period and about to spill over
            if (block.timestamp < rebalance.restrictedUntil && block.timestamp + delta >= rebalance.restrictedUntil) {
                rebalance.restrictedUntil += delta;
                rebalance.availableUntil += delta;
                // the AUCTION_LAUNCER can DoS unrestricted auctions, but this is already true because of closeAuction()
            } else if (block.timestamp + delta > rebalance.availableUntil) {
                rebalance.availableUntil += delta;
            }
        }
    }

    /// @dev stack-too-deep
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

        // checks auction is ongoing and part of rebalance
        // D27{buyTok/sellTok}
        price = _price(rebalance, auction, sellToken, buyToken, params.timestamp);

        // D27{sellTok/share} = D18{BU/share} * D27{sellTok/BU} / D18
        uint256 sellLimit = Math.mulDiv(
            rebalance.limits.high,
            rebalance.details[address(sellToken)].weights.spot,
            D18,
            Math.Rounding.Ceil
        );

        // {sellTok} = D27{sellTok/share} * {share} / D27
        uint256 sellLimitBal = Math.mulDiv(sellLimit, params.totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = params.sellBal > sellLimitBal ? params.sellBal - sellLimitBal : 0;

        // D27{buyTok/share} = D18{BU/share} * D27{buyTok/BU} / D18
        uint256 buyLimit = Math.mulDiv(
            rebalance.limits.low,
            rebalance.details[address(buyToken)].weights.spot,
            D18,
            Math.Rounding.Floor
        );

        // {buyTok} = D27{buyTok/share} * {share} / D27
        uint256 buyLimitBal = Math.mulDiv(buyLimit, params.totalSupply, D27, Math.Rounding.Floor);
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
        uint256 auctionId,
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 sellAmount,
        uint256 bidAmount,
        bool withCallback,
        bytes calldata data
    ) external returns (bool shouldRemoveFromBasket) {
        require(bidAmount != 0, IFolio.Folio__InsufficientBuyAvailable());

        // pay bidder
        SafeERC20.safeTransfer(sellToken, msg.sender, sellAmount);

        // remove sell token from basket at 0 balance
        if (sellToken.balanceOf(address(this)) == 0) {
            shouldRemoveFromBasket = true;
        }

        // {buyTok}
        uint256 buyBalBefore = buyToken.balanceOf(address(this));

        // collect payment from bidder
        if (withCallback) {
            IBidderCallee(msg.sender).bidCallback(address(buyToken), bidAmount, data);
        } else {
            SafeERC20.safeTransferFrom(buyToken, msg.sender, address(this), bidAmount);
        }

        uint256 delta = buyToken.balanceOf(address(this)) - buyBalBefore;
        require(delta >= bidAmount, IFolio.Folio__InsufficientBid());

        emit IFolio.AuctionBid(auctionId, address(sellToken), address(buyToken), sellAmount, delta);
    }

    // ==== Internal ====

    /// @return p D27{buyTok/sellTok}
    function _price(
        IFolio.Rebalance storage rebalance,
        IFolio.Auction storage auction,
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 timestamp
    ) internal view returns (uint256 p) {
        IFolio.RebalanceDetails storage sellDetails = rebalance.details[address(sellToken)];
        IFolio.RebalanceDetails storage buyDetails = rebalance.details[address(buyToken)];

        // ensure auction is ongoing and token pair is in it
        require(
            auction.rebalanceNonce == rebalance.nonce &&
                sellToken != buyToken &&
                sellDetails.inRebalance &&
                buyDetails.inRebalance &&
                auction.inAuction[address(sellToken)] &&
                auction.inAuction[address(buyToken)] &&
                timestamp >= auction.startTime &&
                timestamp <= auction.endTime,
            IFolio.Folio__AuctionNotOngoing()
        );

        // D27{buyTok/sellTok} = D27{UoA/sellTok} * D27 / D27{UoA/buyTok}
        uint256 startPrice = Math.mulDiv(sellDetails.prices.high, D27, buyDetails.prices.low, Math.Rounding.Ceil);
        if (timestamp == auction.startTime) {
            return startPrice;
        }

        // D27{buyTok/sellTok} = D27{UoA/sellTok} * D27 / D27{UoA/buyTok}
        uint256 endPrice = Math.mulDiv(sellDetails.prices.low, D27, buyDetails.prices.high, Math.Rounding.Ceil);
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
        p = Math.mulDiv(startPrice, MathLib.exp(-1 * int256(k * elapsed)), D18, Math.Rounding.Ceil);
        if (p < endPrice) {
            p = endPrice;
        }
    }

    /// TRACKING: Variable limits, constant weights
    function _checkTrackingDTF(
        IFolio.RebalanceLimits memory limits,
        IFolio.WeightRange[] memory weights
    ) internal pure {
        // enforce limits are internally consistent
        require(
            limits.low != 0 && limits.low <= limits.spot && limits.spot <= limits.high && limits.high <= MAX_LIMIT,
            IFolio.Folio__InvalidLimits()
        );

        // enforce weights are constant
        uint256 len = weights.length;
        for (uint256 i; i < len; i++) {
            require(
                weights[i].low == weights[i].spot &&
                    weights[i].spot == weights[i].high &&
                    weights[i].high <= MAX_WEIGHT,
                IFolio.Folio__InvalidWeights()
            );
        }
    }

    /// NATIVE: Constant limits, variable weights
    function _checkNativeDTF(IFolio.RebalanceLimits memory limits, IFolio.WeightRange[] memory weights) internal pure {
        // enforce limits are constant
        require(
            limits.low != 0 && limits.low == limits.spot && limits.spot == limits.high && limits.high <= MAX_LIMIT,
            IFolio.Folio__InvalidLimits()
        );

        // enforce weights are internally consistent
        uint256 len = weights.length;
        for (uint256 i; i < len; i++) {
            require(
                weights[i].low <= weights[i].spot &&
                    weights[i].spot <= weights[i].high &&
                    weights[i].high <= MAX_WEIGHT,
                IFolio.Folio__InvalidWeights()
            );

            // all 0, or none are 0
            require(weights[i].low != 0 || weights[i].high == 0, IFolio.Folio__InvalidWeights());
        }
    }
}
