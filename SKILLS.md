# Juicebox Buyback Hook

## Use this file for

- Use this file when the task involves buyback-vs-mint routing, cash-out-vs-swap routing, Uniswap V4 pool configuration, TWAP settings, or the hook registry.
- Start here, then decide whether the issue is route selection, sell-side callback execution, pool or TWAP configuration, or registry choice.

## Read this next

| If you need... | Open this next |
|---|---|
| Repo overview and architecture | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Runtime routing behavior | [`src/JBBuybackHook.sol`](./src/JBBuybackHook.sol) |
| Registry and per-project hook selection | [`src/JBBuybackHookRegistry.sol`](./src/JBBuybackHookRegistry.sol) |
| Runtime invariants and config gotchas | [`references/runtime.md`](./references/runtime.md), [`references/operations.md`](./references/operations.md) |
| Swap and slippage helpers | [`src/libraries/`](./src/libraries/), [`src/interfaces/`](./src/interfaces/), [`src/structs/`](./src/structs/) |
| Execution-path, oracle, liquidity, and MEV coverage | [`test/V4BuybackHook.t.sol`](./test/V4BuybackHook.t.sol), [`test/TestOracleRevertBehavior.t.sol`](./test/TestOracleRevertBehavior.t.sol), [`test/MEVScenarios.t.sol`](./test/MEVScenarios.t.sol), [`test/JBBuybackHook_Regressions.t.sol`](./test/JBBuybackHook_Regressions.t.sol), [`test/regression/CurrentLiquidityRouteSelection.t.sol`](./test/regression/CurrentLiquidityRouteSelection.t.sol) |
| Registry, math, and edge-case coverage | [`test/Registry.t.sol`](./test/Registry.t.sol), [`test/JBSwapLib.t.sol`](./test/JBSwapLib.t.sol), [`test/CrossCurrency_Unit.t.sol`](./test/CrossCurrency_Unit.t.sol), [`test/TestBuybackFOT.t.sol`](./test/TestBuybackFOT.t.sol), [`test/TestRegressionGaps.sol`](./test/TestRegressionGaps.sol) |

## Repo map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Libraries, interfaces, and structs | [`src/libraries/`](./src/libraries/), [`src/interfaces/`](./src/interfaces/), [`src/structs/`](./src/structs/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Market-aware buyback hook for Juicebox V6. This repo compares protocol-native mint or cash-out behavior against a Uniswap-backed route, then executes the better path for the project while preserving project-level hook and pool configuration.

## Reference files

- Open [`references/runtime.md`](./references/runtime.md) when you need hook and registry roles, route-selection flow, TWAP and pool assumptions, or the main safety properties.
- Open [`references/operations.md`](./references/operations.md) when you need configuration steps, permission and lock behavior, test breadcrumbs, or common stale assumptions.

## Working rules

- Start in [`src/JBBuybackHook.sol`](./src/JBBuybackHook.sol) for route comparison and execution.
- The buy-side and sell-side paths are intentionally asymmetric. Re-check both before simplifying quote or callback handling.
- `hookMetadata` can carry the sell count chosen during route selection, which may be smaller than the terminal's original `cashOutCount`.
- Treat quote logic, fallback behavior, and oracle or TWAP assumptions as high-risk.
- A configured pool is not enough by itself. Initialization, current in-range liquidity, terminal-token normalization, and resolved-hook selection all affect whether the market path is actually live.
- Registry locking and allowed-hook policy are part of the threat model.
- If you touch pool or hook assignment logic, check the lock path and allowed-hook constraints before calling the change safe.
