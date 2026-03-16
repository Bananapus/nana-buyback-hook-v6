# RISKS.md -- nana-buyback-hook-v6

## 1. Trust Assumptions

- **Uniswap V4 PoolManager**: Immutable singleton (`POOL_MANAGER`). All swap settlement flows through `unlock()` -> `unlockCallback()` -> `swap()` -> `settle()`/`take()`. A compromised PoolManager can drain any funds sent during settlement. The hook authenticates only via `msg.sender == POOL_MANAGER` in `unlockCallback` -- no further defense against a malicious PoolManager.
- **Oracle Hook (IGeomeanOracle)**: TWAP integrity depends entirely on the `hooks` field of the PoolKey. The hook calls `IGeomeanOracle(address(key.hooks)).observe()`. A malicious or buggy oracle can return arbitrary tick cumulatives, skewing the TWAP quote in either direction. The `ORACLE_HOOK` is set at construction and baked into all pool keys built by `_buildPoolKey`.
- **Spot Price Fallback**: When the oracle `observe()` reverts (catch block in `JBSwapLib.getQuoteFromOracle`), the library silently falls back to `poolManager.getSlot0()` spot price. Spot is trivially manipulable within a single block. The "TWAP" minimum becomes just spot + sigmoid slippage, degrading protection to a single layer.
- **JB Core Contracts**: The hook trusts `DIRECTORY.isTerminalOf()` for caller authentication, `controller.currentRulesetOf()` for ruleset data, and `controller.mintTokensOf()`/`burnTokensOf()` for token operations. A compromised controller can mint unlimited tokens or refuse to burn swapped tokens.
- **Registry Owner Centralization**: `JBBuybackHookRegistry` owner (`Ownable`) controls `allowHook()`, `disallowHook()`, `setDefaultHook()`. Changing the default hook silently redirects all unlocked projects. Disallowing a hook does not affect locked projects (by design), but a rug of the default hook implementation affects every project that has not locked.
- **Token Cache Immutability**: `projectTokenOf[projectId]` is cached on `setPoolFor()`. JBTokens prevents token migration (both `setTokenFor()` and `deployERC20For()` revert with `JBTokens_ProjectAlreadyHasToken`), so the cache can never become stale. Proven by `JBBuybackHook_FalsePositives.t.sol`.

## 2. Economic Risks

- **Mint-vs-Swap Routing Manipulation**: The decision at `beforePayRecordedWith` compares `tokenCountWithoutHook` (bonding curve mint) against `minimumSwapAmountOut` (TWAP-derived or payer-provided). An attacker who can suppress the TWAP quote (e.g., by draining pool liquidity so `harmonicMeanLiquidity == 0` triggers return 0) forces the mint path when swap would have been more favorable -- or vice versa by inflating the TWAP above fair value.
- **TWAP Window Selection**: Configurable from `MIN_TWAP_WINDOW` (5 minutes / 25 blocks) to `MAX_TWAP_WINDOW` (2 days). Shorter windows are cheaper to manipulate via multi-block MEV. Longer windows lag real price movements, potentially routing swaps at stale prices. No dynamic adjustment -- the project owner must choose a static trade-off via `setTwapWindowOf`.
- **Sigmoid Slippage Function Edge Cases**:
  - `MAX_SLIPPAGE = 8800` (88%) means the hook can accept receiving only 12% of the oracle quote for high-impact swaps in thin pools. This is by design but permits significant value loss.
  - `SIGMOID_K = 5e16` is hardcoded. Cannot be tuned per-pool or per-project. The inflection point may not suit all liquidity profiles.
  - When `impact == 0` (tiny swap in deep pool), tolerance floors at `max(poolFee + 100bps, 200bps)`. A pool with 0.01% fee still gets 200bps minimum tolerance.
  - When `slippageTolerance >= TWAP_SLIPPAGE_DENOMINATOR` (10,000), `_getQuote` returns 0 -> forced mint fallback.
- **Non-18-Decimal Token Handling**: `calculateImpact` computes `mulDiv(amountIn, IMPACT_PRECISION, liquidity)`. With 6-decimal tokens (USDC), `amountIn` is 1e12 smaller for equivalent value, producing proportionally smaller impact values. This shifts the sigmoid curve, giving tighter slippage (closer to `minSlippage`) for equivalent economic impact. No tests cover non-18-decimal tokens.
- **Cross-Currency Weight Ratio**: When `amount.currency != ruleset.baseCurrency()`, the hook queries `PRICES.pricePerUnitOf()` for the weight ratio. If the price feed is inaccurate, the mint-vs-swap comparison uses wrong token counts, potentially routing incorrectly. If the price feed reverts, the entire payment reverts.
- **`amountToSwapWith` Defaults to Full Payment**: When no payer metadata specifies a swap amount, the entire `totalPaid` routes through the swap. Partial minting is only possible via explicit metadata.
- **Pool Immutability Trade-off**: `_poolIsSet` is one-shot -- once set, the pool for a project/token pair can never be changed. If the pool drains to zero liquidity, the hook falls back to minting forever. The project cannot migrate to a new pool. Only `twapWindowOf` remains adjustable.

