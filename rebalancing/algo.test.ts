import { describe, it } from "node:test";
import expect from "expect";

import { bn } from "./numbers";
import { D27, getRebalance, Trade } from "./algo";

const D18: bigint = BigInt(1e18);

const assertApproxEq = (a: bigint, b: bigint, precision: bigint) => {
  const delta = a > b ? a - b : b - a;
  console.log(delta, (precision * b) / D18);
  expect(delta).toBeLessThanOrEqual((precision * b) / D18);
};

const expectTradeApprox = (
  trade: Trade,
  sell: string,
  buy: string,
  sellLimit: bigint,
  buyLimit: bigint,
  startPrice: bigint,
  endPrice: bigint,
  precision: bigint = BigInt(1e15), // 0.1%
) => {
  expect(trade.sell).toBe(sell);
  expect(trade.buy).toBe(buy);

  assertApproxEq(trade.sellLimit, sellLimit, precision);
  assertApproxEq(trade.buyLimit, buyLimit, precision);
  assertApproxEq(trade.startPrice, startPrice, precision);
  assertApproxEq(trade.endPrice, endPrice, precision);
};

describe("getRebalance()", () => {
  it("split: [100%, 0%, 0%] => [0%, 50%, 50%]", () => {
    const tokens = ["USDC", "DAI", "USDT"];
    const bals = [BigInt(1e12), BigInt(0), BigInt(0)];
    const targetBasket = [0, 0.5, 0.5];
    const prices = [1e-6, 1e-18, 1e-6];
    const error = [0.01, 0.01, 0.01];
    const trades = getRebalance(tokens, bals, targetBasket, prices, error);
    expect(trades.length).toBe(2);
    expectTradeApprox(trades[0], "USDC", "DAI", bn("0"), bn("5e68"), bn("1.01e15"), bn("0.99e15"));
    expectTradeApprox(trades[1], "USDC", "USDT", bn("0"), bn("5e56"), bn("1.01e27"), bn("0.99e27"));
  });
  it("join: [0%, 50%, 50%] => [100%, 0%, 0%]", () => {
    const tokens = ["USDC", "DAI", "USDT"];
    const bals = [BigInt(0), BigInt(5e20), BigInt(5e8)];
    const targetBasket = [1, 0, 0];
    const prices = [1e-6, 1e-18, 1e-6];
    const error = [0.01, 0.01, 0.01];
    const trades = getRebalance(tokens, bals, targetBasket, prices, error);
    expect(trades.length).toBe(2);
    expectTradeApprox(trades[0], "DAI", "USDC", bn("0"), bn("1e54"), bn("1.01e39"), bn("0.99e39"));
    expectTradeApprox(trades[1], "USDT", "USDC", bn("0"), bn("1e54"), bn("1.01e27"), bn("0.99e27"));
  });

  it("reweight: [25%, 75%] => [75%, 25%]", () => {
    const tokens = ["USDC", "DAI"];
    const bals = [BigInt(2.5e8), BigInt(7.5e20)];
    const targetBasket = [0.75, 0.25];
    const prices = [1e-6, 1e-18];
    const error = [0.01, 0.01];
    const trades = getRebalance(tokens, bals, targetBasket, prices, error);
    expect(trades.length).toBe(1);
    expectTradeApprox(trades[0], "DAI", "USDC", bn("2.5e65"), bn("7.5e53"), bn("1.01e39"), bn("0.99e39"));
  });

  it("reweight (/w volatiles): [25%, 75%] => [75%, 25%]", () => {
    const tokens = ["USDC", "WETH"];
    const bals = [BigInt(2.5e8), BigInt(0.25e18)];
    const targetBasket = [0.75, 0.25];
    const prices = [1e-6, 3e-15];
    const error = [0.01, 0.01];
    const trades = getRebalance(tokens, bals, targetBasket, prices, error);
    expect(trades.length).toBe(1);
    expectTradeApprox(trades[0], "WETH", "USDC", bn("8.33e61"), bn("7.5e53"), bn("3.367e35"), bn("3.3e35"));
  });

  it("should produce trades across a variety of setups", () => {
    // shitty fuzz test, should do a better thing later

    // 1k runs
    for (let i = 0; i < 1000; i++) {
      const tokens = ["USDC", "DAI", "WETH", "WBTC"];
      const bals = tokens.map((_) => BigInt(Math.round(Math.random() * 1e36)));
      const prices = tokens.map((_) => Math.random() * 1e54);
      let targetBasket = tokens.map((_) => Math.random() * 1);
      let sum = targetBasket.reduce((a, b) => a + b);
      targetBasket = targetBasket.map((a) => a / sum);
      sum = targetBasket.reduce((a, b) => a + b);
      if (sum != 1) {
        targetBasket[0] += 1 - sum;
      }

      const error = [5e16, 5e16, 5e16, 5e16];
      const trades = getRebalance(tokens, bals, targetBasket, prices, error);
      expect(trades.length).toBeLessThanOrEqual(tokens.length - 1);
    }
  });
});
