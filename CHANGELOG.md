# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. It compares
`nana-buyback-hook-v5` in `../../../v5/evm/nana-buyback-hook-v5` with the current `nana-buyback-hook-v6`
repo.

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
- Buy-side AMM routing requires a configured pool with current in-range PoolManager liquidity. A warm TWAP alone is not
  enough to activate the market route if the pool is drained.
- Sell-side route selection compares against what the selected terminal can locally settle, not only aggregate
  project surplus.
- A pay with no caller quote floors its swap at the expected single-range output less 2% when the sigmoid floor would
  sit under direct issuance. Thin pools that beat issuance now route to the swap instead of minting. A pay larger than
  the pool can take above the issuance rate floors its settlement at the swap leg up to the issuance-rate price limit,
  less 2%, plus issuance for the input that leg leaves.
- The expected-output floor covers the whole settlement (swap output plus unconsumed input at the issuance rate), so a
  partial fill whose settlement misses it unwinds and the pay mints. Sigmoid floors stay pro-rated by consumed input.
- A pay with no caller quote reports its expected settlement as `rawSwapQuote` (word 13 of the pay spec): the swap leg
  up to the issuance-rate price limit plus issuance for the input it leaves. Route scorers that read
  `max(rawSwapQuote, minimumSwapAmountOut)` rank such pays by what they settle. Cash-outs, explicit-quote pays and
  cold-start bootstrap quotes keep the raw oracle quote.
- A cash-out with no caller minimum whose sigmoid floor would sit under net reclaim routes on the same expected-output
  floor when it beats both net reclaim and the count at its marginal net reclaim rate, spot is short of the price that
  rate implies, and the count is at most half the supply. That floor only chooses the route: the sale stops at the marginal rate (half the net reclaim of twice the
  count), and unsold tokens return to the holder. See RISKS 9.11.
- Metadata purpose names align with V6 lifecycle phases: use `pay` and `cashOut` caller metadata keyed to the relevant
  hook address.
- `setPoolFor` rejects a pool whose hook is not the configured oracle hook (`JBBuybackHook_PoolHookMismatch`).
  Only the oracle hook prices routes, and a pool with another hook could take a no-minimum sale through its own
  callbacks.
- A no-quote pay to a project that mints nothing (weight zero) keeps the cold-start bootstrap route's spot-derived output
  floor; it used to replace that floor with issuance, which is zero, and swap with no floor.
- A sigmoid-route cash-out also reclaims when spot has already passed the sale's limit, instead of selling a sliver and
  returning the rest.

## Metadata Changes

- Buy-side caller metadata uses the `"pay"` key and encodes
  `(uint256 amountToSwapWith, uint256 minimumSwapAmountOut, bool skipSplits)`. `skipSplits` sends the swap output to
  the beneficiary as-is instead of burning and re-minting it through the reserved split; programmatic pays leave it
  `false`.
- Sell-side caller metadata uses the `"cashOut"` key and encodes
  `(uint256 minimumSwapAmountOut, bool skip)`.
- The pay hook specification returned from `beforePayRecordedWith` carries this hook-internal settlement and preview
  payload:

```solidity
(
  bool projectTokenIs0,
  uint256 amountToMintWith,
  uint256 minimumSwapAmountOut,
  bool hasUserSpecifiedQuote,
  IJBController controller,
  uint256 tokenCountWithoutHook,
  uint256 weightRatio,
  uint256 quotedAmountToSwapWith,
  int24 twapTick,
  uint128 twapLiquidity,
  PoolId poolId,
  uint256 minimumBeneficiaryTokenCount,
  uint256 minimumReservedTokenCount,
  uint256 rawSwapQuote,
  bool oracleUnseeded,
  bool skipSplits,
  uint256 reservedPercent,
  bool floorCoversSettlement
)
```

- `quotedAmountToSwapWith` is the gross quoted swap amount. It lets `afterPayRecordedWith` scale oracle-derived floors
  and issuance-rate price limits when a same-terminal split forwards only a net post-fee amount. Explicit caller minima
  are settlement guarantees and are not scaled.
- The cash-out hook specification returned from `beforeCashOutRecordedWith` carries
  `(uint256 minimumSwapAmountOut, uint256 cashOutCount, uint256 netDirectCashOutAmount, int24 twapTick,
  uint128 twapLiquidity, PoolId poolId, uint256 rawSwapQuote, bool hasUserSpecifiedMinimumSwapAmountOut,
  uint256 sellLimitAmountOut)`. `minimumSwapAmountOut` is the routing floor. `sellLimitAmountOut` is the no-quote sale's
  price limit as an output amount for the whole count, 0 when the sale uses `minimumSwapAmountOut` as its limit, or
  `type(uint256).max` on a noop spec past half the supply or with spot past the limit.
  `afterCashOutRecordedWith` requires all nine words.

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
- Own-source ABI artifacts compared: V6 `5`, V5 `6`.
- Contract/interface coverage: `0` added, `1` removed, `4` shared names with ABI changes, `1` shared name ABI-identical.
- Shared-name ABI item deltas: `70` added, `41` removed, `5` modified.

Added V6 ABI artifacts:
- None.

Removed V5 ABI artifacts:
- `IWETH9` from `src/interfaces/external/IWETH9.sol`: `8` functions, `2` events, `0` errors.

Shared ABI artifacts with changes:
- `IJBBuybackHook`: `14` added, `11` removed, `2` modified ABI items.
- `IJBBuybackHookRegistry`: `11` added, `6` removed, `1` modified ABI item.
- `JBBuybackHook`: `28` added, `18` removed, `1` modified ABI item.
- `JBBuybackHookRegistry`: `17` added, `6` removed, `1` modified ABI item.
- `JBSwapLib`: no ABI item changes.

Generated event/error name deltas:
- Event names added:
  - `CashOutSwap`, `SellSwapReverted`.
- Event names removed or replaced:
  - `Approval`, `Transfer`.
- Error names added:
  - `FailedCall`, `InsufficientBalance`, `JBBuybackHookRegistry_CannotDisallowDefaultHook`,
    `JBBuybackHookRegistry_HookMismatch`, `JBBuybackHookRegistry_ZeroHook`,
    `JBBuybackHook_AlreadyConfigured`, `JBBuybackHook_CallerNotPoolManager`,
    `JBBuybackHook_CallerNotTerminal`, `JBBuybackHook_PoolInitializedAtWrongPrice`,
    `JBBuybackHook_PoolHookMismatch`, `JBBuybackHook_PoolNotInitialized`, `JBBuybackHook_PoolNotSet`,
    `JBMetadataResolver_DataNotPadded`, `JBMetadataResolver_MetadataTooLong`, `JBMetadataResolver_MetadataTooShort`.
- Error names removed or replaced:
  - `JBBuybackHook_AmountOverflow`, `JBBuybackHook_CallerNotPool`, `JBBuybackHook_ZeroTerminalToken`, `T`.

## Migration Notes

- Replace V3 pool-address configuration with V4 `PoolKey` / `PoolId` handling.
- Update metadata builders from V5/V6-draft purpose strings to the current `pay` and `cashOut` purposes.
- Encode the `pay` entry as three words: two-word `(amountToSwapWith, minimumSwapAmountOut)` quotes no longer decode.
  Pass `skipSplits=false` unless the payer is buying for themselves and wants the swap output outside the reserved
  split.
- Regenerate both hook and registry ABIs. The registry is no longer just a small wrapper around the V5 default hook concept.