## 3. MEV / Sandwich Risks

- **Three-Layer Protection Pipeline**:
  1. TWAP cross-validation: `minimumSwapAmountOut = max(payerQuote, twapQuote)`. Neither a stale payer quote nor a manipulated oracle can unilaterally reduce the floor.
  2. Sigmoid slippage: continuous tolerance based on estimated price impact and pool fee. No cliff exploitable at a single threshold.
  3. `sqrtPriceLimitFromAmounts` circuit breaker: computed in `unlockCallback`, enforces a hard price floor on the V4 swap. If an attacker frontruns past this limit, the PoolManager returns a partial/zero fill -> leftover routes to `addToBalanceOf` -> minted at weight.
- **Sandwich Attack Outcome**: When circuit breaker fires, victim gets mint-rate tokens (zero MEV extraction). Attacker loses 2x pool fees on the round trip. Verified by `V4SandwichForkTest.t.sol::test_fork_sandwich_mintFallback` (asserts `attackerProfit < 0`).
- **TWAP Manipulation Cost**: 5-minute minimum window requires dominating 25 consecutive blocks. For a 1M-liquidity pool, ~10,000 ETH of capital plus ~60 ETH in round-trip fees. Economically viable only for very large payments (>10,000 ETH). Risk: LOW for typical projects, MEDIUM for whale-sized payments.
- **Spot Price Fallback During Oracle Warmup**: Newly initialized pools lack observation history. The oracle `observe()` will revert until enough observations accumulate. During this warmup period, all TWAP queries fall back to spot price. Single-block manipulation can then set an artificially favorable or unfavorable `minimumSwapAmountOut`. Mitigation is limited to the `sqrtPriceLimitFromAmounts` circuit breaker and any payer-provided quote.
- **Front-Running the Routing Decision**: `beforePayRecordedWith` is a `view` call executed by the terminal. An attacker who sees the pending payment in the mempool can manipulate the pool state to influence whether the hook returns `weight=0` (swap path) or `weight=original` (mint path). However, the TWAP resists single-block manipulation, and the payer quote provides an additional floor.

## 4. Multi-Pool Risks

- **Independent Pool Configurations Per Terminal Token**: Each `(projectId, terminalToken)` pair has its own PoolKey, TWAP window, and `_poolIsSet` flag. Pools operate independently -- a manipulated ETH pool does not affect a USDC pool for the same project.
- **TWAP Window Is Per-Project-Per-Token**: `twapWindowOf[projectId][normalizedTerminalToken]` is stored independently for each terminal token. Projects can set different TWAP windows for ETH vs USDC pools.
- **Pool Key Collision**: Two projects could configure the same underlying V4 pool (same PoolKey). The hook does not prevent this. If project A's pool key points to the same pool as project B's, manipulation of the pool affects both projects. The hook validates currencies match but not uniqueness across projects.
- **No Pool Migration**: If a pool's liquidity dries up, the project cannot switch to a different pool for the same terminal token. The hook permanently falls back to the mint path for that pair.
- **Shared Oracle Hook**: `ORACLE_HOOK` is immutable at construction and baked into all pool keys constructed via `_buildPoolKey`. All projects share the same oracle hook implementation. The `setPoolFor(PoolKey)` overload allows custom hooks per pool, but the simplified overload always uses `ORACLE_HOOK`.

## 5. Access Control

- **`SET_BUYBACK_POOL`** (JBPermissionIds): Required for `setPoolFor` and `initializePoolFor`. One-shot per (project, terminalToken) pair. Checked via `_requirePermissionFrom` against project owner. Delegatable via JBPermissions.
- **`SET_BUYBACK_TWAP`** (JBPermissionIds): Required for `setTwapWindowOf`. Can be called repeatedly. Bounded to [5 minutes, 2 days]. Delegatable.
- **`SET_BUYBACK_HOOK`** (JBPermissionIds): Required for `setHookFor` and `lockHookFor` on the registry. `setHookFor` is blocked when `hasLockedHook[projectId] == true`. `lockHookFor` requires an `expectedHook` parameter to prevent race conditions.
- **Registry Owner** (`onlyOwner`): `allowHook`, `disallowHook`, `setDefaultHook`. Cannot disallow the current default hook (`CannotDisallowDefaultHook` revert). Cannot set `address(0)` as default (`ZeroHook` revert).
- **Pool Registration Permissions**: The registry's `setPoolFor` and `initializePoolFor` enforce `SET_BUYBACK_POOL` at the registry level, then forward to the resolved hook's `setPoolFor`/`initializePoolFor`, which enforces `SET_BUYBACK_POOL` again. Double permission check -- the hook-level check is the effective gate.
- **`unlockCallback` Gating**: Only `POOL_MANAGER` can call. No user or external contract can trigger the swap settlement path directly.
- **`afterPayRecordedWith` Gating**: Only verified terminals (via `DIRECTORY.isTerminalOf`) can call. Prevents arbitrary callers from triggering swaps.

