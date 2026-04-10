# Juicebox Buyback Hook Risk Register

This file focuses on the routing, MEV, and composition risks in the buyback hook that compares Juicebox minting or cash-out against external AMM execution.

## How to use this file

- Read `Priority risks` first; those are the routing failures with the largest user-impact potential.
- Use the detailed sections for economic, MEV, and same-pool composition reasoning.
- Treat `Invariants to Verify` as hard requirements before relying on this hook in production routing.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Wrong-route execution from stale estimates | If the hook mis-estimates protocol or pool output, users can be routed to a materially worse path. | Preview surfaces, TWAP-based pricing, try/catch fallbacks, and strict slippage floors. |
| P1 | Same-pool recursion and composition complexity | Buyback composition with the V4 router creates deep call chains where a subtle ordering bug can cascade. | Explicit recursion guards, fallback-to-mint behavior, and composition-focused tests. |
| P1 | MEV around route selection | Buyback routing exposes an attacker incentive to manipulate the comparison boundary, especially around low-liquidity or stale-price conditions. | TWAP use, slippage controls, and operational caution on thin markets. |


## 1. Trust Assumptions

- **Uniswap V4 PoolManager**: Immutable singleton (`POOL_MANAGER`). All swap settlement flows through `unlock()` -> `unlockCallback()` -> `swap()` -> `settle()`/`take()`. A compromised PoolManager can drain any funds sent during settlement. The hook authenticates only via `msg.sender == POOL_MANAGER` in `unlockCallback` -- no further defense against a malicious PoolManager.
- **Oracle Hook (IGeomeanOracle)**: TWAP integrity depends entirely on the `hooks` field of the PoolKey. The hook calls `IGeomeanOracle(address(key.hooks)).observe()`. A malicious or buggy oracle can return arbitrary tick cumulatives, skewing the TWAP quote in either direction. The `ORACLE_HOOK` is set at construction and baked into all pool keys built by `_buildPoolKey`.
- **Oracle Failure Behavior**: When the oracle `observe()` reverts (catch block in `JBSwapLib.getQuoteFromOracle`), the library returns `(0, 0, 0)`, which forces the mint path for oracle-dependent flows. This prevents sandwich attacks during oracle warmup, but it does not disable swaps for callers that provide explicit quote metadata or explicit sell-side minimums, because those paths can bypass the oracle lookup entirely.
- **JB Core Contracts**: The hook trusts `DIRECTORY.isTerminalOf()` for caller authentication, `controller.currentRulesetOf()` for ruleset data, and `controller.mintTokensOf()`/`burnTokensOf()` for token operations. A compromised controller can mint unlimited tokens or refuse to burn swapped tokens.
- **Registry Owner Centralization**: `JBBuybackHookRegistry` owner (`Ownable`) controls `allowHook()`, `disallowHook()`, `setDefaultHook()`. Changing the default hook silently redirects all unlocked projects. Disallowing a hook does not affect locked projects (by design), but a rug of the default hook implementation affects every project that has not locked.

## 2. Economic Risks

- **Mint-vs-Swap Routing Manipulation**: The decision at `beforePayRecordedWith` compares `tokenCountWithoutHook` (bonding curve mint) against `minimumSwapAmountOut` (TWAP-derived by default, or explicitly provided via `"quote"` metadata — when explicit, the TWAP lookup is skipped). An attacker who can suppress the TWAP quote (e.g., by draining pool liquidity so `harmonicMeanLiquidity == 0` triggers return 0) forces the mint path when swap would have been more favorable -- or vice versa by inflating the TWAP above fair value. With noop hook specifications in core, the mint path can still surface pool diagnostics without invoking `afterPayRecordedWith`.
- **TWAP Window Selection**: Configurable from `MIN_TWAP_WINDOW` (5 minutes / 25 blocks) to `MAX_TWAP_WINDOW` (2 days). Shorter windows are cheaper to manipulate via multi-block MEV. Longer windows lag real price movements, potentially routing swaps at stale prices. No dynamic adjustment -- the project owner must choose a static trade-off via `setTwapWindowOf`.
- **Sigmoid Slippage Function Edge Cases**:
  - `MAX_SLIPPAGE = 8800` (88%) means the hook can accept receiving only 12% of the oracle quote for high-impact swaps in thin pools. This is by design but permits significant value loss.
  - `SIGMOID_K = 5e16` is hardcoded. Cannot be tuned per-pool or per-project. The inflection point may not suit all liquidity profiles.
  - When `impact == 0` (tiny swap in deep pool), tolerance floors at `max(poolFee + 100bps, 200bps)`. A pool with 0.01% fee still gets 200bps minimum tolerance.
  - When `slippageTolerance >= TWAP_SLIPPAGE_DENOMINATOR` (10,000), `_getQuote` returns 0 -> forced mint fallback.
