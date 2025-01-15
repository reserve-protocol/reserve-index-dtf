export const D27: number = 10 ** 27;

// IFolio.Trade interface minus some fields
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
 * @param prices {USD/wholeTok} USD prices for each token
 * @returns {1} Current basket, total shouldn't exceed 1 (excessively)
 */
const getCurrentBasket = (bals: bigint[], prices: number[], decimals: bigint[]): number[] => {
  // {USD} = {tok} * {USD/wholeTok} / {tok/wholeTok}
  const values = bals.map((bal, i) => (Number(bal) * prices[i]) / Number(10n ** decimals[i]));

  // {USD}
  const total = values.reduce((a, b) => a + b);

  // {1} = {USD} /{USD}
  return values.map((amt, i) => amt / total);
};

/**
 * @param bals {tok} Current balances
 * @param prices {USD/wholeTok} USD prices for each token
 * @returns {USD} Estimated USD value of all the shares
 */
const getSharesValue = (bals: bigint[], prices: number[], decimals: bigint[]): number => {
  // {USD} = {tok} * {USD/wholeTok} / {tok/wholeTok}
  const values = bals.map((bal, i) => (Number(bal) * prices[i]) / Number(10n ** decimals[i]));
  return values.reduce((a, b) => a + b);
};

/**
 *
 * Warnings:
 *   - Breakup large trades into smaller trades in advance of using this algo; a large Folio may have to use this
 *     algo multiple times to rebalance gradually to avoid transacting too much volume in any one trade.
 *
 * @param supply {share} Ideal basket
 * @param tokens Addresses of tokens in the basket
 * @param decimals Decimals of each token
 * @param bals {tok} Current balances, in wei
 * @param targetBasket {1} Ideal basket
 * @param prices {USD/wholeTok} USD prices for each *whole* token
 * @param priceError {1} Price error
 * @param tolerance {1} Tolerance for rebalancing to determine when to tolerance trade or not, default 0.1%
 */
export const getRebalance = (
  supply: bigint,
  tokens: string[],
  decimals: bigint[],
  bals: bigint[],
  targetBasket: number[],
  prices: number[],
  priceError: number[],
  tolerance: number = 0.0001, // 0.01%
): Trade[] => {
  const trades: Trade[] = [];

  // {1} sum to 1
  const currentBasket = getCurrentBasket(bals, prices, decimals);

  // {USD}
  const sharesValue = getSharesValue(bals, prices, decimals);

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

    console.log("currentBasket", currentBasket);
    console.log("targetBasket", targetBasket);

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

    console.log("backingTraded", backingTraded);

    // {1}
    currentBasket[x] -= backingTraded;
    currentBasket[y] += backingTraded;

    // set startPrice and endPrice to be above and below their par levels by the average priceError

    // {1}
    const avgPriceError = (priceError[x] + priceError[y]) / 2;

    if (avgPriceError >= 1) {
      throw new Error("error too large");
    }

    // {wholeBuyTok/wholeSellTok} = {USD/wholeBuyTok} / {USD/wholeSellTok}
    const price = prices[y] / prices[x];

    // {wholeBuyTok/wholeSellTok} = {wholeBuyTok/wholeSellTok} / {1}
    const startPriceWhole = price / (1 - avgPriceError);
    const endPriceWhole = price * (1 - avgPriceError);

    console.log("targetBasket", targetBasket[y], sharesValue, prices[y]);

    // {wholeTok} = {1} * {USD} / {USD/wholeTok}
    const sellLimitWhole = (targetBasket[x] * sharesValue) / prices[x];
    const buyLimitWhole = (targetBasket[y] * sharesValue) / prices[y];

    // {tok/share} = {wholeTok} * {tok/wholeTok} / {share}
    const sellLimit = (sellLimitWhole * Number(10n ** decimals[x])) / Number(supply);
    const buyLimit = (buyLimitWhole * Number(10n ** decimals[y])) / Number(supply);

    // {buyTok/sellTok} = {wholeBuyTok/wholeSellTok} * {buyTok/wholeBuyTok} / {sellTok/wholeSellTok}
    const startPrice = (startPriceWhole * Number(10n ** decimals[y])) / Number(10n ** decimals[x]);
    const endPrice = (endPriceWhole * Number(10n ** decimals[y])) / Number(10n ** decimals[x]);

    // add trade into set

    trades.push({
      sell: tokens[x],
      buy: tokens[y],

      // convert number to 27-decimal bigints
      // D27{tok/share} = {tok/share} * D27
      sellLimit: BigInt(Math.round(sellLimit * D27)),
      buyLimit: BigInt(Math.round(buyLimit * D27)),
      startPrice: BigInt(Math.round(startPrice * D27)),
      endPrice: BigInt(Math.round(endPrice * D27)),
    });

    // do not remove console.logs they do not show in tests that succeed
    console.log("sellLimit", trades[trades.length - 1].sellLimit);
    console.log("buyLimit", trades[trades.length - 1].buyLimit);
    console.log("startPrice", trades[trades.length - 1].startPrice);
    console.log("endPrice", trades[trades.length - 1].endPrice);
    console.log("currentBasket", currentBasket);
  }

  return trades;
};
