# Buyback Hook Runtime

## Contract Roles

- [`src/JBBuybackHook.sol`](../src/JBBuybackHook.sol) compares protocol-native and market-native paths for payments and cash-outs, then executes the better route.
- [`src/JBBuybackHookRegistry.sol`](../src/JBBuybackHookRegistry.sol) controls which hook a project uses, what hooks are allowed, what the default hook is, and whether a project's choice is locked.
- [`src/libraries/JBSwapLib.sol`](../src/libraries/JBSwapLib.sol) provides swap-side helper logic such as slippage and quote-related math.

## Runtime Path

1. Payment or cash-out execution enters [`src/JBBuybackHook.sol`](../src/JBBuybackHook.sol).
2. The hook inspects the project's configured pool and quote/TWAP conditions.
3. It compares the market path against the protocol-native path.
4. It executes the better route, with fallback behavior preserving liveness when supported external calls fail.

## High-Risk Areas

- TWAP window assumptions: edits must preserve the intended bounds and failure behavior when observation history is weak.
- Oracle and quote fallbacks: this repo intentionally balances liveness against precision. Do not remove safeguards casually.
- Pool configuration drift: runtime bugs are often really stale pool-selection or registry-state bugs.
- Fee-on-transfer, partial-fill, and MEV-sensitive behavior: these are core threat-model concerns, not corner cases.

## Tests To Trust First

- [`test/V4BuybackHook.t.sol`](../test/V4BuybackHook.t.sol) for the main execution path.
- [`test/TestOracleRevertBehavior.t.sol`](../test/TestOracleRevertBehavior.t.sol) for oracle-failure semantics.
- [`test/MEVScenarios.t.sol`](../test/MEVScenarios.t.sol) for market-manipulation pressure.
- [`test/TestBuybackFOT.t.sol`](../test/TestBuybackFOT.t.sol) for fee-on-transfer behavior.
- [`test/regression/`](../test/regression/) and [`test/invariant/`](../test/invariant/) for broader safety checks.