- **Non-18-Decimal Token Handling (known test gap)**: `calculateImpact` computes `mulDiv(amountIn, IMPACT_PRECISION, liquidity)`. With 6-decimal tokens (USDC), `amountIn` is 1e12 smaller for equivalent value, producing proportionally smaller impact values. This shifts the sigmoid curve, giving tighter slippage (closer to `minSlippage`) for equivalent economic impact. This is a known test coverage gap — no tests exercise non-18-decimal tokens through the sigmoid path. The functional risk is LOW (tighter slippage is conservative, not exploitable), but edge cases around very small 6-decimal amounts producing zero impact (and thus minimum slippage) have not been verified.
- **Cross-Currency Weight Ratio**: When `amount.currency != ruleset.baseCurrency()`, the hook queries `PRICES.pricePerUnitOf()` for the weight ratio. If the price feed is inaccurate, the mint-vs-swap comparison uses wrong token counts, potentially routing incorrectly. If the price feed reverts, the entire payment reverts.
- **`amountToSwapWith` Defaults to Full Payment**: When no payer metadata specifies a swap amount, the entire `totalPaid` routes through the swap. Partial minting is only possible via explicit metadata.
- **Pool Immutability Trade-off**: `_poolIsSet` is one-shot -- once set, the pool for a project/token pair can never be changed. If the pool drains to zero liquidity, the hook falls back to minting forever. The project cannot migrate to a new pool. Only `twapWindowOf` remains adjustable. Note: `setTwapWindowOf` now requires a pool to be configured first (reverts with `PoolNotSet` otherwise).
- **Dynamic-Fee Pool LP Fee**: For dynamic-fee pools, the slippage calculation reads the actual LP fee from `POOL_MANAGER.getSlot0()` rather than using `key.fee`. If the LP fee changes between the `beforePayRecordedWith` view call and the `afterPayRecordedWith` execution, the slippage tolerance used in the data hook phase may be based on a different fee than what the swap actually incurs. This is a transient inconsistency -- the issuance-rate price limit and minimum output check in the pay hook still protect against value loss.

## 3. MEV / Sandwich Risks

- **Three-Layer Protection Pipeline**:
  1. TWAP or explicit quote floor: when the payer provides an explicit `minimumSwapAmountOut` via metadata, that floor is honored directly and the TWAP lookup is skipped. When no explicit quote is provided, the TWAP oracle supplies the slippage floor. The sell side follows the same pattern with `cashOutMinReclaimed` metadata.
  2. Sigmoid slippage: continuous tolerance based on estimated price impact and pool fee. No cliff exploitable at a single threshold. Applied only when using the TWAP path (skipped when the payer provides an explicit quote).
  3. `sqrtPriceLimitFromAmounts` circuit breaker: computed in `unlockCallback`, enforces a hard price floor on the V4 swap. If an attacker frontruns past this limit, the PoolManager returns a partial/zero fill -> leftover routes to `addToBalanceOf` -> minted at weight.
- **Sandwich Attack Outcome**: When circuit breaker fires, victim gets mint-rate tokens (zero MEV extraction). Attacker loses 2x pool fees on the round trip.
- **TWAP Manipulation Cost**: 5-minute minimum window requires dominating 25 consecutive blocks. For a 1M-liquidity pool, ~10,000 ETH of capital plus ~60 ETH in round-trip fees. Economically viable only for very large payments (>10,000 ETH). Risk: LOW for typical projects, MEDIUM for whale-sized payments.
- **Oracle Warmup Mint-Only Period for no-quote flows**: Newly initialized pools lack observation history. The oracle `observe()` will revert until enough observations accumulate (~30 min). During this warmup period, oracle-dependent flows force the mint path. This is intentional — spot-price fallback was removed because it is trivially sandwich-attackable. Callers that supply explicit quote metadata can still route through the swap path during warmup.
- **Front-Running the Routing Decision**: `beforePayRecordedWith` is a `view` call executed by the terminal. An attacker who sees the pending payment in the mempool can manipulate the pool state to influence whether the hook returns `weight=0` (swap path) or `weight=original` (mint path with noop diagnostics). However, the TWAP resists single-block manipulation, and the payer quote provides an additional floor.

