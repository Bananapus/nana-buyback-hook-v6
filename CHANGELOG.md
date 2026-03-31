# Changelog

## Scope

This file describes the verified change from `nana-buyback-hook-v5` to the current `nana-buyback-hook-v6` repo.

## Current v6 surface

- `JBBuybackHook`
- `JBBuybackHookRegistry`
- `IJBBuybackHook`
- `IJBBuybackHookRegistry`
- `JBSwapLib`

## Summary

- The buyback path is now built around Uniswap v4-era infrastructure rather than the v5 Uniswap v3 model.
- `JBBuybackHook` is no longer only about the pay path. The v6 interface also includes cash-out-hook responsibilities.
- The registry is stricter than before. The current repo includes explicit zero-hook and hook-mismatch protections, plus a more opinionated locking flow.
- Shared swap logic now lives in `JBSwapLib`, which makes this repo and the router terminal part of the same routing vocabulary.
- The repo moved to Solidity `0.8.28`.

## Verified deltas

- `IJBBuybackHook` now extends `IJBCashOutHook` in addition to the pay/data-hook responsibilities.
- The registry adds explicit `HookMismatch` and `ZeroHook` error cases that were not part of the older model.
- The current source and tests are built around v4 pool-manager routing, not the v5 direct-v3-pool mental model.
- The repo includes dedicated regression coverage for default-hook validation, initialization races, leftover accounting, and swap-failure fallback behavior.

## Breaking ABI changes

- `IJBBuybackHook` is not just a pay/data hook anymore; it now includes cash-out-hook semantics.
- Registry-level hook management is stricter and expects callers to handle zero-hook and mismatch cases explicitly.
- The migration is architectural enough that integrations should assume the hook and registry ABIs need full regeneration, not selective patching.

## Indexer impact

- Registry event semantics matter more in v6 because hook selection and locking are more explicit.
- Buyback routing should be modeled as v4-oriented behavior; old v3 pool assumptions are stale even if event names look familiar.

## Migration notes

- Treat this as an architectural migration, not a small ABI bump.
- Regenerate hook and registry ABIs from source and re-check how your integration models routing, quotes, and fallback behavior.
- If your v5 mental model was "buyback hook equals pay hook on top of v3 pools," it is stale for this repo.

## ABI appendix

- Changed interfaces
  - `IJBBuybackHook` now includes cash-out-hook responsibilities
  - `IJBBuybackHookRegistry` has stricter hook-management expectations
- Added migration-sensitive errors
  - zero-hook handling
  - hook-mismatch handling
- Architecture break
  - Uniswap v3 pool assumptions -> Uniswap v4 pool-manager model
