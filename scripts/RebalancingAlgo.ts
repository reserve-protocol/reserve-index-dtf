const D9: bigint = BigInt(1e9);
const D18: bigint = BigInt(1e18);

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
 * @returns D18{1/share} Current basket, total never exceeds D18
 */
const getCurrentBasket = (bals: bigint[], prices: bigint[]): bigint[] => {
  // D18{USD} = {tok} * D18{USD/tok}
  const values = bals.map((bal, i) => bal * prices[i]);

  // D18{USD/share}
  const total = values.reduce((a, b) => a + b);

  // D18{1/share} = D18{USD/share} * D18 / D18{USD}
  return values.map((amt, i) => (amt * D18) / total);
};

/**
 * @param targetBasket D18{1/share} Ideal basket, adds up to D18 or close to it
 * @param prices D18{USD/tok} USD prices for each token
 * @returns D18{USD/share} Estimated share price
 */
const getSharePrice = (targetBasket: bigint[], prices: bigint[]): bigint => {
  // D18{USD/share tok} = D18{1/share} * D18{USD/tok} / D18
  const values = targetBasket.map((portion, i) => (portion * prices[i]) / D18);

  // D18{USD/share} = sum(D18{USD/share tok})
  return values.reduce((a, b) => a + b);
};

/**
 *
 * Warning: If price errors are set too high, this algo will open excessive trades
 *
 * @param shares {share} folio.totalSupply()
 * @param tokens Addresses of tokens in the basket
 * @param bals {tok} Current balances
 * @param targetBasket D18{1/share} Ideal basket
 * @param prices D18{USD/tok} USD prices for each token
 * @param error D18{1/share} Price error
 * @param tolerance D18{1/share} Tolerance for rebalancing to determine when to tolerance trade or not, default 0.1%
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

  // D18{1/share}
  const currentBasket = getCurrentBasket(bals, prices);

  // D18{USD/share}
  const sharePrice = getSharePrice(targetBasket, prices);

  // D18{USD} = D18{USD/share} * {share}
  const sharesValue = sharePrice * shares;

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
        // D18{USD} = {tok} * D18{USD/tok}
        const surplus = (currentBasket[i] - targetBasket[i]) * prices[i];
        if (surplus > biggestSurplus) {
          biggestSurplus = surplus;
          x = i;
        }
      } else if (currentBasket[i] < targetBasket[i] && targetBasket[i] - currentBasket[i] > tolerance) {
        // D18{USD} = {tok} * D18{USD/tok}
        const deficit = (targetBasket[i] - currentBasket[i]) * prices[i];
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

    // D18{1}
    let avgError = (error[x] + error[y]) / BigInt(2);

    if (avgError >= D18) {
      throw new Error("error too large");
    }

    // D18{USD}
    const tradeValue = biggestDeficit < biggestSurplus ? biggestDeficit : biggestSurplus;

    // D18{1/share} = D18{USD} * D18 / D18{USD} / {share}
    const basketTraded = (tradeValue * D18) / sharesValue / shares;

    // update basket state assuming partial fills
    // D18{1/share}
    currentBasket[x] -= (basketTraded * (D18 - avgError)) / D18;
    currentBasket[y] += (basketTraded * (D18 - avgError)) / D18;

    // D27{buyTok/sellTok} = D18{USD/buyTok} * D9 / D18{USD/sellTok}
    let startPrice = (prices[y] * D9) / prices[x];
    // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18 / D18{1}
    startPrice = (startPrice * D18) / (D18 - avgError);

    // D27{buyTok/sellTok} = D18{USD/buyTok} * D9 / D18{USD/sellTok}
    let endPrice = (prices[y] * D9) / prices[x];
    // D27{buyTok/sellTok} = D27{buyTok/sellTok} * D18{1} / D18
    endPrice = (endPrice * (D18 - avgError)) / D18;

    // queue trade
    trades.push({
      sell: tokens[x],
      buy: tokens[y],

      // D27{tok/share} = D18{1/share} * D18{USD} * D9 / D18{USD/tok}
      sellLimit: (targetBasket[x] * sharesValue * D9) / prices[x],
      buyLimit: (targetBasket[y] * sharesValue * D9) / prices[y],
      startPrice: startPrice,
      endPrice: endPrice,
    });
  }

  return trades;
};
