# Audit Instructions

You are auditing the Juicebox V6 buyback hook -- an on-chain mechanism that decides whether an incoming payment should mint new project tokens or buy them from a Uniswap V4 pool, whichever yields more tokens for the payer. Your goal is to find bugs that lose funds, enable MEV extraction, or bypass slippage protection.

Read [RISKS.md](./RISKS.md) for known risks and trust assumptions. Then come back here.

## Scope

**In scope -- all Solidity in `src/`:**
```
src/JBBuybackHook.sol           # Data hook + pay hook (~800 lines)
src/JBBuybackHookRegistry.sol   # Registry/router for hook implementations (~355 lines)
src/libraries/JBSwapLib.sol     # Oracle queries, sigmoid slippage, price limits (~332 lines)
src/interfaces/                 # IJBBuybackHook, IJBBuybackHookRegistry, IGeomeanOracle
```

**Out of scope:** Test files (`test/`), OpenZeppelin/Uniswap V4/Solady dependencies (assume correct), forge-std.

## Architecture

Three contracts form the buyback system:

### JBBuybackHook (src/JBBuybackHook.sol)

The core contract. Implements `IJBRulesetDataHook` (called during payment and cash-out recording), `IJBPayHook` (called during payment fulfillment), and `IJBCashOutHook` (called during cash-out fulfillment).

**Immutables:** `DIRECTORY`, `PRICES`, `PROJECTS`, `TOKENS`, `POOL_MANAGER` (V4 singleton), `ORACLE_HOOK` (shared oracle for all JB V4 pools).

**Key state:**
- `_poolKeyOf[projectId][terminalToken]` -- V4 PoolKey for each project/token pair
- `_poolIsSet[projectId][terminalToken]` -- immutability flag (once set, cannot change)
- `projectTokenOf[projectId]` -- cached project token address
- `twapWindowOf[projectId][terminalToken]` -- TWAP window in seconds

**Key functions:**
- `beforePayRecordedWith(JBBeforePayRecordedContext)` -- Data hook. Computes swap-vs-mint decision. Returns `weight=0` with an active pay hook spec when swapping wins, or the original weight plus a noop pay hook spec when minting wins and a pool is configured. The hook spec metadata encodes 10 fields: `(projectTokenIs0, mintFromExcess, minimumSwapAmountOut, controller, tokenCountWithoutHook, twapTick, twapLiquidity, poolId, minimumBeneficiaryTokenCount, minimumReservedTokenCount)`. Fields 1-4 are consumed by `afterPayRecordedWith`; fields 5-10 are informational for preview clients.
- `afterPayRecordedWith(JBAfterPayRecordedContext)` -- Pay hook. Executes the swap via V4 unlock/callback, burns received project tokens, computes leftover, mints tokens for leftover + swap amount.
- `beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext)` -- Data hook. Compares direct protocol cash-out value against a TWAP-protected pool sell quote. Returns a cash-out hook spec when selling into the pool is better.
- `afterCashOutRecordedWith(JBAfterCashOutRecordedContext)` -- Cash-out hook. Remints burned project tokens to the hook, executes the pool sale, and forwards proceeds to the beneficiary.
- `unlockCallback(bytes)` -- V4 PoolManager callback. Executes `swap()`, settles input tokens, takes output tokens. Only callable by `POOL_MANAGER`.
- `setPoolFor(projectId, PoolKey, twapWindow, terminalToken)` -- Configure pool (immutable once set). Requires `SET_BUYBACK_POOL` permission.
- `setPoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken)` -- Simplified overload that builds the PoolKey internally.
- `initializePoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken, sqrtPriceX96)` -- Atomically initializes pool in V4 PoolManager and configures it.
- `setTwapWindowOf(projectId, terminalToken, newWindow)` -- Adjust TWAP window (5 min to 2 days). Requires `SET_BUYBACK_TWAP` permission.
### JBBuybackHookRegistry (src/JBBuybackHookRegistry.sol)

