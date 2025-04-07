import { Auction } from "../types";
import { getCurrentBasket } from "../utils";

/**
 * Get target basket for a tracking DTF based on a supplied index of basket ratios
 *
 * @param auctions Auctions
 * @param tokens Addresses of tokens in the basket
 * @param decimals Decimals of each token
 * @param _prices {USD/wholeTok} Current USD prices for each *whole* token
 * @returns basket D18{1} Resulting basket from running the smallest auction first
 */
export const getBasketTrackingDTF = (
  auctions: Auction[],
  tokens: string[],
  decimals: bigint[],
  _prices: number[],
): bigint[] => {
  console.log("getBasketTrackingDTF()", auctions, tokens, decimals, _prices);

  console.log("--------------------------------------------------------------------------------");

  // D27{tok/share}
  const basketRatios = getBasketRatiosFromAuctions(tokens, auctions);

  return getCurrentBasket(basketRatios, decimals, _prices);
};

/**
 *
 * @return D27{tok/share} The basket ratios as 27-decimal bigints
 *  */
export const getBasketRatiosFromAuctions = (tokens: string[], auctions: Auction[]): bigint[] => {
  const basketRatios: bigint[] = [];

  for (let i = 0; i < tokens.length; i++) {
    // loop through all auctions and fetch basket ratios; must be uniform!

    let basketRatio = -1n; // -1n means the token isn't present in the auctions period, and therefore this approach doesn't work

    for (let j = 0; j < auctions.length; j++) {
      if (tokens[i] == auctions[j].sell) {
        if (basketRatio != -1n && basketRatio != auctions[j].sellLimit.spot) {
          throw new Error("basket ratios must be uniform! sell side");
        }

        basketRatio = auctions[j].sellLimit.spot;
      } else if (tokens[i] == auctions[j].buy) {
        if (basketRatio != -1n && basketRatio != auctions[j].buyLimit.spot) {
          throw new Error("basket ratios must be uniform! buy side");
        }

        basketRatio = auctions[j].buyLimit.spot;
      }
    }

    if (basketRatio == -1n) {
      console.log("token missing from auctions", tokens[i]);
      throw new Error("token missing from auctions");
    }

    basketRatios.push(basketRatio);
  }

  return basketRatios;
};
