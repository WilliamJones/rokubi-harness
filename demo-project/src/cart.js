// A tiny shopping cart. Deliberately contains one real bug for the harness demo:
// the discount is applied to every line instead of once to the order.
// Percentages hide it (they're distributive), but a fixed discount comes off
// once per line — £20 off a 3-line order takes £60. See test/cart.test.js.

export function subtotal(items) {
  return items.reduce((sum, item) => sum + item.price * item.quantity, 0);
}

export function applyDiscount(amount, discount) {
  if (!discount) return amount;
  if (discount.type === "fixed") return Math.max(0, amount - discount.value);
  if (discount.type === "percent") return amount * (1 - discount.value / 100);
  throw new Error(`Unknown discount type: ${discount.type}`);
}

export function total(items, discount) {
  // BUG: the discount is applied to each line, then summed. It should be applied
  // once, to the subtotal.
  const discounted = items.map((item) =>
    applyDiscount(item.price * item.quantity, discount),
  );
  return round(discounted.reduce((sum, line) => sum + line, 0));
}

export function round(value) {
  return Math.round(value * 100) / 100;
}