## 4. Composition with JBUniswapV4Hook

- **Same-pool composition**: In production, `ORACLE_HOOK` is typically `JBUniswapV4Hook`, which also serves as the V4 pool hook (`PoolKey.hooks`). The buyback hook queries the oracle and executes swaps on the same pool.
- **Reentrancy path**: When the buyback hook swaps, `JBUniswapV4Hook._beforeSwap()` fires. If the router hook decides to route through Juicebox (calling `terminal.pay()`), this re-enters the buyback hook via the data hook. The `_routing` reentrancy guard in `JBUniswapV4Hook` detects this recursion and reverts.
- **hookData format**: The buyback hook passes `hookData: abi.encode(uint256(0))` to the V4 swap. The `0` value delegates slippage protection to `JBUniswapV4Hook`'s own TWAP oracle rather than specifying a fixed minimum output. `JBUniswapV4Hook._beforeSwap()` requires exactly 32 bytes of hookData — empty bytes (`""`) would revert with `AmountOutMinRequired`.
- **Double fallback**: The reentrancy guard revert is caught by the buyback hook's try/catch in `_swap()`, falling back to minting. This is the expected behavior — the buyback hook's TWAP comparison already determined that swapping is better than minting, but if the swap can't execute, minting is the safe fallback.
- **Oracle warmup interaction**: During the first ~30 minutes after pool creation, the oracle lacks sufficient observations. Both `JBUniswapV4Hook` (spot fallback) and `JBBuybackHook` (mint fallback via 0 quote) degrade gracefully — payments always succeed via minting.

## 5. Multi-Pool Risks

- **Independent Pool Configurations Per Terminal Token**: Each `(projectId, terminalToken)` pair has its own PoolKey, TWAP window, and `_poolIsSet` flag. Pools operate independently -- a manipulated ETH pool does not affect a USDC pool for the same project.
- **TWAP Window Is Per-Project-Per-Token**: `twapWindowOf[projectId][normalizedTerminalToken]` is stored independently for each terminal token. Projects can set different TWAP windows for ETH vs USDC pools.
- **Pool Key Collision**: Two projects could configure the same underlying V4 pool (same PoolKey). The hook does not prevent this. If project A's pool key points to the same pool as project B's, manipulation of the pool affects both projects. The hook validates currencies match but not uniqueness across projects.
- **No Pool Migration**: If a pool's liquidity dries up, the project cannot switch to a different pool for the same terminal token. The hook permanently falls back to the mint path for that pair.
- **Shared Oracle Hook**: `ORACLE_HOOK` is immutable at construction and baked into all pool keys constructed via `_buildPoolKey`. All projects share the same oracle hook implementation. The `setPoolFor(PoolKey)` overload allows custom hooks per pool, but the simplified overload always uses `ORACLE_HOOK`.

## 6. Access Control

- **`SET_BUYBACK_POOL`** (JBPermissionIds): Required for `setPoolFor` and `initializePoolFor`. One-shot per (project, terminalToken) pair. Checked via `_requirePermissionFrom` against project owner. Delegatable via JBPermissions.
- **`SET_BUYBACK_TWAP`** (JBPermissionIds): Required for `setTwapWindowOf`. Can be called repeatedly. Bounded to [5 minutes, 2 days]. Delegatable.
- **`SET_BUYBACK_HOOK`** (JBPermissionIds): Required for `setHookFor` and `lockHookFor` on the registry. `setHookFor` is blocked when `hasLockedHook[projectId] == true`. `lockHookFor` requires an `expectedHook` parameter to prevent race conditions.
- **Registry Owner** (`onlyOwner`): `allowHook`, `disallowHook`, `setDefaultHook`. Cannot disallow the current default hook (`CannotDisallowDefaultHook` revert). Cannot set `address(0)` as default (`ZeroHook` revert).
- **Pool Registration Permissions**: The registry's `setPoolFor` and `initializePoolFor` enforce `SET_BUYBACK_POOL` at the registry level, then forward to the resolved hook's `setPoolFor`/`initializePoolFor`, which enforces `SET_BUYBACK_POOL` again. Double permission check -- the hook-level check is the effective gate.
- **`unlockCallback` Gating**: Only `POOL_MANAGER` can call. No user or external contract can trigger the swap settlement path directly.
- **`afterPayRecordedWith` Gating**: Only verified terminals (via `DIRECTORY.isTerminalOf`) can call. Prevents arbitrary callers from triggering swaps.
- **`afterCashOutRecordedWith` Gating**: Only verified terminals can call. Prevents arbitrary callers from reminting burned tokens into the hook and forcing a sell-side swap.

