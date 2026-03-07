# nana-buyback-hook-v5

## Purpose

Route project payments through the better of two paths -- minting from the terminal or buying from a Uniswap V3 pool -- to maximize tokens received by the beneficiary while preserving the reserved rate.

## Contracts

| Contract | Role |
|----------|------|
| `JBBuybackHook` | Core hook: implements `IJBRulesetDataHook` + `IJBPayHook` + `IUniswapV3SwapCallback`. Compares mint vs swap, executes the better route, burns swapped tokens, re-mints through controller with reserved rate. |
| `JBBuybackHookRegistry` | Proxy data hook routing `beforePayRecordedWith` to a per-project or default `JBBuybackHook`. Allows project owners to choose and lock implementations. |
| `JBSwapLib` | Library for computing sigmoid-based slippage tolerance and `sqrtPriceLimitX96` from input/output amounts. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `beforePayRecordedWith(context)` | `JBBuybackHook` | Data hook: compares mint count vs swap quote. If swap is better, returns `weight=0` and a `JBPayHookSpecification` targeting itself. If mint is better, returns original weight (no hook). |
| `afterPayRecordedWith(context)` | `JBBuybackHook` | Pay hook: pulls tokens from terminal, executes Uniswap V3 swap, burns swapped tokens, returns leftover to project balance, mints total (swapped + leftover mint) via controller with `useReservedPercent: true`. |
| `setPoolFor(projectId, fee, twapWindow, terminalToken)` | `JBBuybackHook` | Set the Uniswap V3 pool for a project+terminal token pair. Computes pool address via create2. Stores pool, TWAP window, and project token. Permission: `SET_BUYBACK_POOL`. |
| `setTwapWindowOf(projectId, newWindow)` | `JBBuybackHook` | Change the TWAP window for a project (2 min to 2 days). Permission: `SET_BUYBACK_TWAP`. |
| `uniswapV3SwapCallback(amount0Delta, amount1Delta, data)` | `JBBuybackHook` | Uniswap V3 callback: validates caller is the expected pool, wraps native tokens if needed, transfers input tokens to the pool. |
| `beforeCashOutRecordedWith(context)` | `JBBuybackHook` | Pass-through: returns cash-out context unchanged (buyback only applies to payments). |
| `hasMintPermissionFor(projectId, ruleset, addr)` | `JBBuybackHook` | Returns `false` (the hook itself does not claim mint permission). |
| `setHookFor(projectId, hook)` | `JBBuybackHookRegistry` | Route a project to a specific allowed buyback hook. Permission: `SET_BUYBACK_POOL`. |
| `lockHookFor(projectId)` | `JBBuybackHookRegistry` | Lock the hook choice for a project (irreversible). |
| `hasMintPermissionFor(projectId, ruleset, addr)` | `JBBuybackHookRegistry` | Returns `true` only if `addr` is the hook registered for the project. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `nana-core-v6` | `IJBDirectory`, `IJBController`, `IJBMultiTerminal` | Directory lookups (`isTerminalOf`, `controllerOf`), token minting (`mintTokensOf`), token burning (`burnTokensOf`), balance management (`addToBalanceOf`) |
| `nana-core-v6` | `IJBPrices` | Cross-currency weight ratio when ruleset base currency differs from payment currency |
| `nana-core-v6` | `IJBTokens`, `IJBProjects`, `IJBPermissions` | Token lookups, project ownership, permission checks (`SET_BUYBACK_POOL`, `SET_BUYBACK_TWAP`) |
| `nana-core-v6` | `JBMetadataResolver` | Parsing `"quote"` metadata key from payment calldata (contains `amountToSwapWith` and `minimumSwapAmountOut`) |
| `nana-core-v6` | `JBRulesetMetadataResolver` | Extracting `baseCurrency()` from packed ruleset metadata |
| `nana-permission-ids-v6` | `JBPermissionIds` | Permission ID constants |
| `@uniswap/v3-core` | `IUniswapV3Pool`, `TickMath` | Pool swaps and tick-to-sqrtPrice conversion |
| `@uniswap/v3-periphery` | `OracleLibrary` | TWAP oracle consultation (`consult`, `getQuoteAtTick`, `getOldestObservationSecondsAgo`) |
| `@prb/math` | `mulDiv` | Safe fixed-point multiplication |
| `@openzeppelin/contracts` | `ERC2771Context`, `SafeERC20` | Meta-transactions, safe token transfers |

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `JBBeforePayRecordedContext` | `projectId`, `amount` (token, value, decimals, currency), `weight`, `metadata` | Input to `beforePayRecordedWith` |
| `JBAfterPayRecordedContext` | `projectId`, `forwardedAmount`, `weight`, `beneficiary`, `hookMetadata` | Input to `afterPayRecordedWith` |
| `JBPayHookSpecification` | `hook`, `amount`, `metadata` | Returned from `beforePayRecordedWith` when swap is chosen |
| `JBRuleset` | `baseCurrency()` (from packed metadata) | Used for cross-currency weight adjustment |

