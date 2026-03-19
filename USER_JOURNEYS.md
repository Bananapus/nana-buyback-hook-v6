# User Journeys

Step-by-step flows for every major user interaction with the buyback hook system.

## 1. Pay with Buyback -- Swap Wins

A payer sends ETH to a project whose ruleset has the buyback hook as its data hook. The Uniswap V4 pool offers more tokens per ETH than direct minting.

**Actors:** Payer, JBMultiTerminal, JBTerminalStore, JBBuybackHookRegistry, JBBuybackHook, V4 PoolManager

**Steps:**

1. Payer calls `JBMultiTerminal.pay{value: 1 ether}(projectId, ..., metadata)`.
   - `metadata` optionally contains a payer quote: `(amountToSwapWith, minimumSwapAmountOut)` encoded under the `"quote"` metadata ID.

2. Terminal calls `JBTerminalStore.recordPaymentFrom(...)`, which calls the data hook (the registry).

3. `JBBuybackHookRegistry.beforePayRecordedWith(context)` resolves the hook for the project (project-specific or default) and delegates.

4. `JBBuybackHook.beforePayRecordedWith(context)` runs the swap-vs-mint decision:
   - Computes `tokenCountWithoutHook = amountToSwapWith * weight / weightRatio` (what direct minting would yield).
   - Queries the oracle for a TWAP-based minimum: `_getQuote(projectId, projectToken, amountIn, terminalToken)`.
   - Takes the higher of the payer quote and the TWAP quote: `minimumSwapAmountOut = max(payerQuote, twapMinimum)`.
   - Since `minimumSwapAmountOut > tokenCountWithoutHook`, returns `weight = 0` and a `JBPayHookSpecification` pointing to itself with `amount = amountToSwapWith` and `metadata` encoding 8 fields: `(projectTokenIs0, mintFromExcess, minimumSwapAmountOut, controller, tokenCountWithoutHook, twapTick, twapLiquidity, poolId)`. Fields 1-4 are consumed by `afterPayRecordedWith`; fields 5-8 are informational for preview clients.

   **Interpreting the informational fields (5-8) for preview UIs:**
   - `tokenCountWithoutHook` (uint256): The number of project tokens the payer would have received from direct minting (no swap). Compare against `minimumSwapAmountOut` to show the user how much better the swap is.
   - `twapTick` (int24): The time-weighted average price from the oracle, encoded as a Uniswap tick. Convert to a human-readable price: `price = 1.0001^tick`. If `projectTokenIs0 == true`, this is payment tokens per project token; if `false`, invert it (`1 / price`). In JS: `const price = projectTokenIs0 ? 1.0001 ** tick : 1 / (1.0001 ** tick)`.
   - `twapLiquidity` (uint128): The harmonic mean of in-range liquidity over the TWAP window. Higher values mean deeper liquidity and more reliable pricing. A value of `0` means no liquidity data was available (the hook would have fallen back to minting).
   - `poolId` (bytes32): The V4 pool identifier (`keccak256(abi.encode(poolKey))`). Use with `IPoolManager.getSlot0(poolId)` to look up live pool state, or call `JBBuybackHook.poolKeyOf(projectId, terminalToken)` to recover the full pool key.

5. `JBTerminalStore` records the payment with `weight = 0` (no tokens minted directly). The terminal then calls the pay hook.

6. Terminal calls `JBBuybackHook.afterPayRecordedWith{value: amountToSwapWith}(context)`.

7. The hook records `balanceBefore = address(this).balance - msg.value` (to compute leftover later).

8. The hook calls `_swap()`:
   - Encodes `SwapCallbackData` with the pool key, amounts, and direction.
   - Calls `POOL_MANAGER.unlock(callbackData)`.

9. V4 PoolManager calls `unlockCallback(data)`:
   - Computes `sqrtPriceLimit` from `amountIn` and `minimumSwapAmountOut`.
   - Executes `POOL_MANAGER.swap(key, SwapParams{zeroForOne, amountSpecified: -amountIn, sqrtPriceLimitX96})`.
   - Settles input tokens: `POOL_MANAGER.settle{value: inputAmount}()` for native ETH.
   - Takes output tokens: `POOL_MANAGER.take(outputCurrency, address(this), outputAmount)`.
   - Returns `abi.encode(outputAmount)`.

10. Back in `afterPayRecordedWith`, the hook receives `exactSwapAmountOut` (e.g., 500 project tokens).

