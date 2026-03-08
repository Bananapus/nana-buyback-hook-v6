# Juicebox Buyback Hook

## Purpose

Route project payments through the better of two paths -- minting from the terminal or buying from a Uniswap V4 pool -- to maximize tokens received by the beneficiary while preserving the reserved rate.

## Contracts

| Contract | Role |
|----------|------|
| `JBBuybackHook` | Core hook: implements `IJBRulesetDataHook` + `IJBPayHook` + `IUnlockCallback`. Compares mint vs swap via TWAP oracle or spot price, executes the better route through V4 PoolManager, burns swapped tokens, re-mints through controller with reserved rate. |
| `JBBuybackHookRegistry` | Proxy data hook with allowlist. Routes `beforePayRecordedWith` to a per-project or default `JBBuybackHook`. Project owners choose, and optionally lock, implementations. Registry owner manages the allowlist. |
| `JBSwapLib` | Library for oracle queries (TWAP or spot), sigmoid-based slippage tolerance, price impact estimation, tick-to-price conversion, and `sqrtPriceLimitX96` computation. |

## Key Functions

### JBBuybackHook

| Function | What it does |
|----------|--------------|
| `beforePayRecordedWith(context)` | Data hook (view): compares mint count vs swap quote. Reads `"quote"` metadata for payer-supplied `(amountToSwapWith, minimumSwapAmountOut)`. Computes TWAP-based minimum and uses the higher of the two. If swap yields more tokens, returns `weight=0` and a `JBPayHookSpecification` targeting itself. If mint is better, returns original weight (no hook). |
| `afterPayRecordedWith(context)` | Pay hook: pulls tokens from terminal, executes V4 swap via `POOL_MANAGER.unlock()`, burns swapped tokens, returns leftover to project balance via `addToBalanceOf`, mints total (swapped + leftover mint) via `controller.mintTokensOf` with `useReservedPercent: true`. Reverts with `JBBuybackHook_SpecifiedSlippageExceeded` if swap output < minimum. |
| `setPoolFor(projectId, poolKey, twapWindow, terminalToken)` | Set the V4 pool for a project+terminal token pair. Validates: pool is initialized in PoolManager, currencies match project token and terminal token, TWAP window in bounds. Stores pool key, TWAP window, and project token. **Immutable once set.** Permission: `SET_BUYBACK_POOL` (ID 26). |
| `setTwapWindowOf(projectId, newWindow)` | Change the TWAP window for a project (5 minutes to 2 days). Permission: `SET_BUYBACK_TWAP` (ID 25). |
| `unlockCallback(data)` | V4 PoolManager callback. Decodes `SwapCallbackData`, computes `sqrtPriceLimitX96`, executes swap, settles input tokens, takes output tokens. Only callable by PoolManager. |
| `poolKeyOf(projectId, terminalToken)` | Returns the V4 `PoolKey` for a project+terminal token pair. |
| `beforeCashOutRecordedWith(context)` | Pass-through: returns cash-out context unchanged (buyback only applies to payments). |
| `hasMintPermissionFor(projectId, ruleset, addr)` | Returns `false` (the hook itself does not claim mint permission -- the registry handles this). |
| `supportsInterface(interfaceId)` | Returns `true` for `IJBRulesetDataHook`, `IJBPayHook`, `IJBBuybackHook`, `IJBPermissioned`, `IERC165`. |

### JBBuybackHookRegistry

| Function | What it does |
|----------|--------------|
| `hookOf(projectId)` | Returns the hook for the project, falling back to `defaultHook` if none is set. |
| `beforePayRecordedWith(context)` | Resolves the project's hook (or default) and delegates the call. |
| `beforeCashOutRecordedWith(context)` | Pass-through: returns cash-out context unchanged. |
| `hasMintPermissionFor(projectId, ruleset, addr)` | Returns `true` only if `addr` is the hook registered (or defaulted) for the project. |
| `setHookFor(projectId, hook)` | Route a project to a specific allowed buyback hook. Reverts if hook is locked or not on the allowlist. Permission: `SET_BUYBACK_HOOK` (ID 27). |
| `lockHookFor(projectId, expectedHook)` | Lock the hook choice for a project (irreversible). If using default, snapshots it into storage first. Requires a non-zero hook. Reverts with `JBBuybackHookRegistry_HookMismatch` if the resolved hook differs from `expectedHook` (prevents race conditions). Permission: `SET_BUYBACK_HOOK` (ID 27). |
| `allowHook(hook)` | Add a hook to the allowlist. Owner only. |
| `disallowHook(hook)` | Remove a hook from the allowlist. If the disallowed hook is the current default, also clears the default. Owner only. |
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
| `nana-permission-ids-v6` | `JBPermissionIds` | Permission ID constants (`SET_BUYBACK_TWAP` = 25, `SET_BUYBACK_POOL` = 26, `SET_BUYBACK_HOOK` = 27) |
| `@uniswap/v4-core` | `IPoolManager`, `IUnlockCallback`, `PoolKey`, `PoolId`, `Currency`, `BalanceDelta`, `SwapParams`, `TickMath`, `StateLibrary` | V4 pool swaps (`unlock`, `swap`, `settle`, `take`), pool state queries (`getSlot0`, `getLiquidity`), tick math |
| `@prb/math` | `mulDiv` | Safe fixed-point multiplication |
| `@openzeppelin/contracts` | `ERC2771Context`, `SafeERC20`, `Ownable` (registry only) | Meta-transactions, safe token transfers, registry ownership |

