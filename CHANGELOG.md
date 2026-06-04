# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. It compares `nana-buyback-hook-v5` in `../../v5/evm` with the current `nana-buyback-hook-v6` repo.

## Current V6 Surface

- `JBBuybackHook`
- `JBBuybackHookRegistry`
- `IJBBuybackHook`
- `IJBBuybackHookRegistry`
- `JBSwapLib`
- `DefaultHookSegment`
- `SwapCallbackData`

## Summary

- The buyback hook moved from Uniswap V3 pool assumptions to a Uniswap V4 `PoolManager` and `PoolKey` model.
- The hook now participates in both pay and cash-out routing. V5's main public hook behavior was pay-side buyback; V6 adds sell-side/cash-out handling.
- Chain-specific V4 dependencies are configured through a one-shot `setChainSpecificConstants(...)` setter so the hook can have chain-same deployment inputs.
- Pool configuration is keyed by `(projectId, terminalToken)` and V4 pool key data, not by a V3 pool address.
- The registry default-hook model is thresholded by project ID and exposes history, reducing the risk that changing the default silently changes existing projects.
- Metadata purpose names align with V6 lifecycle phases: use `pay` and `cashOut` metadata keyed to the relevant hook address.

## ABI, Event, and Error Changes

- Removed or replaced V5 functions:
  - `UNISWAP_V3_FACTORY()`
  - `WETH()`
  - `poolOf(uint256,address)` returning an `IUniswapV3Pool`
  - `setPoolFor(uint256,uint24,uint256,address)` returning an `IUniswapV3Pool`
  - `setTwapWindowOf(uint256,uint256)`
- Added or changed functions:
  - `poolManager()`
  - `poolKeyOf(uint256,address)`
  - `twapWindowOf(uint256,address)`
  - `setPoolFor(uint256,PoolKey,uint256,address)`
  - `setPoolFor(uint256,uint24,int24,uint256,address)`
  - `initializePoolFor(...)`
  - `setChainSpecificConstants(IPoolManager,IHooks)`
  - registry default-hook history views: `defaultHookProjectIdThreshold()`, `defaultHookHistoryAt(...)`, and `defaultHookHistoryLength()`
- Added or changed events:
  - `CashOutSwap`
  - `SellSwapReverted`
  - `PoolAdded` now carries a V4 `PoolId` instead of a V3 pool address.
  - `TwapWindowChanged` includes `terminalToken`.
  - registry events are namespaced as `JBBuybackHookRegistry_*`.
- Added or migration-sensitive errors include:
  - `JBBuybackHook_AlreadyConfigured`
  - `JBBuybackHook_PoolInitializedAtWrongPrice`
  - `JBBuybackHook_SpecifiedSlippageExceeded`
  - `JBBuybackHookRegistry_HookMismatch`
  - `JBBuybackHookRegistry_HookLocked`
  - `JBBuybackHookRegistry_CannotDisallowDefaultHook`

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: `nana-buyback-hook-v5`.
- Own-source ABI artifacts compared: V6 `6`, V5 `5`.
- Contract/interface coverage: `2` added, `1` removed, `4` shared names with ABI changes, `0` shared names ABI-identical.
- Shared-name ABI item deltas: `72` added, `44` removed, `5` modified.

Added V6 ABI artifacts:
- `IGeomeanOracle` from `src/interfaces/IGeomeanOracle.sol`: `1` functions, `0` events, `0` errors.
- `JBSwapLib` from `src/libraries/JBSwapLib.sol`: `0` functions, `0` events, `0` errors.

Removed V5 ABI artifacts:
- `IWETH9` from `src/interfaces/external/IWETH9.sol`: `8` functions, `2` events, `0` errors.

Shared ABI artifacts with changes:
- `IJBBuybackHook`: `15` added, `12` removed, `1` modified ABI items.
- `IJBBuybackHookRegistry`: `12` added, `7` removed, `1` modified ABI items.
- `JBBuybackHook`: `27` added, `18` removed, `2` modified ABI items.
- `JBBuybackHookRegistry`: `18` added, `7` removed, `1` modified ABI items.

Generated event/error name deltas:
- Event names added:
  - `CashOutSwap`, `JBBuybackHookRegistry_AllowHook`, `JBBuybackHookRegistry_DisallowHook`, `JBBuybackHookRegistry_LockHook`, `JBBuybackHookRegistry_SetDefaultHook`, `JBBuybackHookRegistry_SetHook`, `PoolAdded`, `SellSwapReverted`.
  - `Swap`, `TwapWindowChanged`.
- Event names removed or replaced:
  - `Approval`, `JBBuybackHookRegistry_AllowHook`, `JBBuybackHookRegistry_DisallowHook`, `JBBuybackHookRegistry_LockHook`, `JBBuybackHookRegistry_SetDefaultHook`, `JBBuybackHookRegistry_SetHook`, `PoolAdded`, `Swap`.
  - `Transfer`, `TwapWindowChanged`.
- Error names added:
  - `FailedCall`, `InsufficientBalance`, `JBBuybackHookRegistry_CannotDisallowDefaultHook`, `JBBuybackHookRegistry_HookMismatch`, `JBBuybackHookRegistry_ZeroHook`, `JBBuybackHook_AlreadyConfigured`, `JBBuybackHook_CallerNotPoolManager`, `JBBuybackHook_CallerNotTerminal`.
  - `JBBuybackHook_PoolAlreadySet`, `JBBuybackHook_PoolInitializedAtWrongPrice`, `JBBuybackHook_PoolNotInitialized`, `JBBuybackHook_PoolNotSet`, `JBBuybackHook_ZeroProjectToken`, `JBMetadataResolver_DataNotPadded`, `JBMetadataResolver_MetadataTooLong`, `JBMetadataResolver_MetadataTooShort`.
- Error names removed or replaced:
  - `JBBuybackHook_AmountOverflow`, `JBBuybackHook_CallerNotPool`, `JBBuybackHook_PoolAlreadySet`, `JBBuybackHook_ZeroProjectToken`, `JBBuybackHook_ZeroTerminalToken`, `T`.

## Migration Notes

- Replace V3 pool-address configuration with V4 `PoolKey` / `PoolId` handling.
- Update metadata builders from V5/V6-draft purpose strings to the current `pay` and `cashOut` purposes.
- Regenerate both hook and registry ABIs. The registry is no longer just a small wrapper around the V5 default hook concept.
