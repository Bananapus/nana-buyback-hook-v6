# Changelog

## Scope

This file describes the verified change from `nana-buyback-hook-v5` to the current `nana-buyback-hook-v6` repo.

## Current v6 surface

- `JBBuybackHook`
- `JBBuybackHookRegistry`
- `IJBBuybackHook`
- `IJBBuybackHookRegistry`
- `JBSwapLib`

## 0.0.66 — Soft-land a derived sell-side floor; apply the first default hook to pre-existing projects

This release bundles two fixes.

### Soft-land a derived sell-side floor on a successful-but-partial fill

Makes the sell-side cash-out path treat a non-caller-specified (oracle/quote-derived) floor consistently across both
swap-outcome branches. Previously `JBBuybackHook.afterCashOutRecordedWith` was asymmetric: a *fully reverted* pool swap
soft-landed a derived floor (returning the reminted project tokens to the holder so the cash-out still completed), but a
*successful-but-partial* fill hard-reverted whenever `amountReceived < minimumSwapAmountOut`, regardless of whether the
floor was an explicit caller minimum or one the hook derived during route selection. A price-limited swap that filled
successfully but stopped short of a derived floor therefore reverted the entire cash-out even though the floor was only
an internal preference.

- The successful-but-underfilled revert now fires only when `shouldEnforceMinimumSwapAmountOut == true` (an explicit
  caller minimum), matching the swap-failed branch. A derived floor (`shouldEnforceMinimumSwapAmountOut == false`)
  soft-lands the partial fill: the partial proceeds are forwarded to the beneficiary and the unsold reminted residue is
  returned to the holder (the residue transfer already existed on the success path). The same gating is applied to the
  ERC-20 fee-on-transfer delivery check so a derived floor cannot re-trigger the hard revert there either.
- An explicit caller-specified minimum still hard-reverts on an underfill — the user-specified-minimum protection is
  unchanged. No funds are stranded on the hook; the terminal has already burned the holder's project tokens before the
  hook runs.
- No interface, ABI, metadata-layout, or storage changes.
- Tests: added `test/regression/SellSidePartialFillDerivedFloor.t.sol` (derived-floor partial fill soft-lands;
  explicit-minimum partial fill still reverts; floor-met fill settles to the beneficiary). Updated
  `test/V4BuybackHook.t.sol`: the prior `test_afterCashOutRecordedWith_revertsWhenDerivedFloorUnderfills` (which encoded
  the old hard-revert-on-derived-floor behavior) is now `test_afterCashOutRecordedWith_softLandsWhenDerivedFloorUnderfills`,
  plus a new `test_afterCashOutRecordedWith_revertsWhenExplicitMinimumUnderfills` proving the explicit-minimum path still
  reverts. Updated `INVARIANTS.md` (A.2.4), `RISKS.md` (§9.6), and `ARCHITECTURE.md` (sell-side flow) to describe the
  derived-vs-explicit soft/hard floor behavior.

### Apply the first default hook to projects that already existed

The first-ever `setDefaultHook` call now also applies to projects that were created before any default hook existed (as
long as they have not pinned a hook of their own). Previously, `setDefaultHook` only recorded a history segment when it
was *replacing* an existing default; the first-ever call recorded nothing, so every project whose ID was already issued
at that moment resolved to `address(0)` in `_resolvedHookOf` / `hookOf` and never picked up the default buyback hook
unless it was individually pinned via `setHookFor`. Projects created before the first default hook was set therefore got
no buyback hook at all.

- `JBBuybackHookRegistry.setDefaultHook` now always pushes exactly one `_defaultHookHistory` segment covering the
  cohort `(defaultHookProjectIdThreshold, PROJECTS.count()]`. On the first-ever call (no prior default) the segment is
  mapped to the NEW hook, so the already-existing, non-pinned cohort resolves to it. On every later call the segment is
  mapped to the OUTGOING default — preserving today's behavior, where a default *change* does not retroactively re-route
  an earlier cohort. A per-project pin (`setHookFor`) still always takes precedence over any default.
- No interface, ABI, metadata-layout, or storage-layout changes — only the value written into the existing
  `_defaultHookHistory` array on the first call, plus NatSpec.
- Tests: added `test_setDefaultHook_firstDefaultAppliesToPreExistingProjects`,
  `test_setDefaultHook_firstDefaultDoesNotOverridePinnedPreExistingProject`, and
  `test_setDefaultHook_laterChangeDoesNotRetroactivelyReroute` to `test/Registry.t.sol`. Updated `INVARIANTS.md` (D.2,
  `setDefaultHook`), `RISKS.md` (§9.7 and the trust-assumptions note), `ARCHITECTURE.md` (new "Hook Resolution" flow),
  and `ADMINISTRATION.md`.

