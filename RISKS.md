# nana-buyback-hook-v6 — Risks

## Trust Assumptions

1. **Uniswap V4 Pool** — TWAP oracle integrity depends on pool liquidity and lack of prolonged manipulation. Low-liquidity pools are vulnerable to TWAP manipulation.
2. **Project Owner** — Can set TWAP parameters (window, slippage tolerance) and change the pool. Misconfigured TWAP can make the hook ineffective or exploitable.
3. **Core Protocol** — Relies on JBTerminalStore to call data hook correctly and JBMultiTerminal to execute pay hooks.

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Sandwich attack on spot fallback | If TWAP oracle fails, falls back to spot price which is manipulable | TWAP is primary; spot fallback includes slippage protection |
| Low liquidity pools | TWAP manipulation easier with low liquidity | Only configure buyback for well-liquid pools |
| Swap revert fallback | If Uniswap swap reverts, falls back to direct minting (may give fewer tokens) | By design — ensures payment always succeeds |
| TWAP window too short | Short TWAP windows are easier to manipulate | Minimum 5-minute TWAP window recommended |
| Transient storage dependency | Uses Cancun EVM features (TSTORE/TLOAD) | Only deployable on Cancun-compatible chains |

## Privileged Roles

| Role | Permission | Scope |
|------|-----------|-------|
| Project owner | `SET_BUYBACK_TWAP` — configure TWAP parameters | Per-project |
| Project owner | `SET_BUYBACK_POOL` — change Uniswap pool | Per-project |
| Project owner | `SET_BUYBACK_HOOK` — register/unregister hook | Per-project |

## MEV Considerations

The buyback hook is specifically designed to mitigate MEV:
- **TWAP oracle** (not spot price) for swap decision — resists single-block manipulation
- **Sigmoid slippage** — progressive slippage tolerance based on deviation from TWAP
- **Price limits** on swaps — caps maximum acceptable price impact
- **Mint fallback** — if swap conditions are unfavorable, direct minting avoids DEX entirely
