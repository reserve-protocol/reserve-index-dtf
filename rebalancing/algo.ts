export const D27: number = 10 ** 27;

// Trade interface minus some fields from solidity implementation
export interface Trade {
  sell: string;
  buy: string;
  sellLimit: bigint; // D27{sellTok/share} spot est for min ratio of sell token to shares allowed, inclusive
  buyLimit: bigint; // D27{buyTok/share} spot est for max ratio of buy token to shares allowed, exclusive
  startPrice: bigint; // D27{buyTok/sellTok}
  endPrice: bigint; // D27{buyTok/sellTok}
}

/**
 * @param bals {tok} Current balances
 * @param prices {USD/tok} USD prices for each token
 * @returns {1} Current basket, total never exceeds 1
 */
const getCurrentBasket = (bals: bigint[], prices: number[]): number[] => {
  // {USD} = {tok} * {USD/tok}
  const values = bals.map((bal, i) => Number(bal) * prices[i]);

  // {USD}
  const total = values.reduce((a, b) => a + b);

  // {1} = {USD} /{USD}
  return values.map((amt, i) => amt / total);
};

/**
 * @param bals {tok} Current balances
 * @param prices {USD/tok} USD prices for each token
 * @returns {USD/share} Estimated share price
 */
const getSharesValue = (bals: bigint[], prices: number[]): number => {
  // {USD} = {tok} * {USD/tok}
  const values = bals.map((bal, i) => Number(bal) * prices[i]);
  return values.reduce((a, b) => a + b);
};

/**
 *
 * Warnings:
 *   - Breakup large trades into smaller trades in advance of using this algo; a large Folio may have to use this
 *     algo multiple times to rebalance gradually to avoid transacting too much volume in any one trade.
 *3
 * @param tokens Addresses of tokens in the basket
 * @param bals {tok} Current balances
 * @param targetBasket {1} Ideal basket
 * @param prices {USD/tok} USD prices for each token
 * @param error {1} Price error
 * @param tolerance {1} Tolerance for rebalancing to determine when to tolerance trade or not, default 0.1%
 */
export const getRebalance = (
  tokens: string[],
  bals: bigint[],
  targetBasket: number[],
  prices: number[],
  error: number[],
  tolerance: number = 0.001, // 0.1%
): Trade[] => {
  const trades: Trade[] = [];

  // {1}
  const currentBasket = getCurrentBasket(bals, prices);

  // {USD}
  const sharesValue = getSharesValue(bals, prices);

  // queue up trades until there are no more trades-to-make left greater than tolerance
  // trades returned will never be longer than tokens.length - 1; proof left as an exercise to the reader

  while (true) {
    if (trades.length > tokens.length - 1) {
      throw new Error("something has gone very wrong");
    }

    // indices
    let x = tokens.length; // sell index
    let y = tokens.length; // buy index

    // {USD}
    let biggestSurplus = 0;
    let biggestDeficit = 0;

    for (let i = 0; i < tokens.length; i++) {
      if (currentBasket[i] > targetBasket[i] && currentBasket[i] - targetBasket[i] > tolerance) {
        // {USD} = {1} * {USD}
        const surplus = (currentBasket[i] - targetBasket[i]) * sharesValue;
        if (surplus > biggestSurplus) {
          biggestSurplus = surplus;
          x = i;
        }
      } else if (currentBasket[i] < targetBasket[i] && targetBasket[i] - currentBasket[i] > tolerance) {
        // {USD} = {1} * {USD}
        const deficit = (targetBasket[i] - currentBasket[i]) * sharesValue;
        if (deficit > biggestDeficit) {
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
    const maxTrade = biggestDeficit < biggestSurplus ? biggestDeficit : biggestSurplus;

    // {1} = {USD} / {USD}
    const backingTraded = maxTrade / sharesValue;

    // {1}
    currentBasket[x] -= backingTraded;
    currentBasket[y] += backingTraded;

    // set startPrice and endPrice to be above and below their par levels by the average error

    // {1}
    let avgError = (error[x] + error[y]) / 2;

    if (avgError >= 1) {
      throw new Error("error too large");
    }

    // {buyTok/sellTok} = {USD/buyTok} / {USD/sellTok}
    const price = prices[y] / prices[x];

    // {buyTok/sellTok} = {buyTok/sellTok} / {1}
    const startPrice = price / (1 - avgError);
    const endPrice = price * (1 - avgError);

    // {tok} = {1} * {USD} / {USD/tok}
    const sellLimit = (targetBasket[x] * sharesValue) / prices[x];
    const buyLimit = (targetBasket[y] * sharesValue) / prices[y];

    console.log("sellLimit", sellLimit);
    console.log("buyLimit", buyLimit);
    console.log("startPrice", startPrice);
    console.log("endPrice", endPrice);
    console.log("currentBasket", currentBasket);

    // add trade into set

    trades.push({
      sell: tokens[x],
      buy: tokens[y],

      sellLimit: BigInt(Math.round(sellLimit * D27)),
      buyLimit: BigInt(Math.round(buyLimit * D27)),
      startPrice: BigInt(Math.round(startPrice * D27)),
      endPrice: BigInt(Math.round(endPrice * D27)),
    });
  }

  return trades;
};
