import { describe, it } from "node:test";
import expect from "expect";

import { ZERO, bn } from "./numbers";
import { getRebalance, Trade } from "./algo";

const D18: bigint = bn("1e18");

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
  precision: bigint = bn("1e15"), // 0.1%
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
    const bals = [bn("1e12"), ZERO, ZERO];
    const targetBasket = [ZERO, bn("5e17"), bn("5e17")];
    const prices = [bn("1e30"), bn("1e18"), bn("1e30")];
    const error = [bn("1e16"), bn("1e16"), bn("1e16")];
    const trades = getRebalance(tokens, bals, targetBasket, prices, error);
    expect(trades.length).toBe(2);
    expectTradeApprox(trades[0], "USDC", "DAI", ZERO, bn("5e68"), bn("1.01e15"), bn("0.99e15"));
    expectTradeApprox(trades[1], "USDC", "USDT", ZERO, bn("5e56"), bn("1.01e27"), bn("0.99e27"));
  });
  it("join: [0%, 50%, 50%] => [100%, 0%, 0%]", () => {
    const tokens = ["USDC", "DAI", "USDT"];
    const bals = [ZERO, bn("5e20"), bn("5e8")];
    const targetBasket = [bn("1e18"), ZERO, ZERO];
    const prices = [bn("1e30"), bn("1e18"), bn("1e30")];
    const error = [bn("1e16"), bn("1e16"), bn("1e16")];
    const trades = getRebalance(tokens, bals, targetBasket, prices, error);
    expect(trades.length).toBe(2);
    expectTradeApprox(trades[0], "DAI", "USDC", ZERO, bn("1e54"), bn("1.01e39"), bn("0.99e39"));
    expectTradeApprox(trades[1], "USDT", "USDC", ZERO, bn("1e54"), bn("1.01e27"), bn("0.99e27"));
  });

  it("reweight: [25%, 75%] => [75%, 25%]", () => {
    const tokens = ["USDC", "DAI"];
    const bals = [bn("2.5e8"), bn("7.5e20")];
    const targetBasket = [bn("0.75e18"), bn("0.25e18")];
    const prices = [bn("1e30"), bn("1e18")];
    const error = [bn("1e16"), bn("1e16")];
    const trades = getRebalance(tokens, bals, targetBasket, prices, error);
    expect(trades.length).toBe(1);
    expectTradeApprox(trades[0], "DAI", "USDC", bn("2.5e65"), bn("7.5e53"), bn("1.01e39"), bn("0.99e39"));
  });

  it("reweight (/w volatiles): [25%, 75%] => [75%, 25%]", () => {
    const tokens = ["USDC", "WETH"];
    const bals = [bn("2.5e8"), bn("0.25e18")];
    const targetBasket = [bn("0.75e18"), bn("0.25e18")];
    const prices = [bn("1e30"), bn("3000e18")];
    const error = [bn("1e16"), bn("1e16")];
    const trades = getRebalance(tokens, bals, targetBasket, prices, error);
    expect(trades.length).toBe(1);
    expectTradeApprox(trades[0], "WETH", "USDC", bn("8.33e61"), bn("7.5e53"), bn("3.367e35"), bn("3.3e35"));
  });

  it("should not revert within range", () => {
    // shitty fuzz test, could do a better thing later

    // 10k runs
    for (let i = 0; i < 10000; i++) {
      const tokens = ["USDC", "DAI", "WETH"];
      const bals = tokens.map((_) => BigInt(Math.round(Math.random() * 1e36)));
      const prices = tokens.map((_) => BigInt(Math.round(Math.random() * 1e54)));
      let targetBasket = tokens.map((_) => BigInt(Math.round(Math.random() * 1e18)));
      let sum = targetBasket.reduce((a, b) => a + b);
      targetBasket = targetBasket.map((a) => (a * D18) / sum);
      sum = targetBasket.reduce((a, b) => a + b);
      if (sum != D18) {
        targetBasket[0] += D18 - sum;
      }

      const error = [bn("5e16"), bn("5e16"), bn("5e16")];
      getRebalance(tokens, bals, targetBasket, prices, error);
    }
  });
});
