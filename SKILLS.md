# Juicebox Buyback Hook

## Purpose

Route project payments and cash outs through the better of the protocol path or a Uniswap V4 pool. On the buy side, compare minting from the terminal against buying from the pool. On the sell side, compare protocol cash out value against selling into the pool.

## Contracts

| Contract | Role |
|----------|------|
| `JBBuybackHook` | Core hook: implements `IJBRulesetDataHook` + `IJBPayHook` + `IJBCashOutHook` + `IUnlockCallback`. Compares mint vs swap and cash-out vs sell via TWAP, executes the better route through the V4 PoolManager, burns/remints on the buy side to apply reserved rate uniformly, and can remint-then-sell on the cash-out side. Stores an immutable `ORACLE_HOOK` (`IHooks`) used in all pool key construction. Constructor takes 8 params: `directory`, `permissions`, `prices`, `projects`, `tokens`, `poolManager`, `oracleHook`, `trustedForwarder`. |
| `JBBuybackHookRegistry` | Proxy data hook with allowlist. Routes `beforePayRecordedWith` to a per-project or default `JBBuybackHook`. Project owners choose, and optionally lock, implementations. Registry owner manages the allowlist. |
| `JBSwapLib` | Library for oracle queries (TWAP or spot), sigmoid-based slippage tolerance, price impact estimation, tick-to-price conversion, and `sqrtPriceLimitX96` computation. |

## Key Functions

### JBBuybackHook

| Function | What it does |
|----------|--------------|
| `beforePayRecordedWith(context)` | Data hook (view): compares mint count vs swap quote and selects the better route. See sub-bullets below. |

**`beforePayRecordedWith` detailed flow:**

1. **Parse metadata**: Reads `"quote"` metadata key for payer-supplied `(amountToSwapWith, minimumSwapAmountOut)`. If `amountToSwapWith == 0` or absent, the full payment amount is used.
2. **Resolve pool**: Loads the `PoolKey` and TWAP window for the project's terminal token pair. If no pool is configured, falls through to pure mint.
3. **Get TWAP quote**: Calls `JBSwapLib.getQuoteFromOracle` for the TWAP-based swap output estimate. If the oracle is unavailable, returns `(0, 0, 0)` to force the mint path.
4. **Compute slippage floor**: Uses `JBSwapLib.getSlippageTolerance` (sigmoid) and `JBSwapLib.calculateImpact` to derive a TWAP-adjusted minimum. Takes the higher of the TWAP minimum and the payer-supplied `minimumSwapAmountOut`.
5. **Compare routes**: Compares the TWAP-quoted swap output against the terminal's mint output (based on `weight`).
6. **Swap path** (swap yields more tokens): Returns `weight=0` and an active `JBPayHookSpecification` with metadata encoding `(projectTokenIs0, mintFromExcess, minimumSwapAmountOut, controller, tokenCountWithoutHook, twapTick, twapLiquidity, poolId, minimumBeneficiaryTokenCount, minimumReservedTokenCount)`.
7. **Mint path** (mint is better or equal): Returns the original weight plus a noop `JBPayHookSpecification` carrying the same 10 metadata fields for preview/simulation clients.
8. **On-chain vs informational fields**: `afterPayRecordedWith` only decodes the first 4 fields; fields 5-10 are informational for off-chain preview clients.
| `afterPayRecordedWith(context)` | Pay hook: pulls tokens from terminal, executes V4 swap via `POOL_MANAGER.unlock()`, burns swapped tokens, returns leftover to project balance via `addToBalanceOf`, mints total (swapped + leftover mint) via `controller.mintTokensOf` with `useReservedPercent: true`. If the swap fails entirely, the hook falls back to minting instead of reverting. |
| `setPoolFor(projectId, poolKey, twapWindow, terminalToken)` | Set the V4 pool for a project+terminal token pair using an explicit `PoolKey`. Validates: pool is initialized in PoolManager, currencies match project token and terminal token, TWAP window in bounds. Stores pool key, TWAP window, and project token. **Immutable once set.** Permission: `SET_BUYBACK_POOL` (ID 27). |
| `setPoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken)` | Simplified overload. Constructs the `PoolKey` internally using the project token, terminal token, and the immutable `ORACLE_HOOK` as the pool's hooks address. The pool must already be initialized. Permission: `SET_BUYBACK_POOL` (ID 27). |
| `initializePoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken, sqrtPriceX96)` | Atomically initializes a V4 pool (if not already initialized) and configures it as the buyback pool. Constructs the `PoolKey` using `ORACLE_HOOK`. Permission: `SET_BUYBACK_POOL` (ID 27). |
| `setTwapWindowOf(projectId, terminalToken, newWindow)` | Change the TWAP window for a project's terminal token (5 minutes to 2 days). Permission: `SET_BUYBACK_TWAP` (ID 26). |
| `unlockCallback(data)` | V4 PoolManager callback. Decodes `SwapCallbackData`, computes `sqrtPriceLimitX96`, executes swap, settles input tokens, takes output tokens. Only callable by PoolManager. |
| `poolKeyOf(projectId, terminalToken)` | Returns the V4 `PoolKey` for a project+terminal token pair. |
| `beforeCashOutRecordedWith(context)` | Data hook (view): compares direct protocol cash-out value against a TWAP-protected pool sell quote. Returns a cash-out hook spec when the pool sell is better. |
| `afterCashOutRecordedWith(context)` | Cash-out hook: remints burned project tokens to the hook, sells them through the configured V4 pool, and forwards proceeds to the beneficiary. |
| `hasMintPermissionFor(projectId, ruleset, addr)` | Returns `false` (the hook itself does not claim mint permission -- the registry handles this). |
| `supportsInterface(interfaceId)` | Returns `true` for `IJBRulesetDataHook`, `IJBPayHook`, `IJBCashOutHook`, `IJBBuybackHook`, `IJBPermissioned`, `IERC165`. |

