import { D9n, D27, D27n } from "./numbers";

/**
 * @param limit D27{tok/share} Range.buyLimit or Range.sellLimit
 * @param decimals Decimals of the token
 * @param _price {USD/wholeTok} Price of the *whole* token
 * @param _sharePrice {USD/wholeShare} Price of the *whole* share
 * @return {1} % of the basket given by the limit
 */
export const getBasketPortion = (limit: bigint, decimals: bigint, _price: number, _sharePrice: number): number => {
  // D27{USD/share} = {USD/wholeShare} * D27 / {share/wholeShare}
  const sharePrice = BigInt(Math.round(_sharePrice * D27)) / 10n ** 18n;

  // D27{USD/tok} = {USD/wholeTok} * D27 / {tok/wholeTok}
  const price = BigInt(Math.round(_price * D27)) / 10n ** decimals;

  // D27{1} = D27{tok/share} * D27{USD/tok} / D27{USD/share}
  const portion = (limit * price) / sharePrice;

  return Number(portion) / D27;
};

/**
 * @param bals {tok} Current balances
 * @param decimals Decimals of each token
 * @param prices {USD/wholeTok} USD prices for each *whole* token
 * @returns D27{1} Current basket, total will be around 1e27 but not exactly
 */
export const getCurrentBasket = (bals: bigint[], decimals: bigint[], _prices: number[]): bigint[] => {
  // D27{USD/tok} = {USD/wholeTok} * D27 / {tok/wholeTok}
  const prices = _prices.map((a, i) => BigInt(Math.round(a * D27)) / 10n ** decimals[i]);

  // D27{USD} = {tok} * D27{USD/tok}
  const values = bals.map((bal, i) => bal * prices[i]);

  // D27{USD}
  const total = values.reduce((a, b) => a + b);

  // D27{1} = D27{USD} * D27/ D27{USD}
  return values.map((amt, i) => (amt * D27n) / total);
};

/**
 * @param supply {share} DTF supply
 * @param bals {tok} Current balances
 * @param decimals Decimals of each token
 * @param prices {USD/wholeTok} USD prices for each *whole* token
 * @returns sharesValue D27{USD} Estimated USD value of all the shares
 * @returns sharePrice {USD/wholeShare} Estimated USD value of each *whole* share
 */
export const getSharePricing = (
  supply: bigint,
  bals: bigint[],
  decimals: bigint[],
  _prices: number[],
): [bigint, number] => {
  // D27{USD/tok} = {USD/wholeTok} * D27 / {tok/wholeTok}
  const prices = _prices.map((a, i) => BigInt(Math.round((a * D27) / 10 ** Number(decimals[i]))));

  // D27{USD} = {tok} * D27{USD/tok}
  const values = bals.map((bal, i) => bal * prices[i]);
  const total = values.reduce((a, b) => a + b);

  // {USD/wholeShare} = D27{USD} / (D18{wholeShare} * D9)
  const per = Number(total) / Number(supply * D9n);

  return [total, per];
};

export const makeTrade = (
  sell: string,
  buy: string,
  sellLimit: bigint,
  buyLimit: bigint,
  startPrice: bigint,
  endPrice: bigint,
) => {
  return {
    sell: sell,
    buy: buy,
    sellLimit: {
      spot: sellLimit,
      low: sellLimit,
      high: sellLimit,
    },
    buyLimit: {
      spot: buyLimit,
      low: buyLimit,
      high: buyLimit,
    },
    prices: {
      start: startPrice,
      end: endPrice,
    },
  };
};
