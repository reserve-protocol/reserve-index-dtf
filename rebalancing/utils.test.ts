import { describe, it } from "node:test";
import expect from "expect";

import { bn } from "./numbers";
import { getDustAmount, toDecimals } from "./utils";

describe("getDustAmount()", () => {
  it("should get dust amount correctly", () => {
    expect(getDustAmount(bn("18"), 1, 1)).toBe(bn("1e21"));
    expect(getDustAmount(bn("6"), 1, 1)).toBe(bn("1e9"));
    expect(getDustAmount(bn("8"), 1, 1)).toBe(bn("1e11"));
    expect(getDustAmount(bn("21"), 1, 1)).toBe(bn("1e24"));
    expect(getDustAmount(bn("18"), 1e-3, 1)).toBe(bn("1e24"));
    expect(getDustAmount(bn("6"), 1e-3, 1)).toBe(bn("1e12"));
    expect(getDustAmount(bn("8"), 1e-3, 1)).toBe(bn("1e14"));
    expect(getDustAmount(bn("21"), 1e-3, 1)).toBe(bn("1e27"));
    expect(getDustAmount(bn("18"), 1e3, 1)).toBe(bn("1e18"));
    expect(getDustAmount(bn("6"), 1e3, 1)).toBe(bn("1e6"));
    expect(getDustAmount(bn("8"), 1e3, 1)).toBe(bn("1e8"));
    expect(getDustAmount(bn("21"), 1e3, 1)).toBe(bn("1e21"));

    expect(getDustAmount(bn("18"), 1, 1e-3)).toBe(bn("1e18"));
    expect(getDustAmount(bn("6"), 1, 1e-3)).toBe(bn("1e6"));
    expect(getDustAmount(bn("8"), 1, 1e-3)).toBe(bn("1e8"));
    expect(getDustAmount(bn("21"), 1, 1e-3)).toBe(bn("1e21"));
    expect(getDustAmount(bn("18"), 1, 1e3)).toBe(bn("1e24"));
    expect(getDustAmount(bn("6"), 1, 1e3)).toBe(bn("1e12"));
    expect(getDustAmount(bn("8"), 1, 1e3)).toBe(bn("1e14"));
    expect(getDustAmount(bn("21"), 1, 1e3)).toBe(bn("1e27"));
  });
});

describe("toDecimals()", () => {
  it("should vomit on zero", () => {
    expect(() => toDecimals([0.000000000001, 1, 2])).not.toThrow();
    expect(() => toDecimals([0, 1, 2])).toThrowError("a price is zero");
  });
});
