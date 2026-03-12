# nana-buyback-hook-v6 -- Risks

Deep implementation-level risk analysis based on line-by-line code review of all source and test files.

## Trust Assumptions

1. **Uniswap V4 PoolManager** -- The contract trusts `POOL_MANAGER` as an immutable singleton. All swap settlement flows through `unlock()` -> `unlockCallback()` -> `swap()` -> `settle()`/`take()`. If the PoolManager implementation has bugs, fund safety depends entirely on V4's correctness. The hook validates `msg.sender == address(POOL_MANAGER)` in `unlockCallback` (line 411), but has no defense against a compromised PoolManager.

2. **Oracle Hook (IGeomeanOracle)** -- TWAP integrity depends on the oracle hook attached to the pool's `hooks` field. The contract queries `IGeomeanOracle(address(key.hooks)).observe(key, secondsAgos)` (JBSwapLib.sol line 75). If the oracle hook is absent, compromised, or returns manipulated cumulatives, the TWAP-based minimum can be gamed. The fallback to spot price (JBSwapLib.sol lines 98-107) when the oracle reverts exposes the swap to single-block manipulation.

3. **JB Core Protocol** -- The hook trusts that `DIRECTORY.isTerminalOf()` accurately gates terminal access (line 195), that `controller.currentRulesetOf()` returns the correct ruleset and metadata, and that `controller.mintTokensOf()` / `burnTokensOf()` execute correctly. A compromised or malicious controller could mint arbitrary tokens or fail to burn swapped tokens.

4. **Project Owner** -- Can set TWAP window (`SET_BUYBACK_TWAP`), configure pools (`SET_BUYBACK_POOL`), and register hooks via registry (`SET_BUYBACK_HOOK`). A malicious project owner could set a 2-day TWAP window (maximum) that lags real price movements, or configure a low-liquidity pool. However, pools are **immutable once set** (`_poolIsSet` flag, line 330-332), which prevents post-configuration pool-swapping attacks.

5. **Registry Owner** -- `JBBuybackHookRegistry` has an `Ownable` owner who can `allowHook()`, `disallowHook()`, and `setDefaultHook()`. This is a centralization point: the owner controls which hook implementations are available to all projects. Disallowing a hook does not affect projects that have already locked it.

6. **Token Immutability** -- `projectTokenOf[projectId]` is cached in `setPoolFor()` (line 375). This relies on `JBTokens` preventing token migration after deployment. Test file `JBBuybackHook_FalsePositives.t.sol` explicitly proves that `JBTokens.setTokenFor()` and `deployERC20For()` both revert with `JBTokens_ProjectAlreadyHasToken` after initial deployment, confirming the cache can never become stale.

## Known Risks

### Critical Path: Swap-vs-Mint Decision (beforePayRecordedWith, lines 507-597)

| Risk | Severity | Description | Mitigation |
|------|----------|-------------|------------|
| Spot price fallback when oracle reverts | MEDIUM | When `IGeomeanOracle.observe()` reverts (JBSwapLib.sol line 97 catch block), the library falls back to spot price via `poolManager.getSlot0()`. Spot price is trivially manipulable within a single block, enabling an attacker to push the spot price to make `minimumSwapAmountOut = 0`, forcing the mint path (value extraction if mint rate < market rate) or pushing it high enough to force a swap at an unfavorable price. | The sigmoid slippage tolerance still applies to the spot-derived quote. When `harmonicMeanLiquidity = 0` (line 746) or `amountOut = 0` (line 743), the function returns 0, triggering the mint fallback. Additionally, the TWAP cross-validation at line 575 ensures `max(payerQuote, twapQuote)` is used, so a client-provided quote can override a weak oracle. |
| Zero-liquidity pool returns zero impact | LOW | `calculateImpact()` returns 0 when `liquidity == 0` (JBSwapLib.sol line 165). This causes `getSlippageTolerance()` to return `minSlippage` (the floor), which may be too tight for a truly illiquid pool, causing unnecessary mint fallbacks. | By design -- zero liquidity means the pool cannot execute swaps, so minting is the correct fallback. |
| `amountToSwapWith` defaults to `totalPaid` | INFO | When no payer metadata specifies `amountToSwapWith`, it defaults to `totalPaid` (line 537). This means the entire payment routes through the swap, with no portion reserved for minting. If the swap partially fills, the leftover is re-added to the terminal and minted proportionally. | Partial fills are handled correctly: leftover is computed via balance delta (lines 241-242) and minted at the current weight (lines 260-288). |

