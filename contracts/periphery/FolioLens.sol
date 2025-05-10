// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Versioned } from "@utils/Versioned.sol";

import { IFolio } from "@src/interfaces/IFolio.sol";
import { Folio } from "@src/Folio.sol";
import { D18, D27 } from "@utils/Constants.sol";
/**
 * @title FolioLens
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Read-only interface for Folio summary info
 *
 * Not intended for onchain use; only for offchain analysis
 */
contract FolioLens is Versioned {
    constructor() {}

    /// Get token-share weights given by the current balances of the Folio
    /// @return tokens The tokens in the basket
    /// @return weights D27{tok/share} The weights of the tokens per share given by the current balances
    function getSpotWeights(Folio folio) external view returns (address[] memory tokens, uint256[] memory weights) {
        (, tokens, , , , , , , , , ) = folio.getRebalance();
        weights = new uint256[](tokens.length);

        uint256 totalSupply = folio.totalSupply();

        for (uint256 i = 0; i < tokens.length; i++) {
            // D27{tok/share} = D27 * {tok} / {share}
            weights[i] = (D27 * IERC20(tokens[i]).balanceOf(address(folio))) / totalSupply;
        }
    }

    /// Get bids for all pairs at once
    /// Many entries will be 0 to indicate an invalid token pair
    /// @return sellTokens Sell token in quote
    /// @return buyTokens Buy token in quote
    /// @return sellAmounts {sellTok}
    /// @return bidAmounts {bidTok}
    /// @return prices D27{buyTok/sellTok}
    function getAllBids(
        Folio folio,
        uint256 auctionId,
        uint256 timestamp
    )
        external
        view
        returns (
            address[] memory sellTokens,
            address[] memory buyTokens,
            uint256[] memory sellAmounts,
            uint256[] memory bidAmounts,
            uint256[] memory prices
        )
    {
        (, address[] memory tokens, , , , , , , , , ) = folio.getRebalance();

        sellTokens = new address[](tokens.length * tokens.length);
        buyTokens = new address[](tokens.length * tokens.length);
        sellAmounts = new uint256[](tokens.length * tokens.length);
        bidAmounts = new uint256[](tokens.length * tokens.length);
        prices = new uint256[](tokens.length * tokens.length);

        uint256 len = tokens.length;

        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = 0; j < len; j++) {
                uint256 index = i * len + j;

                sellTokens[index] = tokens[i];
                buyTokens[index] = tokens[j];

                try
                    folio.getBid(auctionId, IERC20(tokens[i]), IERC20(tokens[j]), timestamp, type(uint256).max)
                returns (uint256 sellAmount, uint256 bidAmount, uint256 price) {
                    sellAmounts[index] = sellAmount;
                    bidAmounts[index] = bidAmount;
                    prices[index] = price;
                } catch {
                    continue;
                }
            }
        }
    }

    /// Get all surplus and deficit balances at the given sell and buy limits
    /// @param sellLimit D18{BU/share} A sell limit of the rebalance
    /// @param buyLimit D18{BU/share} A buy limit of the rebalance
    function surplusesAndDeficits(
        Folio folio,
        uint256 sellLimit,
        uint256 buyLimit
    ) external view returns (address[] memory tokens, uint256[] memory surpluses, uint256[] memory deficits) {
        require(sellLimit >= buyLimit, "sellLimit < buyLimit");

        uint256 totalSupply = folio.totalSupply();

        IFolio.WeightRange[] memory weights;
        (, tokens, weights, , , , , , , , ) = folio.getRebalance();

        for (uint256 i = 0; i < tokens.length; i++) {
            // {tok}
            uint256 bal = IERC20(tokens[i]).balanceOf(address(folio));

            // surpluses
            {
                // D27{tok/share} = D18{BU/share} * D27{tok/BU} / D18
                uint256 tokenSellLimit = Math.mulDiv(sellLimit, weights[i].spot, D18, Math.Rounding.Ceil);

                // {tok} = D27{tok/share} * {share} / D27
                uint256 sellLimitBal = Math.mulDiv(tokenSellLimit, totalSupply, D27, Math.Rounding.Ceil);
                if (bal > sellLimitBal) {
                    surpluses[i] = bal - sellLimitBal;
                }
            }

            // deficits
            // only possible if there wasn't a surplus
            if (surpluses[i] == 0) {
                // D27{tok/share} = D18{BU/share} * D27{tok/BU} / D18
                uint256 tokenBuyLimit = Math.mulDiv(buyLimit, weights[i].spot, D18, Math.Rounding.Floor);

                // {tok} = D27{tok/share} * {share} / D27
                uint256 buyLimitBal = Math.mulDiv(tokenBuyLimit, totalSupply, D27, Math.Rounding.Floor);
                if (bal < buyLimitBal) {
                    deficits[i] = buyLimitBal - bal;
                }
            }
        }
    }
}
