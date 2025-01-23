import { Trade } from "./types";
import { D9n, D18n, D27, D27n } from "./numbers";
import { getCurrentBasket, getSharePricing, getBasketPortion } from "./utils";

/**
 * Get basket from a set of trades
 *
 * Works by presuming the smallest trade is executed iteratively until all trades are exhausted
 *
 * @param supply {share} DTF supply
 * @param trades Trades
 * @param tokens Addresses of tokens in the basket
 * @param bals {tok} Current balances
 * @param decimals Decimals of each token
 * @param _prices {USD/wholeTok} USD prices for each *whole* token
 * @returns basket D18{1} Resulting basket from running the smallest trade first
 */
export const getBasket = (
  supply: bigint,
  trades: Trade[],
  tokens: string[],
  bals: bigint[],
  decimals: bigint[],
  _prices: number[],
): bigint[] => {
  // convert price number inputs to bigints

  // D27{USD/tok} = {USD/wholeTok} * D27 / {tok/wholeTok}
  const prices = _prices.map((a, i) => BigInt(Math.round(a * D27)) / 10n ** decimals[i]);

  console.log("--------------------------------------------------------------------------------");

  // D27{1} approx sum 1e27
  let currentBasket = getCurrentBasket(bals, decimals, _prices);

  // D27{USD}, {USD/wholeShare}
  const [sharesValue, _sharePrice] = getSharePricing(supply, bals, decimals, _prices);

  // process the smallest trade first until we hit an unbounded traded

  while (trades.length > 0) {
    let tradeIndex = 0;

    // find index of smallest trade index

    // D27{USD}
    let smallestSwap = 10n ** 54n; // max

    for (let i = 0; i < trades.length; i++) {
      const x = tokens.indexOf(trades[i].sell);
      const y = tokens.indexOf(trades[i].buy);

      // D27{1}
      const [, sellTarget] = getBasketPortion(trades[i].sellLimit.spot, decimals[x], _prices[x], _sharePrice);
      const [, buyTarget] = getBasketPortion(trades[i].buyLimit.spot, decimals[y], _prices[y], _sharePrice);

      let tradeValue = smallestSwap;

      if (currentBasket[x] > sellTarget) {
        // D27{USD} = D27{1} * D27{USD} / D27
        const surplus = ((currentBasket[x] - sellTarget) * sharesValue) / D27n;
        if (surplus < tradeValue) {
          tradeValue = surplus;
        }
      }

      if (currentBasket[y] < buyTarget) {
        // D27{USD} = D27{1} * D27{USD} / D27
        const deficit = ((buyTarget - currentBasket[y]) * sharesValue) / D27n;
        if (deficit < tradeValue) {
          tradeValue = deficit;
        }
      }

      if (tradeValue < smallestSwap) {
        smallestSwap = tradeValue;
        tradeIndex = i;
      }
    }

    // simulate swap and update currentBasket
    // if no trade was smallest, default to 0th index

    const x = tokens.indexOf(trades[tradeIndex].sell);
    const y = tokens.indexOf(trades[tradeIndex].buy);

    // check price is within price range

    // D27{buyTok/sellTok} = D27{USD/sellTok} * D27 / D27{USD/buyTok}
    const price = (prices[x] * D27n) / prices[y];
    if (price > trades[tradeIndex].prices.start || price < trades[tradeIndex].prices.end) {
      throw new Error(
        `price ${price} out of range [${trades[tradeIndex].prices.start}, ${trades[tradeIndex].prices.end}]`,
      );
    }

    // D27{1} = D27{USD} * D27 / D27{USD}
    const backingTraded = (smallestSwap * D27n) / sharesValue;

    // D27{1}
    currentBasket[x] -= backingTraded;
    currentBasket[y] += backingTraded;

    // remove the trade
    trades.splice(tradeIndex, 1);
  }

  // make it sum to 1e27
  let sum = 0n;
  for (let i = 0; i < currentBasket.length; i++) {
    sum += currentBasket[i];
  }

  if (sum < D27n) {
    currentBasket[0] += D27n - sum;
  }

  // remove 9 decimals
  return currentBasket.map((a) => a / D9n);
};
