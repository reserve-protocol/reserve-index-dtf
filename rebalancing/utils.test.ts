import { describe, it } from "node:test";
import expect from "expect";

import { toDecimals } from "./utils";

describe("toDecimals()", () => {
  it("should vomit on zero", () => {
    expect(() => toDecimals([0.000000000001, 1, 2])).not.toThrow();
    expect(() => toDecimals([0, 1, 2])).toThrowError("a price is zero");
  });
});
