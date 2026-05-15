# Changelog

## Scope

This file describes the verified change from `nana-buyback-hook-v5` to the current `nana-buyback-hook-v6` repo.

## Current v6 surface

- `JBBuybackHook`
- `JBBuybackHookRegistry`
- `IJBBuybackHook`
- `IJBBuybackHookRegistry`
- `JBSwapLib`

## 0.0.46 — Bump nana-core-v6 to 0.0.52

`nana-core-v6@0.0.52` centralized the protocol fee constant into `JBConstants.FEE` and dropped `IJBFeeTerminal.FEE()`. Updated `JBBuybackHook` accordingly:

- The direct cash-out fee deduction in `beforeCashOutRecordedWith` now uses `JBFees.standardFeeAmountFrom(directCashOutAmount)` instead of `JBFees.feeAmountFrom(directCashOutAmount, IJBFeeTerminal(context.terminal).FEE())`. `standardFeeAmountFrom` is the new compile-time-constant helper that hardcodes the standard 25/1000 rate.
- Dropped the `IJBFeeTerminal` import (no longer referenced from src).
- Removed all `vm.mockCall(... IJBFeeTerminal.FEE ...)` setups across `test/` — those mocks no longer intercept anything because the call is now a pure library reference. Test files that imported `IJBFeeTerminal` only for the mock had the import dropped.
- Test struct literals updated for the new core 0.0.52 schema: `JBRulesetMetadata` gained `pauseCrossProjectFeeFreeInflows: false`; `JBBeforeCashOutRecordedContext` left unchanged (no new fields).
- `package.json`: version 0.0.45 -> 0.0.46, core dep ^0.0.48 -> ^0.0.52, univ4-router-v6 dep ^0.0.30 -> ^0.0.31 (the matching downstream bump for core 0.0.52).

## Summary

- The buyback path is now built around Uniswap v4-era infrastructure rather than the v5 Uniswap v3 model.
- `JBBuybackHook` is no longer only about the pay path. The v6 interface also includes cash-out-hook responsibilities.
- The registry is stricter than before. The current repo includes explicit zero-hook and hook-mismatch protections, plus a more opinionated locking flow.
- Shared swap logic now lives in `JBSwapLib`, which makes this repo and the Uniswap V4 router hook part of the same routing vocabulary.
- The repo moved to Solidity `0.8.28`.

## Verified deltas

- `IJBBuybackHook` now extends `IJBCashOutHook` in addition to the pay/data-hook responsibilities.
- The registry adds explicit `HookMismatch` and `ZeroHook` error cases that were not part of the older model.
- The current source and tests are built around v4 pool-manager routing, not the v5 direct-v3-pool mental model.
- The repo includes dedicated regression coverage for default-hook validation, initialization races, leftover accounting, swap-failure fallback behavior, and cash-out partial-fill residue accounting.

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
