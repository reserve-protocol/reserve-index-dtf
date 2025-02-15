// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { UD60x18, powu, pow } from "@prb/math/src/UD60x18.sol";
import { SD59x18, exp, intoUint256 } from "@prb/math/src/SD59x18.sol";

import { IFolio } from "../interfaces/IFolio.sol";
import { GPv2OrderLib, COWSWAP_GPV2_SETTLEMENT } from "../utils/GPv2OrderLib.sol";

import { ISwapFactory } from "../interfaces/ISwapFactory.sol";

uint256 constant MAX_RATE = 1e54; // D18{buyTok/sellTok}

uint256 constant D18 = 1e18; // D18
uint256 constant D27 = 1e27; // D27

library FolioLib {
    using GPv2OrderLib for GPv2OrderLib.Data;
    using SafeERC20 for IERC20;

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

    // ==== Math ====

    function UD_powu(UD60x18 x, uint256 y) external pure returns (uint256 z) {
        return powu(x, y).unwrap();
    }

    function UD_pow(UD60x18 x, UD60x18 y) external pure returns (uint256 z) {
        return pow(x, y).unwrap();
    }
}
