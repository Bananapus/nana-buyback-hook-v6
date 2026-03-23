# User Journeys

Step-by-step flows for every major user interaction with the buyback hook system.

---

## 1. Pay with Buyback -- Swap Wins

A payer sends ETH to a project whose ruleset has the buyback hook as its data hook. The Uniswap V4 pool offers more tokens per ETH than direct minting.

**Entry point**: `JBMultiTerminal.pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)`

**Who can call**: Anyone (via the terminal). The buyback hook is invoked automatically as a data hook / pay hook.

**Parameters** (metadata-encoded, optional):
- `amountToSwapWith` -- Amount of terminal tokens to route through the V4 pool (defaults to full payment if omitted)
- `minimumSwapAmountOut` -- Minimum acceptable project tokens from the swap (payer-specified slippage floor)
- Both are encoded under the `"quote"` metadata ID: `JBMetadataResolver.getId("quote")`

**Actors:** Payer, JBMultiTerminal, JBTerminalStore, JBBuybackHookRegistry, JBBuybackHook, V4 PoolManager

**Steps:**

1. Payer calls `JBMultiTerminal.pay{value: 1 ether}(projectId, ..., metadata)`.
   - `metadata` optionally contains a payer quote: `(amountToSwapWith, minimumSwapAmountOut)` encoded under the `"quote"` metadata ID.

2. Terminal calls `JBTerminalStore.recordPaymentFrom(...)`, which calls the data hook (the registry).

3. `JBBuybackHookRegistry.beforePayRecordedWith(context)` resolves the hook for the project (project-specific or default) and delegates.

4. `JBBuybackHook.beforePayRecordedWith(context)` runs the swap-vs-mint decision:
   - Computes `tokenCountWithoutHook = amountToSwapWith * weight / weightRatio` (what direct minting would yield).
   - If no explicit quote metadata was provided, queries the oracle for a TWAP/geomean-based minimum: `_getQuote(projectId, projectToken, amountIn, terminalToken)`.
   - If explicit quote metadata was provided, honors that minimum directly and skips the TWAP lookup.
   - Since `minimumSwapAmountOut > tokenCountWithoutHook`, returns `weight = 0` and a `JBPayHookSpecification` pointing to itself with `noop = false`, `amount = amountToSwapWith`, and `metadata` encoding 10 fields: `(projectTokenIs0, amountToMintWith, minimumSwapAmountOut, controller, tokenCountWithoutHook, twapTick, twapLiquidity, poolId, minimumBeneficiaryTokenCount, minimumReservedTokenCount)`. Fields 1-4 are consumed by `afterPayRecordedWith`; fields 5-10 are informational for preview clients.

   **Interpreting the informational fields (5-10) for preview UIs:**
   - `tokenCountWithoutHook` (uint256): The number of project tokens the payer would have received from direct minting (no swap). Compare against `minimumSwapAmountOut` to show the user how much better the swap is.
   - `twapTick` (int24): The time-weighted average price from the oracle, encoded as a Uniswap tick. Convert to a human-readable price: `price = 1.0001^tick`. If `projectTokenIs0 == true`, this is payment tokens per project token; if `false`, invert it (`1 / price`). In JS: `const price = projectTokenIs0 ? 1.0001 ** tick : 1 / (1.0001 ** tick)`.
   - `twapLiquidity` (uint128): The harmonic mean of in-range liquidity over the TWAP window. Higher values mean deeper liquidity and more reliable pricing. A value of `0` means no liquidity data was available (the hook would have fallen back to minting).
   - `poolId` (bytes32): The V4 pool identifier (`keccak256(abi.encode(poolKey))`). Use with `IPoolManager.getSlot0(poolId)` to look up live pool state, or call `JBBuybackHook.poolKeyOf(projectId, terminalToken)` to recover the full pool key.
   - `minimumBeneficiaryTokenCount` (uint256): Minimum share of the swap output that would go to the beneficiary after applying the reserved rate.
   - `minimumReservedTokenCount` (uint256): Minimum share of the swap output that would be reserved after applying the reserved rate.

5. `JBTerminalStore` records the payment with `weight = 0` (no tokens minted directly). The terminal then calls the pay hook.

