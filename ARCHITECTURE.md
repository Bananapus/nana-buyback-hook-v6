# Architecture

## Purpose

`nana-buyback-hook-v6` gives a Juicebox project best-execution behavior on both entry and exit. On payments it compares minting through Juicebox against buying from a Uniswap V4 pool. On cash outs it compares reclaiming through Juicebox against selling reminted project tokens into the pool. The hook chooses the better route while preserving Juicebox's accounting and reserved-rate semantics.

## Boundaries

- `JBBuybackHook` owns route selection and swap execution.
- `JBBuybackHookRegistry` owns which hook instance a project is allowed to use.
- `univ4-router-v6` owns the TWAP oracle hook used by the configured pools.
- Core terminal accounting remains in `nana-core-v6`.

## Main Components

| Component | Responsibility |
| --- | --- |
| `JBBuybackHook` | Data hook, pay hook, cash-out hook, and Uniswap V4 unlock callback |
| `JBBuybackHookRegistry` | Project-level routing to an approved hook instance, with optional locking |
| `JBSwapLib` | TWAP-based quoting, liquidity-sensitive slippage limits, and price-limit helpers |

## Runtime Model

### Buy Side

```text
payment arrives
  -> hook estimates direct mint output
  -> hook estimates pool output using explicit quote metadata or TWAP-based quoting
  -> if pool wins, hook returns an active pay-hook spec and later executes the swap
  -> swapped tokens are burned and re-minted through the controller so reserved-rate semantics still apply
  -> if mint wins, the spec is informational only
```

### Sell Side

```text
cash out requested
  -> hook compares protocol reclaim value to pool sell value
  -> if pool wins, after-cash-out callback remints the selected token count to itself and sells it
  -> if protocol wins, the spec stays noop but still carries diagnostics for preview clients
```

## Critical Invariants

- Buy-side and sell-side execution must never bypass core accounting. The hook chooses routes; it does not create alternate treasury math.
- Oracle failure should degrade to the safer protocol path, not silently force a risky swap path.
- Registry allowlisting and project-level locking are part of the security model. Projects should not be able to point at arbitrary hook implementations.
- Noop specs may carry metadata, but not funds. That distinction is fundamental to composability with preview surfaces and wrappers.

## Where Complexity Lives

- The hard part is not swapping; it is preserving Juicebox semantics while sometimes swapping.
- Buy-side and sell-side routing look symmetrical at a glance, but their settlement paths differ materially.
- Oracle assumptions, slippage limits, and fallback behavior are tightly coupled and should be reviewed together.

## Dependencies

- `nana-core-v6` hooks, controller, terminal, prices, and permissions
- `univ4-router-v6` as the canonical oracle hook
- Uniswap V4 pool manager infrastructure

## Safe Change Guide

- Treat quote selection, slippage logic, and execution fallback as one system.
- If you modify buy-side behavior, re-check reserved-rate application. That is where most subtle accounting regressions appear.
- If you modify sell-side metadata or callback behavior, inspect wrapper deployers that pass through hook specs.
- Avoid adding mutable governance surfaces to the core hook; keep project-level selection in the registry.
- Changes that make the hook "more helpful" by adding implicit fallback routes are usually dangerous.