### JBBuybackHookRegistry

| Function | What it does |
|----------|--------------|
| `hookOf(projectId)` | Returns the hook for the project, falling back to `defaultHook` if none is set. |
| `beforePayRecordedWith(context)` | Resolves the project's hook (or default) and delegates the call. |
| `beforeCashOutRecordedWith(context)` | Resolves the project's hook (or default) and delegates the call. |
| `hasMintPermissionFor(projectId, ruleset, addr)` | Returns `true` only if `addr` is the hook registered (or defaulted) for the project. |
| `setHookFor(projectId, hook)` | Route a project to a specific allowed buyback hook. Reverts if hook is locked or not on the allowlist. Permission: `SET_BUYBACK_HOOK` (ID 28). |
| `lockHookFor(projectId, expectedHook)` | Lock the hook choice for a project (irreversible). If using default, snapshots it into storage first. Requires a non-zero hook. Reverts with `JBBuybackHookRegistry_HookMismatch` if the resolved hook differs from `expectedHook` (prevents race conditions). Permission: `SET_BUYBACK_HOOK` (ID 28). |
| `allowHook(hook)` | Add a hook to the allowlist. Owner only. |
| `disallowHook(hook)` | Remove a hook from the allowlist. Reverts with `JBBuybackHookRegistry_CannotDisallowDefaultHook` if the hook is the current default -- the owner must call `setDefaultHook` to change the default first. Owner only. |
| `setDefaultHook(hook)` | Set the default hook (also adds to allowlist). Owner only. |
| `supportsInterface(interfaceId)` | Returns `true` for `IJBBuybackHookRegistry`, `IJBRulesetDataHook`, `IERC165`. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `nana-core-v6` | `IJBDirectory`, `IJBController`, `IJBMultiTerminal` | Directory lookups (`isTerminalOf`, `controllerOf`), token minting (`mintTokensOf`), token burning (`burnTokensOf`), balance management (`addToBalanceOf`) |
| `nana-core-v6` | `IJBPrices` | Cross-currency weight ratio when ruleset base currency differs from payment currency (`pricePerUnitOf`) |
| `nana-core-v6` | `IJBTokens`, `IJBProjects`, `IJBPermissions` | Token lookups (`tokenOf`), project ownership (`ownerOf`), permission checks |
| `nana-core-v6` | `JBMetadataResolver` | Parsing `"quote"` metadata key from payment calldata (contains `amountToSwapWith` and `minimumSwapAmountOut`) |
| `nana-core-v6` | `JBRulesetMetadataResolver` | Extracting `baseCurrency()` from packed ruleset metadata |
| `nana-permission-ids-v6` | `JBPermissionIds` | Permission ID constants (`SET_BUYBACK_TWAP` = 26, `SET_BUYBACK_POOL` = 27, `SET_BUYBACK_HOOK` = 28) |
| `@bananapus/univ4-router-v6` | `Univ4RouterDeploymentLib` | Oracle hook deployment address resolution (used in deployment script) |
| `@uniswap/v4-core` | `IPoolManager`, `IUnlockCallback`, `IHooks`, `PoolKey`, `PoolId`, `Currency`, `BalanceDelta`, `SwapParams`, `TickMath`, `StateLibrary` | V4 pool swaps (`unlock`, `swap`, `settle`, `take`), pool state queries (`getSlot0`, `getLiquidity`), tick math, `IHooks` for `ORACLE_HOOK` typing |
| `@prb/math` | `mulDiv` | Safe fixed-point multiplication |
| `@openzeppelin/contracts` | `ERC2771Context`, `SafeERC20`, `Ownable` (registry only) | Meta-transactions, safe token transfers, registry ownership |

