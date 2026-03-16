# nana-buyback-hook-v6 Changelog (v5 → v6)

This document describes all changes between `nana-buyback-hook` (v5) and `nana-buyback-hook-v6` (v6).

---

## 1. Breaking Changes

### Uniswap V3 → V4 Migration
- **All Uniswap V3 dependencies replaced with Uniswap V4.** The hook now swaps through V4's `IPoolManager` singleton instead of interacting with individual `IUniswapV3Pool` contracts.
- `IJBBuybackHook` no longer extends `IUniswapV3SwapCallback`. It extends only `IJBPayHook` and `IJBRulesetDataHook`.
- `JBBuybackHook` now implements `IUnlockCallback` (V4's callback pattern) instead of `IUniswapV3SwapCallback`.
- The `uniswapV3SwapCallback` function is removed entirely. Replaced by `unlockCallback(bytes calldata data)`.

### Constructor Changes
- **`JBBuybackHook` constructor:** `IWETH9 weth` and `address factory` parameters replaced with `IPoolManager poolManager` and `IHooks oracleHook`.
- WETH wrapping/unwrapping is no longer needed — V4's PoolManager handles native ETH natively via `Currency.wrap(address(0))`.

### Pool Storage
- `poolOf(uint256 projectId, address terminalToken) → IUniswapV3Pool` replaced with `poolKeyOf(uint256 projectId, address terminalToken) → PoolKey memory`. Returns a full V4 `PoolKey` struct instead of a pool address.
- `_poolKeyOf` is an internal mapping; the public accessor `poolKeyOf()` is a view function (not a direct storage getter) that returns a memory struct.

### `setPoolFor` Signature Changes
- **v5:** `setPoolFor(uint256 projectId, uint24 fee, uint256 twapWindow, address terminalToken) → IUniswapV3Pool`
- **v6 overload 1:** `setPoolFor(uint256 projectId, PoolKey calldata poolKey, uint256 twapWindow, address terminalToken)` — accepts a full V4 `PoolKey`. No return value.
- **v6 overload 2:** `setPoolFor(uint256 projectId, uint24 fee, int24 tickSpacing, uint256 twapWindow, address terminalToken)` — adds `tickSpacing` parameter (required by V4). No return value.
- v5 returned `IUniswapV3Pool newPool`. v6 returns nothing (`void`).
- v5 computed pool addresses via CREATE2. v6 validates the pool is initialized in the PoolManager via `getSlot0()`.

### `setTwapWindowOf` Signature Change
- **v5:** `setTwapWindowOf(uint256 projectId, uint256 newWindow)` — single global TWAP window per project.
- **v6:** `setTwapWindowOf(uint256 projectId, address terminalToken, uint256 newWindow)` — per-project, per-terminal-token TWAP window.

### TWAP Window Storage
- **v5:** `mapping(uint256 projectId => uint256) twapWindowOf` — one TWAP window per project.
- **v6:** `mapping(uint256 projectId => mapping(address terminalToken => uint256)) twapWindowOf` — one TWAP window per project/terminal token pair.

### Terminal Token Normalization
- **v5:** Native token payments use `address(WETH)` as the internal key for pool lookups and swaps.
- **v6:** Native token payments use `address(0)` as the internal key. V4's `Currency` type treats `address(0)` as native ETH.

### `lockHookFor` Signature Change (Registry)
- **v5:** `lockHookFor(uint256 projectId)` — no protection against race conditions.
- **v6:** `lockHookFor(uint256 projectId, IJBRulesetDataHook expectedHook)` — requires the caller to specify the expected hook, preventing race conditions where the hook changes between transaction submission and execution.

### Permission ID Changes (Registry)
- **v5:** `lockHookFor` and `setHookFor` use `JBPermissionIds.SET_BUYBACK_POOL`.
- **v6:** `lockHookFor` and `setHookFor` use `JBPermissionIds.SET_BUYBACK_HOOK`. `setPoolFor`/`initializePoolFor` continue using `SET_BUYBACK_POOL`.

### Removed Constants and Immutables
- `UNISWAP_V3_FACTORY` — removed (V4 uses a singleton PoolManager, no factory).
- `WETH` — removed (V4 handles native ETH natively).
- `UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE` — removed (replaced by continuous sigmoid slippage in `JBSwapLib`).

### Removed Error
- `JBBuybackHook_ZeroTerminalToken` — removed. Terminal token is now normalized to `address(0)` for native, so a zero address is valid.

### Removed File
- `src/interfaces/external/IWETH9.sol` — removed (WETH no longer used).

### Solidity Version
- **v5:** `pragma solidity 0.8.23`
- **v6:** `pragma solidity 0.8.26`

---

## 2. New Features

### `initializePoolFor` (JBBuybackHook)
```solidity
function initializePoolFor(
    uint256 projectId,
    uint24 fee,
    int24 tickSpacing,
    uint256 twapWindow,
    address terminalToken,
    uint160 sqrtPriceX96
) external;
```
Atomically initializes a V4 pool in the PoolManager (via `POOL_MANAGER.initialize()`) and configures it as the buyback pool. This eliminates the need for a separate pool deployment step.

### `initializePoolFor` and `setPoolFor` on Registry
The v6 `JBBuybackHookRegistry` gains forwarding methods that resolve the hook for a project and delegate pool configuration:
- `initializePoolFor(uint256 projectId, uint24 fee, int24 tickSpacing, uint256 twapWindow, address terminalToken, uint160 sqrtPriceX96)`
- `setPoolFor(uint256 projectId, uint24 fee, int24 tickSpacing, uint256 twapWindow, address terminalToken)`

### `JBSwapLib` Library (New File)
A new shared library at `src/libraries/JBSwapLib.sol` extracts and improves swap math for reuse across `JBBuybackHook` and `JBSwapTerminal`:
- `getQuoteFromOracle(...)` — queries a V4 oracle hook for TWAP data, with spot-price fallback.
- `getSlippageTolerance(uint256 impact, uint256 poolFeeBps)` — continuous sigmoid slippage curve (replaces v5's piecewise step function).
- `calculateImpact(...)` — estimates price impact using `1e18` precision (vs v5's `10 * SLIPPAGE_DENOMINATOR`).
- `getQuoteAtTick(...)` — ported from Uniswap V3 `OracleLibrary.getQuoteAtTick`, removing the V3 dependency.
- `sqrtPriceLimitFromAmounts(...)` — computes a V4-compatible `sqrtPriceLimitX96` from input/output amounts so the swap stops if the execution price degrades below the minimum acceptable rate.

### `IGeomeanOracle` Interface (New File)
`src/interfaces/IGeomeanOracle.sol` — interface for V4 oracle hooks that implement the `observe` pattern (e.g., `TruncGeoOracle`). Used by `JBSwapLib.getQuoteFromOracle()` to query TWAP data.

### Pool Initialization Validation
`_setPoolFor` now validates that the pool is actually initialized in the PoolManager by checking `getSlot0()` returns a non-zero `sqrtPriceX96`. If not, it reverts with `JBBuybackHook_PoolNotInitialized(PoolId)`.

### Pool Key Currency Validation
`_setPoolFor` validates that the `PoolKey`'s `currency0` and `currency1` match the project token and terminal token (in either order). Reverts with a require message if they don't match.

### Improved TWAP Quote Logic
In `beforePayRecordedWith`, v6 always computes the TWAP-based minimum and uses the higher of the payer's quote and the TWAP quote. This prevents stale or malicious payer quotes from getting a worse deal than the oracle suggests. In v5, the TWAP was only computed when no payer quote was provided.

### Improved Leftover Balance Tracking
In `afterPayRecordedWith`, v6 records the terminal token balance BEFORE pulling payment tokens and computes leftover as a delta (`balanceAfter - balanceBefore`). This prevents pre-existing balances from inflating leftovers. v5 simply read the contract's balance after the swap.

### Swap Failure Handling
`_swap` now returns a `swapFailed` boolean. When `true`, the slippage check in `afterPayRecordedWith` is skipped, allowing a clean fallback to the mint path. v5 simply returned `0` from `_swap` on failure, which would then fail the slippage check.

### `receive()` Function
v6 adds an explicit `receive() external payable {}` to accept native ETH from V4's `take()` and potential wrapped token unwrap scenarios.

### `POOL_MANAGER` Immutable
```solidity
function POOL_MANAGER() external view returns (IPoolManager);
```
New immutable referencing the V4 PoolManager singleton.

### `ORACLE_HOOK` Immutable
```solidity
IHooks public immutable ORACLE_HOOK;
```
The oracle hook used for all JB V4 pools (provides TWAP via `observe()`). Set at construction time.

### `SwapCallbackData` Struct
New internal struct used to pass data through the V4 unlock callback:
```solidity
struct SwapCallbackData {
    PoolKey key;
    bool projectTokenIs0;
    uint256 amountIn;
    uint256 minimumSwapAmountOut;
    address terminalToken;
}
```

### `MIN_TWAP_WINDOW` Increased
- **v5:** `2 minutes`
- **v6:** `5 minutes`

---

## 3. Event Changes

### `Swap` Event
- **v5:** `event Swap(uint256 indexed projectId, uint256 amountToSwapWith, IUniswapV3Pool pool, uint256 amountReceived, address caller)`
- **v6:** `event Swap(uint256 indexed projectId, uint256 amountToSwapWith, PoolId indexed poolId, uint256 amountReceived, address caller)`
- `IUniswapV3Pool pool` replaced with `PoolId indexed poolId`. The pool ID is now indexed for efficient filtering.

### `PoolAdded` Event
- **v5:** `event PoolAdded(uint256 indexed projectId, address indexed terminalToken, address pool, address caller)`
- **v6:** `event PoolAdded(uint256 indexed projectId, address indexed terminalToken, PoolId poolId, address caller)`
- `address pool` replaced with `PoolId poolId`.

### `TwapWindowChanged` Event
- **v5:** `event TwapWindowChanged(uint256 indexed projectId, uint256 oldWindow, uint256 newWindow, address caller)`
- **v6:** `event TwapWindowChanged(uint256 indexed projectId, address indexed terminalToken, uint256 oldWindow, uint256 newWindow, address caller)`
- Added `address indexed terminalToken` parameter to support per-terminal-token TWAP windows.

### `Mint` Event
Unchanged in signature.

---

## 4. Error Changes

### Added Errors
| Error | Contract | Description |
|---|---|---|
| `JBBuybackHook_CallerNotPoolManager(address)` | `JBBuybackHook` | Replaces `JBBuybackHook_CallerNotPool`. Validates that only the V4 PoolManager can call `unlockCallback`. |
| `JBBuybackHook_PoolNotInitialized(PoolId)` | `JBBuybackHook` | Reverts in `_setPoolFor` when the pool's `sqrtPriceX96` is zero (not initialized in the PoolManager). |
| `JBBuybackHookRegistry_CannotDisallowDefaultHook()` | `JBBuybackHookRegistry` | Prevents disallowing the current default hook, which would break payments for projects relying on it. |
| `JBBuybackHookRegistry_HookMismatch(IJBRulesetDataHook, IJBRulesetDataHook)` | `JBBuybackHookRegistry` | Reverts in `lockHookFor` when the resolved hook doesn't match the caller's expected hook. |
| `JBBuybackHookRegistry_ZeroHook()` | `JBBuybackHookRegistry` | Prevents setting `address(0)` as the default hook. |

### Removed Errors
| Error | Contract | Reason |
|---|---|---|
| `JBBuybackHook_CallerNotPool(address)` | `JBBuybackHook` | Replaced by `JBBuybackHook_CallerNotPoolManager`. |
| `JBBuybackHook_ZeroTerminalToken()` | `JBBuybackHook` | `address(0)` is now a valid terminal token (native ETH in V4). |

### Modified Errors
| Error | Change |
|---|---|
| `JBBuybackHook_PoolAlreadySet(...)` | Parameter changed from `IUniswapV3Pool pool` to `PoolId poolId`. |

---

## 5. Struct Changes

### Added Structs
| Struct | Location | Description |
|---|---|---|
| `SwapCallbackData` | `JBBuybackHook` (internal) | Carries swap parameters through V4's `unlock`/`unlockCallback` pattern. Fields: `key`, `projectTokenIs0`, `amountIn`, `minimumSwapAmountOut`, `terminalToken`. |

---

## 6. Implementation Changes (Non-Interface)

### Swap Mechanism (`_swap`)
- **v5:** Calls `pool.swap(...)` directly on the `IUniswapV3Pool`, which triggers `uniswapV3SwapCallback` to transfer tokens.
- **v6:** Calls `POOL_MANAGER.unlock(callbackData)`, which triggers `unlockCallback`. Inside the callback, executes `POOL_MANAGER.swap(...)`, then settles input tokens via `POOL_MANAGER.settle()` and takes output tokens via `POOL_MANAGER.take()`.
- **v6:** Computes a `sqrtPriceLimitX96` from the minimum acceptable output via `JBSwapLib.sqrtPriceLimitFromAmounts()`, rather than using the hard-coded `TickMath.MAX_SQRT_RATIO - 1` / `TickMath.MIN_SQRT_RATIO + 1`.
- **v6:** Returns `(uint256 amountReceived, bool swapFailed)` tuple instead of just `uint256`.

### Slippage Tolerance Algorithm
- **v5:** Piecewise step function in `_getSlippageTolerance()` with 9 hardcoded tiers. Uses `10 * TWAP_SLIPPAGE_DENOMINATOR` as precision amplifier, which rounds small-swap impacts to zero.
- **v6:** Continuous sigmoid curve in `JBSwapLib.getSlippageTolerance()`: `minSlippage + (maxSlippage - minSlippage) * impact / (impact + K)`. Uses `1e18` precision (`IMPACT_PRECISION`) for sub-basis-point granularity. Pool fee is factored into `minSlippage` (pool fee + 1% buffer, with a floor of 2%).

### Oracle / TWAP Query
- **v5:** Uses Uniswap V3's `OracleLibrary.consult()` and `OracleLibrary.getOldestObservationSecondsAgo()` to get TWAP data. Falls back to spot tick and liquidity when `oldestObservation == 0`.
- **v6:** Uses `JBSwapLib.getQuoteFromOracle()` which calls `IGeomeanOracle(hookAddress).observe()` on the pool's V4 hook. Falls back to `POOL_MANAGER.getSlot0()` / `POOL_MANAGER.getLiquidity()` if the oracle hook reverts or if `twapWindow == 0`.

### Pool Configuration (`_setPoolFor` / `setPoolFor`)
- **v5:** Computes the pool address via CREATE2 hash (keccak256 of factory, token pair, fee, init code hash). Stores pool address directly.
- **v6:** Accepts a `PoolKey` directly or constructs one from `(fee, tickSpacing, oracleHook)`. Validates the pool is initialized via `POOL_MANAGER.getSlot0()`. Validates currency pair matches project/terminal tokens. Uses a `_poolIsSet` boolean mapping to track whether a pool has been configured (since default `PoolKey` has all-zero fields).

### Registry: `hookOf` Storage
- **v5:** `mapping(uint256 projectId => IJBRulesetDataHook) public override hookOf` — public storage mapping (direct getter). Default-fallback logic duplicated in `beforePayRecordedWith`, `hasMintPermissionFor`, and `lockHookFor`.
- **v6:** `mapping(uint256 projectId => IJBRulesetDataHook) internal _hookOf` — internal storage. A public `hookOf(uint256)` view function applies the default-hook fallback in one place.

### Registry: `disallowHook` Safety
- **v5:** No check — the default hook can be disallowed, which would break payments for projects using it.
- **v6:** Reverts with `JBBuybackHookRegistry_CannotDisallowDefaultHook()` if the hook being disallowed is the current default.

### Registry: `setDefaultHook` Safety
- **v5:** No check — `address(0)` can be set as the default hook.
- **v6:** Reverts with `JBBuybackHookRegistry_ZeroHook()` if `address(0)` is passed.

### Registry: `lockHookFor` Race Condition Protection
- **v5:** Locks whatever hook is currently set. If no hook is set, copies the default into `hookOf[projectId]` before locking.
- **v6:** Requires an `expectedHook` parameter. Reverts with `JBBuybackHookRegistry_HookMismatch` if the resolved hook doesn't match.

### Import Changes
- `@bananapus/core-v5` → `@bananapus/core-v6`
- `@bananapus/permission-ids-v5` → `@bananapus/permission-ids-v6`
- `@uniswap/v3-core` and `@uniswap/v3-periphery` → `@uniswap/v4-core`
- `ERC165` (abstract contract) → `IERC165` (interface only) for the import in `JBBuybackHookRegistry`

---

## 7. Migration Table

| v5 | v6 | Notes |
|---|---|---|
| `UNISWAP_V3_FACTORY` | Removed | V4 uses singleton `POOL_MANAGER` |
| `WETH` | Removed | V4 handles native ETH via `Currency.wrap(address(0))` |
| `UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE` | Removed | Replaced by sigmoid curve in `JBSwapLib` |
| `poolOf[projectId][token]` | `poolKeyOf(projectId, token)` | Returns `PoolKey memory` instead of `IUniswapV3Pool` |
| `twapWindowOf[projectId]` | `twapWindowOf[projectId][terminalToken]` | Now per-terminal-token |
| `setPoolFor(id, fee, twap, token)` | `setPoolFor(id, fee, tickSpacing, twap, token)` | Added `tickSpacing`; no return value |
| `setPoolFor(id, fee, twap, token)` | `setPoolFor(id, PoolKey, twap, token)` | New overload accepting full `PoolKey` |
| N/A | `initializePoolFor(id, fee, tickSpacing, twap, token, sqrtPrice)` | New: atomically init + configure pool |
| `setTwapWindowOf(id, window)` | `setTwapWindowOf(id, token, window)` | Added `terminalToken` parameter |
| `uniswapV3SwapCallback(...)` | `unlockCallback(bytes)` | V3 callback → V4 unlock callback |
| `_getSlippageTolerance(...)` | `JBSwapLib.getSlippageTolerance(impact, feeBps)` | Piecewise steps → continuous sigmoid |
| `_getQuote(...)` | `_getQuote(...)` + `JBSwapLib.getQuoteFromOracle(...)` | V3 OracleLibrary → V4 oracle hook |
| `OracleLibrary.getQuoteAtTick(...)` | `JBSwapLib.getQuoteAtTick(...)` | Ported inline, no V3 dependency |
| `lockHookFor(projectId)` | `lockHookFor(projectId, expectedHook)` | Added race condition protection |
| `hookOf` (public mapping) | `_hookOf` (internal) + `hookOf()` (view) | Encapsulates default-hook fallback |
| `IWETH9` interface | Removed | No longer needed |
| N/A | `IGeomeanOracle` interface | New: V4 oracle hook interface |
| N/A | `JBSwapLib` library | New: shared swap math library |
| `JBPermissionIds.SET_BUYBACK_POOL` (for registry lock/set) | `JBPermissionIds.SET_BUYBACK_HOOK` (for registry lock/set) | Distinct permission for hook vs pool config |
| `MIN_TWAP_WINDOW = 2 minutes` | `MIN_TWAP_WINDOW = 5 minutes` | Increased minimum |
