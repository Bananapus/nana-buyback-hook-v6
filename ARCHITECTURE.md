# Architecture

## Purpose

`nana-buyback-hook-v6` gives a Juicebox project market-aware entry and exit routing. On pay, it compares the protocol mint path with a Uniswap V4 buy path. On cash out, it compares the protocol reclaim path with selling reminted project tokens into the pool. It chooses the better route without replacing core treasury accounting.

## System Overview

`JBBuybackHook` is the runtime route selector and executor. `JBBuybackHookRegistry` is not just configuration storage. It is also the project-facing wrapper that resolves the active hook for a project and forwards hook callbacks to that resolved implementation. `JBSwapLib` provides quoting and slippage helpers.

The TWAP oracle surface comes from `univ4-router-v6`, while settlement truth remains in `nana-core-v6`.

## Core Invariants

- the hook must never create alternate treasury accounting
- oracle failure should degrade toward the safer protocol path
- registry allowlisting and lock status are part of the security model
- buy-side fallback and sell-side fallback are intentionally asymmetric
- the registry may intentionally act as a pass-through data hook when no concrete buyback hook exists on that chain
- a project's chosen hook remains sovereign once assigned
- noop hook specs may carry diagnostics, but not funds

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBBuybackHook` | Data-hook, pay-hook, cash-out-hook, and swap callback logic | Runtime core |
| `JBBuybackHookRegistry` | Project-to-hook configuration, locking, and runtime forwarding to the resolved hook | Governance and wrapper surface |
| `JBSwapLib` | Quoting, slippage, and price-limit helpers | Shared routing math |

## Trust Boundaries

- core accounting, token minting, and permissions remain in `nana-core-v6`
- oracle observations and pool-level market data come from `univ4-router-v6` and Uniswap V4
- projects should not be able to point at arbitrary hook implementations once locked
- the registry is trusted to resolve the correct active hook for project-facing callback flows

## Critical Flows

### Buy Side

```text
payment arrives
  -> hook estimates direct mint output
  -> hook estimates pool output from explicit quote metadata or TWAP-derived quoting
  -> if pool wins, hook returns an active pay-hook spec and later executes the swap
  -> swapped tokens are burned and re-minted through the controller so reserved-rate semantics still apply
  -> if the swap fully fails, explicit caller minima still revert but oracle-derived minima can degrade to mint fallback
```

### Sell Side

```text
cash out requested
  -> hook compares protocol reclaim value with pool sell value
  -> hook always returns sell-side diagnostics in metadata so preview clients can inspect the comparison
  -> if pool wins, hook maxes the cash-out tax so the terminal does not reclaim surplus directly
  -> after-cash-out callback remints the chosen token amount to itself and sells it
  -> if the sell-side swap fails hard, the cash out reverts
  -> if protocol wins, the hook returns diagnostics but no active swap path
```

## Accounting Model

This repo owns route selection and swap execution logic. It does not own the canonical ledger for balances, fees, or surplus.

On the buy side, the hook uses the controller preview path to preserve beneficiary-versus-reserved-token semantics even when comparing against market quotes. On the sell side, hook metadata can describe the route comparison even when the hook leaves the protocol cash-out path unchanged.

## Security Model

- the danger is semantic drift between quote selection, slippage logic, and execution
- buy and sell routing are not mirror images
- explicit user minima and oracle-derived minima are not equivalent
- sell-side routing suppresses direct protocol reclaim only when the market path wins
- reserved-rate preservation is a primary audit target on the buy side

## Safe Change Guide

- review quote selection, slippage bounds, and fallback behavior as one system
- if registry behavior changes, re-check the no-hook pass-through path and the rule that disallowed hooks do not override already-pinned project assignments
- if buy-side behavior changes, re-check reserved-rate application through the controller
- if sell-side callback behavior changes, inspect wrappers and preview clients that read the returned specs
- keep governance or registry mutability out of the core hook

## Canonical Checks

- buy-side failure fallback and mint degradation:
  `test/regression/SwapFailureMintFallback.t.sol`
- sell-side metadata and callback safety:
  `test/audit/CashOutMetadataInflation.t.sol`
- routing invariants across configurations:
  `test/invariant/BuybackHookInvariant.t.sol`

## Source Map

- `src/JBBuybackHook.sol`
- `src/JBBuybackHookRegistry.sol`
- `src/libraries/JBSwapLib.sol`
- `test/regression/SwapFailureMintFallback.t.sol`
- `test/audit/CashOutMetadataInflation.t.sol`
- `test/invariant/BuybackHookInvariant.t.sol`