### Swap Execution (afterPayRecordedWith, lines 193-303)

| Risk | Severity | Description | Mitigation |
|------|----------|-------------|------------|
| Swap failure with non-zero minimum | MEDIUM (FIXED) | Before the fix (regression test M34), when `POOL_MANAGER.unlock()` reverted and `minimumSwapAmountOut > 0`, the slippage check at line 230 (`exactSwapAmountOut < minimumSwapAmountOut` where `exactSwapAmountOut = 0`) would revert with `SpecifiedSlippageExceeded`, preventing the mint fallback. | Fixed by adding `swapFailed` flag (line 220-221). When `swapFailed == true`, the slippage check is skipped (line 230), allowing the mint fallback path. Verified by `M34_SwapFailureMintFallback.t.sol`. |
| Balance delta underflow for native ETH | MEDIUM (FIXED) | Before the fix (regression test L44), `balanceBefore` included `msg.value` (since ETH was already in the contract at call time). When the swap consumed the ETH, `balanceAfter < balanceBefore`, causing underflow. | Fixed by subtracting `msg.value` from `balanceBefore` for native token payments (line 208-209). For ERC-20, `balanceBefore` is captured before `safeTransferFrom` (line 207 precedes line 214-215). Verified by `L44_BalanceDeltaLeftover.t.sol`. |
| Pre-existing ETH balance inflation | LOW (FIXED) | If the hook contract held ETH from a previous transaction, the old absolute-balance approach would count it as leftover and mint extra tokens. | Fixed by the delta-based approach: `leftover = balanceAfter - balanceBefore`. Pre-existing balance cancels out. Verified by `test_nativeETH_preExistingBalance_notInflated`. |
| Reentrancy via controller.mintTokensOf | LOW | After swap and burn, `controller.mintTokensOf()` (line 296) is an external call. A malicious controller could reenter `afterPayRecordedWith`. | The hook has no exploitable state between the burn (line 690-693) and mint (line 296-302). The swap is already settled with the PoolManager, tokens are burned, and the mint is the final operation. A reentrant call from a different terminal payment would be gated by `DIRECTORY.isTerminalOf()` and would operate on independent state. |
| `addToBalanceOf` failure for leftover | LOW | If the terminal's `addToBalanceOf` (line 281) reverts, the entire `afterPayRecordedWith` transaction fails, and the payment tokens remain in the hook contract with no recovery mechanism. | The terminal is a trusted contract (it is `msg.sender`, verified via `isTerminalOf`). If the terminal reverts on `addToBalanceOf`, it is a terminal bug, not a hook bug. |

### Unlock Callback (unlockCallback, lines 409-477)

