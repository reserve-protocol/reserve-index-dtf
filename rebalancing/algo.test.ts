import { describe, it } from "node:test";
import expect from "expect";

import { bn } from "./numbers";
import { getRebalance, Trade } from "./algo";

const D18: bigint = BigInt(1e18);

const assertApproxEq = (a: bigint, b: bigint, precision: bigint) => {
  const delta = a > b ? a - b : b - a;
  console.log("assertApproxEq", a, b);
  console.log("assertApproxEq", delta, (precision * b) / D18);
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
  const supply = bn("1e21"); // 1000 supply

  it("split: [100%, 0%, 0%] => [0%, 50%, 50%]", () => {
    const tokens = ["USDC", "DAI", "USDT"];
    const decimals = [bn("6"), bn("18"), bn("6")];
    const bals = [bn("1e9"), bn("0"), bn("0")];
    const targetBasket = [bn("0"), bn("0.5e18"), bn("0.5e18")];
    const prices = [1, 1, 1];
    const error = [0.01, 0.01, 0.01];
    const trades = getRebalance(supply, tokens, decimals, bals, targetBasket, prices, error);
    expect(trades.length).toBe(2);
    expectTradeApprox(trades[0], "USDC", "DAI", bn("0"), bn("5e26"), bn("1.01e39"), bn("0.99e39"));
    expectTradeApprox(trades[1], "USDC", "USDT", bn("0"), bn("5e14"), bn("1.01e27"), bn("0.99e27"));
  });
  it("join: [0%, 50%, 50%] => [100%, 0%, 0%]", () => {
    const tokens = ["USDC", "DAI", "USDT"];
    const decimals = [bn("6"), bn("18"), bn("6")];
    const bals = [bn("0"), bn("500e18"), bn("500e6")];
    const targetBasket = [bn("1e18"), bn("0"), bn("0")];
    const prices = [1, 1, 1];
    const error = [0.01, 0.01, 0.01];
    const trades = getRebalance(supply, tokens, decimals, bals, targetBasket, prices, error);
    expect(trades.length).toBe(2);
    expectTradeApprox(trades[0], "DAI", "USDC", bn("0"), bn("1e15"), bn("1.01e15"), bn("0.99e15"));
    expectTradeApprox(trades[1], "USDT", "USDC", bn("0"), bn("1e15"), bn("1.01e27"), bn("0.99e27"));
  });

  it("reweight: [25%, 75%] => [75%, 25%]", () => {
    const tokens = ["USDC", "DAI"];
    const decimals = [bn("6"), bn("18")];
    const bals = [bn("250e6"), bn("750e18")];
    const targetBasket = [bn("0.75e18"), bn("0.25e18")];
    const prices = [1, 1];
    const error = [0.01, 0.01];
    const trades = getRebalance(supply, tokens, decimals, bals, targetBasket, prices, error);
    expect(trades.length).toBe(1);
    expectTradeApprox(trades[0], "DAI", "USDC", bn("2.5e26"), bn("7.5e14"), bn("1.01e15"), bn("0.99e15"));
  });

  it("reweight (/w volatiles): [25%, 75%] => [75%, 25%]", () => {
    const tokens = ["USDC", "WETH"];
    const decimals = [bn("6"), bn("18")];
    const bals = [bn("250e6"), bn("0.25e18")];
    const targetBasket = [bn("0.75e18"), bn("0.25e18")];
    const prices = [1, 3000];
    const error = [0.01, 0.01];
    const trades = getRebalance(supply, tokens, decimals, bals, targetBasket, prices, error);
    expect(trades.length).toBe(1);
    expectTradeApprox(trades[0], "WETH", "USDC", bn("8.33e22"), bn("750e12"), bn("3.03e18"), bn("2.97e18"));
  });

  it("should produce trades across a variety of setups", () => {
    // shitty fuzz test, should do a better thing later

    // 1k runs
    for (let i = 0; i < 1000; i++) {
      const tokens = ["USDC", "DAI", "WETH", "WBTC"];
      const decimals = [bn("6"), bn("18"), bn("18"), bn("8")];
      const bals = tokens.map((_, i) => BigInt(Math.round(Math.random() * 1e36)));
      const prices = tokens.map((_, i) => Math.round(Math.random() * 1e54) / Number(10n ** decimals[i]));
      const targetBasketAsNum = tokens.map((_) => Math.random());
      const sumAsNum = targetBasketAsNum.reduce((a, b) => a + b);
      const targetBasket = targetBasketAsNum.map((a) => BigInt(Math.round((a * 10 ** 18) / sumAsNum)));
      const sum = targetBasket.reduce((a, b) => a + b);
      if (sum != 10n ** 18n) {
        targetBasket[0] += 10n ** 18n - sum;
      }

      const error = tokens.map((_) => Math.random() * 0.5);
      const trades = getRebalance(supply, tokens, decimals, bals, targetBasket, prices, error);
      expect(trades.length).toBeLessThanOrEqual(tokens.length - 1);
    }
  });
});
