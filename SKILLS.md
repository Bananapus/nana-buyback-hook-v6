# Juicebox Buyback Hook

## Use This File For

- Use this file when the task involves buyback-vs-mint routing, cash-out-vs-swap routing, Uniswap V4 pool configuration, TWAP settings, or the hook registry.
- Start here, then open the hook, registry, swap library, or tests that own the exact path under review.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and architecture | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Runtime routing behavior | [`src/JBBuybackHook.sol`](./src/JBBuybackHook.sol) |
| Registry and per-project hook selection | [`src/JBBuybackHookRegistry.sol`](./src/JBBuybackHookRegistry.sol) |
| Swap and slippage helpers | [`src/libraries/`](./src/libraries/), [`src/interfaces/`](./src/interfaces/), [`src/structs/`](./src/structs/) |
| Execution-path tests, oracle behavior, and regressions | [`test/V4BuybackHook.t.sol`](./test/V4BuybackHook.t.sol), [`test/TestOracleRevertBehavior.t.sol`](./test/TestOracleRevertBehavior.t.sol), [`test/MEVScenarios.t.sol`](./test/MEVScenarios.t.sol), [`test/regression/`](./test/regression/) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Libraries, interfaces, and structs | [`src/libraries/`](./src/libraries/), [`src/interfaces/`](./src/interfaces/), [`src/structs/`](./src/structs/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Market-aware buyback hook for Juicebox V6. This repo compares protocol-native mint or cash-out behavior against a Uniswap-backed route, then executes the better path for the project while preserving project-level hook and pool configuration.

## Reference Files

- Open [`references/runtime.md`](./references/runtime.md) when you need the hook and registry roles, route-selection flow, TWAP and pool assumptions, or the main safety properties.
- Open [`references/operations.md`](./references/operations.md) when you need configuration steps, permission and lock behavior, test breadcrumbs, or the common sources of stale assumptions.

## Working Rules

- Start in [`src/JBBuybackHook.sol`](./src/JBBuybackHook.sol) for route comparison and execution. Do not treat the registry as an implementation detail when the issue is really a configuration bug.
- Treat quote logic, fallback behavior, and oracle/TWAP assumptions as high-risk. Small changes there can alter execution outcomes materially.
- When a task mentions Uniswap behavior, verify whether the source of truth is this repo or the integrated V4 routing surface in the wider ecosystem.
- If you touch pool or hook assignment logic, check the lock path and allowed-hook constraints before calling the change safe.
