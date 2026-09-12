import test from "node:test";
import assert from "node:assert/strict";
import { subtotal, applyDiscount, total } from "../src/cart.js";

const items = [
  { name: "Keyboard", price: 80, quantity: 1 },
  { name: "Cable", price: 10, quantity: 2 },
  { name: "Stand", price: 40, quantity: 1 },
];

test("subtotal sums price x quantity", () => {
  assert.equal(subtotal(items), 140);
});

test("fixed discount comes off the order once", () => {
  assert.equal(total(items, { type: "fixed", value: 20 }), 120);
});

test("percent discount comes off the order once", () => {
  // 10% off 140 = 126
  assert.equal(total(items, { type: "percent", value: 10 }), 126);
});

test("no discount leaves the subtotal alone", () => {
  assert.equal(total(items, null), 140);
});

test("applyDiscount rejects unknown types", () => {
  assert.throws(() => applyDiscount(100, { type: "bogus", value: 1 }), /Unknown discount type/);
});
