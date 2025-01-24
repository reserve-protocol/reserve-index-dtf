import { describe, it } from "node:test";
import expect from "expect";

import { getCurrentBasket } from "./utils";
import { bn } from "./numbers";
import { makeTrade } from "./utils";
import { Trade } from "./types";
import { getBasket } from "./getBasket";

const D18: bigint = BigInt(1e18);
const precision: bigint = bn("1e15"); // should be pretty exact

const assertApproxEq = (a: bigint, b: bigint, precision: bigint) => {
  const delta = a > b ? a - b : b - a;
  console.log("assertApproxEq", a, b);
  console.log("assertApproxEq", delta, (precision * b) / D18);
  expect(delta).toBeLessThanOrEqual((precision * b) / D18);
};

describe("getBasket()", () => {
  const supply = bn("1e21"); // 1000 supply
  it("split: [100%, 0%, 0%] => [0%, 50%, 50%]", () => {
    const trades: Trade[] = [];
    trades.push(makeTrade("USDC", "DAI", bn("0"), bn("5e26"), bn("1.01e39"), bn("0.99e39")));
    trades.push(makeTrade("USDC", "USDT", bn("0"), bn("5e14"), bn("1.01e27"), bn("0.99e27")));

    const tokens = ["USDC", "DAI", "USDT"];
    const decimals = [bn("6"), bn("18"), bn("6")];
    const currentBasket = [bn("1e18"), bn("0"), bn("0")];
    const prices = [1, 1, 1];
    const targetBasket = getBasket(supply, trades, tokens, decimals, currentBasket, prices, 1);
    expect(targetBasket.length).toBe(3);
    assertApproxEq(targetBasket[0], bn("0"), precision);
    assertApproxEq(targetBasket[1], bn("0.5e18"), precision);
    assertApproxEq(targetBasket[2], bn("0.5e18"), precision);
  });
  it("join: [0%, 50%, 50%] => [100%, 0%, 0%]", () => {
    const trades: Trade[] = [];
    trades.push(makeTrade("USDT", "USDC", bn("0"), bn("1e15"), bn("1.01e27"), bn("0.99e27")));
    trades.push(makeTrade("DAI", "USDC", bn("0"), bn("1e15"), bn("1.01e15"), bn("0.99e15")));

    const tokens = ["USDC", "DAI", "USDT"];
    const decimals = [bn("6"), bn("18"), bn("6")];
    const currentBasket = [bn("0"), bn("0.5e18"), bn("0.5e18")];
    const prices = [1, 1, 1];
    const targetBasket = getBasket(supply, trades, tokens, decimals, currentBasket, prices, 1);
    expect(targetBasket.length).toBe(3);
    assertApproxEq(targetBasket[0], bn("1e18"), precision);
    assertApproxEq(targetBasket[1], bn("0"), precision);
    assertApproxEq(targetBasket[2], bn("0"), precision);
  });

  it("reweight: [25%, 75%] => [75%, 25%]", () => {
    const trades: Trade[] = [];
    trades.push(makeTrade("DAI", "USDC", bn("2.5e26"), bn("7.5e14"), bn("1.01e15"), bn("0.99e15")));

    const tokens = ["USDC", "DAI"];
    const decimals = [bn("6"), bn("18")];
    const currentBasket = [bn("0.25e18"), bn("0.75e18")];
    const prices = [1, 1];
    const targetBasket = getBasket(supply, trades, tokens, decimals, currentBasket, prices, 1);
    expect(targetBasket.length).toBe(2);
    assertApproxEq(targetBasket[0], bn("0.75e18"), precision);
    assertApproxEq(targetBasket[1], bn("0.25e18"), precision);
  });

  it("reweight (/w volatiles): [25%, 75%] => [75%, 25%]", () => {
    const trades: Trade[] = [];
    trades.push(makeTrade("WETH", "USDC", bn("8.33e22"), bn("750e12"), bn("3.03e18"), bn("2.97e18")));

    const tokens = ["USDC", "WETH"];
    const decimals = [bn("6"), bn("18")];
    const currentBasket = [bn("0.25e18"), bn("0.75e18")];
    const prices = [1, 3000];
    const targetBasket = getBasket(supply, trades, tokens, decimals, currentBasket, prices, 1);
    expect(targetBasket.length).toBe(2);
    assertApproxEq(targetBasket[0], bn("0.75e18"), precision);
    assertApproxEq(targetBasket[1], bn("0.25e18"), precision);
  });

  it("should produce trades across a variety of setups", () => {
    // shitty fuzz test, should do a better thing later

    // 1k runs
    for (let i = 0; i < 1000; i++) {
      const trades: Trade[] = [];

      const tokens = ["USDC", "DAI", "WETH", "WBTC"];
      const decimals = [bn("6"), bn("18"), bn("18"), bn("8")];
      const bals = tokens.map((_, i) => BigInt(Math.round(Math.random() * 1e36)));
      const prices = tokens.map((_, i) => Math.round(Math.random() * 1e54) / Number(10n ** decimals[i]));
      const currentBasket = getCurrentBasket(bals, decimals, prices);
      const sellIndex = Math.floor(Math.random() * tokens.length);
      const buyIndex = Math.floor(Math.random() * tokens.length);
      let price = BigInt(Math.round((prices[sellIndex] * 1e27) / prices[buyIndex]));
      price = (price * 10n ** decimals[buyIndex]) / 10n ** decimals[sellIndex];

      const startPrice = (price * 10n) / 9n;
      const endPrice = (price * 9n) / 10n;

      trades.push(makeTrade(tokens[sellIndex], tokens[buyIndex], bn("0"), bn("1e54"), startPrice, endPrice));

      const targetBasket = getBasket(supply, trades, tokens, decimals, currentBasket, prices, 1);
      expect(targetBasket.length).toBe(tokens.length);
    }
  });
});