## Key Types

| Struct/Type | Fields | Used In |
|-------------|--------|---------|
| `SwapCallbackData` (`src/structs/SwapCallbackData.sol`) | `key` (PoolKey), `zeroForOne` (bool), `amountIn` (uint256), `minimumSwapAmountOut` (uint256) | Encoded as `bytes` for `POOL_MANAGER.unlock()`, decoded in `unlockCallback` |
| `PoolKey` (Uniswap V4) | `currency0` (Currency), `currency1` (Currency), `fee` (uint24), `tickSpacing` (int24), `hooks` (IHooks) | Stored per project+terminalToken in `_poolKeyOf`. Passed to `setPoolFor`. |
| `JBBeforePayRecordedContext` | `projectId`, `amount` (token, value, decimals, currency), `weight`, `metadata` | Input to `beforePayRecordedWith` |
| `JBAfterPayRecordedContext` | `projectId`, `forwardedAmount`, `weight`, `beneficiary`, `hookMetadata` | Input to `afterPayRecordedWith` |
| `JBPayHookSpecification` | `hook` (IJBPayHook), `noop` (bool), `amount` (uint256), `metadata` (bytes) | Returned from `beforePayRecordedWith` for both active swap specs and noop informational mint-path specs. `metadata` encodes 10 fields: `(bool projectTokenIs0, uint256 mintFromExcess, uint256 minimumSwapAmountOut, IJBController controller, uint256 tokenCountWithoutHook, int24 twapTick, uint128 twapLiquidity, PoolId poolId, uint256 minimumBeneficiaryTokenCount, uint256 minimumReservedTokenCount)`. `afterPayRecordedWith` only decodes the first 4; fields 5-10 are informational for preview clients. |
| `JBRuleset` | `baseCurrency()` (from packed metadata) | Used for cross-currency weight adjustment |

## JBSwapLib Details

| Function | What it does |
|----------|--------------|
| `getQuoteFromOracle(poolManager, key, twapWindow, amountIn, baseToken, quoteToken)` | Queries the pool's oracle hook via `IGeomeanOracle.observe` for TWAP data. If `twapWindow == 0`, uses spot price from `poolManager.getSlot0`. If the oracle reverts, returns `(0, 0, 0)` to force the mint path (no spot fallback). Returns `(amountOut, arithmeticMeanTick, harmonicMeanLiquidity)`. |
| `getSlippageTolerance(impact, poolFeeBps)` | Continuous sigmoid: `minSlippage + (maxSlippage - minSlippage) * impact / (impact + K)`. Min = pool fee + 1% (floor 2%), max = 88%. K = 5e16. Returns tolerance in basis points of `SLIPPAGE_DENOMINATOR` (10,000). |
| `calculateImpact(amountIn, liquidity, sqrtP, zeroForOne)` | Estimates price impact scaled by `IMPACT_PRECISION` (1e18): `amountIn * 1e18 / liquidity`, normalized by sqrtPrice direction. Returns 0 when liquidity or sqrtP is 0. |
| `getQuoteAtTick(tick, baseAmount, baseToken, quoteToken)` | Converts a tick to a price and returns the equivalent quote amount. Ported from Uniswap V3 `OracleLibrary.getQuoteAtTick` -- pure math, no V3 dependency. |
| `sqrtPriceLimitFromAmounts(amountIn, minimumAmountOut, zeroForOne)` | Computes a `sqrtPriceLimitX96` from the minimum acceptable swap rate. Provides MEV protection by stopping the swap if the execution price would be worse than the minimum. Handles extreme ratios gracefully with fallback to no limit. |