## 7. DoS Vectors

- **JBPrices Revert**: If `PRICES.pricePerUnitOf()` reverts (stale Chainlink feed, missing feed), both `beforePayRecordedWith` and `afterPayRecordedWith` revert. All buyback-routed payments halt for cross-currency projects. Workaround: change ruleset `baseCurrency` to match terminal currency.
- **Controller Mint/Burn Revert**: If `controller.mintTokensOf()` or `burnTokensOf()` reverts, the entire payment fails. No fallback.
- **`addToBalanceOf` Revert**: If the terminal's `addToBalanceOf` reverts when returning leftover funds, the payment fails and tokens remain stuck in the hook. No recovery mechanism. The terminal is trusted (it is `msg.sender`).
- **Pool Deinitialization**: If a V4 pool's `sqrtPriceX96` becomes 0 (not possible in practice), `_getQuote` returns 0, permanently forcing the mint path.
- **Gas Exhaustion**: The swap path involves `unlock` -> `unlockCallback` -> `swap` -> `settle`/`take` -> `burnTokensOf` -> `addToBalanceOf` -> `mintTokensOf`. Multiple external calls. If gas is tight, the swap may fail and fall back to mint (caught by try/catch). Explicit caller-provided minimums can still cause a revert after that failure; oracle-derived routing minimums do not. The mint fallback itself still requires `addToBalanceOf` + `mintTokensOf`.

## 8. Invariants to Verify

- **Users always get at least their specified minimum**: `beforePayRecordedWith` only routes to swap when `minimumSwapAmountOut > tokenCountWithoutHook`. Otherwise it returns the normal mint weight plus a noop informational pay spec. On the swap path, the `sqrtPriceLimit` is set to the issuance rate (`tokenCountWithoutHook / amountIn`), so the swap fills only while the pool offers a better rate for the payer than minting. Any unconsumed tokens are minted at the issuance rate. The combined output (swap + leftover mint) must meet the caller's explicit `minimumSwapAmountOut`, otherwise the transaction reverts. For oracle-derived routing minimums, a total swap failure can still degrade to mint fallback.
- **Cash-out beneficiaries always get at least direct protocol cash-out value when routed through the pool**: `beforeCashOutRecordedWith` only routes to the sell path when the sell-side minimum beats the direct reclaim amount. That sell-side minimum comes from explicit `cashOutMinReclaimed` metadata when provided, otherwise from the TWAP/geomean oracle path.
- **Cash-out sell count matches data hook intent**: `afterCashOutRecordedWith` decodes `cashOutCountToSell` from `hookMetadata` rather than using `context.cashOutCount`. This prevents fee bypass when a wrapper (e.g. REVDeployer) splits the cash-out into fee and non-fee tranches -- without this, the hook would remint and sell the full count (including fee tokens), double-monetizing the fee. When metadata is empty, the hook falls back to `context.cashOutCount` for backwards compatibility.
- **Swap fallback to mint works correctly**: When `POOL_MANAGER.unlock()` reverts, `_swap` returns `(0, true)`. All payment tokens become leftover, are sent to `addToBalanceOf`, and minted at the current weight. Explicit caller minima remain enforceable after that failure; oracle-derived routing minima allow the mint fallback to complete. Verified by `SwapFailureMintFallback.t.sol`.
- **No value extraction through routing manipulation**: The `sqrtPriceLimitFromAmounts` circuit breaker sets the swap's price limit to the issuance rate (`tokenCountWithoutHook / amountIn`). The swap only executes while the pool offers a better rate for the payer than minting. When the pool price reaches the issuance boundary, the swap stops and leftover is minted. There is no gap between the swap boundary and the mint rate for an attacker to exploit. The combined output is still checked against the user's minimum.
- **Leftover accounting is delta-based**: `balanceBefore` is captured before pulling funds (ETH: `address(this).balance - msg.value`; ERC-20: before `safeTransferFrom`). Leftover = `balanceAfter - balanceBefore`. Pre-existing contract balances do not inflate leftovers. Verified by `BalanceDeltaLeftover.t.sol`.
- **Pool key immutability**: `_poolIsSet[projectId][terminalToken]` is set to `true` on first `setPoolFor` and never cleared. Subsequent calls revert with `PoolAlreadySet`. The pool cannot be swapped to an attacker-controlled pool after configuration.
- **Token supply conservation**: Swapped project tokens are burned via `burnTokensOf`, then the total (swap output + leftover mint count) is re-minted via `mintTokensOf` with `useReservedPercent: true`. On the cash-out sell path, any partial-fill residue is burned from the actual swap input consumed (`cashOutCountToSell - amountSpent`), not from the hook's full project-token balance. Reserved rate applies uniformly regardless of routing path.
- **TWAP window bounds**: `twapWindow` is validated against `[MIN_TWAP_WINDOW, MAX_TWAP_WINDOW]` in both `_setPoolFor` and `setTwapWindowOf`. The `uint256 -> uint32` cast in `getQuoteFromOracle` is safe because `MAX_TWAP_WINDOW = 172800 < type(uint32).max`.
- **Registry lock prevents hook changes**: Once `hasLockedHook[projectId] == true`, `setHookFor` reverts with `HookLocked`. The `lockHookFor` function requires `expectedHook` to match the resolved hook, preventing race conditions.

