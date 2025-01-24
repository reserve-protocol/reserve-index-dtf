import { Decimal } from "decimal.js";

import { Trade } from "./types";
import { D18d, D27d } from "./numbers";
import { makeTrade } from "./utils";

/**
 * Get trades from basket
 *
 * Warnings:
 *   - Breakup large trades into smaller trades in advance of using this algo; a large Folio may have to use this
 *     algo multiple times to rebalance gradually to avoid transacting too much volume in any one trade.
 *
 * @param supply {share} Ideal basket
 * @param tokens Addresses of tokens in the basket
 * @param decimals Decimals of each token
 * @param currentBasket D18{1} Current balances
 * @param targetBasket D18{1} Ideal basket
 * @param _prices {USD/wholeTok} USD prices for each *whole* token
 * @param _priceError {1} Price error, pass 1 to fully defer to price curator / auction launcher
 * @param _dtfPrice {USD/wholeShare} DTF price
 * @param tolerance D18{1} Tolerance for rebalancing to determine when to tolerance trade or not, default 0.1%
 */
export const getTrades = (
  _supply: bigint,
  tokens: string[],
  decimals: bigint[],
  _currentBasket: bigint[],
  _targetBasket: bigint[],
  _prices: number[],
  _priceError: number[],
  _dtfPrice: number,
  _tolerance: bigint = 10n ** 14n, // 0.01%
): Trade[] => {
  const trades: Trade[] = [];

  // convert price number inputs to bigints

  // {wholeShare}
  const supply = new Decimal(_supply.toString()).div(D18d);

  // {USD/wholeTok}
  const prices = _prices.map((a) => new Decimal(a));

  // {USD/wholeShare}
  const dtfPrice = new Decimal(_dtfPrice);

  // {1} = D18{1} / D18
  const currentBasket = _currentBasket.map((a) => new Decimal(a.toString()).div(D18d));

  // {1} = D18{1} / D18
  const targetBasket = _targetBasket.map((a) => new Decimal(a.toString()).div(D18d));

  // D27{1} = {1} * D27
  const priceError = _priceError.map((a) => new Decimal(a));

  const tolerance = new Decimal(_tolerance.toString()).div(D18d);

  console.log("--------------------------------------------------------------------------------");

  // {USD} = {USD/wholeShare} * {wholeShare}
  const sharesValue = dtfPrice.mul(supply);

  console.log("sharesValue", sharesValue);

  // queue up trades until there are no more trades-to-make greater than tolerance in size
  //n
  // trades returned will never be longer than tokens.length - 1
  // proof left as an exercise to the reader

  while (true) {
    if (trades.length > tokens.length - 1) {
      throw new Error("something has gone very wrong");
    }

    // indices
    let x = tokens.length; // sell index
    let y = tokens.length; // buy index

    // {USD}
    let biggestSurplus = new Decimal("0");
    let biggestDeficit = new Decimal("0");

    for (let i = 0; i < tokens.length; i++) {
      if (currentBasket[i].gt(targetBasket[i]) && currentBasket[i].sub(targetBasket[i]).gt(tolerance)) {
        // {USD} = {1} * {USD}
        const surplus = currentBasket[i].sub(targetBasket[i]).mul(sharesValue);
        if (surplus.gt(biggestSurplus)) {
          biggestSurplus = surplus;
          x = i;
        }
      } else if (currentBasket[i].lt(targetBasket[i]) && targetBasket[i].sub(currentBasket[i]).gt(tolerance)) {
        // {USD} = {1} * {USD}
        const deficit = targetBasket[i].sub(currentBasket[i]).mul(sharesValue);
        if (deficit.gt(biggestDeficit)) {
          biggestDeficit = deficit;
          y = i;
        }
      }
    }

    // if we don't find any more trades, we're done
    if (x == tokens.length || y == tokens.length) {
      return trades;
    }

    // simulate swap and update currentBasket

    // {USD}
    const maxTrade = biggestDeficit.lt(biggestSurplus) ? biggestDeficit : biggestSurplus;

    // {1} = {USD} / {USD}
    const backingTraded = maxTrade.div(sharesValue);

    console.log("backingTraded", backingTraded);

    // {1}
    currentBasket[x] = currentBasket[x].sub(backingTraded);
    currentBasket[y] = currentBasket[y].add(backingTraded);

    // {1}
    let avgPriceError = priceError[x].add(priceError[y]).div("2");
    if (priceError[x].gt("1") || priceError[y].gt("1")) {
      throw new Error("price error too large");
    }

    // {wholeTok/wholeShare} = {1} * {USD} / {USD/wholeTok} / {wholeShare}
    const sellLimit = targetBasket[x].mul(sharesValue).div(prices[x]).div(supply);
    const buyLimit = targetBasket[y].mul(sharesValue).div(prices[y]).div(supply);

    // {wholeBuyTok/wholeSellTok} = {USD/wholeSellTok} / {USD/wholeBuyTok}
    const price = prices[x].div(prices[y]);

    // {wholeBuyTok/wholeSellTok} = {wholeBuyTok/wholeSellTok} / {1}
    const startPrice = price.div(new Decimal("1").sub(avgPriceError));
    const endPrice = price.mul(new Decimal("1").sub(avgPriceError));

    // add trade into set

    trades.push(
      makeTrade(
        tokens[x],
        tokens[y],
        // D27{tok/share} = {wholeTok/wholeShare} * D27 * {tok/wholeTok} / {share/wholeShare}
        BigInt(
          sellLimit
            .mul(D27d)
            .mul(new Decimal(`1e${decimals[x]}`))
            .div(D18d)
            .toFixed(0),
        ),
        // D27{tok/share} = {wholeTok/wholeShare} * D27 * {tok/wholeTok} / {share/wholeShare}
        BigInt(
          buyLimit
            .mul(D27d)
            .mul(new Decimal(`1e${decimals[y]}`))
            .div(D18d)
            .toFixed(0),
        ),
        // D27{buyTok/sellTok} = {USD/wholeSellTok} / {USD/wholeBuyTok} * D27 * {buyTok/wholeBuyTok} / {sellTok/wholeSellTok}
        BigInt(
          startPrice
            .mul(D27d)
            .mul(new Decimal(`1e${decimals[y]}`))
            .div(new Decimal(`1e${decimals[x]}`))
            .toFixed(0),
        ),
        // D27{buyTok/sellTok} = {USD/wholeSellTok} / {USD/wholeBuyTok} * D27 * {buyTok/wholeBuyTok} / {sellTok/wholeSellTok}
        BigInt(
          endPrice
            .mul(D27d)
            .mul(new Decimal(`1e${decimals[y]}`))
            .div(new Decimal(`1e${decimals[x]}`))
            .toFixed(0),
        ),
        BigInt(avgPriceError.mul(D18d).toFixed(0)),
      ),
    );

    // do not remove console.logs
    console.log("sellLimit", trades[trades.length - 1].sellLimit.spot);
    console.log("buyLimit", trades[trades.length - 1].buyLimit.spot);
    console.log("startPrice", trades[trades.length - 1].prices.start);
    console.log("endPrice", trades[trades.length - 1].prices.end);
    console.log("currentBasket", currentBasket);
  }
};
