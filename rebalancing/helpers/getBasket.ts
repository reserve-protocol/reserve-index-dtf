import { Decimal } from "decimal.js";

import { Auction } from "../types";
import { bn, D18d, D27d, ZERO } from "../numbers";
import { toDecimals } from "../utils";

/**
 * Get basket from a set of auctions
 *
 * Works by presuming the smallest auction is executed iteratively until all auctions are exhausted
 *
 * @param supply {share} DTF supply
 * @param auctions Auctions
 * @param tokens Addresses of tokens in the basket
 * @param decimals Decimals of each token
 * @param currentBasket D18{1} Current basket breakdown
 * @param _prices {USD/wholeTok} USD prices for each *whole* token
 * @returns basket D18{1} Resulting basket from running the smallest auction first
 */
export const getBasket = (
  _supply: bigint,
  auctions: Auction[],
  tokens: string[],
  decimals: bigint[],
  _currentBasket: bigint[],
  _prices: number[],
  _dtfPrice: number,
): bigint[] => {
  // {wholeShare}
  const supply = new Decimal(_supply.toString()).div(D18d);

  // {USD/wholeTok}
  const prices = toDecimals(_prices);

  // {USD/wholeShare}
  const dtfPrice = new Decimal(_dtfPrice);

  // {1} = D18{1} / D18
  const currentBasket = _currentBasket.map((a) => new Decimal(a.toString()).div(D18d));

  console.log("--------------------------------------------------------------------------------");

  // {USD} = {USD/wholeShare} * {wholeShare}
  const sharesValue = dtfPrice.mul(supply);

  console.log("sharesValue", sharesValue);

  // process the smallest auction first until we hit an unbounded auctiond

  while (auctions.length > 0) {
    let auctionIndex = 0;

    // find index of smallest auction index

    // {USD}
    let smallestSwap = D27d.mul(D27d); // max, 1e54

    for (let i = 0; i < auctions.length; i++) {
      const x = tokens.indexOf(auctions[i].sell);
      const y = tokens.indexOf(auctions[i].buy);

      // D27{tok * wholeShare/share * wholeTok} = D27{tok/share} * {USD/wholeTok} / {USD/wholeShare}
      let sellTarget = new Decimal(auctions[i].sellLimit.spot.toString()).mul(prices[x]).div(dtfPrice);
      let buyTarget = new Decimal(auctions[i].buyLimit.spot.toString()).mul(prices[y]).div(dtfPrice);

      // D27{1} = D27{tok * wholeShare/share * wholeTok} * {share/wholeShare} / {tok/wholeTok}
      sellTarget = sellTarget.mul(D18d).div(new Decimal(`1e${decimals[x]}`));
      buyTarget = buyTarget.mul(D18d).div(new Decimal(`1e${decimals[y]}`));

      // {1} = D27{1} / D27
      sellTarget = sellTarget.div(D27d);
      buyTarget = buyTarget.div(D27d);

      console.log("sellTarget", sellTarget, currentBasket[x]);
      console.log("buyTarget", buyTarget, currentBasket[y]);

      // {USD} = {1} * {USD}
      let surplus = currentBasket[x].gt(sellTarget) ? currentBasket[x].minus(sellTarget).mul(sharesValue) : ZERO;
      const deficit = currentBasket[y].lt(buyTarget) ? buyTarget.minus(currentBasket[y]).mul(sharesValue) : ZERO;
      const auctionValue = surplus.gt(deficit) ? deficit : surplus;

      if (auctionValue.gt(ZERO) && auctionValue.lt(smallestSwap)) {
        smallestSwap = auctionValue;
        auctionIndex = i;
      }
    }

    // simulate swap and update currentBasket
    // if no auction was smallest, default to 0th index

    const x = tokens.indexOf(auctions[auctionIndex].sell);
    const y = tokens.indexOf(auctions[auctionIndex].buy);

    // check price is within price range

    // D27{buyTok/sellTok} = {USD/wholeSellTok} / {USD/wholeBuyTok} * D27 * {buyTok/wholeBuyTok} / {sellTok/wholeSellTok}
    const price = (bn(prices[x].div(prices[y]).mul(D27d)) * 10n ** decimals[y]) / 10n ** decimals[x];
    if (price > auctions[auctionIndex].prices.start || price < auctions[auctionIndex].prices.end) {
      throw new Error(
        `price ${price} out of range [${auctions[auctionIndex].prices.start}, ${auctions[auctionIndex].prices.end}]`,
      );
    }

    // {1} = {USD} / {USD}
    const backingAuctioned = smallestSwap.div(sharesValue);

    console.log("backingAuctioned", backingAuctioned, smallestSwap, sharesValue);

    // {1}
    currentBasket[x] = currentBasket[x].minus(backingAuctioned);
    currentBasket[y] = currentBasket[y].plus(backingAuctioned);

    // remove the auction
    auctions.splice(auctionIndex, 1);
  }

  // D18{1} = {1} * D18
  return currentBasket.map((a) => bn(a.mul(D18d)));
};
