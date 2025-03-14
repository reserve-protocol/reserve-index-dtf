import { describe, it } from "node:test";
import expect from "expect";

import { bn } from "./numbers";
import { getDustLimit } from "./utils";

describe("getDustLimit()", () => {
  it("should get dust limit correctly", () => {
    expect(getDustLimit(bn("18"), 1, 1)).toBe(bn("1e21"));
    expect(getDustLimit(bn("6"), 1, 1)).toBe(bn("1e9"));
    expect(getDustLimit(bn("8"), 1, 1)).toBe(bn("1e11"));
    expect(getDustLimit(bn("21"), 1, 1)).toBe(bn("1e24"));
    expect(getDustLimit(bn("18"), 1e-3, 1)).toBe(bn("1e24"));
    expect(getDustLimit(bn("6"), 1e-3, 1)).toBe(bn("1e12"));
    expect(getDustLimit(bn("8"), 1e-3, 1)).toBe(bn("1e14"));
    expect(getDustLimit(bn("21"), 1e-3, 1)).toBe(bn("1e27"));
    expect(getDustLimit(bn("18"), 1e3, 1)).toBe(bn("1e18"));
    expect(getDustLimit(bn("6"), 1e3, 1)).toBe(bn("1e6"));
    expect(getDustLimit(bn("8"), 1e3, 1)).toBe(bn("1e8"));
    expect(getDustLimit(bn("21"), 1e3, 1)).toBe(bn("1e21"));

    expect(getDustLimit(bn("18"), 1, 1e-3)).toBe(bn("1e18"));
    expect(getDustLimit(bn("6"), 1, 1e-3)).toBe(bn("1e6"));
    expect(getDustLimit(bn("8"), 1, 1e-3)).toBe(bn("1e8"));
    expect(getDustLimit(bn("21"), 1, 1e-3)).toBe(bn("1e21"));
    expect(getDustLimit(bn("18"), 1, 1e3)).toBe(bn("1e24"));
    expect(getDustLimit(bn("6"), 1, 1e3)).toBe(bn("1e12"));
    expect(getDustLimit(bn("8"), 1, 1e3)).toBe(bn("1e14"));
    expect(getDustLimit(bn("21"), 1, 1e3)).toBe(bn("1e27"));
  });
});