## JBSwapLib Details

| Function | What it does |
|----------|--------------|
| `getSlippageTolerance(impact, poolFeeBps)` | Continuous sigmoid: `minSlippage + (maxSlippage - minSlippage) * impact / (impact + K)`. Min = pool fee + 1% (floor 2%), max = 88%. K = 5e16. |
| `calculateImpact(amountIn, liquidity, sqrtP, zeroForOne)` | Estimates price impact scaled by 1e18: `amountIn * 1e18 / liquidity`, normalized by sqrtPrice direction. |
| `sqrtPriceLimitFromAmounts(amountIn, minimumAmountOut, zeroForOne)` | Computes a `sqrtPriceLimitX96` from the minimum acceptable swap rate. Provides MEV protection by stopping the swap if the execution price would be worse than the minimum. |

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `MIN_TWAP_WINDOW` | `2 minutes` | Minimum TWAP oracle window |
| `MAX_TWAP_WINDOW` | `2 days` | Maximum TWAP oracle window |
| `TWAP_SLIPPAGE_DENOMINATOR` | `10,000` | Basis points denominator |
| `UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE` | `1,050` | 10.5% fallback when impact is zero |
| `JBSwapLib.MAX_SLIPPAGE` | `8,800` | 88% sigmoid ceiling |
| `JBSwapLib.IMPACT_PRECISION` | `1e18` | Impact calculation precision |
| `JBSwapLib.SIGMOID_K` | `5e16` | Sigmoid curve inflection point |

## Gotchas

- The hook computes pool addresses via create2 (`POOL_INIT_CODE_HASH`) rather than calling the factory, so `setPoolFor` works even if the pool hasn't been deployed yet.
- Pool addresses are computed using Uniswap V3's canonical init code hash (`0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54`). This will not match forks that changed the bytecode.
- `setPoolFor` can only be called once per project+terminalToken pair. After the pool is set, it cannot be changed. Calling again reverts with `JBBuybackHook_PoolAlreadySet`.
- Tokens received from the swap are burned via `controller.burnTokensOf`, then re-minted (along with any leftover-mint count) via `controller.mintTokensOf` with `useReservedPercent: true`. This ensures the reserved rate applies uniformly regardless of the payment route.
- If the swap reverts (slippage, insufficient liquidity, etc.), `_swap` returns 0. The `afterPayRecordedWith` then reverts with `JBBuybackHook_SpecifiedSlippageExceeded(0, minimumSwapAmountOut)`.
- TWAP fallback: when no observations exist (`oldestObservation == 0`), falls back to spot tick and current liquidity rather than reverting.
- The sigmoid slippage formula (`JBSwapLib.getSlippageTolerance`) produces smooth tolerance curves. Small swaps in deep pools get ~2% tolerance; large swaps relative to pool liquidity approach the 88% ceiling.
- `beforePayRecordedWith` is a `view` function -- it cannot modify state. All swap execution happens in `afterPayRecordedWith`.
- The hook validates that `msg.sender` is a registered terminal of the project via `DIRECTORY.isTerminalOf(projectId, msg.sender)`.
- Metadata key `"quote"` encodes `(uint256 amountToSwapWith, uint256 minimumSwapAmountOut)`. If `amountToSwapWith == 0`, the full payment amount is used. If `minimumSwapAmountOut == 0`, a TWAP-based quote is calculated.
- When the payment currency differs from the ruleset's base currency, the hook queries `PRICES.pricePerUnitOf(...)` for the conversion factor.
- State vars are public: `poolOf[projectId][terminalToken]`, `projectTokenOf[projectId]`, `twapWindowOf[projectId]` -- NOT prefixed with underscore.
- `_msgSender()` (ERC-2771) is used instead of `msg.sender` for meta-transaction compatibility in permissioned functions (`setPoolFor`, `setTwapWindowOf`).
- `hasMintPermissionFor` returns `false` on `JBBuybackHook` but returns `addr == address(hook)` on `JBBuybackHookRegistry`. The registry grants mint permission to whichever hook is active for the project.

## Example Integration

```solidity
// Deploy the buyback hook
JBBuybackHook hook = new JBBuybackHook(
    directory,
    permissions,
    prices,
    projects,
    tokens,
    weth,
    uniswapV3Factory, // factory address for create2 pool derivation
    trustedForwarder
);

// Configure a pool for project 1 with a 0.3% fee tier and 30-minute TWAP
IUniswapV3Pool pool = hook.setPoolFor({
    projectId: 1,
    fee: 3000,        // 0.3%
    twapWindow: 30 minutes,
    terminalToken: address(weth) // or JBConstants.NATIVE_TOKEN
});

// Set the hook as the project's data hook in the ruleset config:
// rulesetConfig.metadata.useDataHookForPay = true;
// rulesetConfig.metadata.dataHook = address(hook);

// Now when someone pays project 1, the hook automatically
// compares mint vs swap and takes the better route.
```