### JBSwapLib Error & Edge Cases

| Function | Input / Condition | Behavior |
|----------|-------------------|----------|
| `getQuoteFromOracle` | `twapWindow == 0` | Uses spot price from `poolManager.getSlot0` instead of TWAP. Sandwich-attackable — only suitable for testing. |
| `getQuoteFromOracle` | `sqrtPriceX96 == 0` (pool not initialized, spot path) | Returns `(0, 0, 0)` — forces the mint path. |
| `getQuoteFromOracle` | Oracle hook reverts (not deployed, not warmed up) | Catches the revert and returns `(0, 0, 0)` — forces the mint path. No spot fallback. |
| `getQuoteFromOracle` | `amountIn == 0` | Returns `amountOut == 0` from `getQuoteAtTick` (pure math: `0 * price = 0`). |
| `getSlippageTolerance` | `impact == 0` (negligible swap in deep pool) | Returns `minSlippage` (pool fee + 1%, floor 2%). |
| `getSlippageTolerance` | `poolFeeBps >= MAX_SLIPPAGE` (8,800) | Returns `MAX_SLIPPAGE` (88%) immediately. |
| `getSlippageTolerance` | `impact > type(uint256).max - SIGMOID_K` | Returns `MAX_SLIPPAGE` to prevent overflow in `(impact + K)`. |
| `calculateImpact` | `liquidity == 0` or `sqrtP == 0` | Returns `0` — signals no data, caller should fall back to mint. |
| `getQuoteAtTick` | `baseAmount == 0` | Returns `0` (pure math). |
| `getQuoteAtTick` | Extreme ticks near `MIN_TICK` / `MAX_TICK` | `TickMath.getSqrtPriceAtTick` reverts if tick is out of range `[-887272, 887272]`. |
| `sqrtPriceLimitFromAmounts` | `minimumAmountOut == 0` or `amountIn == 0` | Returns extreme value (no limit): `MIN_SQRT_PRICE + 1` for zeroForOne, `MAX_SQRT_PRICE - 1` otherwise. |
| `sqrtPriceLimitFromAmounts` | Ratio `num/den >= 2^128` (extreme price imbalance) | Falls back to no limit to avoid overflow. |
| `sqrtPriceLimitFromAmounts` | Ratio `num/den >= 2^64` but `< 2^128` | Uses reduced-precision `ratioX128` path with a shift to avoid mulDiv overflow. |

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `MIN_TWAP_WINDOW` | `5 minutes` (300s) | Minimum TWAP oracle window |
| `MAX_TWAP_WINDOW` | `2 days` (172,800s) | Maximum TWAP oracle window |
| `TWAP_SLIPPAGE_DENOMINATOR` | `10,000` | Basis points denominator for slippage |
| `JBSwapLib.SLIPPAGE_DENOMINATOR` | `10,000` | Basis points denominator (internal to library) |
| `JBSwapLib.MAX_SLIPPAGE` | `8,800` | 88% sigmoid ceiling |
| `JBSwapLib.IMPACT_PRECISION` | `1e18` | Impact calculation precision |
| `JBSwapLib.SIGMOID_K` | `5e16` | Sigmoid curve inflection point |

## Storage

### JBBuybackHook

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `DIRECTORY` | `IJBDirectory` | `public immutable` | Directory of terminals and controllers |
| `PRICES` | `IJBPrices` | `public immutable` | Price feed contract for cross-currency weight conversion |
| `PROJECTS` | `IJBProjects` | `public immutable` | Project registry (ERC-721) |
| `TOKENS` | `IJBTokens` | `public immutable` | Token registry for looking up project ERC-20 addresses |
| `POOL_MANAGER` | `IPoolManager` | `public immutable` | Uniswap V4 PoolManager singleton |
| `ORACLE_HOOK` | `IHooks` | `public immutable` | Oracle hook embedded in all pool keys constructed by simplified overloads |
| `projectTokenOf` | `mapping(uint256 => address)` | `public` | ERC-20 address of each project's token (set on first `setPoolFor`) |
| `twapWindowOf` | `mapping(uint256 => mapping(address => uint256))` | `public` | TWAP window in seconds per project + terminal token pair |
| `_poolKeyOf` | `mapping(uint256 => mapping(address => PoolKey))` | `internal` | V4 `PoolKey` per project + terminal token pair (exposed via `poolKeyOf()` getter) |
| `_poolIsSet` | `mapping(uint256 => mapping(address => bool))` | `private` | Tracks whether a pool has been configured. Used for: (1) preventing re-setting via `setPoolFor`, (2) pool existence checks in `beforePayRecordedWith`, (3) guarding `setTwapWindowOf` against configuring windows for unconfigured pools |

