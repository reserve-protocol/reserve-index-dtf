import { Decimal } from "decimal.js";

export const D27n: bigint = 10n ** 27n;
export const D18n: bigint = 10n ** 18n;
export const D9n: bigint = 10n ** 9n;

export const D27d: Decimal = new Decimal("1e27");
export const D18d: Decimal = new Decimal("1e18");
export const D9d: Decimal = new Decimal("1e9");

export const bn = (str: string): bigint => {
  if (typeof str !== "string") {
    return BigInt(str);
  }

  return BigInt(new Decimal(str).toFixed(0));
};
