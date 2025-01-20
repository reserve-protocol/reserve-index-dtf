import { Trade } from "./types";
import { D9n, D18n, D27, D27n } from "./numbers";
import { getCurrentBasket, getSharePricing, getBasketPortion } from "./utils";

/**
 * Get basket from trades
 *
 * @param supply {share} DTF supply
 * @param trades Trades
 * @param tokens Addresses of tokens in the basket
 * @param bals {tok} Current balances
 * @param decimals Decimals of each token
 * @param prices {USD/wholeTok} USD prices for each *whole* token
 * @returns basket D18{1} Resulting basket
 * @returns amountDeficit D18{1} Amount deficit of being able to achieve the targetBasket; should be 0 for a well-configured rebalance
 */
export const getBasket = (
  supply: bigint,
  trades: Trade[],
  tokens: string[],
  bals: bigint[],
  decimals: bigint[],
  prices: number[],
): [bigint[], bigint] => {
  // convert price number inputs to bigints

  console.log("--------------------------------------------------------------------------------");

  // D27{1} approx sum 1e27
  const currentBasket = getCurrentBasket(bals, decimals, prices);

  // D27{USD}, {USD/wholeShare}
  const [sharesValue, sharePrice] = getSharePricing(supply, bals, decimals, prices);

  // determine targetBasket from trades

  const targetBasket: bigint[] = [];
  let sum = 0n;

  for (let i = 0; i < tokens.length; i++) {
    targetBasket.push(0n);

    for (let j = 0; j < trades.length; j++) {
      const balBuy = bals[tokens.indexOf(trades[j].sell)];
      // TODO

      if (balBuy > 0n) {
        // D27{USD} = {buyTok} * D27{USD/buyTok}
        const buyValue = balBuy / prices[i];

        // D27{1} = D27{USD} * D27 / D27{USD}
        const basketPct = (buyValue * D27n) / sharesValue;

        if (basketPct > targetBasket[i]) {
          targetBasket[i] = basketPct;
        }
      }

      const balSell = bals[tokens.indexOf(trades[j].sell)];
      if (balSell > 0n) {
        // D27{USD} = {sellTok} * D27{USD/sellTok}
        const sellValue = balSell / prices[i];

        // D27{1} = D27{USD} * D27 / D27{USD}
        const basketPct = (sellValue * D27n) / sharesValue;

        if (basketPct > targetBasket[i]) {
          targetBasket[i] = basketPct;
        }
      }
    }

    sum += targetBasket[i];
  }

  if (sum != D18n) {
    console.log("sum", sum);
    console.log("targetBasket", targetBasket);
    throw new Error("targetBasket does not sum to 1e18");
  }

  // determine if we can reach the targetBasket
  // TODO

  for (let i = 0; i < trades.length; i++) {
    const sellIndex = tokens.indexOf(trades[i].sell);
    const buyIndex = tokens.indexOf(trades[i].buy);

    // // D27{sellTok/share} = {sellTok} * D27{USD/sellTok} / D27{USD}
    // const currentSell = (bals[sellIndex] * prices[sellIndex]) / sharesValue;

    // // D27{buyTok/share} = {buyTok} * D27{USD/buyTok} / D27{USD}
    // const currentBuy = (bals[buyIndex] * prices[buyIndex]) / sharesValue;

    // // D27{1} = D27{USD} * D27 / D27{USD}
    // const backingTraded = (maxTrade * D27n) / sharesValue;

    // console.log("backingTraded", backingTraded);
  }

  return [targetBasket, 0n];
};