## Key Types

| Struct/Type | Fields | Used In |
|-------------|--------|---------|
| `SwapCallbackData` (internal to `JBBuybackHook`) | `key` (PoolKey), `projectTokenIs0` (bool), `amountIn` (uint256), `minimumSwapAmountOut` (uint256), `terminalToken` (address) | Encoded as `bytes` for `POOL_MANAGER.unlock()`, decoded in `unlockCallback` |
| `PoolKey` (Uniswap V4) | `currency0` (Currency), `currency1` (Currency), `fee` (uint24), `tickSpacing` (int24), `hooks` (IHooks) | Stored per project+terminalToken in `_poolKeyOf`. Passed to `setPoolFor`. |
| `JBBeforePayRecordedContext` | `projectId`, `amount` (token, value, decimals, currency), `weight`, `metadata` | Input to `beforePayRecordedWith` |
| `JBAfterPayRecordedContext` | `projectId`, `forwardedAmount`, `weight`, `beneficiary`, `hookMetadata` | Input to `afterPayRecordedWith` |
| `JBPayHookSpecification` | `hook` (IJBPayHook), `amount` (uint256), `metadata` (bytes) | Returned from `beforePayRecordedWith` when swap is chosen |
| `JBRuleset` | `baseCurrency()` (from packed metadata) | Used for cross-currency weight adjustment |

## JBSwapLib Details

| Function | What it does |
|----------|--------------|
| `getQuoteFromOracle(poolManager, key, twapWindow, amountIn, baseToken, quoteToken)` | Queries the pool's oracle hook via `IGeomeanOracle.observe` for TWAP data. If `twapWindow == 0` or the oracle reverts, falls back to spot price from `poolManager.getSlot0`. Returns `(amountOut, arithmeticMeanTick, harmonicMeanLiquidity)`. |
| `getSlippageTolerance(impact, poolFeeBps)` | Continuous sigmoid: `minSlippage + (maxSlippage - minSlippage) * impact / (impact + K)`. Min = pool fee + 1% (floor 2%), max = 88%. K = 5e16. Returns tolerance in basis points of `SLIPPAGE_DENOMINATOR` (10,000). |
| `calculateImpact(amountIn, liquidity, sqrtP, zeroForOne)` | Estimates price impact scaled by `IMPACT_PRECISION` (1e18): `amountIn * 1e18 / liquidity`, normalized by sqrtPrice direction. Returns 0 when liquidity or sqrtP is 0. |
| `getQuoteAtTick(tick, baseAmount, baseToken, quoteToken)` | Converts a tick to a price and returns the equivalent quote amount. Ported from Uniswap V3 `OracleLibrary.getQuoteAtTick` -- pure math, no V3 dependency. |
| `sqrtPriceLimitFromAmounts(amountIn, minimumAmountOut, zeroForOne)` | Computes a `sqrtPriceLimitX96` from the minimum acceptable swap rate. Provides MEV protection by stopping the swap if the execution price would be worse than the minimum. Handles extreme ratios gracefully with fallback to no limit. |

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

## Permission IDs

| ID | Constant | Used By | Grants |
|----|----------|---------|--------|
| 25 | `SET_BUYBACK_TWAP` | `JBBuybackHook.setTwapWindowOf` | Change the TWAP window for a project |
| 26 | `SET_BUYBACK_POOL` | `JBBuybackHook.setPoolFor` | Set the V4 pool for a project+terminal token pair |
| 27 | `SET_BUYBACK_HOOK` | `JBBuybackHookRegistry.setHookFor`, `lockHookFor` | Choose and lock the hook implementation for a project |

## Events

### JBBuybackHook

