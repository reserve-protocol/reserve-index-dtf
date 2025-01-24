import { Decimal } from "decimal.js";

import { Trade } from "./types";
import { D18d, D27d } from "./numbers";

/**
 * Get basket from a set of trades
 *
 * Works by presuming the smallest trade is executed iteratively until all trades are exhausted
 *
 * @param supply {share} DTF supply
 * @param trades Trades
 * @param tokens Addresses of tokens in the basket
 * @param decimals Decimals of each token
 * @param currentBasket D18{1} Current basket breakdown
 * @param _prices {USD/wholeTok} USD prices for each *whole* token
 * @returns basket D18{1} Resulting basket from running the smallest trade first
 */
export const getBasket = (
  _supply: bigint,
  trades: Trade[],
  tokens: string[],
  decimals: bigint[],
  _currentBasket: bigint[],
  _prices: number[],
  _dtfPrice: number,
): bigint[] => {
  // {wholeShare}
  const supply = new Decimal(_supply.toString()).div(D18d);

  // {USD/wholeTok}
  const prices = _prices.map((a) => new Decimal(a));

  // {USD/wholeShare}
  const dtfPrice = new Decimal(_dtfPrice);

  // {1} = D18{1} / D18
  const currentBasket = _currentBasket.map((a) => new Decimal(a.toString()).div(D18d));

  console.log("--------------------------------------------------------------------------------");

  // {USD} = {USD/wholeShare} * {wholeShare}
  const sharesValue = dtfPrice.mul(supply);

  console.log("sharesValue", sharesValue);

  // process the smallest trade first until we hit an unbounded traded

  while (trades.length > 0) {
    let tradeIndex = 0;

    // find index of smallest trade index

    // {USD}
    let smallestSwap = D27d.mul(D27d); // max, 1e54

    for (let i = 0; i < trades.length; i++) {
      const x = tokens.indexOf(trades[i].sell);
      const y = tokens.indexOf(trades[i].buy);

      // D27{tok * wholeShare/share * wholeTok} = D27{tok/share} * {USD/wholeTok} / {USD/wholeShare}
      let sellTarget = new Decimal(trades[i].sellLimit.spot.toString()).mul(prices[x]).div(dtfPrice);
      let buyTarget = new Decimal(trades[i].buyLimit.spot.toString()).mul(prices[y]).div(dtfPrice);

      // D27{1} = D27{tok * wholeShare/share * wholeTok} * {share/wholeShare} / {tok/wholeTok}
      sellTarget = sellTarget.mul(D18d).div(new Decimal(`1e${decimals[x]}`));
      buyTarget = buyTarget.mul(D18d).div(new Decimal(`1e${decimals[y]}`));

      // {1} = D27{1} / D27
      sellTarget = sellTarget.div(D27d);
      buyTarget = buyTarget.div(D27d);

      console.log("sellTarget", sellTarget, currentBasket[x]);
      console.log("buyTarget", buyTarget, currentBasket[y]);

      // {USD} = {1} * {USD}
      let surplus = currentBasket[x].gt(sellTarget)
        ? currentBasket[x].sub(sellTarget).mul(sharesValue)
        : new Decimal("0");
      const deficit = currentBasket[y].lt(buyTarget)
        ? buyTarget.sub(currentBasket[y]).mul(sharesValue)
        : new Decimal("0");
      const tradeValue = surplus.gt(deficit) ? deficit : surplus;

      if (tradeValue.gt(new Decimal("0")) && tradeValue.lt(smallestSwap)) {
        smallestSwap = tradeValue;
        tradeIndex = i;
      }
    }

    // simulate swap and update currentBasket
    // if no trade was smallest, default to 0th index

    const x = tokens.indexOf(trades[tradeIndex].sell);
    const y = tokens.indexOf(trades[tradeIndex].buy);

    // check price is within price range

    // D27{buyTok/sellTok} = {USD/wholeSellTok} / {USD/wholeBuyTok} * D27 * {buyTok/wholeBuyTok} / {sellTok/wholeSellTok}
    const price = (BigInt(prices[x].div(prices[y]).mul(D27d).toFixed(0)) * 10n ** decimals[y]) / 10n ** decimals[x];
    if (price > trades[tradeIndex].prices.start || price < trades[tradeIndex].prices.end) {
      throw new Error(
        `price ${price} out of range [${trades[tradeIndex].prices.start}, ${trades[tradeIndex].prices.end}]`,
      );
    }

    // {1} = {USD} / {USD}
    const backingTraded = smallestSwap.div(sharesValue);

    console.log("backingTraded", backingTraded, smallestSwap, sharesValue);

    // {1}
    currentBasket[x] = currentBasket[x].sub(backingTraded);
    currentBasket[y] = currentBasket[y].add(backingTraded);

    // remove the trade
    trades.splice(tradeIndex, 1);
  }

  // D18{1} = {1} * D18
  return currentBasket.map((a) => BigInt(a.mul(D18d).toFixed(0)));
};
