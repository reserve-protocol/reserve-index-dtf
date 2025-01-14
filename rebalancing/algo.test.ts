import { describe, it } from "node:test";
import expect from "expect";

import { getRebalance, Trade } from "./algo";

const ZERO = BigInt(0);

const bn = (base: number, exp: number): bigint => {
  return BigInt(base.toString() + "0".repeat(exp));
};

const D18: bigint = bn(1, 18);

const shares: bigint = bn(1, 27);

const assertApproxEq = (a: bigint, b: bigint, precision: bigint) => {
  console.log("a", a);
  console.log("b", b);
  console.log("precision", precision);
  const delta = a > b ? a - b : b - a;
  expect(delta).toBeLessThanOrEqual((precision * a) / D18);
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
  it("[100%, 0%, 0%] => [0%, 50%, 50%]", () => {
    const tokens = ["USDC", "DAI", "USDT"];
    const bals = [bn(1, 21), ZERO, ZERO];
    const targetBasket = [ZERO, bn(5, 17), bn(5, 17)];
    const prices = [bn(1, 6), bn(1, 18), bn(1, 6)];
    const error = [bn(1, 16), bn(1, 16), bn(1, 16)];

    const trades = getRebalance(shares, tokens, bals, targetBasket, prices, error);
    expect(trades.length).toBe(2);
    expectTradeApprox(trades[0], "USDC", "DAI", ZERO, bn(5, 53), bn(101, 37), bn(99, 37));
    expectTradeApprox(trades[1], "USDC", "USDT", ZERO, bn(5, 65), bn(101, 25), bn(99, 25));
  });
});