A routing layer that maps projects to buyback hook implementations. Set as the data hook in a project's ruleset; delegates `beforePayRecordedWith` calls to the resolved hook implementation.

**Key functions:**
- `beforePayRecordedWith(context)` -- Resolves the hook for `context.projectId` (project-specific or default) and delegates the call.
- `beforeCashOutRecordedWith(context)` -- Resolves the hook for `context.projectId` (project-specific or default) and delegates the call.
- `hasMintPermissionFor(projectId, ruleset, addr)` -- Returns true only if `addr` is the resolved hook for the project.
- `hookOf(projectId)` -- Returns the resolved hook (project-specific or default fallback).
- `setHookFor(projectId, hook)` -- Set a project's hook. Requires `SET_BUYBACK_HOOK` permission. Reverts if locked.
- `lockHookFor(projectId, expectedHook)` -- Permanently lock a project's hook. `expectedHook` parameter prevents race conditions.
- `allowHook(hook)` / `disallowHook(hook)` -- Owner-only allowlist management.
- `setDefaultHook(hook)` -- Owner-only. Changes the default hook for all projects without a project-specific hook.
- `initializePoolFor(...)` / `setPoolFor(...)` -- Forward pool configuration calls to the resolved hook.

### JBSwapLib (src/libraries/JBSwapLib.sol)

Shared library for oracle queries, slippage calculations, and price limit computation.

**Key functions:**
- `getQuoteFromOracle(poolManager, key, twapWindow, amountIn, baseToken, quoteToken)` -- Queries TWAP from oracle hook via `IGeomeanOracle.observe()`. Returns `(0, 0, 0)` if the oracle reverts, forcing the mint path. Uses spot price via `getSlot0()` only when `twapWindow == 0`. Returns `(amountOut, arithmeticMeanTick, harmonicMeanLiquidity)`.
- `getSlippageTolerance(impact, poolFeeBps)` -- Sigmoid slippage: `minSlippage + (MAX_SLIPPAGE - minSlippage) * impact / (impact + K)`. Range: `max(poolFee + 100bps, 200bps)` to `8800bps` (88%).
- `calculateImpact(amountIn, liquidity, sqrtP, zeroForOne)` -- Estimates price impact at 1e18 precision.
- `getQuoteAtTick(tick, baseAmount, baseToken, quoteToken)` -- Pure math: token amount at a specific tick. Ported from Uniswap V3 OracleLibrary.
- `sqrtPriceLimitFromAmounts(amountIn, minimumAmountOut, zeroForOne)` -- Computes a V4-compatible `sqrtPriceLimitX96` that stops the swap if execution price exceeds the minimum acceptable rate.

**Key constants:**
- `SLIPPAGE_DENOMINATOR = 10_000`
- `MAX_SLIPPAGE = 8800` (88%)
- `IMPACT_PRECISION = 1e18`
- `SIGMOID_K = 5e16`

## Key Flows

### Swap-vs-Mint Decision (beforePayRecordedWith)

