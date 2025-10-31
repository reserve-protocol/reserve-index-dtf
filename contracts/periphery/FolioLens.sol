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
        (, , IFolio.TokenRebalanceParams[] memory tokenParams, , , ) = folio.getRebalance();

        tokens = new address[](tokenParams.length);
        weights = new uint256[](tokenParams.length);

        uint256 totalSupply = folio.totalSupply();

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokenParams[i].token;
            tokens[i] = token;

            // D27{tok/share} = D27 * {tok} / {share}
            weights[i] = (D27 * IERC20(token).balanceOf(address(folio))) / totalSupply;
        }
    }

    struct SingleBid {
        address sellToken;
        address buyToken;
        uint256 sellAmount; // {sellTok}
        uint256 bidAmount; // {bidTok}
        uint256 price; // D27{buyTok/sellTok}
    }

    /// Get bids for all pairs at once for the current block
    /// Many entries will be 0 to indicate an invalid token pair
    function getAllBids(Folio folio, uint256 auctionId) external view returns (SingleBid[] memory bids) {
        (uint256 nonce, , IFolio.TokenRebalanceParams[] memory tokenParams, , , ) = folio.getRebalance();

        {
            (uint256 rebalanceNonce, , ) = folio.auctions(auctionId);

            if (nonce != rebalanceNonce) {
                return bids;
            }
        }

        uint256 len = tokenParams.length;
        SingleBid[] memory allBids = new SingleBid[](len * len);

        uint256 count = 0;
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = 0; j < len; j++) {
                try
                    folio.getBid(
                        auctionId,
                        IERC20(tokenParams[i].token),
                        IERC20(tokenParams[j].token),
                        type(uint256).max
                    )
                returns (uint256 sellAmount, uint256 bidAmount, uint256 price) {
                    if (sellAmount != 0 && bidAmount != 0) {
                        allBids[count] = SingleBid({
                            sellToken: tokenParams[i].token,
                            buyToken: tokenParams[j].token,
                            sellAmount: sellAmount,
                            bidAmount: bidAmount,
                            price: price
                        });
                        count++;
                    }
                } catch {
                    continue;
                }
            }
        }

        bids = new SingleBid[](count);
        for (uint256 i = 0; i < count; i++) {
            bids[i] = allBids[i];
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

        (, , IFolio.TokenRebalanceParams[] memory tokenParams, , , ) = folio.getRebalance();

        uint256 len = tokenParams.length;
        tokens = new address[](len);
        surpluses = new uint256[](len);
        deficits = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address token = tokenParams[i].token;

            tokens[i] = token;

            // {tok}
            uint256 bal = IERC20(token).balanceOf(address(folio));

            // surpluses
            {
                // D27{tok/share} = D18{BU/share} * D27{tok/BU} / D18
                uint256 tokenSellLimit = Math.mulDiv(sellLimit, tokenParams[i].weight.high, D18, Math.Rounding.Ceil);

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
                uint256 tokenBuyLimit = Math.mulDiv(buyLimit, tokenParams[i].weight.low, D18, Math.Rounding.Floor);

                // {tok} = D27{tok/share} * {share} / D27
                uint256 buyLimitBal = Math.mulDiv(tokenBuyLimit, totalSupply, D27, Math.Rounding.Floor);
                if (bal < buyLimitBal) {
                    deficits[i] = buyLimitBal - bal;
                }
            }
        }
    }
}
