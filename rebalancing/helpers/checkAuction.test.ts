import { describe, it } from "node:test";
import expect from "expect";

import { bn } from "../numbers";
import { checkAuction } from "./checkAuction";

describe("checkAuction()", () => {
  const callCheckAuction = (startPrice: bigint, endPrice: bigint): boolean => {
    const trade = {
      sell: "USDC",
      buy: "DAI",
      sellLimit: {
        spot: bn("0"),
        low: bn("0"),
        high: bn("0"),
      },
      buyLimit: {
        spot: bn("1e54"),
        low: bn("1e54"),
        high: bn("1e54"),
      },
      prices: {
        start: startPrice,
        end: endPrice,
      },
    };
    const tokens = ["USDC", "DAI"];
    const prices = [1, 1];
    const decimals = [6n, 18n];
    return checkAuction(trade, tokens, decimals, prices);
  };

  it("should handle boundary cases", () => {
    expect(callCheckAuction(bn("1e39"), bn("1e39"))).toBe(true);
    expect(callCheckAuction(bn("1e39"), bn("0"))).toBe(true);
    expect(callCheckAuction(bn("1e54"), bn("1e39"))).toBe(true);
    expect(callCheckAuction(bn("1e40"), bn("1e38"))).toBe(true);
    expect(callCheckAuction(bn("1e39") + 1n, bn("1e38"))).toBe(true);
    expect(callCheckAuction(bn("1e39"), bn("1e38") - 1n)).toBe(true);

    expect(callCheckAuction(bn("1e39") - 1n, bn("1e39"))).toBe(false);
    expect(callCheckAuction(bn("1e39"), bn("1e39") + 1n)).toBe(false);
    expect(callCheckAuction(bn("1e38"), bn("1e38"))).toBe(false);
    expect(callCheckAuction(bn("1e27"), bn("1e27"))).toBe(false);
    expect(callCheckAuction(bn("1e15"), bn("1e15"))).toBe(false);
  });
});