```
Terminal calls beforePayRecordedWith(context)
  |
  +--> Parse payer quote from metadata (amountToSwapWith, minimumSwapAmountOut)
  |    If no amountToSwapWith specified, use totalPaid
  |
  +--> Compute tokenCountWithoutHook = amountToSwapWith * weight / weightRatio
  |
  +--> Compute twapMinimum via _getQuote():
  |      1. getQuoteFromOracle() -- TWAP (returns 0 if oracle unavailable)
  |      2. calculateImpact() + getSlippageTolerance() -- sigmoid slippage
  |      3. amountOut * (DENOMINATOR - slippageTolerance) / DENOMINATOR
  |
  +--> minimumSwapAmountOut = max(payerQuote, twapMinimum)
  |
  +--> If minimumSwapAmountOut > tokenCountWithoutHook:
  |      Return weight=0 + JBPayHookSpecification(this, amountToSwapWith, metadata)
  |      metadata = abi.encode(
  |        projectTokenIs0,              // 1 — bool
  |        mintFromExcess,               // 2 — uint256
  |        minimumSwapAmountOut,         // 3 — uint256
  |        controller,                   // 4 — IJBController
  |        tokenCountWithoutHook,        // 5 — uint256 (informational)
  |        twapTick,                     // 6 — int24 (informational)
  |        twapLiquidity,               // 7 — uint128 (informational)
  |        poolId,                       // 8 — PoolId (informational)
  |        minimumBeneficiaryTokenCount, // 9 — uint256 (informational)
  |        minimumReservedTokenCount     // 10 — uint256 (informational)
  |      )
  |      NOTE: afterPayRecordedWith only decodes fields 1-4. Fields 5-10 are for preview clients.
  |    Else:
  |      Return original weight (mint path)
```

### Swap Execution (afterPayRecordedWith)

```
Terminal calls afterPayRecordedWith(context) with payment tokens
  |
  +--> Record balanceBefore (subtract msg.value for native ETH)
  +--> Pull ERC-20 tokens from terminal (safeTransferFrom)
  |
  +--> _swap():
  |      try POOL_MANAGER.unlock(callbackData):
  |        unlockCallback():
  |          Compute sqrtPriceLimit from amountIn + minimumSwapAmountOut
  |          POOL_MANAGER.swap(key, params)
  |          Settle input (ETH via value, ERC-20 via sync+transfer+settle)
  |          Take output project tokens
  |          Return outputAmount
  |      catch: return (0, swapFailed=true)
  |
  +--> If !swapFailed && exactSwapAmountOut < minimumSwapAmountOut: REVERT
  +--> Burn received project tokens (they'll be re-minted with reserves)
  |
  +--> Compute leftover = balanceAfter - balanceBefore
  +--> If leftover > 0:
  |      Return tokens to terminal via addToBalanceOf
  |      Compute partialMintTokenCount = leftover * weight / weightRatio
  |
  +--> Mint (exactSwapAmountOut + partialMintTokenCount) for beneficiary
  +--> Mint (exactSwapAmountOut + partialMintTokenCount) * reservedPercent for reserved
```

### Three-Layer MEV Protection

1. **TWAP or Explicit Quote Floor**: When the payer provides an explicit `minimumSwapAmountOut` via metadata, it is honored directly and the TWAP lookup is skipped. When no explicit quote is provided, the TWAP oracle supplies the slippage floor. The sell side follows the same pattern with `cashOutMinReclaimed` metadata.

2. **Sigmoid Slippage**: The TWAP-derived quote is reduced by a continuous sigmoid function of estimated price impact. Small swaps in deep pools get tight tolerance (~2%); large swaps in thin pools get wide tolerance (up to 88%). The sigmoid parameters (`SIGMOID_K = 5e16`, `IMPACT_PRECISION = 1e18`) are hardcoded.

3. **sqrtPriceLimit Circuit Breaker**: The V4 swap has a hard price limit computed from `amountIn` and `minimumSwapAmountOut`. If frontrunning pushes the price past this limit, the swap partially fills or returns zero. Leftover tokens are minted instead.

## Pool Configuration

- **Immutable once set**: `_poolIsSet[projectId][terminalToken]` prevents pool changes after initial configuration. A bad pool choice is permanent.
- **TWAP window adjustable**: `setTwapWindowOf()` can change the window between 5 minutes (`MIN_TWAP_WINDOW = 300`) and 2 days (`MAX_TWAP_WINDOW = 172800`).
- **Validation**: `_setPoolFor()` checks that the pool is initialized (`sqrtPriceX96 != 0`), currencies match (project token + terminal token), project has a token, and terminal token != project token.
- **Token cache**: `projectTokenOf[projectId]` is cached at `_setPoolFor()` time. The core protocol prevents token migration after deployment (`JBTokens_ProjectAlreadyHasToken`), so the cache cannot go stale.

