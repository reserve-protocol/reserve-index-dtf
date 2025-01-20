import { describe, it } from "node:test";
import expect from "expect";

import { bn } from "./numbers";
import { makeTrade } from "./utils";
import { Trade } from "./types";
import { getBasket } from "./getBasket";

const D18: bigint = BigInt(1e18);

const assertApproxEq = (a: bigint, b: bigint, precision: bigint) => {
  const delta = a > b ? a - b : b - a;
  console.log("assertApproxEq", a, b);
  console.log("assertApproxEq", delta, (precision * b) / D18);
  expect(delta).toBeLessThanOrEqual((precision * b) / D18);
};

describe("getBasket()", () => {
  const supply = bn("1e21"); // 1000 supply

  //   it("split: [100%, 0%, 0%] => [0%, 50%, 50%]", () => {
  //     const trades: Trade[] = [];
  //     trades.push(makeTrade("USDC", "DAI", bn("0"), bn("5e26"), bn("1.01e39"), bn("0.99e39")));
  //     trades.push(makeTrade("USDC", "USDT", bn("0"), bn("5e14"), bn("1.01e27"), bn("0.99e27")));
  //     const tokens = ["USDC", "DAI", "USDT"];
  //     const decimals = [bn("6"), bn("18"), bn("6")];
  //     const bals = [bn("1e9"), bn("0"), bn("0")];
  //     const prices = [1, 1, 1];
  //     const [targetBasket, deficit] = getBasket(supply, trades, tokens, bals, decimals, prices);
  //     console.log(deficit, targetBasket);
  //     expect(targetBasket).toBe(true);
  //     expect(targetBasket.length).toBe(3);
  //     expect(targetBasket[0]).toBe(bn("0"));
  //     expect(targetBasket[1]).toBe(bn("0.5e18"));
  //     expect(targetBasket[2]).toBe(bn("0.5e18"));
  //   });
});
