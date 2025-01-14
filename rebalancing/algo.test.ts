import test from "ava";

import { getRebalance } from "./algo";

const shares = BigInt(1e27);

test("[100%, 0%, 0%] => [0%, 50%, 50%]", (t) => {
  const tokens = ["USDC", "DAI", "USDT"];
  const bals = [BigInt(1e21), BigInt(0), BigInt(0)];
  const targetBasket = [BigInt(0), BigInt(5e17), BigInt(5e17)];
  const prices = [BigInt(1e6), BigInt(1e18), BigInt(1e6)];
  const error = [BigInt(1e16), BigInt(1e16), BigInt(1e16)];

  const trades = getRebalance(shares, tokens, bals, targetBasket, prices, error);
  t.is(trades.length, 2);
  t.is(trades[0].sell, "USDC");
  t.is(trades[0].buy, "DAI");
  t.is(trades[1].sell, "USDC");
  t.is(trades[1].buy, "USDT");

  // TODO
});