## Priority Audit Areas

| Priority | Target | Why |
|----------|--------|-----|
| 1 | **Swap-vs-mint decision** (`beforePayRecordedWith`) | The core economic decision. If an attacker can force swaps when minting is better (or vice versa), they extract value. When the payer provides an explicit quote, it is honored directly (TWAP is skipped). When no quote is provided, the TWAP oracle supplies the floor. Verify the sigmoid slippage bounds, `tokenCountWithoutHook` comparison, and that explicit quotes cannot be used maliciously. |
| 2 | **unlockCallback + swap settlement** | All fund movement happens here. Verify: caller auth (only PoolManager), delta interpretation (positive = received, negative = spent), settle/take ordering, sqrtPriceLimit enforcement. |
| 3 | **Leftover handling** (`afterPayRecordedWith`) | Balance delta approach: `leftover = balanceAfter - balanceBefore`. Verify: native ETH msg.value subtraction, ERC-20 pull timing, addToBalanceOf failure path, mint arithmetic. |
| 4 | **Oracle unavailable behavior** | When `observe()` reverts, the hook returns `(0, 0, 0)` forcing the mint path. Verify: no swap occurs during oracle warmup, payer-provided quotes still work, no path bypasses this fallback. |
| 5 | **Registry delegation** | `beforePayRecordedWith` in the registry delegates to the resolved hook. Verify: hook resolution (project-specific vs default), `hasMintPermissionFor` consistency, lock/unlock race conditions. |
| 6 | **Price conversion** | `weightRatio` depends on `PRICES.pricePerUnitOf()` when `baseCurrency != payment currency`. Verify: currency mismatch handling, decimal scaling. |
| 7 | **sqrtPriceLimitFromAmounts overflow handling** | Three-tier precision approach for extreme price ratios. Verify: overflow guards, clamping to valid V4 range, behavior at boundary values. |
| 8 | **Composition with JBUniswapV4Hook** | In production, `ORACLE_HOOK` is `JBUniswapV4Hook`, which also serves as the V4 pool hook. The buyback hook passes `hookData: abi.encode(uint256(0))` — verify this doesn't bypass slippage protection. When the router hook re-routes through JB, a `_routing` reentrancy guard prevents infinite recursion. Verify: the try/catch fallback to minting works correctly, no tokens are lost in the reentrancy path. |

## Invariants to Verify

1. **No flash-loan profit**: Pay + cash out in the same block should never yield more tokens than a direct payment would mint (minus fees).
2. **Slippage floor**: When no explicit payer quote is provided, `minimumSwapAmountOut >= twapQuote * (1 - sigmoidSlippage)`. When an explicit payer quote is provided, it is honored directly.
3. **Token conservation**: `swappedTokens + mintedFromLeftover == totalTokensMintedForBeneficiary` (before reserved percent).
4. **Pool immutability**: Once `_poolIsSet[pid][token] = true`, no code path can change the pool key.
5. **Leftover non-negative**: `balanceAfter >= balanceBefore` always holds after swap (no underflow in leftover calculation).
6. **Burn-before-mint**: Project tokens from swap are always burned before any minting occurs.

## How to Run Tests

```bash
cd nana-buyback-hook-v6
npm install
forge build
forge test

# Run with high verbosity for debugging
forge test -vvvv --match-test testExploitName

# Write a PoC
forge test --match-path test/audit/ExploitPoC.t.sol -vvv

# Specific test suites
forge test --match-contract V4BuybackHook     # Core swap flow
forge test --match-contract JBSwapLibTest      # Library: sigmoid, impact, sqrtPriceLimit
forge test --match-contract MEVScenarios       # MEV attack scenarios
forge test --match-contract Registry           # Registry routing and permissions
forge test --match-path test/regression/       # Regression tests for prior bugs

# Fork tests (require RPC URL)
forge test --match-path test/fork/ --fork-url $ETH_RPC_URL

# Gas analysis
forge test --gas-report
```