6. Terminal calls `JBBuybackHook.afterPayRecordedWith{value: amountToSwapWith}(context)`.

7. The hook records `balanceBefore` to compute leftover as a delta later:
   - **Native ETH:** `balanceBefore = address(this).balance - msg.value` (subtracts the forwarded payment that is already included in the balance).
   - **ERC-20:** `balanceBefore = IERC20(token).balanceOf(address(this))` (captured BEFORE the hook pulls tokens from the terminal).

8. If the terminal token is an ERC-20 (not native ETH), the hook pulls the payment from the terminal via `IERC20(token).safeTransferFrom(terminal, address(this), amountToSwapWith)`.

9. The hook calls `_swap()`:
   - Encodes `SwapCallbackData` with the pool key, amounts, and direction.
   - Calls `POOL_MANAGER.unlock(callbackData)`.

10. V4 PoolManager calls `unlockCallback(data)`:
   - Computes `sqrtPriceLimit` from `amountIn` and `minimumSwapAmountOut`.
   - Executes `POOL_MANAGER.swap(key, SwapParams{zeroForOne, amountSpecified: -amountIn, sqrtPriceLimitX96})`.
   - Settles input tokens: `POOL_MANAGER.settle{value: inputAmount}()` for native ETH, or `sync → safeTransfer → settle` for ERC-20.
   - Takes output tokens: `POOL_MANAGER.take(outputCurrency, address(this), outputAmount)`.
   - Returns `abi.encode(outputAmount)`.

11. Still inside `_swap()`, the hook receives `exactSwapAmountOut` (e.g., 500 project tokens), emits the `Swap` event, and then burns the tokens via `controller.burnTokensOf(address(this), projectId, 500, "")`. Both happen inside `_swap()` before it returns.

12. Back in `afterPayRecordedWith`, slippage check: `exactSwapAmountOut >= minimumSwapAmountOut` -- passes.

13. Computes `leftover = balanceAfter - balanceBefore`. If the swap consumed all input, leftover = 0.

14. If `amountToMintWith > 0` (the payer specified a portion of their payment to mint with directly instead of swapping), `partialMintTokenCount` is incremented by `amountToMintWith * weight / weightRatio`. In this example, the payer used the full payment for the swap, so `amountToMintWith = 0`.

15. Mints `totalTokensToMint = exactSwapAmountOut + partialMintTokenCount` (i.e., 500 + 0 = 500) tokens for the beneficiary via `controller.mintTokensOf(projectId, 500, beneficiary, ...)` with `useReservedPercent = true`. The burn-then-mint pattern ensures the reserved percent is applied to swap output tokens that would otherwise bypass it.

**State changes**:
1. `JBTerminalStore.balanceOf[terminal][projectId][token]` -- incremented by the payment amount
2. V4 pool state -- swap executed, liquidity positions updated
3. Project token `balanceOf[buybackHook]` -- temporarily receives swap output, then burned (inside `_swap()`)
4. `JBController.pendingReservedTokenBalanceOf[projectId]` -- incremented by the reserved portion of minted tokens
5. `JBTokens` -- mints `exactSwapAmountOut + partialMintTokenCount` tokens to beneficiary (subject to reserved percent), where `partialMintTokenCount` includes both leftover-based and `amountToMintWith`-based components
6. If leftover exists: `JBTerminalStore.balanceOf[terminal][projectId][token]` -- incremented by leftover amount via `addToBalanceOf` (for ERC-20 leftovers, the hook approves the terminal to pull via `forceApprove` before calling `addToBalanceOf`)

**Events**:
- `Swap(projectId, amountToSwapWith, poolId, amountReceived, caller)` -- emitted on `JBBuybackHook` after successful V4 swap
- `Mint(projectId, leftoverAmount, tokenCount, caller)` -- emitted on `JBBuybackHook` if there are leftover terminal tokens to mint with (partial fills or `amountToMintWith > 0`)

**Edge cases**:
- `JBBuybackHook_Unauthorized(caller)` -- reverts if `afterPayRecordedWith` caller is not a terminal of the project
- `JBBuybackHook_SpecifiedSlippageExceeded(amount, minimum)` -- reverts if swap output is below `minimumSwapAmountOut` (skipped when swap failed)
- `JBBuybackHook_InsufficientPayAmount(swapAmount, totalPaid)` -- reverts in `beforePayRecordedWith` if payer-specified `amountToSwapWith > totalPaid`
- If `weight = 0` in the ruleset and the swap fails, `totalTokensToMint = 0` and the mint call is skipped entirely

