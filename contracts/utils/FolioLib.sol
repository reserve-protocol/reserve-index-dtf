// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SD59x18, exp, intoUint256 } from "@prb/math/src/SD59x18.sol";

import { IFolio } from "../interfaces/IFolio.sol";
import { GPv2OrderLib, COWSWAP_GPV2_SETTLEMENT } from "../utils/GPv2OrderLib.sol";

uint256 constant MAX_RATE = 1e54; // D18{buyTok/sellTok}

uint256 constant D18 = 1e18; // D18
uint256 constant D27 = 1e27; // D27

library FolioLib {
    using GPv2OrderLib for GPv2OrderLib.Data;

    function price(IFolio.Auction storage auction, uint256 timestamp) public view returns (uint256 p) {
        // ensure auction is ongoing
        require(timestamp >= auction.start && timestamp <= auction.end, IFolio.Folio__AuctionNotOngoing());

        if (timestamp == auction.start) {
            return auction.prices.start;
        }
        if (timestamp == auction.end) {
            return auction.prices.end;
        }

        uint256 elapsed = timestamp - auction.start;

        // P_t = P_0 * e ^ -kt
        // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
        p = (auction.prices.start * intoUint256(exp(SD59x18.wrap(-1 * int256(auction.k * elapsed))))) / D18;
        if (p < auction.prices.end) {
            p = auction.prices.end;
        }
    }

    /// The amount on sale in an auction
    /// @dev Supports partial fills
    /// @dev Fluctuates changes over time as price changes (can go up or down)
    /// @return sellAmount {sellTok} The amount of sell token on sale in the auction at a given timestamp
    function lot(
        IFolio.Auction storage auction,
        uint256 timestamp,
        uint256 totalSupply
    ) external view returns (uint256 sellAmount) {
        uint256 sellBal = auction.sell.balanceOf(address(this));
        uint256 buyBal = auction.buy.balanceOf(address(this));

        // {sellTok} = D27{sellTok/share} * {share} / D27
        uint256 minSellBal = Math.mulDiv(auction.sellLimit.spot, totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = sellBal > minSellBal ? sellBal - minSellBal : 0;

        // {buyTok} = D27{buyTok/share} * {share} / D27
        uint256 maxBuyBal = Math.mulDiv(auction.buyLimit.spot, totalSupply, D27, Math.Rounding.Floor);
        uint256 buyAvailable = buyBal < maxBuyBal ? maxBuyBal - buyBal : 0;

        // avoid overflow
        if (buyAvailable > MAX_RATE) {
            return sellAvailable;
        }

        // {sellTok} = {buyTok} * D27 / D27{buyTok/sellTok}
        uint256 sellAvailableFromBuy = Math.mulDiv(buyAvailable, D27, price(auction, timestamp), Math.Rounding.Floor);
        sellAmount = Math.min(sellAvailable, sellAvailableFromBuy);
    }

    /// @dev Check auction is ongoing and that sellAmount/maxBuyAmount are valid/met
    /// @return bidAmt {buyTok} The buy amount corresponding to the sell amount
    function getBid(
        IFolio.Auction storage auction,
        uint256 timestamp,
        uint256 totalSupply,
        uint256 sellAmount,
        uint256 maxBuyAmount
    ) public view returns (uint256 bidAmt) {
        // checks auction is ongoing
        // D27{buyTok/sellTok}
        uint256 _price = price(auction, timestamp);

        // {buyTok} = {sellTok} * D27{buyTok/sellTok} / D27
        bidAmt = Math.mulDiv(sellAmount, _price, D27, Math.Rounding.Ceil);
        require(bidAmt <= maxBuyAmount && bidAmt != 0, IFolio.Folio__SlippageExceeded());

        uint256 sellBal = auction.sell.balanceOf(address(this));

        // {sellTok} = D27{sellTok/share} * {share} / D27
        uint256 minSellBal = Math.mulDiv(auction.sellLimit.spot, totalSupply, D27, Math.Rounding.Ceil);
        uint256 sellAvailable = sellBal > minSellBal ? sellBal - minSellBal : 0;

        // ensure auction is large enough to cover bid
        require(sellAmount <= sellAvailable && sellAmount != 0, IFolio.Folio__InsufficientBalance());
    }

    function isValidSignature(
        IFolio.Auction[] storage auctions,
        uint256 totalSupply,
        bytes32 _hash,
        bytes calldata signature
    ) external view returns (bytes4) {
        // decode the signature to get the CowSwap order
        GPv2OrderLib.Data memory order = abi.decode(signature, (GPv2OrderLib.Data));

        // get auctionId from appData metadata field
        uint256 auctionId = abi.decode(abi.encodePacked(order.appData), (uint256));

        // lookup running auction
        IFolio.Auction storage auction = auctions[auctionId];

        // check auction is ongoing and that order.buyAmount is sufficient
        getBid(auction, block.timestamp, totalSupply, order.sellAmount, order.buyAmount);

        // verify order details
        require(_hash == order.hash(COWSWAP_GPV2_SETTLEMENT.domainSeparator()), IFolio.Folio__EIP712InvalidSignature());
        require(
            order.sellToken == address(auction.sell) &&
                order.buyToken == address(auction.buy) &&
                order.sellAmount != 0 &&
                order.feeAmount == 0 &&
                order.partiallyFillable &&
                order.validTo <= auction.end &&
                order.receiver == address(this),
            IFolio.Folio__CowSwapInvalidOrder()
        );

        // If all checks pass, return the magic value
        // bytes4(keccak256("isValidSignature(bytes32,bytes)")
        return 0x1626ba7e;
    }
}