### JBBuybackHookRegistry

| Variable | Type | Visibility | Purpose |
|----------|------|------------|---------|
| `PROJECTS` | `IJBProjects` | `public immutable` | Project registry for ownership checks |
| `defaultHook` | `IJBRulesetDataHook` | `public` | Fallback hook used when a project has no explicit hook set |
| `hasLockedHook` | `mapping(uint256 => bool)` | `public` | Whether a project's hook choice is permanently locked |
| `isHookAllowed` | `mapping(IJBRulesetDataHook => bool)` | `public` | Allowlist of hooks that can be assigned to projects |
| `_hookOf` | `mapping(uint256 => IJBRulesetDataHook)` | `internal` | Project-specific hook override (exposed via `hookOf()` getter) |

## Permission IDs

| ID | Constant | Used By | Grants |
|----|----------|---------|--------|
| 26 | `SET_BUYBACK_TWAP` | `JBBuybackHook.setTwapWindowOf` | Change the TWAP window for a project |
| 27 | `SET_BUYBACK_POOL` | `JBBuybackHook.setPoolFor`, `initializePoolFor` | Set the V4 pool for a project+terminal token pair |
| 28 | `SET_BUYBACK_HOOK` | `JBBuybackHookRegistry.setHookFor`, `lockHookFor` | Choose and lock the hook implementation for a project |

## Events

### JBBuybackHook

| Event | Fields |
|-------|--------|
| `CashOutSwap` | `projectId` (indexed), `cashOutCount`, `poolId` (indexed), `amountReceived`, `caller` |
| `Swap` | `projectId` (indexed), `amountToSwapWith`, `poolId` (indexed), `amountReceived`, `caller` |
| `Mint` | `projectId` (indexed), `leftoverAmount`, `tokenCount`, `caller` |
| `PoolAdded` | `projectId` (indexed), `terminalToken` (indexed), `poolId`, `caller` |
| `TwapWindowChanged` | `projectId` (indexed), `terminalToken` (indexed), `oldWindow`, `newWindow`, `caller` |

### JBBuybackHookRegistry

| Event | Fields |
|-------|--------|
| `JBBuybackHookRegistry_AllowHook` | `hook` |
| `JBBuybackHookRegistry_DisallowHook` | `hook` |
| `JBBuybackHookRegistry_LockHook` | `projectId` |
| `JBBuybackHookRegistry_SetDefaultHook` | `hook` |
| `JBBuybackHookRegistry_SetHook` | `projectId` (indexed), `hook` |

## Custom Errors

### JBBuybackHook

| Error | When |
|-------|------|
| `JBBuybackHook_CallerNotPoolManager(address caller)` | `unlockCallback` called by someone other than the PoolManager |
| `JBBuybackHook_CallerNotTerminal(address caller)` | `afterCashOutRecordedWith` called by non-terminal |
| `JBBuybackHook_InsufficientPayAmount(uint256 swapAmount, uint256 totalPaid)` | Metadata specifies `amountToSwapWith > totalPaid` |
| `JBBuybackHook_InvalidTwapWindow(uint256 value, uint256 min, uint256 max)` | TWAP window outside [5 minutes, 2 days] |
| `JBBuybackHook_PoolAlreadySet(PoolId poolId)` | `setPoolFor` called again for same project+token pair |
| `JBBuybackHook_PoolNotInitialized(PoolId poolId)` | Pool not initialized in V4 PoolManager (sqrtPriceX96 == 0) |
| `JBBuybackHook_PoolNotSet()` | `setTwapWindowOf` called for a project/terminal token pair that has no pool configured |
| `JBBuybackHook_SpecifiedSlippageExceeded(uint256 amount, uint256 minimum)` | Swap output less than minimum acceptable amount |
| `JBBuybackHook_TerminalTokenIsProjectToken(address, address)` | Terminal token same as project token |
| `JBBuybackHook_Unauthorized(address caller)` | `afterPayRecordedWith` called by non-terminal |
| `JBBuybackHook_ZeroProjectToken()` | Project has not issued an ERC-20 token |