11. Slippage check: `exactSwapAmountOut >= minimumSwapAmountOut` -- passes.

12. The hook burns the swapped project tokens via `controller.burnTokensOf(address(this), projectId, 500, "")`.

13. Computes `leftover = balanceAfter - balanceBefore`. If the swap consumed all input, leftover = 0.

14. Mints `500` project tokens for the beneficiary via `controller.mintTokensOf(projectId, 500, beneficiary, ...)` with `useReservedPercent = true`.

**Result:** Payer receives 500 project tokens (more than the ~400 that direct minting would have yielded). Reserved tokens are distributed according to the ruleset's reserved percent.

## 2. Pay with Buyback -- Mint Wins

Same setup, but the pool price is worse than the mint rate.

**Steps:**

1-3. Same as above.

4. `JBBuybackHook.beforePayRecordedWith(context)`:
   - Computes `tokenCountWithoutHook = 400` (what minting yields).
   - Computes `minimumSwapAmountOut = 350` (pool is worse than minting).
   - Since `minimumSwapAmountOut <= tokenCountWithoutHook`, returns the original `weight` and an empty `hookSpecifications` array.

5. `JBTerminalStore` records the payment with the original weight. The terminal mints 400 tokens for the payer directly. No pay hook is called.

**Result:** Payer receives 400 tokens via direct minting. The buyback hook is not involved in the payment execution.

## 3. Configure Pool for Project

A project owner sets up a Uniswap V4 pool for buyback routing.

**Actors:** Project owner, JBBuybackHookRegistry, JBBuybackHook

**Steps:**

1. Project owner calls `JBBuybackHookRegistry.initializePoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken, sqrtPriceX96)`.

2. Registry enforces `SET_BUYBACK_POOL` permission from the project owner.

3. Registry resolves the hook for the project and delegates to `JBBuybackHook.initializePoolFor(...)`.

4. The hook builds a `PoolKey` from `(fee, tickSpacing, projectToken, terminalToken)`, sorting currencies correctly.

5. Calls `POOL_MANAGER.initialize(poolKey, sqrtPriceX96)` inside a try-catch (skips if pool already exists).

6. Calls `_setPoolFor(...)` which:
   - Checks `_poolIsSet[projectId][normalizedTerminalToken]` is false (reverts with `PoolAlreadySet` otherwise).
   - Validates `twapWindow` is between `MIN_TWAP_WINDOW` (5 min) and `MAX_TWAP_WINDOW` (2 days).
   - Validates the project has a deployed ERC-20 token (`projectToken != address(0)`).
   - Validates `terminalToken != projectToken`.
   - Validates the pool is initialized in the PoolManager (`sqrtPriceX96 != 0`).
   - Validates the PoolKey currencies match the project token and terminal token.
   - Stores the pool key and marks `_poolIsSet = true`.
   - Caches the project token address in `projectTokenOf[projectId]`.
   - Stores the TWAP window.

**Result:** The pool is permanently configured. Future payments to this project with this terminal token will use this pool for buyback decisions.

**Important:** If the project calls `setPoolFor(...)` (without initialize) instead, the pool must already be initialized in the V4 PoolManager. This is the overload for pools that already exist.

## 4. Set TWAP Window

A project owner adjusts the TWAP window for a specific terminal token.

**Actors:** Project owner, JBBuybackHook

**Steps:**

1. Project owner calls `JBBuybackHook.setTwapWindowOf(projectId, terminalToken, 600)` (10 minutes).

2. The hook enforces `SET_BUYBACK_TWAP` permission from the project owner.

3. Validates `600 >= MIN_TWAP_WINDOW (300) && 600 <= MAX_TWAP_WINDOW (172800)`.

4. Normalizes the terminal token (uses `address(0)` for native ETH).

5. Updates `twapWindowOf[projectId][normalizedTerminalToken] = 600`.

6. Emits `TwapWindowChanged(projectId, normalizedTerminalToken, oldWindow, 600, caller)`.

**Result:** Future oracle queries for this project/token pair use a 10-minute TWAP window. This can be called multiple times (not immutable like the pool itself).

## 5. Register Hook via Registry

A project owner assigns a specific buyback hook implementation via the registry.

**Actors:** Project owner, Registry owner, JBBuybackHookRegistry

**Steps:**

1. Registry owner calls `JBBuybackHookRegistry.allowHook(hookAddress)` to add the implementation to the allowlist.

2. Project owner calls `JBBuybackHookRegistry.setHookFor(projectId, hookAddress)`.

