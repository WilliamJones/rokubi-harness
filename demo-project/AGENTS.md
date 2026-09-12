# Demo cart — project instructions

A deliberately small project used to demonstrate the ROKUBI Harness.

## Commands
- Test: `npm test` (Node's built-in runner — no dependencies to install)

## Conventions
- ES modules (`type: "module"`), named exports.
- Money is rounded to 2 decimals only at the boundary, in `total()` — never mid-calculation.
- Fix the code, not the test. The tests describe the intended behaviour.