### JBBuybackHookRegistry

| Error | When |
|-------|------|
| `JBBuybackHookRegistry_CannotDisallowDefaultHook()` | `disallowHook` called on the current default hook |
| `JBBuybackHookRegistry_HookLocked(uint256 projectId)` | `setHookFor` called on a locked project |
| `JBBuybackHookRegistry_HookMismatch(IJBRulesetDataHook currentHook, IJBRulesetDataHook expectedHook)` | `lockHookFor` called but resolved hook differs from the caller's `expectedHook` |
| `JBBuybackHookRegistry_HookNotAllowed(IJBRulesetDataHook hook)` | `setHookFor` called with a hook not on the allowlist |
| `JBBuybackHookRegistry_HookNotSet(uint256 projectId)` | `lockHookFor` called but no hook is set and no default exists |
| `JBBuybackHookRegistry_ZeroHook()` | `setDefaultHook` called with `address(0)` |

## Gotchas

- **ORACLE_HOOK is immutable**: The `ORACLE_HOOK` (`IHooks`) is set once in the constructor and cannot be changed. The simplified `setPoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken)` and `initializePoolFor` overloads embed `ORACLE_HOOK` into the constructed `PoolKey`. If you need a different oracle hook, use the explicit `setPoolFor(projectId, poolKey, twapWindow, terminalToken)` overload with a custom `PoolKey`, or deploy a new `JBBuybackHook`.
- **V4, not V3**: This version uses Uniswap V4 (`IPoolManager`, `PoolKey`, `unlock`/`unlockCallback`). There is no `IUniswapV3Pool`, no `uniswapV3SwapCallback`, no create2 pool address derivation, and no factory. Pools are identified by their `PoolKey` and must be initialized in the V4 PoolManager before calling `setPoolFor`.
- **Pool immutability**: `setPoolFor` can only be called once per project+terminalToken pair. After the pool key is stored, calling again reverts with `JBBuybackHook_PoolAlreadySet`. This is intentional to prevent swap routing manipulation.
- **PoolKey validation**: `setPoolFor` validates that the PoolKey's `currency0`/`currency1` match the project token and normalized terminal token. It also checks that the pool is initialized (sqrtPriceX96 != 0).
- **Burn-and-remint**: Tokens received from the swap are burned via `controller.burnTokensOf`, then re-minted (along with any leftover-mint count) via `controller.mintTokensOf` with `useReservedPercent: true`. This ensures the reserved rate applies uniformly regardless of the payment route.
- **Swap failure fallback**: If the V4 `POOL_MANAGER.unlock()` call reverts (insufficient liquidity, etc.), `_swap` catches it with try-catch and returns `(0, true)`. All payment tokens become leftover and are minted at the issuance rate.
- **TWAP oracle fallback**: When the oracle hook is absent or `observe()` reverts, `JBSwapLib.getQuoteFromOracle` returns `(0, 0, 0)`, forcing the mint path. Spot-price fallback was removed because it is trivially sandwich-attackable. Swaps activate once the oracle warms up (~30 min after pool creation).
- **Zero liquidity protection**: If the oracle returns zero liquidity (`harmonicMeanLiquidity == 0`), `_getQuote` returns 0, which ensures the hook falls back to minting rather than attempting a swap in an empty pool.
- **Sigmoid slippage ceiling**: If `getSlippageTolerance` returns `>= TWAP_SLIPPAGE_DENOMINATOR` (10,000 bps = 100%), `_getQuote` returns 0 to trigger mint fallback.
- **Quote floor**: When the payer provides an explicit `minimumSwapAmountOut` via `"quote"` metadata, it is honored directly and the TWAP lookup is skipped. When no explicit quote is provided, the TWAP oracle supplies the slippage floor via `_getQuote`. The sell side follows the same pattern with `"cashOutMinReclaimed"` metadata.
- **Issuance-rate price limit + minimum check**: The `unlockCallback` computes a `sqrtPriceLimitX96` from `amountIn` and `tokenCountWithoutHook` (the issuance-rate equivalent). The swap fills only while the pool offers a better rate for the payer than minting. When the pool price reaches the issuance boundary, the swap stops and leftover tokens are minted. After the swap, `afterPayRecordedWith` checks that the combined output (swap + leftover mint) meets the user's `minimumSwapAmountOut`. If not, the transaction reverts with `JBBuybackHook_SpecifiedSlippageExceeded`. When the swap fails entirely (pool unavailable), all tokens are minted as a fallback without the minimum check.
- **`beforePayRecordedWith` is a `view` function**: It cannot modify state. All swap execution happens in `afterPayRecordedWith`. Mint-path diagnostics are returned using noop pay-hook specifications.
- **Terminal validation**: `afterPayRecordedWith` validates that `msg.sender` is a registered terminal of the project via `DIRECTORY.isTerminalOf(projectId, IJBTerminal(msg.sender))`.
- **Native token handling**: When the terminal token is `JBConstants.NATIVE_TOKEN`, the hook normalizes to `address(0)` for storage and pool lookups — matching Uniswap V4's native ETH representation. For V4 settlement, native ETH uses `POOL_MANAGER.settle{value:}()` directly; ERC-20 tokens use `sync()` + `safeTransfer()` + `settle()`. No WETH wrapping/unwrapping is involved.
- **Metadata key**: `"quote"` encodes `(uint256 amountToSwapWith, uint256 minimumSwapAmountOut)`. If `amountToSwapWith == 0`, the full payment amount is used. If not provided at all, same behavior.
- **Hook spec metadata has 10 fields, 5 decoded on-chain**: `JBPayHookSpecification.metadata` encodes 10 fields: `(bool projectTokenIs0, uint256 mintFromExcess, uint256 minimumSwapAmountOut, IJBController controller, uint256 tokenCountWithoutHook, int24 twapTick, uint128 twapLiquidity, PoolId poolId, uint256 minimumBeneficiaryTokenCount, uint256 minimumReservedTokenCount)`. `afterPayRecordedWith` decodes the first 5. `tokenCountWithoutHook` is used as the swap's price limit (issuance rate) and `minimumSwapAmountOut` is used as the minimum acceptable combined output (swap + leftover mint). Fields 5-10 are informational for preview/simulation clients and are present on both active swap specs and noop mint-path specs. **Parsing the informational fields**: `twapTick` (int24) converts to price via `price = 1.0001^tick` — if `projectTokenIs0`, this gives payment tokens per project token directly; otherwise invert it (`1/price`). On-chain: `TickMath.getSqrtPriceAtTick(twapTick)` returns a Q64.96 sqrtPrice. `twapLiquidity` (uint128) is the harmonic mean of in-range liquidity over the TWAP window — higher means deeper liquidity and lower price impact; `0` means no data (mint fallback). `poolId` (bytes32) is `keccak256(abi.encode(poolKey))` — use it with `IPoolManager.getSlot0(poolId)` for current price or `poolKeyOf(projectId, terminalToken)` to recover the full `PoolKey`.
- **State variable names**: Public: `projectTokenOf[projectId]`, `twapWindowOf[projectId]`. Internal with public getter: `poolKeyOf(projectId, terminalToken)` (backed by `_poolKeyOf`). Internal only: `_poolIsSet[projectId][terminalToken]`.
- **ERC-2771**: `_msgSender()` (ERC-2771) is used instead of `msg.sender` for meta-transaction compatibility in permissioned functions (`setPoolFor`, `setTwapWindowOf`).
- **hookData format for V4 swaps**: The buyback hook passes `abi.encode(uint256(0))` as `hookData` when calling `POOL_MANAGER.unlock()` for swaps. The `0` value delegates slippage protection to the pool hook's own TWAP oracle. Do NOT use empty bytes (`""`) — `JBUniswapV4Hook._beforeSwap()` requires exactly 32 bytes and reverts with `AmountOutMinRequired` otherwise.
- **Composition with JBUniswapV4Hook**: In production, `ORACLE_HOOK` is typically `JBUniswapV4Hook`, which also serves as the V4 pool hook (`PoolKey.hooks`). When the buyback hook swaps, `JBUniswapV4Hook._beforeSwap()` fires and may try to re-route through Juicebox, creating a reentrancy loop. `JBUniswapV4Hook`'s `_routing` guard catches this and reverts the inner swap. The buyback hook's try/catch then falls back to minting. This is expected behavior.
- **Mint permission**: `hasMintPermissionFor` returns `false` on `JBBuybackHook` but returns `addr == address(hook)` on `JBBuybackHookRegistry`. The registry grants mint permission to whichever hook is active for the project.
- **Registry locking**: `lockHookFor(projectId, expectedHook)` snapshots the default into `_hookOf[projectId]` if the project hasn't explicitly set one. The `expectedHook` parameter prevents race conditions: if the resolved hook differs from what the caller expects, it reverts with `HookMismatch`. This prevents a later `setDefaultHook` from changing the locked project's hook.
- **Registry setDefaultHook**: `setDefaultHook(address(0))` reverts with `ZeroHook` to prevent DoS when projects without a specific hook try to use the default.
- **Registry disallowHook**: `disallowHook` reverts with `JBBuybackHookRegistry_CannotDisallowDefaultHook` if the hook being disallowed is the current default. The owner must call `setDefaultHook` to change the default before disallowing the old one.
- **Currency conversion**: When the payment currency differs from the ruleset's base currency, the hook queries `PRICES.pricePerUnitOf(...)` for the conversion factor. This is used both in `beforePayRecordedWith` (for comparing mint vs swap) and in `afterPayRecordedWith` (for computing leftover mint tokens).
- **Dynamic-fee pools**: The slippage calculation in `_getQuote` reads the LP fee from `POOL_MANAGER.getSlot0()` rather than from `key.fee`. For dynamic-fee pools (where `key.fee` is a flag, not the actual fee), this ensures the sigmoid slippage uses the real LP fee. For standard pools, `slot0.lpFee == key.fee`.
- **`setTwapWindowOf` requires a pool**: `setTwapWindowOf` reverts with `JBBuybackHook_PoolNotSet()` if no pool has been configured for the project/terminal token pair. Configure the pool first via `setPoolFor` or `initializePoolFor`.
- **`forceApprove(0)` after `addToBalanceOf`**: After returning ERC-20 leftover tokens to the terminal via `addToBalanceOf`, the hook resets the terminal's allowance to 0. This prevents leaving a residual approval that could be exploited if the terminal contract were compromised.

