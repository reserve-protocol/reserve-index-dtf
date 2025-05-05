// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Versioned } from "@utils/Versioned.sol";

import { Folio } from "@src/Folio.sol";
import { D27 } from "@utils/Constants.sol";

/**
 * @title FolioLens
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Read-only interface for Folio summary info
 */
contract FolioLens is Versioned {
    constructor() {}

    /// Get token-share weights given by the current balances of the Folio
    /// @return tokens The tokens in the basket
    /// @return weights D27{tok/share} The weights of the tokens per share given by the current balances
    function getSpotWeights(Folio folio) external view returns (address[] memory tokens, uint256[] memory weights) {
        (tokens, , , , ) = folio.getRebalance();
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
        (address[] memory tokens, , , , ) = folio.getRebalance();

        sellTokens = new address[](tokens.length * tokens.length);
        buyTokens = new address[](tokens.length * tokens.length);
        sellAmounts = new uint256[](tokens.length * tokens.length);
        bidAmounts = new uint256[](tokens.length * tokens.length);
        prices = new uint256[](tokens.length * tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < tokens.length; j++) {
                uint256 index = i * tokens.length + j;

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

    function surplusesAndDeficits(
        Folio folio
    ) external view returns (address[] memory tokens, uint256[] memory surpluses, uint256[] memory deficits) {
        // TODO
    }
}