| Risk | Severity | Description | Mitigation |
|------|----------|-------------|------------|
| Caller authentication | LOW | Only `POOL_MANAGER` can call `unlockCallback` (line 411). This is sufficient because V4's `unlock()` always calls back on `msg.sender`, so the hook is always the unlock initiator. | Direct check: `msg.sender != address(POOL_MANAGER)` reverts with `CallerNotPoolManager`. |
| int128 delta casting | LOW | Lines 449 and 457 cast `delta` values via `uint256(uint128(-deltaX))`. If the PoolManager returns unexpected positive values where negative are expected (or vice versa), the cast would produce wrong amounts. | V4's swap convention is well-defined: negative = caller spent, positive = caller received. The `projectTokenIs0` flag ensures correct interpretation. Fuzz tests across both directions confirm correctness. |
| sqrtPriceLimit computation overflow | LOW | `sqrtPriceLimitFromAmounts()` (JBSwapLib.sol lines 226-301) uses `FullMath.mulDiv` to compute `num * 2^192 / den`, which can overflow for extreme price ratios. | Three-tier approach: ratios >= 2^128 fall back to no limit (line 272), ratios in [2^64, 2^128) use intermediate precision (lines 274-276), and normal ratios use full 192-bit precision (lines 278-280). All results are clamped to `[MIN_SQRT_PRICE, MAX_SQRT_PRICE]`. Fuzz tested via `testFuzz_sqrtPriceLimitValid` and `testFuzz_sqrtPriceLimitBounds`. |

### Oracle and TWAP (JBSwapLib.sol, _getQuote in JBBuybackHook.sol lines 711-764)

| Risk | Severity | Description | Mitigation |
|------|----------|-------------|------------|
| TWAP manipulation via multi-block MEV | MEDIUM | An attacker who controls consecutive blocks can skew the TWAP by holding a manipulated price across the entire window. The minimum 5-minute window (300 seconds / 12s per block = 25 blocks) requires dominating 25 consecutive blocks, which is expensive but not impossible for sophisticated validators. | `MIN_TWAP_WINDOW = 5 minutes` (line 87) raises the cost vs the old 2-minute minimum. `MEVScenarios.t.sol::test_twapManipulationCost` quantifies: the attacker needs ~10,000 ETH of capital for a 1M-liquidity pool, held for 25 blocks. |
| Arithmetic mean tick truncation | LOW | The TWAP tick is computed as `tickCumulativesDelta / twapWindow` with truncation toward negative infinity (JBSwapLib.sol lines 80-85). For short windows or small cumulative deltas, this can round the tick by up to 1 unit, affecting the quote by ~1 basis point. | Economically insignificant. The sigmoid slippage tolerance absorbs this rounding. |
| `harmonicMeanLiquidity` overflow | LOW | If `secondsPerLiquidityDelta` is extremely small (very high liquidity), the division `(twapWindow << 128) / secondsPerLiquidityDelta` (line 92) can return very large values. If it overflows `uint128`, the cast silently truncates. | For realistic liquidity values, this does not overflow. A pool would need more liquidity than exists in all of DeFi to trigger this edge case. |
| Spot fallback for pools without oracle hooks | MEDIUM | Many V4 pools will not have an oracle hook. The `catch` block (JBSwapLib.sol line 97) falls back to `getSlot0()` spot price. This makes the TWAP cross-validation ineffective -- the "TWAP minimum" is actually just spot + sigmoid slippage. | The `sqrtPriceLimitFromAmounts` function (computed in `unlockCallback` line 417) still enforces a hard price floor on the swap itself, acting as a circuit breaker even when the TWAP is unavailable. The payer can also provide their own quote via metadata to set a tighter minimum. |

### Sigmoid Slippage Tolerance (JBSwapLib.sol lines 114-141)

| Risk | Severity | Description | Mitigation |
|------|----------|-------------|------------|
| 88% maximum slippage | INFO | `MAX_SLIPPAGE = 8800` (88%) allows very large slippage for high-impact swaps. In extreme cases, the hook would accept receiving only 12% of the oracle quote. | This is by design for pools with extreme price impact. The `_getQuote` function returns 0 when `slippageTolerance >= TWAP_SLIPPAGE_DENOMINATOR` (line 760), triggering the mint fallback before the 100% threshold. At 88%, the remaining 12% buffer prevents the sigmoid from reaching total loss. |
| Pool fee awareness raises floor | LOW | The minimum slippage is `max(poolFee + 100bps, 200bps)` (JBSwapLib.sol lines 126-128). For high-fee pools (e.g., 1% fee tier), the minimum slippage is 200bps, which might be too tight for legitimate price movements. | The sigmoid curve adapts: as pool impact increases, tolerance grows smoothly toward `MAX_SLIPPAGE`. The 1% buffer above pool fee accounts for normal execution costs. |
| SIGMOID_K constant is hardcoded | INFO | `SIGMOID_K = 5e16` controls the curve's inflection point. This cannot be tuned per-project or per-pool. | The value was calibrated to match the original K=5000 with 1e5 amplifier. The 1e18 precision means sub-basis-point impacts are correctly captured (verified by `test_impactPrecisionSmallSwap`). |