| Event | Fields |
|-------|--------|
| `Swap` | `projectId` (indexed), `amountToSwapWith`, `poolId` (indexed), `amountReceived`, `caller` |
| `Mint` | `projectId` (indexed), `leftoverAmount`, `tokenCount`, `caller` |
| `PoolAdded` | `projectId` (indexed), `terminalToken` (indexed), `poolId`, `caller` |
| `TwapWindowChanged` | `projectId` (indexed), `oldWindow`, `newWindow`, `caller` |

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
| `JBBuybackHook_InsufficientPayAmount(uint256 swapAmount, uint256 totalPaid)` | Metadata specifies `amountToSwapWith > totalPaid` |
| `JBBuybackHook_InvalidTwapWindow(uint256 value, uint256 min, uint256 max)` | TWAP window outside [5 minutes, 2 days] |
| `JBBuybackHook_PoolAlreadySet(PoolId poolId)` | `setPoolFor` called again for same project+token pair |
| `JBBuybackHook_PoolNotInitialized(PoolId poolId)` | Pool not initialized in V4 PoolManager (sqrtPriceX96 == 0) |
| `JBBuybackHook_SpecifiedSlippageExceeded(uint256 amount, uint256 minimum)` | Swap output less than minimum acceptable amount |
| `JBBuybackHook_TerminalTokenIsProjectToken(address, address)` | Terminal token same as project token |
| `JBBuybackHook_Unauthorized(address caller)` | `afterPayRecordedWith` called by non-terminal |
| `JBBuybackHook_ZeroProjectToken()` | Project has not issued an ERC-20 token |
| `JBBuybackHook_ZeroTerminalToken()` | Terminal token resolves to address(0) |

### JBBuybackHookRegistry

| Error | When |
|-------|------|
| `JBBuybackHookRegistry_HookLocked(uint256 projectId)` | `setHookFor` called on a locked project |
| `JBBuybackHookRegistry_HookMismatch(IJBRulesetDataHook currentHook, IJBRulesetDataHook expectedHook)` | `lockHookFor` called but resolved hook differs from the caller's `expectedHook` |
| `JBBuybackHookRegistry_HookNotAllowed(IJBRulesetDataHook hook)` | `setHookFor` called with a hook not on the allowlist |
| `JBBuybackHookRegistry_HookNotSet(uint256 projectId)` | `lockHookFor` called but no hook is set and no default exists |
| `JBBuybackHookRegistry_ZeroHook()` | `setDefaultHook` called with `address(0)` |

## Gotchas

