const D9: bigint = BigInt(1e9);
const D18: bigint = BigInt(1e18);
const D27: bigint = BigInt(1e27);

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
 * @param prices D18{USD/tok} USD prices for each token
 * @returns D18{1} Current basket, total never exceeds D18
 */
const getCurrentBasket = (bals: bigint[], prices: bigint[]): bigint[] => {
  // D18{USD} = {tok} * D18{USD/tok}
  const values = bals.map((bal, i) => bal * prices[i]);

  // D18{USD}
  const total = values.reduce((a, b) => a + b);

  // D18{1} = D18{USD} * D18 / D18{USD}
  return values.map((amt, i) => (amt * D18) / total);
};

/**
 * @param bals {tok} Current balances
 * @param prices D18{USD/tok} USD prices for each token
 * @returns D18{USD/share} Estimated share price
 */
const getSharesValue = (bals: bigint[], prices: bigint[]): bigint => {
  // D18{USD} = {tok} * D18{USD/tok}
  const values = bals.map((bal, i) => bal * prices[i]);
  return values.reduce((a, b) => a + b);
};

/**
 *
 * Warning: If price errors are set too high, this algo will open excessive trades
 *3
 * @param shares {share} folio.totalSupply()
 * @param tokens Addresses of tokens in the basket
 * @param bals {tok} Current balances
 * @param targetBasket D18{1} Ideal basket
 * @param prices D18{USD/tok} USD prices for each token
 * @param error D18{1} Price error
 * @param tolerance D18{1} Tolerance for rebalancing to determine when to tolerance trade or not, default 0.1%
 */
export const getRebalance = (
  shares: bigint,
  tokens: string[],
  bals: bigint[],
  targetBasket: bigint[],
  prices: bigint[],
  error: bigint[],
  tolerance: bigint = BigInt(1e15),
): Trade[] => {
  const trades: Trade[] = [];

  // D18{1}
  const currentBasket = getCurrentBasket(bals, prices);

  // D18{USD}
  const sharesValue = getSharesValue(bals, prices);

  console.log("sharesValue", sharesValue);
  console.log("initial basket", currentBasket);

  // queue up trades until there are no more trades left greater than tolerance
  while (true) {
    // indices
    let x = tokens.length; // sell index
    let y = tokens.length; // buy index

    // D18{USD}
    let biggestSurplus = BigInt(0);
    let biggestDeficit = BigInt(0);

    for (let i = 0; i < tokens.length; i++) {
      if (currentBasket[i] > targetBasket[i] && currentBasket[i] - targetBasket[i] > tolerance) {
        // D18{USD} = D18{1} * D18{USD} / D18
        const surplus = ((currentBasket[i] - targetBasket[i]) * sharesValue) / D18;
        if (surplus > biggestSurplus) {
          biggestSurplus = surplus;
          x = i;
        }
      } else if (currentBasket[i] < targetBasket[i] && targetBasket[i] - currentBasket[i] > tolerance) {
        // D18{USD} = D18{1} * D18{USD} / D18
        const deficit = ((targetBasket[i] - currentBasket[i]) * sharesValue) / D18;
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

    // simulate trade and update currentBasket

    // D18{USD}
    const maxTrade = biggestDeficit < biggestSurplus ? biggestDeficit : biggestSurplus;

    // D18{1} = D18{USD} * D18 / D18{USD}
    const backingTraded = (maxTrade * D18) / sharesValue;

    // D18{1}
    currentBasket[x] -= backingTraded;
    currentBasket[y] += backingTraded;

    // set startPrice and endPrice to be above and below their par levels by the error

    // D18{1}
    let avgError = (error[x] + error[y]) / BigInt(2);

    if (avgError >= D18) {
      throw new Error("error too large");
    }

    // D27{buyTok/sellTok} = D18{USD/buyTok} * D27 / D18{USD/sellTok}
    let startPrice = (prices[y] * D27) / prices[x];
    // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18 / D18{1}
    startPrice = (startPrice * D18) / (D18 - avgError);

    // D27{buyTok/sellTok} = D18{USD/buyTok} * D27 / D18{USD/sellTok}
    let endPrice = (prices[y] * D27) / prices[x];
    // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
    endPrice = (endPrice * (D18 - avgError)) / D18;

    // D27{tok/share} = D18{1/share} * D18{USD} * D9 / D18{USD/tok}
    const sellLimit = (targetBasket[x] * sharesValue * D27) / prices[x];
    const buyLimit = (targetBasket[y] * sharesValue * D27) / prices[y];

    console.log("-------------------------");
    console.log(trades.length);
    console.log("maxTrade", maxTrade);
    console.log("backingTraded", backingTraded);
    console.log("sellLimit", sellLimit);
    console.log("buyLimit", buyLimit);
    console.log("startPrice", startPrice);
    console.log("endPrice", endPrice);
    console.log("currentBasket", currentBasket);

    // queue trade

    trades.push({
      sell: tokens[x],
      buy: tokens[y],

      sellLimit: sellLimit,
      buyLimit: buyLimit,
      startPrice: startPrice,
      endPrice: endPrice,
    });
  }

  return trades;
};