### Pool Configuration (setPoolFor, lines 312-383)

| Risk | Severity | Description | Mitigation |
|------|----------|-------------|------------|
| Pool immutability prevents upgrades | INFO | Once `_poolIsSet[projectId][terminalToken] = true` (line 368), the pool for that project/token pair can never be changed. If the pool becomes illiquid, the project is stuck with it. | This is an intentional trust trade-off: immutability prevents a malicious project owner from swapping the pool to one they control. Projects can still add pools for different terminal tokens. The TWAP window can still be adjusted via `setTwapWindowOf`. |
| TWAP window is per-project, not per-pool | LOW | `twapWindowOf[projectId]` (line 374) is shared across all pools for a project. A project with both an ETH pool (high liquidity) and a USDC pool (low liquidity) cannot set different TWAP windows for each. | Acceptable trade-off for simplicity. The project owner should set the window for the most vulnerable pool. |
| Pool key currency validation | LOW | Lines 360-364 validate that the pool's currencies match the project token and terminal token. However, this does not validate other pool parameters (fee tier, tick spacing, hooks). A project owner could set a pool with an unfavorable fee tier. | The project owner is trusted to choose a reasonable pool. `setPoolFor` requires `SET_BUYBACK_POOL` permission, and the pool must be initialized in the PoolManager (line 356-357). |
| `uint256 -> uint32` truncation on twapWindow | LOW | `getQuoteFromOracle` casts `twapWindow` from `uint256` to `uint32` (line 736: `uint32(twapWindow)`). `MAX_TWAP_WINDOW = 2 days = 172800`, which fits in `uint32` (max 4.29B). | No practical risk since `setPoolFor` and `setTwapWindowOf` enforce `twapWindow <= MAX_TWAP_WINDOW`. |
| `uint128` truncation on amountIn | LOW | `getQuoteFromOracle` casts `amountIn` to `uint128` (line 737). For payments exceeding `type(uint128).max` (~3.4e38), this silently truncates. | No practical risk -- this would require a payment of ~3.4e20 ETH, which exceeds total ETH supply by many orders of magnitude. |

### Registry (JBBuybackHookRegistry.sol)

| Risk | Severity | Description | Mitigation |
|------|----------|-------------|------------|
| Disallowed hook still usable by locked projects | INFO | When `disallowHook(hook)` is called, projects that already locked that hook (via `lockHookFor`) continue using it. The disallow only prevents new projects from setting it. | By design -- locked hooks are immutable commitments. The lock mechanism exists precisely so projects can guarantee their hook will not be changed underneath them. |
| Default hook change affects unlocked projects | LOW | When the registry owner calls `setDefaultHook(newHook)`, all projects that have not explicitly set a hook (and have not locked) immediately start using the new default. This is a silent configuration change. | Projects that care about hook stability should call `lockHookFor`. The `expectedHook` parameter prevents race conditions during locking (verified by `LockRace_ExpectedHook.t.sol`). |
| `beforePayRecordedWith` delegation to address(0) | MEDIUM | If no hook is set for a project and `defaultHook == address(0)`, `beforePayRecordedWith` (line 208-209) calls `hook.beforePayRecordedWith(context)` on `address(0)`, which will revert. | `setDefaultHook` prevents setting `address(0)` (line 147). However, if no default is ever set and a project with `useDataHookForPay=true` points to the registry, payments will revert. This is a deployment sequencing issue, not a code bug. Verified by `L46_DefaultHookZeroCheck.t.sol`. |
| `setHookFor` allows setting any allowed hook | LOW | `setHookFor` checks `isHookAllowed[hook]` (line 167) but does not verify the hook is compatible with the project's token or pool configuration. | The registry is a routing layer, not a configuration validator. Compatibility is the project owner's responsibility. |
| `lockHookFor` race condition | LOW (FIXED) | Before the fix, `lockHookFor` did not take an `expectedHook` parameter, allowing a race where the owner changes the hook between the caller's transaction submission and execution, locking the wrong hook. | Fixed by requiring `expectedHook` parameter (line 131). If the resolved hook differs, it reverts with `HookMismatch`. Verified by `LockRace_ExpectedHook.t.sol`. |

