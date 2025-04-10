import { describe, it } from "node:test";
import expect from "expect";

import { makeAuction } from "../utils";
import { bn } from "../numbers";
import { openAuction } from "./openAuction";

const D18: bigint = bn("1e18");

const assertApproxEq = (a: bigint, b: bigint, precision: bigint) => {
  const delta = a > b ? a - b : b - a;
  console.log("assertApproxEq", a, b);
  expect(delta).toBeLessThanOrEqual((precision * b) / D18);
};

const checkResult = (
  result: bigint[],
  expectedResult: bigint[],
  precision: bigint = bn("1e14"), // 0.01%
) => {
  expect(result.length).toBe(expectedResult.length);
  for (let i = 0; i < result.length; i++) {
    assertApproxEq(result[i], expectedResult[i], precision);
  }
};

describe("openAuction()", () => {
  const supply = bn("1e21"); // 1000 supply

  it("target: [0%, 100%]", () => {
    const initialPrices = { start: bn("1.02e39"), end: bn("0.98e39") };
    const auction = makeAuction("USDC", "DAI", bn("0"), bn("1e27"), bn("0"), bn("0"), bn("1e16"));
    const tokens = ["USDC", "DAI"];
    const decimals = [bn("6"), bn("18")];
    const targetBasket = [bn("0"), bn("1e18")];
    const prices = [1, 1];
    const error = [0.01, 0.01];

    const result = openAuction(auction, initialPrices, supply, tokens, decimals, targetBasket, prices, error, 1, true);
    // should target +inf buy when ejectFully
    const expectedResult = [bn("0"), bn("1e54"), bn("1.02e39"), bn("0.99e39")];
    checkResult(result, expectedResult);
    expect(result[1]).toBeGreaterThan(bn("1e27"));
  });

  it("target: [0%, 100%] -- variant 2", () => {
    const initialPrices = { start: bn("1.02e39"), end: bn("0.98e39") };
    const auction = makeAuction("USDC", "DAI", bn("0"), bn("1e27"), bn("0"), bn("0"), bn("1e16"));
    const tokens = ["USDC", "DAI"];
    const decimals = [bn("6"), bn("18")];
    const targetBasket = [bn("0"), bn("1e18")];
    const prices = [1, 1];
    const error = [0.01, 0.01];

    const result = openAuction(auction, initialPrices, supply, tokens, decimals, targetBasket, prices, error, 1, false);
    // should target +inf buy when !ejectFully
    const expectedResult = [bn("0"), bn("1e27"), bn("1.02e39"), bn("0.99e39")];
    checkResult(result, expectedResult);
  });

  it("target: [50%, 50%]", () => {
    const initialPrices = { start: bn("1.02e39"), end: bn("0.98e39") };
    const auction = makeAuction("USDC", "DAI", bn("5e14"), bn("5e26"), bn("0"), bn("0"), bn("1e16"));
    const tokens = ["USDC", "DAI"];
    const decimals = [bn("6"), bn("18")];
    const targetBasket = [bn("0.5e18"), bn("0.5e18")];
    const prices = [1, 1];
    const error = [0.01, 0.01];

    const result = openAuction(auction, initialPrices, supply, tokens, decimals, targetBasket, prices, error, 1);
    const expectedResult = [bn("5e14"), bn("5e26"), bn("1.02e39"), bn("0.99e39")];
    checkResult(result, expectedResult);
  });

  it("target (/w volatiles): [50%, 50%]", () => {
    const initialPrices = { start: bn("3.04e18"), end: bn("2.96e18") };
    const auction = makeAuction("WETH", "USDC", bn("1.666e23"), bn("5e14"), bn("0"), bn("0"), bn("1e16"));
    const tokens = ["WETH", "USDC"];
    const decimals = [bn("18"), bn("6")];
    const targetBasket = [bn("0.5e18"), bn("0.5e18")];
    const prices = [3000, 1];
    const error = [0.01, 0.01];

    const result = openAuction(auction, initialPrices, supply, tokens, decimals, targetBasket, prices, error, 1);
    const expectedResult = [bn("1.6666e23"), bn("5e14"), bn("3.04e18"), bn("2.97e18")];
    checkResult(result, expectedResult);
  });
});