## Example Integration

```solidity
import {JBBuybackHook} from "@bananapus/buyback-hook-v6/src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/JBBuybackHookRegistry.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

// Deploy the registry (owner-managed)
JBBuybackHookRegistry registry = new JBBuybackHookRegistry(
    permissions,
    projects,
    registryOwner,     // address that manages the hook allowlist
    trustedForwarder
);

// Deploy the buyback hook (8 constructor params — includes oracleHook)
JBBuybackHook hook = new JBBuybackHook(
    directory,
    permissions,
    prices,
    projects,
    tokens,
    IPoolManager(poolManager),
    IHooks(oracleHook),      // ORACLE_HOOK immutable — used in all pool keys
    trustedForwarder
);

// Register the hook as the default
registry.setDefaultHook(hook);

// Configure a V4 pool for project 1 with a 30-minute TWAP
// The pool must already be initialized in the V4 PoolManager.
address projectToken = address(tokens.tokenOf(1));

// Simplified overload — constructs the PoolKey using ORACLE_HOOK automatically.
// The pool must already be initialized in the V4 PoolManager.
hook.setPoolFor({
    projectId: 1,
    fee: 3000,              // 0.3% in V4 fee units (hundredths of a bip)
    tickSpacing: 60,
    twapWindow: 30 minutes,
    terminalToken: JBConstants.NATIVE_TOKEN  // normalized to address(0) internally
});

// Or use initializePoolFor to atomically create the pool and configure the hook:
// hook.initializePoolFor({
//     projectId: 1,
//     fee: 3000,
//     tickSpacing: 60,
//     twapWindow: 30 minutes,
//     terminalToken: JBConstants.NATIVE_TOKEN,
//     sqrtPriceX96: initialPrice
// });

// Set the registry as the project's data hook in the ruleset config:
// rulesetConfig.metadata.useDataHookForPay = true;
// rulesetConfig.metadata.dataHook = address(registry);

// Now when someone pays project 1, the registry delegates to the hook,
// which compares mint vs swap and takes the better route.
```
