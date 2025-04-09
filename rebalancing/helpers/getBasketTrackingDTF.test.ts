import { describe, it } from "node:test";
import expect from "expect";

import { bn } from "../numbers";
import { makeAuction } from "../utils";
import { Auction } from "../types";
import { getBasketTrackingDTF } from "./getBasketTrackingDTF";

const D18: bigint = bn("1e18");
const precision: bigint = bn("1e15"); // should be pretty exact

const assertApproxEq = (a: bigint, b: bigint, precision: bigint) => {
  const delta = a > b ? a - b : b - a;
  console.log("assertApproxEq", a, b);
  expect(delta).toBeLessThanOrEqual((precision * b) / D18);
};

describe("getBasketTrackingDTF()", () => {
  it("split: [100%, 0%, 0%] => [0%, 50%, 50%] auctions only", () => {
    const auctions: Auction[] = [];
    auctions.push(makeAuction("USDC", "DAI", bn("0"), bn("5e26"), bn("1.01e39"), bn("0.99e39")));
    auctions.push(makeAuction("USDC", "USDT", bn("0"), bn("5e14"), bn("1.01e27"), bn("0.99e27")));

    const tokens = ["USDC", "DAI", "USDT"];
    const decimals = [bn("6"), bn("18"), bn("6")];
    const amounts = [bn("0"), bn("0"), bn("0")]; // should be unused since all tokens are present in auctions
    const prices = [1, 1, 1];
    const targetBasket = getBasketTrackingDTF(auctions, tokens, amounts, decimals, prices);
    expect(targetBasket.length).toBe(3);
    assertApproxEq(targetBasket[0], bn("0"), precision);
    assertApproxEq(targetBasket[1], bn("0.5e18"), precision);
    assertApproxEq(targetBasket[2], bn("0.5e18"), precision);
  });

  it("join: [0%, 50%, 50%] => [100%, 0%, 0%] auctions only", () => {
    const auctions: Auction[] = [];
    auctions.push(makeAuction("USDT", "USDC", bn("0"), bn("1e15"), bn("1.01e27"), bn("0.99e27")));
    auctions.push(makeAuction("DAI", "USDC", bn("0"), bn("1e15"), bn("1.01e15"), bn("0.99e15")));

    const tokens = ["USDC", "DAI", "USDT"];
    const decimals = [bn("6"), bn("18"), bn("6")];
    const amounts = [bn("0"), bn("0"), bn("0")]; // should be unused since all tokens are present in auctions
    const prices = [1, 1, 1];
    const targetBasket = getBasketTrackingDTF(auctions, tokens, amounts, decimals, prices);
    expect(targetBasket.length).toBe(3);
    assertApproxEq(targetBasket[0], bn("1e18"), precision);
    assertApproxEq(targetBasket[1], bn("0"), precision);
    assertApproxEq(targetBasket[2], bn("0"), precision);
  });

  it("reweight: [25%, 75%] => [75%, 25%] auctions + amounts", () => {
    const auctions: Auction[] = [];
    auctions.push(makeAuction("DAI", "USDC", bn("2.5e26"), bn("7.5e14"), bn("1.01e15"), bn("0.99e15")));

    const tokens = ["USDC", "DAI", "USDT"];
    const decimals = [bn("6"), bn("18"), bn("6")];
    const amounts = [bn("0"), bn("0"), bn("1e6")]; // USDT value should be used
    const prices = [1, 1, 1];
    const targetBasket = getBasketTrackingDTF(auctions, tokens, amounts, decimals, prices);
    expect(targetBasket.length).toBe(3);
    assertApproxEq(targetBasket[0], bn("0.75e18") / 2n, precision);
    assertApproxEq(targetBasket[1], bn("0.25e18") / 2n, precision);
    assertApproxEq(targetBasket[2], bn("1e18") / 2n, precision);
  });

  it("reweight (/w volatiles): [25%, 75%] => [75%, 25%] auctions only", () => {
    const auctions: Auction[] = [];
    auctions.push(makeAuction("WETH", "USDC", bn("8.33e22"), bn("750e12"), bn("3.03e18"), bn("2.97e18")));

    const tokens = ["USDC", "WETH"];
    const decimals = [bn("6"), bn("18")];
    const amounts = [bn("0"), bn("0")]; // should be unused since all tokens are present in auctions
    const prices = [1, 3000];
    const targetBasket = getBasketTrackingDTF(auctions, tokens, amounts, decimals, prices);
    expect(targetBasket.length).toBe(2);
    assertApproxEq(targetBasket[0], bn("0.75e18"), precision);
    assertApproxEq(targetBasket[1], bn("0.25e18"), precision);
  });
});