- **V4, not V3**: This version uses Uniswap V4 (`IPoolManager`, `PoolKey`, `unlock`/`unlockCallback`). There is no `IUniswapV3Pool`, no `uniswapV3SwapCallback`, no create2 pool address derivation, and no factory. Pools are identified by their `PoolKey` and must be initialized in the V4 PoolManager before calling `setPoolFor`.
- **Pool immutability**: `setPoolFor` can only be called once per project+terminalToken pair. After the pool key is stored, calling again reverts with `JBBuybackHook_PoolAlreadySet`. This is intentional to prevent swap routing manipulation.
- **PoolKey validation**: `setPoolFor` validates that the PoolKey's `currency0`/`currency1` match the project token and normalized terminal token. It also checks that the pool is initialized (sqrtPriceX96 != 0).
- **Burn-and-remint**: Tokens received from the swap are burned via `controller.burnTokensOf`, then re-minted (along with any leftover-mint count) via `controller.mintTokensOf` with `useReservedPercent: true`. This ensures the reserved rate applies uniformly regardless of the payment route.
- **Swap failure fallback**: If the V4 `POOL_MANAGER.unlock()` call reverts (slippage, insufficient liquidity, etc.), `_swap` catches it with try-catch and returns `(0, true)`. The `swapFailed` flag bypasses the slippage check, allowing the payment to fall through to the mint path. Any WETH wrapped for the swap is unwrapped back to ETH so leftover accounting remains correct.
- **TWAP oracle fallback**: When the oracle hook is absent or `observe()` reverts, `JBSwapLib.getQuoteFromOracle` falls back to spot price from `poolManager.getSlot0()` and current liquidity from `poolManager.getLiquidity()`.
- **Zero liquidity protection**: If the oracle/spot returns zero liquidity (`harmonicMeanLiquidity == 0`), `_getQuote` returns 0, which ensures the hook falls back to minting rather than attempting a swap in an empty pool.
- **Sigmoid slippage ceiling**: If `getSlippageTolerance` returns `>= TWAP_SLIPPAGE_DENOMINATOR` (10,000 bps = 100%), `_getQuote` returns 0 to trigger mint fallback.
- **Quote floor**: `beforePayRecordedWith` uses the **higher** of the payer's supplied `minimumSwapAmountOut` and the TWAP-derived minimum. A stale or manipulated payer quote cannot produce a worse deal than the oracle suggests.
- **sqrtPriceLimitX96 protection**: The `unlockCallback` computes a `sqrtPriceLimitX96` from `amountIn` and `minimumSwapAmountOut`. The V4 swap stops early if the price moves beyond this limit, providing on-chain MEV protection.
- **`beforePayRecordedWith` is a `view` function**: It cannot modify state. All swap execution happens in `afterPayRecordedWith`.
- **Terminal validation**: `afterPayRecordedWith` validates that `msg.sender` is a registered terminal of the project via `DIRECTORY.isTerminalOf(projectId, IJBTerminal(msg.sender))`.
- **Native token handling**: When the terminal token is `JBConstants.NATIVE_TOKEN`, the hook normalizes to WETH for storage and pool lookups. For V4 settlement, if the pool's input currency is `address(0)` (native ETH), it uses `settle{value:}`; otherwise it wraps to WETH first via `WETH.deposit{value:}`.
- **Metadata key**: `"quote"` encodes `(uint256 amountToSwapWith, uint256 minimumSwapAmountOut)`. If `amountToSwapWith == 0`, the full payment amount is used. If not provided at all, same behavior.
- **State variable names**: Public: `projectTokenOf[projectId]`, `twapWindowOf[projectId]`. Internal with public getter: `poolKeyOf(projectId, terminalToken)` (backed by `_poolKeyOf`). Internal only: `_poolIsSet[projectId][terminalToken]`.
- **ERC-2771**: `_msgSender()` (ERC-2771) is used instead of `msg.sender` for meta-transaction compatibility in permissioned functions (`setPoolFor`, `setTwapWindowOf`).
- **Mint permission**: `hasMintPermissionFor` returns `false` on `JBBuybackHook` but returns `addr == address(hook)` on `JBBuybackHookRegistry`. The registry grants mint permission to whichever hook is active for the project.
- **Registry locking**: `lockHookFor(projectId, expectedHook)` snapshots the default into `_hookOf[projectId]` if the project hasn't explicitly set one. The `expectedHook` parameter prevents race conditions: if the resolved hook differs from what the caller expects, it reverts with `HookMismatch`. This prevents a later `setDefaultHook` from changing the locked project's hook.
- **Registry setDefaultHook**: `setDefaultHook(address(0))` reverts with `ZeroHook` to prevent DoS when projects without a specific hook try to use the default.
- **Registry disallowHook**: If `disallowHook` removes the current default, it also clears `defaultHook` to `address(0)`.
- **Currency conversion**: When the payment currency differs from the ruleset's base currency, the hook queries `PRICES.pricePerUnitOf(...)` for the conversion factor. This is used both in `beforePayRecordedWith` (for comparing mint vs swap) and in `afterPayRecordedWith` (for computing leftover mint tokens).

## Example Integration

```solidity
import {JBBuybackHook} from "@bananapus/buyback-hook-v6/src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/JBBuybackHookRegistry.sol";
import {IWETH9} from "@bananapus/buyback-hook-v6/src/interfaces/external/IWETH9.sol";
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

// Deploy the buyback hook
JBBuybackHook hook = new JBBuybackHook(
    directory,
    permissions,
    prices,
    projects,
    tokens,
    IWETH9(weth),
    IPoolManager(poolManager),
    trustedForwarder
);

// Register the hook as the default
registry.setDefaultHook(hook);

// Configure a V4 pool for project 1 with a 30-minute TWAP
// The pool must already be initialized in the V4 PoolManager.
address projectToken = address(tokens.tokenOf(1));

hook.setPoolFor({
    projectId: 1,
    poolKey: PoolKey({
        currency0: Currency.wrap(projectToken < weth ? projectToken : weth),
        currency1: Currency.wrap(projectToken < weth ? weth : projectToken),
        fee: 3000,          // 0.3% in V4 fee units (hundredths of a bip)
        tickSpacing: 60,
        hooks: IHooks(address(0))  // or an oracle hook address
    }),
    twapWindow: 30 minutes,
    terminalToken: JBConstants.NATIVE_TOKEN  // or address(weth)
});

// Set the registry as the project's data hook in the ruleset config:
// rulesetConfig.metadata.useDataHookForPay = true;
// rulesetConfig.metadata.dataHook = address(registry);

// Now when someone pays project 1, the registry delegates to the hook,
// which compares mint vs swap and takes the better route.
```