## 6. DoS Vectors

- **Pool Revert Cascading to Payment Failure**: If `POOL_MANAGER.unlock()` reverts, the try/catch in `_swap` catches it and sets `swapFailed = true`. The payment falls through to the mint path. No DoS -- the mint fallback is always available.
- **Oracle Observation Gaps**: If the oracle hook has insufficient observation history (newly initialized pool, or observations pruned), `observe()` reverts. The catch block falls back to spot price. No DoS, but degraded protection.
- **JBPrices Revert**: If `PRICES.pricePerUnitOf()` reverts (stale Chainlink feed, missing feed), both `beforePayRecordedWith` and `afterPayRecordedWith` revert. All buyback-routed payments halt for cross-currency projects. Workaround: change ruleset `baseCurrency` to match terminal currency.
- **Controller Mint/Burn Revert**: If `controller.mintTokensOf()` or `burnTokensOf()` reverts, the entire payment fails. No fallback.
- **`addToBalanceOf` Revert**: If the terminal's `addToBalanceOf` reverts when returning leftover funds, the payment fails and tokens remain stuck in the hook. No recovery mechanism. The terminal is trusted (it is `msg.sender`).
- **Pool Deinitialization**: If a V4 pool's `sqrtPriceX96` becomes 0 (not possible in practice), `_getQuote` returns 0, permanently forcing the mint path.
- **Gas Exhaustion**: The swap path involves `unlock` -> `unlockCallback` -> `swap` -> `settle`/`take` -> `burnTokensOf` -> `addToBalanceOf` -> `mintTokensOf`. Multiple external calls. If gas is tight, the swap may fail and fall back to mint (caught by try/catch). The mint fallback itself still requires `addToBalanceOf` + `mintTokensOf`.

## 7. Invariants to Verify

- **Users always get at least bonding curve value**: `beforePayRecordedWith` only routes to swap when `minimumSwapAmountOut > tokenCountWithoutHook`. If the swap produces less than `minimumSwapAmountOut`, either the slippage check reverts (non-failure case) or `swapFailed == true` triggers full mint fallback. The user never receives fewer tokens than the mint path would have provided.
- **Swap fallback to mint works correctly**: When `POOL_MANAGER.unlock()` reverts, `_swap` returns `(0, true)`. The slippage check is skipped (`!swapFailed` guard). All payment tokens become leftover, are sent to `addToBalanceOf`, and minted at the current weight. Verified by `SwapFailureMintFallback.t.sol`.
- **No value extraction through routing manipulation**: The `max(payerQuote, twapQuote)` cross-validation ensures neither party can unilaterally degrade the minimum. The `sqrtPriceLimitFromAmounts` circuit breaker prevents execution at prices worse than the minimum. Partial fills route leftover to mint. Fork-tested across multiple attack vectors.
- **Leftover accounting is delta-based**: `balanceBefore` is captured before pulling funds (ETH: `address(this).balance - msg.value`; ERC-20: before `safeTransferFrom`). Leftover = `balanceAfter - balanceBefore`. Pre-existing contract balances do not inflate leftovers. Verified by `BalanceDeltaLeftover.t.sol`.
- **Pool key immutability**: `_poolIsSet[projectId][terminalToken]` is set to `true` on first `setPoolFor` and never cleared. Subsequent calls revert with `PoolAlreadySet`. The pool cannot be swapped to an attacker-controlled pool after configuration.
- **Token supply conservation**: Swapped project tokens are burned via `burnTokensOf`, then the total (swap output + leftover mint count) is re-minted via `mintTokensOf` with `useReservedPercent: true`. Reserved rate applies uniformly regardless of routing path.
- **TWAP window bounds**: `twapWindow` is validated against `[MIN_TWAP_WINDOW, MAX_TWAP_WINDOW]` in both `_setPoolFor` and `setTwapWindowOf`. The `uint256 -> uint32` cast in `getQuoteFromOracle` is safe because `MAX_TWAP_WINDOW = 172800 < type(uint32).max`.
- **Registry lock prevents hook changes**: Once `hasLockedHook[projectId] == true`, `setHookFor` reverts with `HookLocked`. The `lockHookFor` function requires `expectedHook` to match the resolved hook, preventing race conditions.