- `package.json`: version 0.0.65 -> 0.0.66.

## 0.0.64 — Pre-compute metadata IDs as constructor immutables

Hoists the `getId` purpose-string hashing out of the per-call hot path into deployment-time immutables, mirroring the
pattern in `JBRouterTerminal`. Pure gas/internal-cleanup change — **no ABI, metadata layout, or behavioral change**, so
consumers do not need to re-bump for correctness (only to pick up the gas savings).

- `JBBuybackHook`: added internal immutables `_CASH_OUT_ID = getId("cashOut")` and `_PAY_ID = getId("pay")`, set in the
  constructor. `beforeCashOutRecordedWith` and `beforePayRecordedWith` now read these immutables instead of hashing the
  purpose string on every call. Both are keyed to `address(this)`, which is deterministic under CREATE2, so the
  immutables are byte-identical on every chain (the unified address is preserved).
- `JBBuybackHookRegistry`: added internal immutables `_REGISTRY_CASH_OUT_ID` and `_REGISTRY_PAY_ID` (the registry's own
  `address(this)`-scoped IDs), set in the constructor. The per-call re-key into the resolved hook's ID
  (`getId(purpose, address(hook))`) stays computed inline because the resolved hook address varies per call.
- Self-target lookups use the single-argument `getId(purpose)` shorthand (which resolves `target: address(this)`).

## 0.0.63 — Rename metadata purpose keys to lifecycle-phase names

Renamed the two caller-provided metadata purpose strings to match the lifecycle-phase convention used by the 721 hook (`"pay"` / `"cashOut"`), so a project that stacks multiple data hooks reads one consistent key per phase.

- Buy side: `getId("quote")` → `getId("pay")` (read in `JBBuybackHook.beforePayRecordedWith`; rekeyed by `JBBuybackHookRegistry.beforePayRecordedWith`). Payload unchanged: `(uint256 amountToSwapWith, uint256 minimumSwapAmountOut)`.
- Sell side: `getId("cashOutMinReclaimed")` → `getId("cashOut")` (read in `JBBuybackHook.beforeCashOutRecordedWith`; rekeyed by `JBBuybackHookRegistry.beforeCashOutRecordedWith`). Payload unchanged: `(uint256 minimumSwapAmountOut, bool skip)`.
- **Breaking metadata-key change** (acceptable pre-deploy): every off-chain client and consumer contract that builds buyback metadata must use the new purpose strings. Each lifecycle phase reads exactly one purpose, so the phase-based names collide with nothing. Registry rekey, NatSpec, README/ARCHITECTURE/INVARIANTS/USER_JOURNEYS, and all tests updated; the registry's internal id variables renamed (`registryPayId`/`hookPayId`, `registryCashOutId`/`hookCashOutId`).
- `package.json`: version 0.0.62 -> 0.0.63.

## 0.0.62 — Sell-side `skip` cash-out flag

Added a caller-provided sell-side override that forces cash-outs through the protocol bonding-curve/terminal path and skips the Uniswap V4 pool entirely, even when the pool would return more.

- The `"cashOutMinReclaimed"` metadata entry read in `JBBuybackHook.beforeCashOutRecordedWith` is now encoded as `(uint256 minimumSwapAmountOut, bool skip)` instead of a bare `uint256`. `skip` defaults to `false`. **This is a breaking metadata-encoding change** (acceptable pre-deploy). The same metadata id is reused rather than introducing a new key, so the existing `JBBuybackHookRegistry` remap forwards both values in a single rekey.
- When `skip == true`, the hook short-circuits to the direct protocol cash-out (no pool quote, no swap, empty hook spec). Any non-zero `minimumSwapAmountOut` is still enforced against the direct net reclaim, so an unmeetable floor reverts with `JBBuybackHook_SpecifiedSlippageExceeded` rather than silently routing to the AMM — `skip` is a venue selector, not a waiver of slippage protection.
- No new metadata id, no interface/ABI signature changes, no storage changes.
- Tests: added `test_skip_*` to `TestSellSideNetComparison.t.sol` (passthrough, floor-still-enforced, and a control proving the pool would otherwise win) and `test_registryScopedSkipRoutesToTerminal` to the registry metadata audit test (proves the packed bool survives the registry remap). Updated all existing `cashOutMinReclaimed` test encoders to the 2-tuple form.

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