The test suite covers: V4 swap flow, swap fallback to mint, sigmoid slippage bounds and monotonicity, sqrtPriceLimit precision, TWAP cross-validation, balance delta leftover accounting, registry hook resolution and locking, sandwich attack simulation, and 30+ fuzz tests. See RISKS.md for the full "What IS Tested" / "What is NOT Tested" breakdown.

## Previous Audit Findings

No prior formal audit with finding IDs has been conducted on this codebase. All risk analysis is internal. See [RISKS.md](./RISKS.md) for the full trust model and known risks.

## Anti-Patterns to Hunt

| Pattern | Where to Look | Why It's Dangerous |
|---------|--------------|-------------------|
| TWAP manipulation | `JBSwapLib.getQuoteFromOracle()` | Attacker can move the TWAP by trading in the pool over the observation window. Short TWAP windows (5 min minimum) are more vulnerable. |
| Sigmoid edge cases | `JBSwapLib.getSlippageTolerance()` | At extreme `impact` values, sigmoid saturates at `MAX_SLIPPAGE` (88%). Verify the function is monotonically increasing and bounded. |
| `try-catch` swallowing swap failures | `_swap()` in JBBuybackHook | A failed swap silently falls back to minting. If the swap failure is due to manipulation (not just liquidity), the mint path may give worse terms. |
| Oracle warmup period | `getQuoteFromOracle()` returns `(0,0,0)` on revert | During oracle warmup, all payments go through mint path. An attacker could time large payments during warmup to avoid price-aware routing. |
| `balanceAfter - balanceBefore` accounting | `afterPayRecordedWith` leftover calculation | Fee-on-transfer tokens or tokens with callbacks could make `balanceAfter` unexpected. The hook uses `safeTransferFrom` but doesn't validate the received amount. |
| Immutable pool key | `_poolIsSet` flag | Once set, a pool cannot be changed. If the pool is set to a low-liquidity or manipulable pool, the project is permanently vulnerable. |
| `hookData: abi.encode(uint256(0))` | Swap call in `unlockCallback` | This hookData is passed to the V4 pool hook (JBUniswapV4Hook). Verify this doesn't bypass slippage or routing protections in the pool hook. |
| Metadata decoding | `beforePayRecordedWith` payer quote parsing | Malformed metadata could cause `abi.decode` to revert or return unexpected values. Verify graceful handling of missing/malformed data. |

## Coverage Gaps

The test suite is comprehensive but these areas have limited coverage:

- **Multi-pool routing**: No tests where a single payment is split across multiple pools or where pool selection is contested.
- **Oracle manipulation over time**: Fuzz tests cover static oracle states but not dynamic TWAP manipulation across multiple blocks.
- **Fee-on-transfer tokens**: No tests with tokens that charge fees on transfer (affects balance delta calculations).
- **Concurrent buyback + cashout**: No tests where a buyback swap and a cash out from the same project execute in the same block.
- **Registry lock race conditions**: Limited testing of `lockHookFor` timing relative to `setHookFor` and `setDefaultHook`.
- **V4 pool hook interaction**: The interaction between buyback hook's `hookData` and the V4 pool hook (JBUniswapV4Hook) is tested in isolation but not under adversarial conditions.

## Error Reference