## 9. Accepted Behaviors

### 9.1 Oracle warmup forces mint-only period (~30 minutes)

Newly initialized pools lack observation history. During the warmup period, `observe()` reverts and the catch block returns `(0, 0, 0)`, which makes oracle-dependent comparisons fall back to minting. This is intentional: the previous design used spot-price fallback during warmup, which was trivially sandwich-attackable. The mint-only period applies to callers that rely on the hook's oracle-derived minimums; callers that supply explicit quote metadata can still use the swap path. For no-quote users, this is a conservative degradation — no value is lost, but the swap-vs-mint optimization is temporarily disabled.

### 9.2 Pool immutability prevents migration to better liquidity

`_poolIsSet` is a one-shot flag. Once set, the pool for a `(projectId, terminalToken)` pair can never be changed, even if the pool's liquidity drops to zero. This is accepted because: (1) allowing pool changes would create an attack surface where a compromised operator redirects swaps to a manipulated pool, (2) the mint fallback ensures payments always succeed even with zero pool liquidity, and (3) `twapWindowOf` remains adjustable, so the project can adapt the TWAP window even if the pool cannot be changed. The trade-off is that a permanently drained pool forces the project into mint-only mode for that terminal token.

### 9.3 Token cache cannot become stale

`projectTokenOf[projectId]` is cached on `setPoolFor()`. JBTokens prevents token migration (both `setTokenFor()` and `deployERC20For()` revert with `JBTokens_ProjectAlreadyHasToken`), so the cache can never become stale. Proven by `JBBuybackHook_FalsePositives.t.sol`.

### 9.4 Fee-on-transfer (FOT) token handling in mint fallback

When a swap fails and leftover terminal tokens are returned to the terminal via `addToBalanceOf`, the hook measures the terminal's actual credited amount before minting fallback project tokens. For fee-on-transfer tokens, this avoids overissuing against value the terminal never reacquired on the return hop. Note: the swap path itself (V4 PoolManager settlement) still does not special-case fee-on-transfer behavior — projects using FOT terminal tokens should treat the broader Uniswap V4 integration surface as higher risk.

### 9.5 Pre-initialized pools can win the initial price race

`initializePoolFor()` catches `POOL_MANAGER.initialize(...)` failures and then proceeds to configure the hook against whatever pool state already exists. This is intentional so project owners can register an already-initialized pool, but it also means a third party can initialize the exact pool key first and choose the starting price. That is not an authorization bypass — the owner still decides whether to register that pool — but it is an accepted race on initial price selection.

### 9.6 Sell-side swaps fail closed instead of degrading to protocol reclaim

Once `beforeCashOutRecordedWith()` routes a cash-out through the pool, `afterCashOutRecordedWith()` executes `_swapExactInput()` without a native reclaim fallback. A hard swap failure reverts the cash-out rather than silently degrading to protocol reclaim. This preserves the sell-side minimum guarantee and avoids mixed accounting after `MAX_CASH_OUT_TAX_RATE` routing, at the cost of liveness when the external pool path is unavailable.
