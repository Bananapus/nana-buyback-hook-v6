# nana-buyback-hook-v6 — Architecture

## Purpose

DEX buyback hook for Juicebox V6. When a payment arrives, the hook compares the token amount from direct minting (via weight) against buying on a Uniswap V4 pool. Whichever yields more tokens wins. Uses TWAP oracle to prevent sandwich attacks.

## Contract Map

```
src/
├── JBBuybackHook.sol         — Data hook: TWAP comparison, swap execution, mint fallback
├── JBBuybackHookRegistry.sol — Registry mapping projects to their buyback hooks
├── interfaces/
│   ├── IJBBuybackHook.sol
│   └── IJBBuybackHookRegistry.sol
└── libraries/
    └── JBSwapLib.sol          — Uniswap V4 swap helpers, TWAP calculation
```

## Key Data Flow

### Swap-vs-Mint Decision
```
Payment → JBTerminalStore calls data hook
  → JBBuybackHook.beforePayRecordedWith()
    → Calculate mintable tokens from weight
    → Read TWAP price from Uniswap V4 pool
    → If TWAP gives more tokens:
      → Return swap specification as pay hook
    → Else:
      → Return empty (direct mint wins)

If swap selected:
  → JBBuybackHook.afterPayRecordedWith()
    → Execute swap on Uniswap V4
    → If swap succeeds: transfer bought tokens + mint reserved portion
    → If swap fails: fall back to direct minting via controller
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Data hook | `IJBRulesetDataHook` | Intercepts payments for swap decision |
| Pay hook | `IJBPayHook` | Executes the swap if chosen |
| Registry | `IJBBuybackHookRegistry` | Maps projects → hooks |

## Dependencies
- `@bananapus/core-v6` — Core protocol interfaces
- `@bananapus/permission-ids-v6` — SET_BUYBACK_TWAP, SET_BUYBACK_POOL, SET_BUYBACK_HOOK
- `@openzeppelin/contracts` — SafeERC20
- `@uniswap/v4-core` — Pool manager, TWAP oracle