3. Registry checks:
   - `hasLockedHook[projectId]` is false (reverts with `HookLocked` otherwise).
   - `isHookAllowed[hookAddress]` is true (reverts with `HookNotAllowed` otherwise).
   - Caller has `SET_BUYBACK_HOOK` permission from the project owner.

4. Stores `_hookOf[projectId] = hookAddress`.

**Result:** This project now uses the specified hook implementation instead of the default. The registry's `beforePayRecordedWith` will delegate to this hook for all future payments.

## 6. Lock Hook

A project owner permanently locks their buyback hook, preventing future changes.

**Actors:** Project owner, JBBuybackHookRegistry

**Steps:**

1. Project owner calls `JBBuybackHookRegistry.lockHookFor(projectId, expectedHook)`.

2. Registry enforces `SET_BUYBACK_HOOK` permission from the project owner.

3. Resolves the current hook: checks `_hookOf[projectId]`, falls back to `defaultHook` if zero.

4. If the resolved hook is `address(0)` (no hook set and no default), reverts with `HookNotSet`.

5. If using the default, copies it to `_hookOf[projectId]` so the lock captures the specific implementation (not a floating reference to the default).

6. Verifies `resolvedHook == expectedHook` (reverts with `HookMismatch` if a race condition changed it).

7. Sets `hasLockedHook[projectId] = true`.

**Result:** The project's hook cannot be changed. Even if the registry owner disallows the hook or changes the default, this project continues using the locked implementation. Future calls to `setHookFor` for this project will revert.

## 7. Swap Fallback to Mint

A payment triggers the swap path, but the V4 swap reverts (e.g., insufficient liquidity, pool issue).

**Actors:** Payer, JBMultiTerminal, JBBuybackHook, V4 PoolManager

**Steps:**

1-6. Same as Journey 1 (swap wins). The hook enters `afterPayRecordedWith`.

7. The hook calls `_swap()`, which calls `POOL_MANAGER.unlock(callbackData)`.

8. Inside `unlockCallback`, `POOL_MANAGER.swap()` reverts (insufficient liquidity, pool not initialized, etc.).

9. The `try POOL_MANAGER.unlock(...)` catch block catches the revert. Returns `(0, swapFailed=true)`.

10. Back in `afterPayRecordedWith`:
    - `swapFailed == true`, so the slippage check is skipped (no revert even though `exactSwapAmountOut = 0 < minimumSwapAmountOut`).
    - No tokens to burn (swap returned 0).

11. Computes `leftover = balanceAfter - balanceBefore`. Since no tokens were consumed by the swap, `leftover == amountToSwapWith`.

12. Returns all tokens to the terminal via `addToBalanceOf`.

13. Computes `partialMintTokenCount = leftover * weight / weightRatio`.

14. Mints `partialMintTokenCount` for the beneficiary via the controller.

**Result:** The payer receives tokens at the mint rate as if the buyback hook did not exist. No funds are lost. The swap failure is silently absorbed.

## 8. Partial Fill Handling

The V4 swap executes but only partially fills due to the `sqrtPriceLimit` being hit.

**Actors:** Payer, JBBuybackHook, V4 PoolManager

**Steps:**

1-8. Same as Journey 1. The hook enters `unlockCallback`.

9. `POOL_MANAGER.swap()` executes but hits the `sqrtPriceLimit` before consuming all input:
   - `inputAmount = 0.7 ether` (consumed by swap).
   - `outputAmount = 350` project tokens (received from swap).
   - The remaining `0.3 ether` is not consumed.

10. Settlement: hook settles `0.7 ether` with `POOL_MANAGER.settle{value: 0.7 ether}()` and takes `350` project tokens.

11. Back in `afterPayRecordedWith`:
    - `exactSwapAmountOut = 350` passes slippage check.
    - Burns 350 project tokens.
    - Computes `leftover = balanceAfter - balanceBefore = 0.3 ether` (the unconsumed portion).

12. Returns 0.3 ETH to the terminal via `addToBalanceOf{value: 0.3 ether}(...)`.

13. Computes `partialMintTokenCount = 0.3 ether * weight / weightRatio` (e.g., 120 tokens).

14. Mints `350 + 120 = 470` total tokens for the beneficiary.

**Result:** The payer gets 350 tokens from the swap (at the pool rate) plus 120 tokens from minting (at the mint rate). The partial fill is handled seamlessly. Both portions respect the reserved percent during minting.