## MEV Analysis

### Three-Layer Protection Pipeline

1. **TWAP Cross-Validation** (`beforePayRecordedWith` line 575): `minimumSwapAmountOut = max(payerQuote, twapQuote)`. A stale or malicious payer quote cannot reduce the minimum below what the TWAP oracle suggests. Conversely, a manipulated oracle cannot reduce the minimum below what the payer expects.

2. **Sigmoid Slippage Tolerance** (`_getQuote` lines 751-763): The TWAP-derived quote is reduced by a sigmoid-computed slippage that depends on estimated price impact and pool fee. Small swaps in deep pools get tight tolerance (~2%); large swaps in thin pools get wide tolerance (up to 88%). This is a continuous function (no cliff), making it harder for attackers to find profitable thresholds.

3. **sqrtPriceLimit Circuit Breaker** (`unlockCallback` lines 416-419): The actual V4 swap has a hard price limit computed from `amountIn` and `minimumSwapAmountOut`. If an attacker frontruns the swap by enough to push the price past this limit, the V4 PoolManager returns a partial fill (or zero fill). The hook detects leftover tokens and routes them back to the terminal for minting.

### Concrete Attack Scenarios

**Scenario 1: Classic Sandwich Attack**
- Attacker frontruns a 1 ETH buyback in a 100K-liquidity pool, pushing the price down.
- The `sqrtPriceLimit` in the V4 swap stops execution when the price exceeds the minimum acceptable rate.
- If the attack moves the price past the limit, the swap returns 0 tokens, all 1 ETH goes to `addToBalanceOf`, and the beneficiary gets mint-rate tokens.
- Attacker loses 2x pool fees (0.6% round trip) with zero extraction.
- Verified by `V4SandwichForkTest.t.sol::test_fork_sandwich_mintFallback` (asserts attacker profit < 0 when circuit breaker fires).

**Scenario 2: Stale Frontend Quote**
- Frontend sends a 30-second-old quote while price moved against the user.
- `beforePayRecordedWith` computes `twapMinimum` from the oracle.
- If `twapMinimum > payerQuote`, the TWAP overrides (line 575), protecting the user.
- Verified by `MEVScenarios.t.sol::test_twapCrossValidationValue`.

**Scenario 3: Oracle-Less Pool**
- Pool has no oracle hook (common for V4 pools without the Geomean Oracle).
- `getQuoteFromOracle` `catch` block (JBSwapLib.sol line 97) falls back to spot.
- Spot is manipulable, but `sqrtPriceLimitFromAmounts` still constrains the swap execution.
- **Residual risk**: without TWAP, protection is limited to the sigmoid slippage applied to spot price. A single-block manipulation of spot could cause the hook to either (a) swap at a slightly worse price within the sigmoid tolerance, or (b) fall back to minting.