| Error | Contract | Trigger |
|-------|----------|---------|
| `JBBuybackHook_CallerNotPoolManager(address)` | JBBuybackHook | `unlockCallback` called by an address other than `POOL_MANAGER`. |
| `JBBuybackHook_CallerNotTerminal(address)` | JBBuybackHook | `afterPayRecordedWith` called by an address that is not a terminal of the project. |
| `JBBuybackHook_InsufficientPayAmount(uint256, uint256)` | JBBuybackHook | Payer-specified `amountToSwapWith` exceeds `totalPaid` in payment metadata. |
| `JBBuybackHook_InvalidTwapWindow(uint256, uint256, uint256)` | JBBuybackHook | TWAP window set outside the allowed range (`MIN_TWAP_WINDOW` to `MAX_TWAP_WINDOW`). Checked in `setTwapWindowOf` and `_setPoolFor`. |
| `JBBuybackHook_PoolAlreadySet(PoolId)` | JBBuybackHook | `_setPoolFor` called for a project/token pair that already has an immutable pool configured. |
| `JBBuybackHook_PoolNotInitialized(PoolId)` | JBBuybackHook | `_setPoolFor` called with a pool key whose pool has not been initialized in the V4 PoolManager (`sqrtPriceX96 == 0`). |
| `JBBuybackHook_SpecifiedSlippageExceeded(uint256, uint256)` | JBBuybackHook | Swap output is less than `minimumSwapAmountOut`. Checked in `afterPayRecordedWith` (pay path) and `afterCashOutRecordedWith` (cash-out path). |
| `JBBuybackHook_TerminalTokenIsProjectToken(address, address)` | JBBuybackHook | `_setPoolFor` called where `terminalToken` equals the project's token (cannot swap a token for itself). |
| `JBBuybackHook_Unauthorized(address)` | JBBuybackHook | `afterCashOutRecordedWith` called by an address that is not a terminal of the project. |
| `JBBuybackHook_ZeroProjectToken()` | JBBuybackHook | `_setPoolFor` called for a project that has no token deployed yet. |
| `JBBuybackHookRegistry_CannotDisallowDefaultHook()` | JBBuybackHookRegistry | `disallowHook` called with the current `defaultHook` (would break payments for projects using the default). |
| `JBBuybackHookRegistry_HookLocked(uint256)` | JBBuybackHookRegistry | `setHookFor` called for a project whose hook has been permanently locked. |
| `JBBuybackHookRegistry_HookMismatch(IJBRulesetDataHook, IJBRulesetDataHook)` | JBBuybackHookRegistry | `lockHookFor` called with an `expectedHook` that doesn't match the project's resolved hook (race condition guard). |
| `JBBuybackHookRegistry_HookNotAllowed(IJBRulesetDataHook)` | JBBuybackHookRegistry | `setHookFor` called with a hook that is not on the allowlist. |
| `JBBuybackHookRegistry_HookNotSet(uint256)` | JBBuybackHookRegistry | `lockHookFor` called for a project with no project-specific hook and no default hook configured. |
| `JBBuybackHookRegistry_ZeroHook()` | JBBuybackHookRegistry | `setDefaultHook` called with `address(0)` (would break payment delegation). |

## Compiler and Version Info

- **Solidity**: 0.8.26
- **EVM target**: Cancun
- **Optimizer**: via-IR, 200 runs
- **Dependencies**: OpenZeppelin 5.x, Uniswap V4 core/periphery, Solady, forge-std
- **Build**: `forge build` (Foundry)

## How to Report Findings

For each finding:

1. **Title** -- one line, starts with severity (CRITICAL/HIGH/MEDIUM/LOW)
2. **Affected contract(s)** -- exact file path and line numbers
3. **Description** -- what is wrong, in plain language
4. **Trigger sequence** -- step-by-step, minimal steps to reproduce
5. **Impact** -- what an attacker gains, what a user loses (with numbers if possible)
6. **Proof** -- code trace showing the exact execution path, or a Foundry test
7. **Fix** -- minimal code change that resolves the issue

**Severity guide:**
- **CRITICAL**: Direct fund loss or permanent swap manipulation. Exploitable with no preconditions.
- **HIGH**: Conditional fund loss, MEV extraction beyond normal slippage, or broken invariant.
- **MEDIUM**: Value leakage, suboptimal routing under specific conditions, griefing.
- **LOW**: Informational, edge-case-only with no material impact.
