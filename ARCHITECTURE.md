# nana-buyback-hook-v6 — Architecture

## Purpose

DEX buyback hook for Juicebox V6. When a payment arrives, the hook compares the token amount from direct minting (via weight) against buying on a Uniswap V4 pool. When a cash out arrives, it compares protocol cash-out value against selling into the pool. Whichever yields more value wins. Uses a TWAP oracle to prevent sandwich attacks.

## Contract Map

```
src/
├── JBBuybackHook.sol         — Data hook: TWAP comparison (via ORACLE_HOOK), pay/cash-out routing, swap execution, mint fallback
├── JBBuybackHookRegistry.sol — Registry mapping projects to their buyback hooks
├── interfaces/
│   ├── IJBBuybackHook.sol
│   ├── IJBBuybackHookRegistry.sol
│   └── IGeomeanOracle.sol    — Interface for V4 oracle hooks that implement the observe() pattern
├── libraries/
│   └── JBSwapLib.sol          — Uniswap V4 swap helpers, TWAP calculation
└── structs/
    └── SwapCallbackData.sol   — Data passed through to the V4 unlock callback
```

## Key Data Flow

### Swap-vs-Mint Decision
```
Payment → JBTerminalStore calls data hook
  → JBBuybackHook.beforePayRecordedWith()
    → Calculate mintable tokens from weight
    → Read minimum from explicit quote metadata or, by default, from the TWAP/geomean oracle path
    → If swap minimum gives more tokens:
      → Return active pay specification as pay hook
      → Hook spec metadata includes routing diagnostics for preview clients
    → Else:
      → Return noop pay specification with routing diagnostics (direct mint wins)

If swap selected:
  → JBBuybackHook.afterPayRecordedWith()
    → Execute swap on Uniswap V4
    → If swap succeeds: burn bought tokens, re-mint total (swap output + leftover) with reserved rate applied
    → If swap fails: fall back to direct minting via controller
```

### Sell-side Cash-out Decision
```
Cash out → JBTerminalStore calls data hook
  → JBBuybackHook.beforeCashOutRecordedWith()
    → Calculate direct protocol cash-out value
    → Read minimum from explicit cash-out metadata or, by default, from the TWAP/geomean oracle path
    → Always return cash-out hook specification with routing diagnostics when pool is configured
    → If pool sale is better:
      → Spec is active (`noop = false`)
      → JBBuybackHook.afterCashOutRecordedWith()
        → Remint burned tokens to the hook
        → Execute swap on Uniswap V4
        → Forward proceeds to beneficiary
    → Else:
      → Spec is informational (`noop = true`)
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Data hook | `IJBRulesetDataHook` | Intercepts payments for swap decision |
| Pay hook | `IJBPayHook` | Executes the swap if chosen |
| Registry | `IJBBuybackHookRegistry` | Maps projects → hooks |

## Composition with JBUniswapV4Hook

In production, `JBBuybackHook` is deployed with `JBUniswapV4Hook` as its `ORACLE_HOOK`. This same hook also serves as the pool's V4 hook (in `PoolKey.hooks`). This means:

1. The buyback hook queries the oracle via `IGeomeanOracle(address(key.hooks)).observe()` — this is the same contract that handles `_beforeSwap` routing.
2. When the buyback hook executes a swap, the V4 PoolManager calls `JBUniswapV4Hook._beforeSwap()`, which may try to route through Juicebox (triggering `terminal.pay()` → buyback hook again).
3. `JBUniswapV4Hook` has a `_routing` reentrancy guard that detects this recursion and reverts the inner swap.
4. The buyback hook's try/catch catches the revert and falls back to minting via the controller.
5. The buyback hook passes `hookData: abi.encode(uint256(0))` to delegate slippage protection to the oracle's TWAP rather than specifying a fixed minimum.

**Integration note:** The `hookData: abi.encode(uint256(0))` pattern is how any caller signals "no explicit minimum — use the oracle." Integrators executing swaps through `JBUniswapV4Hook` should pass this encoding when they want TWAP-derived slippage protection rather than a hardcoded floor.

## Design Decisions

### TWAP over spot price
The hook uses a time-weighted average price (TWAP) from the Uniswap V4 geomean oracle rather than the current spot price. Spot prices are trivially manipulable within a single block, making them vulnerable to sandwich attacks. The TWAP, computed over a configurable window (5 minutes to 2 days), reflects the average price across many blocks. This means an attacker would need to sustain a manipulated price for the entire window, making exploitation economically impractical. When the oracle is too young (not yet warmed up, ~30 min after pool creation), `getQuoteFromOracle` returns 0, which forces the mint path — the hook never falls back to spot price for swap decisions.

### Try-catch with mint fallback
All V4 swap calls are wrapped in `try POOL_MANAGER.unlock(...) {} catch {}`. If the swap reverts for any reason — pool not initialized, insufficient liquidity, reentrancy guard triggered by `JBUniswapV4Hook`, or slippage exceeded — the hook falls back to minting tokens directly via `controller.mintTokensOf`. This ensures payments never revert due to DEX issues. The project always receives value from every payment, either through bought tokens or freshly minted ones. The `swapFailed` flag propagated from `_swap` lets `afterPayRecordedWith` skip the slippage check and route the full payment amount back through the terminal's mint path.

### Dual data hook and pay hook
`JBBuybackHook` implements both `IJBRulesetDataHook` (data hook) and `IJBPayHook` (pay hook) in a single contract. The data hook phase (`beforePayRecordedWith`) is a `view` call — it compares TWAP vs. mint and returns a pay hook specification pointing back to itself. The pay hook phase (`afterPayRecordedWith`) is a state-changing call — it executes the actual swap, burns bought tokens, and re-mints with reserved rate applied. This two-phase design is imposed by the terminal architecture: the data hook runs inside `JBTerminalStore.recordPaymentFrom` (read-only context), while the pay hook runs after recording when the terminal has already forwarded funds. Combining both in one contract avoids state synchronization between separate contracts.

### Separate registry
`JBBuybackHookRegistry` exists as an indirection layer so that the data hook address in a project's ruleset metadata never needs to change when upgrading the buyback hook implementation. Projects point their ruleset's `dataHook` at the registry, which resolves to the correct `JBBuybackHook` instance. The registry supports a default hook (used by all projects that have not pinned a specific one), per-project overrides, an allowlist to gate which hook implementations can be selected, and a lock mechanism that makes a project's hook choice permanent. This lets the protocol upgrade the default buyback hook without requiring every project to re-queue its ruleset.

### Burn-and-remint for reserve rate
When the swap path wins, the hook receives project tokens from the pool, then burns them and re-mints the same amount with `useReservedPercent: true`. This ensures the project's reserved rate is applied identically regardless of whether tokens came from minting or buying. Without this step, swapped tokens would bypass the reserved rate, creating an arbitrage between the two paths.

## Dependencies
- `@bananapus/core-v6` — Core protocol interfaces
- `@bananapus/permission-ids-v6` — SET_BUYBACK_TWAP, SET_BUYBACK_POOL, SET_BUYBACK_HOOK
- `@bananapus/univ4-router-v6` — Oracle hook deployment (TWAP via `observe()`)
- `@openzeppelin/contracts` — SafeERC20
- `@uniswap/v4-core` — Pool manager, V4 swap execution