**Scenario 4: TWAP Manipulation via Multi-Block MEV**
- Attacker controls 25+ consecutive blocks (5-minute minimum window).
- Holds a large position to skew the TWAP, then executes the sandwich.
- Cost: for a 1M-liquidity pool, approximately 10,000 ETH of capital locked for 25 blocks, plus ~60 ETH in pool fees.
- This attack is economically viable only against very large payments (>10,000 ETH) in very deep pools.
- **Risk assessment**: LOW for most projects, MEDIUM for projects receiving whale-sized payments.

## Reentrancy Analysis

- **afterPayRecordedWith**: External calls are: `safeTransferFrom` (line 215), `POOL_MANAGER.unlock()` (line 674 via `_swap`), `addToBalanceOf` (line 281), and `controller.mintTokensOf()` (line 296). Native ETH settles directly via `POOL_MANAGER.settle{value:}()` — no WETH wrapping. The V4 unlock/callback pattern is inherently reentrant-safe because the PoolManager holds a lock during the callback. After the swap settles, all token state is finalized before `addToBalanceOf` and `mintTokensOf` are called. No exploitable reentrancy vector exists.

- **unlockCallback**: Called only by PoolManager during `unlock`. Cannot be called externally (line 411 check). The callback settles/takes tokens with the PoolManager and returns -- no external calls to user-controlled contracts.

- **MockSplitHook test**: `test/mock/MockSplitHook.sol` attempts a `delegatecall` to `afterPayRecordedWith` from a split hook context. This is a reentrancy/context-manipulation test vector. The `delegatecall` would execute `afterPayRecordedWith` in the caller's storage context, which would fail because the hook's state (pool keys, project tokens) would not exist in the split hook's storage.

- **No ReentrancyGuard**: The contract does not use OpenZeppelin's `ReentrancyGuard`. Protection relies on state ordering (write-before-external-call) and the V4 PoolManager's built-in lock.

## Denial of Service Vectors

| Vector | Description | Impact |
|--------|-------------|--------|
| JBPrices revert | If `PRICES.pricePerUnitOf()` reverts (stale Chainlink feed, missing price feed), both `beforePayRecordedWith` (line 549) and `afterPayRecordedWith` (line 251) revert. This blocks all buyback-routed payments when `baseCurrency != payment currency`. | Payments to the project halt until the price feed is restored. The project can work around this by changing the ruleset's `baseCurrency` to match the terminal currency. |
| Controller revert on mint/burn | If `controller.mintTokensOf()` or `burnTokensOf()` reverts, the entire payment reverts. | Same as above -- payment halts. |
| Pool deinitialization | If a V4 pool is somehow deinitialized (sqrtPriceX96 becomes 0), `_getQuote` returns 0, the mint path is chosen, and swaps are permanently disabled for that pool. | The pool is immutable in the hook, so there is no recovery path. However, V4 pools cannot be deinitialized in practice. |
| Large payment amount | No explicit cap on payment amounts. However, the `uint128` cast on `amountIn` in `getQuoteFromOracle` (line 737) would silently truncate amounts > 2^128. | No practical risk -- exceeds total supply of any token. |

## Test Coverage Assessment

### What IS Tested (15 test files, ~2,500 lines of tests)

- V4 swap flow: unlock -> callback -> settle/take (V4BuybackHook.t.sol)
- Swap fallback to mint when PoolManager reverts (V4BuybackHook.t.sol, M34 regression)
- unlockCallback auth (only PoolManager can call)
- Native ETH and ERC-20 terminal token paths
- Oracle hook TWAP query and unavailability fallback
- Sigmoid slippage: monotonicity, bounds, fee awareness, regression values (JBSwapLib.t.sol, V4BuybackHook.t.sol)
- sqrtPriceLimit: bounds, precision, extended range, extreme ratios (JBSwapLib.t.sol)
- Partial fill leftover handling (V4BuybackHook.t.sol)
- Payer quote cross-validation with TWAP (V4BuybackHook.t.sol)
- Balance delta leftover accounting (L44 regression for both ETH and ERC-20)
- Pre-existing balance not inflating leftovers (L44 regression)
- TWAP window event emission (L45 regression)
- Registry: allow/disallow/set/lock hooks, default fallback, permission checks, lock race condition (Registry.t.sol, LockRace regression, L46 regression)
- Token migration impossibility (FalsePositives test)
- Sandwich attacks on real V4 PoolManager (V4SandwichForkTest.t.sol)
- Full E2E flow: beforePayRecordedWith -> afterPayRecordedWith on fork (V4ForkTest.t.sol)
- MEV protection quantification (MEVScenarios.t.sol)
- Fuzz tests: sigmoid bounds, monotonicity, impact calculation, sqrtPriceLimit validity, full pipeline (30+ fuzz tests)

