import { describe, it } from "node:test";
import expect from "expect";

import { getCurrentBasket, getSharePricing } from "../utils";
import { bn } from "../numbers";
import { Auction } from "../types";
import { getAuctions } from "./getAuctions";

const D18: bigint = bn("1e18");

const assertApproxEq = (a: bigint, b: bigint, precision: bigint) => {
  const delta = a > b ? a - b : b - a;
  console.log("assertApproxEq", a, b);
  expect(delta).toBeLessThanOrEqual((precision * b) / D18);
};

const expectAuctionApprox = (
  auction: Auction,
  sell: string,
  buy: string,
  sellLimit: bigint,
  buyLimit: bigint,
  startPrice: bigint,
  endPrice: bigint,
  precision: bigint = bn("1e15"), // 0.1%
) => {
  expect(auction.sell).toBe(sell);
  expect(auction.buy).toBe(buy);

  assertApproxEq(auction.sellLimit.spot, sellLimit, precision);
  assertApproxEq(auction.buyLimit.spot, buyLimit, precision);
  assertApproxEq(auction.prices.start, startPrice, precision);
  assertApproxEq(auction.prices.end, endPrice, precision);
};

describe("getAuctions()", () => {
  const supply = bn("1e21"); // 1000 supply

  it("split: [100%, 0%, 0%] => [0%, 50%, 50%]", () => {
    const tokens = ["USDC", "DAI", "USDT"];
    const decimals = [bn("6"), bn("18"), bn("6")];
    const currentBasket = [bn("1e18"), bn("0"), bn("0")];
    const targetBasket = [bn("0"), bn("0.5e18"), bn("0.5e18")];
    const prices = [1, 1, 1];
    const error = [0.01, 0.01, 0.01];
    const auctions = getAuctions(supply, tokens, decimals, currentBasket, targetBasket, prices, error, 1);
    expect(auctions.length).toBe(2);
    expectAuctionApprox(auctions[0], "USDC", "DAI", bn("0"), bn("5e26"), bn("1.01e39"), bn("0.99e39"));
    expectAuctionApprox(auctions[1], "USDC", "USDT", bn("0"), bn("5e14"), bn("1.01e27"), bn("0.99e27"));
  });
  it("join: [0%, 50%, 50%] => [100%, 0%, 0%]", () => {
    const tokens = ["USDC", "DAI", "USDT"];
    const decimals = [bn("6"), bn("18"), bn("6")];
    const currentBasket = [bn("0"), bn("0.5e18"), bn("0.5e18")];
    const targetBasket = [bn("1e18"), bn("0"), bn("0")];
    const prices = [1, 1, 1];
    const error = [0.01, 0.01, 0.01];
    const auctions = getAuctions(supply, tokens, decimals, currentBasket, targetBasket, prices, error, 1);
    expect(auctions.length).toBe(2);
    expectAuctionApprox(auctions[0], "DAI", "USDC", bn("0"), bn("1e15"), bn("1.01e15"), bn("0.99e15"));
    expectAuctionApprox(auctions[1], "USDT", "USDC", bn("0"), bn("1e15"), bn("1.01e27"), bn("0.99e27"));
  });

  it("reweight: [25%, 75%] => [75%, 25%]", () => {
    const tokens = ["USDC", "DAI"];
    const decimals = [bn("6"), bn("18")];
    const currentBasket = [bn("0.25e18"), bn("0.75e18")];
    const targetBasket = [bn("0.75e18"), bn("0.25e18")];
    const prices = [1, 1];
    const error = [0.01, 0.01];
    const auctions = getAuctions(supply, tokens, decimals, currentBasket, targetBasket, prices, error, 1);
    expect(auctions.length).toBe(1);
    expectAuctionApprox(auctions[0], "DAI", "USDC", bn("2.5e26"), bn("7.5e14"), bn("1.01e15"), bn("0.99e15"));
  });

  it("reweight (/w volatiles): [25%, 75%] => [75%, 25%]", () => {
    const tokens = ["USDC", "WETH"];
    const decimals = [bn("6"), bn("18")];
    const currentBasket = [bn("0.25e18"), bn("0.75e18")];
    const targetBasket = [bn("0.75e18"), bn("0.25e18")];
    const prices = [1, 3000];
    const error = [0.01, 0.01];
    const auctions = getAuctions(supply, tokens, decimals, currentBasket, targetBasket, prices, error, 1);
    expect(auctions.length).toBe(1);
    expectAuctionApprox(auctions[0], "WETH", "USDC", bn("8.33e22"), bn("750e12"), bn("3.03e18"), bn("2.97e18"));
  });

  it("should handle defer to curator case", () => {
    const tokens = ["USDC", "DAI"];
    const decimals = [bn("6"), bn("18")];
    const currentBasket = [bn("1e18"), bn("0")];
    const targetBasket = [bn("0.5e18"), bn("0.5e18")];
    const prices = [1, 1];
    const error = [1, 1];
    const auctions = getAuctions(supply, tokens, decimals, currentBasket, targetBasket, prices, error, 1);
    expect(auctions.length).toBe(1);
    expectAuctionApprox(auctions[0], "USDC", "DAI", bn("5e14"), bn("5e26"), bn("0"), bn("0"));
    expect(auctions[0].sellLimit.low).toBe(0n);
    expect(auctions[0].sellLimit.high).toBe(bn("1e54"));
    expect(auctions[0].buyLimit.low).toBe(1n);
    expect(auctions[0].buyLimit.high).toBe(bn("1e54"));
  });
});