**Result:** Payer receives 500 project tokens (more than the ~400 that direct minting would have yielded). Reserved tokens are distributed according to the ruleset's reserved percent.

---

## 2. Pay with Buyback -- Mint Wins

Same setup, but the pool price is worse than the mint rate.

**Entry point**: `JBMultiTerminal.pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)`

**Who can call**: Anyone (via the terminal).

**Steps:**

1-3. Same as above.

4. `JBBuybackHook.beforePayRecordedWith(context)`:
   - Computes `tokenCountWithoutHook = 400` (what minting yields).
   - Computes `minimumSwapAmountOut = 350` (pool is worse than minting).
   - Since `minimumSwapAmountOut <= tokenCountWithoutHook`, returns the original `weight` and a noop `JBPayHookSpecification` with `amount = 0`. The metadata still includes the same 10 routing/preview fields as the swap path.

5. `JBTerminalStore` records the payment with the original weight. The terminal mints 400 tokens for the payer directly. Because the spec is marked noop, no pay hook callback is made.

**State changes**:
1. `JBTerminalStore.balanceOf[terminal][projectId][token]` -- incremented by the payment amount
2. `JBTokens` -- mints tokens to beneficiary at the standard mint rate
3. `JBController.pendingReservedTokenBalanceOf[projectId]` -- incremented by reserved portion

**Events**: Standard terminal `Pay(...)` event only. No buyback hook events are emitted because the hook is not executed.

**Edge cases**:
- If no pool is configured (`poolId == bytes32(0)`), `hookSpecifications` is empty and the payment proceeds as a normal mint with no buyback hook involvement
- If oracle returns 0 (no liquidity data, oracle not warmed up), `minimumSwapAmountOut = 0`, which is always `<= tokenCountWithoutHook`, so mint wins

**Result:** Payer receives 400 tokens via direct minting. The buyback hook is not involved in execution, but preview/simulation callers still receive pool diagnostics from the noop spec metadata.

---

## 2b. Cash Out -- Pool Sell Wins

A holder cashes out project tokens, and selling reminted tokens into the configured V4 pool yields more terminal tokens than the protocol cash-out path.

**Entry point**: `JBMultiTerminal.cashOutTokensOf(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, uint256 minTokensReclaimed, address payable beneficiary, bytes metadata)`

**Who can call**: The token holder, or an address with the holder's `CASH_OUT_TOKENS` permission (via the terminal).

**Parameters** (metadata-encoded, optional):
- `cashOutMinReclaimed` -- Minimum acceptable terminal tokens from the pool sell, encoded under the `"cashOutMinReclaimed"` metadata ID. If omitted, the hook derives a TWAP-based minimum.

**Steps:**

1. Holder calls `cashOutTokensOf(...)`.
2. Terminal/store calls `beforeCashOutRecordedWith(...)`.
3. If no explicit `"cashOutMinReclaimed"` metadata was provided, the hook derives a TWAP/geomean-based sell minimum with `_getQuote(...)`.
4. If explicit `"cashOutMinReclaimed"` metadata was provided, the hook honors that minimum directly and skips the TWAP lookup.
5. The hook computes the direct protocol reclaim amount via `JBCashOuts.cashOutFrom(surplus, cashOutCount, totalSupply, cashOutTaxRate)`.
6. It always returns a cash-out hook specification with routing metadata when a pool is configured.
7. If the pool sale is better (`minimumSwapAmountOut > directCashOutAmount`), the spec is active (`noop = false`) and the hook returns `cashOutTaxRate = MAX_CASH_OUT_TAX_RATE` to suppress the direct protocol reclaim path.
8. If the protocol cash out is better, the spec is informational (`noop = true`) and the terminal skips the cash-out hook callback.
9. After the terminal burns the holder's tokens on the active path, it calls `afterCashOutRecordedWith(...)`.
10. The hook remints `cashOutCount` project tokens to itself via `controller.mintTokensOf(projectId, cashOutCount, address(this), "", false)`.
11. The hook executes `_swapExactInput(key, cashOutCount, minimumSwapAmountOut, zeroForOne)` to sell the reminted tokens.
12. Slippage re-check: `amountReceived >= minimumSwapAmountOut`.
13. The hook forwards the received ETH/ERC20 terminal tokens to the beneficiary via `Address.sendValue` (native) or `IERC20.safeTransfer` (ERC-20).