### What is NOT Tested

- **Multi-pool projects**: No test configures a project with pools for multiple terminal tokens and verifies independent operation.
- **Non-18-decimal tokens**: All tests use 18-decimal tokens. The `mulDiv(amountIn, IMPACT_PRECISION, liquidity)` in `calculateImpact` could behave differently with 6-decimal tokens (e.g., USDC).
- **Weight ratio with non-matching currencies**: The `weightRatio` calculation in `afterPayRecordedWith` (lines 249-256) is tested only with matching currencies (`baseCurrency == payment currency`). The `PRICES.pricePerUnitOf` branch is not directly tested.
- **Concurrent payments**: No test sends two payments to the same project simultaneously to verify that the balance-delta approach handles interleaving correctly. (The delta approach should be safe since each payment's `balanceBefore` is captured at entry.)
- **Fee-on-transfer tokens**: If a terminal token charges a transfer fee, `safeTransferFrom` delivers fewer tokens than expected, but the hook does not account for the discrepancy.
- **Rebasing tokens**: Tokens that change balances between calls would break the balance-delta leftover calculation.
- **Registry hook upgrade during payment**: No test verifies behavior if the registry owner changes the default hook while a payment is in flight (between `beforePayRecordedWith` and `afterPayRecordedWith`). This is safe because `afterPayRecordedWith` uses the controller/metadata encoded in `hookMetadata` from `beforePayRecordedWith`, not the registry.
- **ERC-2771 meta-transaction context**: No test verifies that `_msgSender()` is used correctly in permission checks via a trusted forwarder.

## Privileged Roles

| Role | Permission | Scope | Impact |
|------|-----------|-------|--------|
| Project owner | `SET_BUYBACK_TWAP` | Per-project | Can change the TWAP window (5 min to 2 days). A longer window is more manipulation-resistant but less responsive to legitimate price changes. |
| Project owner | `SET_BUYBACK_POOL` | Per-project, one-time | Can set the Uniswap V4 pool for a project/terminal-token pair. Immutable once set. A bad pool choice is permanent. |
| Project owner | `SET_BUYBACK_HOOK` | Per-project (via registry) | Can register or change which buyback hook implementation is used. Can lock it permanently. |
| Registry owner | `allowHook` / `disallowHook` / `setDefaultHook` | Global | Controls which hook implementations are available. Can change the default hook affecting all unlocked projects. Cannot affect locked projects. |

## Integer Arithmetic

- All arithmetic uses Solidity 0.8.26 checked math except where explicitly using `FullMath.mulDiv` (which handles overflow internally).
- `mulDiv` from `@prb/math` (used in `afterPayRecordedWith` lines 261, 292, 557) reverts on division by zero but rounds down, potentially losing up to 1 wei per operation.
- `FullMath.mulDiv` from Uniswap (used in JBSwapLib.sol) handles full 512-bit intermediate products without overflow.
- The sigmoid formula `minSlippage + FullMath.mulDiv(range, impact, impact + SIGMOID_K)` (JBSwapLib.sol line 138) is safe because `impact + SIGMOID_K > 0` when `impact > 0` (line 131 returns early for `impact == 0`), and the overflow guard at line 134 catches the edge case where `impact > type(uint256).max - SIGMOID_K`.
