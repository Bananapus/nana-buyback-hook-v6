# Juicebox Buyback Hook

`@bananapus/buyback-hook-v6` is a data hook that compares Juicebox's native mint or cash-out path with a Uniswap V4 pool and routes through whichever produces the better result for the project at that moment.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)

## Overview

The hook is designed for projects that want a market-backed buyback surface without giving up Juicebox-native economics. On payment it can either:

- mint through the terminal if the protocol path is better
- swap through a Uniswap V4 pool if market execution is better

On sell-side flows it makes the same comparison for cash outs. A companion registry controls which hook and pool a project uses and can lock that choice once configured.

Use this repo when a project wants market-aware issuance and redemption routing. Do not use it when deterministic terminal-only economics are the goal.

If the question is "how does the pool-side routing primitive work?" you may need to start in `univ4-router-v6` first. This repo is where Juicebox chooses whether to use that market path.

## Key Contracts

| Contract | Role |
| --- | --- |
| `JBBuybackHook` | Main data hook that compares protocol and market routes, then executes the better one. |
| `JBBuybackHookRegistry` | Registry that stores which hook and pool a project uses and exposes locking controls. |
| `JBSwapLib` | Shared swap-path helper logic. |

## Mental Model

There are two separate responsibilities here:

1. `JBBuybackHook` decides between protocol-native and market-native execution
2. `JBBuybackHookRegistry` decides which pool and hook configuration a project is allowed to use

Operational bugs often come from the second part; economic bugs often come from the first.

## Read These Files First

1. `src/JBBuybackHook.sol`
2. `src/JBBuybackHookRegistry.sol`
3. `src/libraries/JBSwapLib.sol`
4. `univ4-router-v6/src/JBUniswapV4Hook.sol`

## Install

```bash
npm install @bananapus/buyback-hook-v6
```

## Development

```bash
npm install
forge build
forge test
```

Useful scripts:

- `npm run test:fork`
- `npm run deploy:mainnets`
- `npm run deploy:testnets`

## Deployment Notes

This package is meant to compose with [`@bananapus/univ4-router-v6`](https://www.npmjs.com/package/@bananapus/univ4-router-v6), which provides the Uniswap V4 hook and TWAP oracle surface used for market comparison and protection.

## Repository Layout

```text
src/
  JBBuybackHook.sol
  JBBuybackHookRegistry.sol
  interfaces/
  libraries/
  structs/
test/
  unit, fork, invariant, audit, FOT, oracle, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks And Notes

- TWAP quality depends on the oracle hook having enough history and liquidity to be meaningful
- route comparison intentionally falls back when external calls fail, which is good for liveness but easy to misunderstand operationally
- pool and hook configuration should usually be locked after validation to avoid governance surprises
- fee-on-transfer and partial-fill behaviors are part of the main threat model and should stay that way