**State changes**:
1. Project tokens burned by the terminal (holder's tokens)
2. `JBTokens` -- remints `cashOutCount` tokens to the hook (bypasses reserved percent with `useReservedPercent: false`)
3. V4 pool state -- swap executed selling project tokens for terminal tokens
4. Project token `balanceOf[buybackHook]` -- temporarily receives reminted tokens, consumed by swap
5. Terminal token balance of beneficiary -- increases by `amountReceived`

**Events**:
- `CashOutSwap(projectId, cashOutCount, poolId, amountReceived, caller)` -- emitted on `JBBuybackHook` after the sell-side swap completes

**Edge cases**:
- `JBBuybackHook_CallerNotTerminal(caller)` -- reverts if `afterCashOutRecordedWith` caller is not a terminal of the project
- `JBBuybackHook_SpecifiedSlippageExceeded(amountReceived, minimumSwapAmountOut)` -- reverts if the pool returns less than the minimum
- If no pool is configured, no project token is known, or `cashOutCount == 0`, the hook passes through the protocol cash-out values unchanged (no hook specification returned)
- Unlike the pay path, the cash-out swap has no try-catch fallback -- if the swap reverts, the entire cash-out reverts

**Result:** The cash-out beneficiary receives the better sell-side execution route.

---

## 3. Configure Pool for Project

A project owner sets up a Uniswap V4 pool for buyback routing.

**Entry point**: `JBBuybackHookRegistry.initializePoolFor(uint256 projectId, uint24 fee, int24 tickSpacing, uint256 twapWindow, address terminalToken, uint160 sqrtPriceX96)`

**Who can call**: The project owner, or an address with the owner's `SET_BUYBACK_POOL` permission (checked both at the registry and at the hook).

**Parameters**:
- `projectId` -- The ID of the project to configure the pool for
- `fee` -- The Uniswap V4 pool fee tier (in hundredths of a basis point, e.g., 3000 = 0.30%)
- `tickSpacing` -- The Uniswap V4 pool tick spacing
- `twapWindow` -- TWAP observation window in seconds (min: 300 = 5 minutes, max: 172800 = 2 days)
- `terminalToken` -- The terminal token address (use `JBConstants.NATIVE_TOKEN` for ETH)
- `sqrtPriceX96` -- Initial pool price as sqrtPriceX96 (ignored if pool already initialized)

**Actors:** Project owner, JBBuybackHookRegistry, JBBuybackHook

**Steps:**

1. Project owner calls `JBBuybackHookRegistry.initializePoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken, sqrtPriceX96)`.

2. Registry enforces `SET_BUYBACK_POOL` permission from the project owner.

3. Registry resolves the hook for the project and delegates to `JBBuybackHook.initializePoolFor(...)`.

4. The hook enforces `SET_BUYBACK_POOL` permission again (allows the registry or any permissioned caller).

5. The hook builds a `PoolKey` from `(fee, tickSpacing, projectToken, terminalToken)`, sorting currencies correctly, with `ORACLE_HOOK` as the hooks field.

6. Calls `POOL_MANAGER.initialize(poolKey, sqrtPriceX96)` inside a try-catch (skips if pool already exists).

7. Calls `_setPoolFor(...)` which:
   - Checks `_poolIsSet[projectId][normalizedTerminalToken]` is false (reverts with `PoolAlreadySet` otherwise).
   - Validates `twapWindow` is between `MIN_TWAP_WINDOW` (5 min) and `MAX_TWAP_WINDOW` (2 days).
   - Validates the project has a deployed ERC-20 token (`projectToken != address(0)`).
   - Validates `terminalToken != projectToken`.
   - Validates the pool is initialized in the PoolManager (`sqrtPriceX96 != 0`).
   - Validates the PoolKey currencies match the project token and terminal token.
   - `require("JBBuybackHook: pool key currencies mismatch")` — reverts if the PoolKey currencies do not match the project token and terminal token. Unreachable via `initializePoolFor` (which constructs the key internally) but possible via `setPoolFor(PoolKey)` with a mismatched key.
   - Stores the pool key and marks `_poolIsSet = true`.
   - Caches the project token address in `projectTokenOf[projectId]`.
   - Stores the TWAP window.

**State changes**:
1. `POOL_MANAGER` -- pool initialized at `sqrtPriceX96` (if not already initialized)
2. `JBBuybackHook._poolKeyOf[projectId][normalizedTerminalToken]` -- set to the constructed `PoolKey`
3. `JBBuybackHook._poolIsSet[projectId][normalizedTerminalToken]` -- set to `true`
4. `JBBuybackHook.twapWindowOf[projectId][normalizedTerminalToken]` -- set to `twapWindow`
5. `JBBuybackHook.projectTokenOf[projectId]` -- set to the project's ERC-20 token address

**Events**:
- `TwapWindowChanged(projectId, terminalToken, oldWindow, newWindow, caller)` -- emitted with `oldWindow = 0` on first configuration
- `PoolAdded(projectId, terminalToken, poolId, caller)` -- emitted after the pool key is stored

**Edge cases**:
- `JBBuybackHook_PoolAlreadySet(poolId)` -- reverts if a pool is already configured for this project/token pair (pool keys are immutable once set)
- `JBBuybackHook_InvalidTwapWindow(value, min, max)` -- reverts if `twapWindow < 300` or `twapWindow > 172800`
- `JBBuybackHook_ZeroProjectToken()` -- reverts if the project has not deployed an ERC-20 token
- `JBBuybackHook_TerminalTokenIsProjectToken(terminalToken, projectToken)` -- reverts if the terminal token is the same as the project token
- `JBBuybackHook_PoolNotInitialized(poolId)` -- reverts if the pool is not initialized in the PoolManager (should not happen with `initializePoolFor` unless the try-catch skipped and the pool was uninitialized)

**Result:** The pool is permanently configured. Future payments to this project with this terminal token will use this pool for buyback decisions.

**Important:** If the project calls `setPoolFor(...)` (without initialize) instead, the pool must already be initialized in the V4 PoolManager. This is the overload for pools that already exist.

---

## 4. Set TWAP Window

A project owner adjusts the TWAP window for a specific terminal token.

**Entry point**: `JBBuybackHook.setTwapWindowOf(uint256 projectId, address terminalToken, uint256 newWindow)`

**Who can call**: The project owner, or an address with the owner's `SET_BUYBACK_TWAP` permission.

**Parameters**:
- `projectId` -- The ID of the project to update
- `terminalToken` -- The terminal token address (use `JBConstants.NATIVE_TOKEN` for native ETH; normalized to `address(0)` internally)
- `newWindow` -- The new TWAP window in seconds (min: 300, max: 172800)

**Steps:**

1. Project owner calls `JBBuybackHook.setTwapWindowOf(projectId, terminalToken, 600)` (10 minutes).

2. The hook enforces `SET_BUYBACK_TWAP` permission from the project owner.

3. Validates `600 >= MIN_TWAP_WINDOW (300) && 600 <= MAX_TWAP_WINDOW (172800)`.

4. Normalizes the terminal token (uses `address(0)` for native ETH).

5. Updates `twapWindowOf[projectId][normalizedTerminalToken] = 600`.

**State changes**:
1. `JBBuybackHook.twapWindowOf[projectId][normalizedTerminalToken]` -- updated from `oldWindow` to `newWindow`

**Events**:
- `TwapWindowChanged(projectId, terminalToken, oldWindow, newWindow, caller)` -- emitted with both old and new values

**Edge cases**:
- `JBBuybackHook_InvalidTwapWindow(value, min, max)` -- reverts if `newWindow < 300` or `newWindow > 172800`
- Unlike the pool itself, the TWAP window can be changed multiple times (not immutable)

**Result:** Future oracle queries for this project/token pair use a 10-minute TWAP window. This can be called multiple times (not immutable like the pool itself).

---

## 5. Register Hook via Registry

A project owner assigns a specific buyback hook implementation via the registry.

**Entry point**: `JBBuybackHookRegistry.setHookFor(uint256 projectId, IJBRulesetDataHook hook)`

**Who can call**: The project owner, or an address with the owner's `SET_BUYBACK_HOOK` permission.

**Parameters**:
- `projectId` -- The ID of the project to configure
- `hook` -- The buyback hook implementation to assign. Pass `IJBRulesetDataHook(address(0))` (if allowed) to clear back to the default hook.

**Prerequisite**: The hook must first be allowed by the registry owner via `allowHook(hook)`.

**Actors:** Project owner, Registry owner, JBBuybackHookRegistry

**Steps:**

1. Registry owner calls `JBBuybackHookRegistry.allowHook(hookAddress)` to add the implementation to the allowlist.

2. Project owner calls `JBBuybackHookRegistry.setHookFor(projectId, hookAddress)`.

3. Registry checks:
   - `hasLockedHook[projectId]` is false (reverts with `HookLocked` otherwise).
   - `isHookAllowed[hookAddress]` is true (reverts with `HookNotAllowed` otherwise).
   - Caller has `SET_BUYBACK_HOOK` permission from the project owner.

4. Stores `_hookOf[projectId] = hookAddress`.

**State changes**:
1. `JBBuybackHookRegistry.isHookAllowed[hook]` -- set to `true` (in the `allowHook` step)
2. `JBBuybackHookRegistry._hookOf[projectId]` -- set to the specified hook address

**Events**:
- `JBBuybackHookRegistry_AllowHook(hook)` -- emitted when the registry owner allows a hook
- `JBBuybackHookRegistry_SetHook(projectId, hook)` -- emitted when the project's hook is set

**Edge cases**:
- `JBBuybackHookRegistry_HookLocked(projectId)` -- reverts if the project's hook has been locked
- `JBBuybackHookRegistry_HookNotAllowed(hook)` -- reverts if the hook is not on the allowlist
- Setting `address(0)` as the hook (if allowed) returns the project to using the default hook
- A disallowed hook does not affect projects that already have it set -- disallowing only prevents new assignments

**Result:** This project now uses the specified hook implementation instead of the default. The registry's `beforePayRecordedWith` will delegate to this hook for all future payments.

---

## 5b. Allow / Disallow Hook

The registry owner manages the hook allowlist.

**Entry points**:
- `JBBuybackHookRegistry.allowHook(IJBRulesetDataHook hook)`
- `JBBuybackHookRegistry.disallowHook(IJBRulesetDataHook hook)`

**Who can call**: Only the registry owner (`onlyOwner`).

**Parameters**:
- `hook` -- The hook implementation to allow or disallow

**State changes**:
1. `JBBuybackHookRegistry.isHookAllowed[hook]` -- set to `true` (allow) or `false` (disallow)

**Events**:
- `JBBuybackHookRegistry_AllowHook(hook)` -- emitted when a hook is allowed
- `JBBuybackHookRegistry_DisallowHook(hook)` -- emitted when a hook is disallowed

**Edge cases**:
- `JBBuybackHookRegistry_CannotDisallowDefaultHook()` -- reverts if attempting to disallow the current default hook (would break payments for projects relying on it)
- Allowing `address(0)` is permitted by design -- it provides a mechanism for authorized operators to clear a project's hook assignment via `setHookFor`, returning to the default hook
- Disallowing a hook does not affect projects that already have it assigned; it only prevents new assignments via `setHookFor`

---

## 5c. Set Default Hook

The registry owner sets the default hook used by projects that have not assigned a specific hook.

**Entry point**: `JBBuybackHookRegistry.setDefaultHook(IJBRulesetDataHook hook)`

**Who can call**: Only the registry owner (`onlyOwner`).

**Parameters**:
- `hook` -- The hook to set as the default (must not be `address(0)`)

**State changes**:
1. `JBBuybackHookRegistry.defaultHook` -- set to the specified hook
2. `JBBuybackHookRegistry.isHookAllowed[hook]` -- set to `true` (automatically allowed)

**Events**:
- `JBBuybackHookRegistry_SetDefaultHook(hook)` -- emitted after the default hook is updated

**Edge cases**:
- `JBBuybackHookRegistry_ZeroHook()` -- reverts if `hook` is `address(0)` (would break payments for projects relying on the default)

---

## 6. Lock Hook

A project owner permanently locks their buyback hook, preventing future changes.

**Entry point**: `JBBuybackHookRegistry.lockHookFor(uint256 projectId, IJBRulesetDataHook expectedHook)`

**Who can call**: The project owner, or an address with the owner's `SET_BUYBACK_HOOK` permission.

**Parameters**:
- `projectId` -- The ID of the project to lock
- `expectedHook` -- The hook the caller expects to lock (race condition guard)

**Steps:**

1. Project owner calls `JBBuybackHookRegistry.lockHookFor(projectId, expectedHook)`.

2. Registry enforces `SET_BUYBACK_HOOK` permission from the project owner.

3. Resolves the current hook: checks `_hookOf[projectId]`, falls back to `defaultHook` if zero.

4. If the resolved hook is `address(0)` (no hook set and no default), reverts with `HookNotSet`.

5. If using the default, copies it to `_hookOf[projectId]` so the lock captures the specific implementation (not a floating reference to the default).

6. Verifies `resolvedHook == expectedHook` (reverts with `HookMismatch` if a race condition changed it).

7. Sets `hasLockedHook[projectId] = true`.

**State changes**:
1. `JBBuybackHookRegistry._hookOf[projectId]` -- set to the resolved hook (if it was previously defaulting)
2. `JBBuybackHookRegistry.hasLockedHook[projectId]` -- set to `true`

**Events**:
- `JBBuybackHookRegistry_LockHook(projectId)` -- emitted after the lock is applied

**Edge cases**:
- `JBBuybackHookRegistry_HookNotSet(projectId)` -- reverts if no hook is set and no default exists
- `JBBuybackHookRegistry_HookMismatch(currentHook, expectedHook)` -- reverts if the resolved hook does not match `expectedHook` (race condition protection)
- Once locked, `setHookFor` for this project will always revert with `JBBuybackHookRegistry_HookLocked(projectId)`
- Atomic set-and-lock is intentionally supported: calling `setHookFor` then `lockHookFor` in one transaction allows trusted operators to configure and finalize in a single tx

**Result:** The project's hook cannot be changed. Even if the registry owner disallows the hook or changes the default, this project continues using the locked implementation. Future calls to `setHookFor` for this project will revert.

---

## 7. Swap Fallback to Mint

A payment triggers the swap path, but the V4 swap reverts (e.g., insufficient liquidity, pool issue).

**Entry point**: `JBMultiTerminal.pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)`

**Who can call**: Anyone (via the terminal).

**Actors:** Payer, JBMultiTerminal, JBBuybackHook, V4 PoolManager

**Steps:**

1-8. Same as Journey 1 (swap wins), through the hook entering `afterPayRecordedWith` and pulling ERC-20 tokens (if applicable).

9. The hook calls `_swap()`, which calls `POOL_MANAGER.unlock(callbackData)`.

10. Inside `unlockCallback`, `POOL_MANAGER.swap()` reverts (insufficient liquidity, pool not initialized, etc.).

11. The `try POOL_MANAGER.unlock(...)` catch block catches the revert. `_swap()` returns `(0, swapFailed=true)`. No tokens were received, so no burn occurs inside `_swap()`.

12. Back in `afterPayRecordedWith`:
    - `swapFailed == true`, so the slippage check is skipped (no revert even though `exactSwapAmountOut = 0 < minimumSwapAmountOut`).

13. Computes `leftover = balanceAfter - balanceBefore`. Since no tokens were consumed by the swap, `leftover == amountToSwapWith`.

14. Returns all tokens to the terminal via `addToBalanceOf` (for ERC-20, the hook first approves the terminal via `forceApprove`, then calls `addToBalanceOf` with `payValue = 0`).

15. Computes `partialMintTokenCount = leftover * weight / weightRatio`, plus `amountToMintWith * weight / weightRatio` if the payer specified a non-swap portion.

16. Mints `totalTokensToMint = exactSwapAmountOut + partialMintTokenCount` (i.e., 0 + partialMintTokenCount) for the beneficiary via the controller.

**State changes**:
1. `JBTerminalStore.balanceOf[terminal][projectId][token]` -- incremented by the full payment amount (returned via `addToBalanceOf`)
2. `JBTokens` -- mints tokens to beneficiary at the standard mint rate
3. `JBController.pendingReservedTokenBalanceOf[projectId]` -- incremented by reserved portion

**Events**:
- `Mint(projectId, leftoverAmount, tokenCount, caller)` -- emitted on `JBBuybackHook` for the leftover amount being minted
- No `Swap(...)` event is emitted (the swap failed)

**Edge cases**:
- The swap failure is silently absorbed via try-catch -- no revert propagated to the payer
- The payer receives tokens at the mint rate as if the buyback hook did not exist
- If `weight = 0`, no tokens are minted (`totalTokensToMint = 0`) and the mint call is skipped

**Result:** The payer receives tokens at the mint rate as if the buyback hook did not exist. No funds are lost. The swap failure is silently absorbed.

---

## 8. Partial Fill Handling

The V4 swap executes but only partially fills due to the `sqrtPriceLimit` being hit.

**Entry point**: `JBMultiTerminal.pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)`

**Who can call**: Anyone (via the terminal).

**Actors:** Payer, JBBuybackHook, V4 PoolManager

**Steps:**

1-10. Same as Journey 1. The hook enters `unlockCallback`.

11. `POOL_MANAGER.swap()` executes but hits the `sqrtPriceLimit` before consuming all input:
   - `inputAmount = 0.7 ether` (consumed by swap).
   - `outputAmount = 350` project tokens (received from swap).
   - The remaining `0.3 ether` is not consumed.

12. Settlement: hook settles `0.7 ether` with `POOL_MANAGER.settle{value: 0.7 ether}()` and takes `350` project tokens.

13. Still inside `_swap()`, the hook emits the `Swap` event and then burns the 350 project tokens via `controller.burnTokensOf(address(this), projectId, 350, "")`. Both happen inside `_swap()` before it returns.

14. Back in `afterPayRecordedWith`:
    - Slippage check: `exactSwapAmountOut = 350` passes `>= minimumSwapAmountOut`.
    - Computes `leftover = balanceAfter - balanceBefore = 0.3 ether` (the unconsumed portion).

15. Returns 0.3 ETH to the terminal via `addToBalanceOf{value: 0.3 ether}(...)` (for ERC-20, the hook approves the terminal via `forceApprove` before calling `addToBalanceOf`).

16. Computes `partialMintTokenCount = 0.3 ether * weight / weightRatio` (e.g., 120 tokens), plus `amountToMintWith * weight / weightRatio` if the payer specified a non-swap portion.

17. Mints `totalTokensToMint = exactSwapAmountOut + partialMintTokenCount` (i.e., 350 + 120 = 470) total tokens for the beneficiary.

**State changes**:
1. V4 pool state -- partial swap executed
2. Project token `balanceOf[buybackHook]` -- temporarily receives 350 tokens, then burned (inside `_swap()`)
3. `JBTerminalStore.balanceOf[terminal][projectId][token]` -- incremented by 0.3 ETH leftover via `addToBalanceOf`
4. `JBTokens` -- mints 470 tokens to beneficiary (subject to reserved percent)
5. `JBController.pendingReservedTokenBalanceOf[projectId]` -- incremented by reserved portion

**Events**:
- `Swap(projectId, amountToSwapWith, poolId, 350, caller)` -- emitted for the partial swap (note: `amountToSwapWith` is the full intended amount, not the amount actually consumed)
- `Mint(projectId, 0.3 ether, 120, caller)` -- emitted for the leftover mint portion

**Edge cases**:
- The `sqrtPriceLimit` is derived from `minimumSwapAmountOut / amountIn`, ensuring the swap stops before the execution price degrades below the minimum acceptable rate
- Both the swap portion (350 tokens) and the mint portion (120 tokens) respect the reserved percent during the final `controller.mintTokensOf` call

**Result:** The payer gets 350 tokens from the swap (at the pool rate) plus 120 tokens from minting (at the mint rate). The partial fill is handled seamlessly. Both portions respect the reserved percent during minting.
