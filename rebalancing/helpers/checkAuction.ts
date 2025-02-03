import { Decimal } from "decimal.js";

import { D27d } from "../numbers";
import { Auction } from "../types";

/**
 * Check if a auction contains the current market price of the tokens in the auction, without accounting for slippage
 *
 * @param auction Auction
 * @param tokens Addresses of tokens in the basket, must match prices
 * @param _prices {USD/wholeTok} USD prices for each *whole* token, must match tokens
 * @param decimals Decimals of each token
 * @return boolean True if the auction price range contains the naive clearing price of the tokens in the auction
 *
 */
export const checkAuction = (auction: Auction, tokens: string[], _prices: number[], decimals: bigint[]): boolean => {
  // {USD/wholeTok}
  const prices = _prices.map((a) => new Decimal(a));

  let sellIndex = prices.length;
  let buyIndex = prices.length;

  // find indices

  for (let i = 0; i < prices.length; i++) {
    if (tokens[i] == auction.sell) {
      sellIndex = i;
    } else if (tokens[i] == auction.buy) {
      buyIndex = i;
    }
  }

  if (sellIndex == prices.length || buyIndex == prices.length) {
    throw new Error("auction tokens not found in tokens array");
  }

  // {wholeBuyTok/wholeSellTok} = {USD/wholeSellTok} / {USD/wholeBuyTok}
  const wholePrice = prices[sellIndex].div(prices[buyIndex]);

  // {buyTok/sellTok} = {wholeBuyTok/wholeSellTok} * {buyTok/wholeBuyTok} / {sellTok/wholeSellTok}
  const price = wholePrice.mul(new Decimal(`1e${decimals[buyIndex]}`)).div(new Decimal(`1e${decimals[sellIndex]}`));

  // D27{buyTok/sellTok} = D27 * {buyTok/sellTok}
  const priceD27 = BigInt(price.mul(D27d).toFixed(0));

  return priceD27 >= auction.prices.end && priceD27 <= auction.prices.start;
};
