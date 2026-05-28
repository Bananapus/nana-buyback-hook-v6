# Juicebox Buyback Hook

`@bananapus/buyback-hook-v6` is a data hook that compares Juicebox's native mint or cash-out path with a Uniswap V4 pool and routes through whichever produces the better result for the project at that moment.


## Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md) — system overview, modules, trust boundaries, buy- and sell-side flows.
- [INVARIANTS.md](./INVARIANTS.md) — per-contract enumeration of user, operator, and cross-cutting invariants with file:line references.
- [USER_JOURNEYS.md](./USER_JOURNEYS.md) — primary actor flows: attach routing, pay, cash out, operate.
- [RISKS.md](./RISKS.md) — routing, MEV, and composition risk register with accepted behaviors.
- [ADMINISTRATION.md](./ADMINISTRATION.md) — privileged surfaces, roles, irreversible actions, and recovery posture.
- [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md) — scope, attack surfaces, and verification steps for auditors.
- [SKILLS.md](./SKILLS.md) — quick-reference index for agents and contributors.
- [CHANGELOG.md](./CHANGELOG.md) — verified v5 → v6 deltas and major-change notes.
- [STYLE_GUIDE.md](./STYLE_GUIDE.md) — Solidity and repo-layout conventions across the V6 ecosystem.

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
2. `JBBuybackHookRegistry` decides which hook and pool configuration a project is allowed to use

Operational bugs often come from the second part. Economic bugs often come from the first.

## Caller-Provided Metadata

Callers can shape the route through `JBMetadataResolver`-keyed entries in the terminal's `metadata` argument. Address the entry to the hook (or to the registry, which rekeys it to the resolved hook).

**Buy side (`pay`), key `"quote"`** — encodes `(uint256 amountToSwapWith, uint256 minimumSwapAmountOut)`. A non-zero `minimumSwapAmountOut` is honored as an explicit floor; a zero minimum falls through to the TWAP oracle.

**Sell side (`cashOut`), key `"cashOutMinReclaimed"`** — encodes `(uint256 minimumSwapAmountOut, bool skip)`:

- `minimumSwapAmountOut` is a hard slippage floor on the net terminal-token output. It is a protection value, **not** a venue selector. A non-zero floor is enforced even when the hook falls back to the direct protocol cash-out.
- `skip` (defaults to `false`) forces the cash-out through the protocol bonding-curve/terminal path and skips the pool entirely — **even when the pool would pay more**. The floor still applies: a `skip` cash-out whose `minimumSwapAmountOut` the direct reclaim cannot meet reverts rather than silently routing to the AMM. Use `skip` when you want deterministic terminal settlement (e.g. predictable accounting, or avoiding pool exposure) regardless of momentary pool pricing. Note this is distinct from setting a low `minimumSwapAmountOut`: that would surrender your slippage protection to coax a terminal route, whereas `skip` decouples venue choice from the floor.

## Read These Files First

1. `src/JBBuybackHook.sol`
2. `src/JBBuybackHookRegistry.sol`
3. `src/libraries/JBSwapLib.sol`
4. `univ4-router-v6/src/JBUniswapV4Hook.sol`

## Integration Traps

- this hook can fall back between market and protocol paths, so preview behavior is not the same as guaranteed execution
- oracle-derived minima and caller-supplied minima have intentionally different failure behavior
- pool keys are intentionally immutable once set for a given project/token pair, so fixing a bad pool choice is expensive
- registry configuration is part of the economic surface because it determines which hook and pool are even eligible
- fee-on-transfer and partial-fill behavior are central threat-model concerns

## Where State Lives

- route choice and execution behavior: `JBBuybackHook`
- per-project pool and hook selection: `JBBuybackHookRegistry`
- swap math helpers: `JBSwapLib`
- actual pool routing and oracle state: `univ4-router-v6`

## Install

```bash
npm install @bananapus/buyback-hook-v6
```

## Development

```bash
npm install
forge build --deny notes
forge test --deny notes
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
  unit, fork, invariant, review, FOT, oracle, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks And Notes

- TWAP quality depends on the oracle hook having enough history and liquidity to be meaningful
- route comparison intentionally distinguishes explicit caller minima from oracle-derived routing minima
- explicit cash-out minima are checked against conservative direct or noop bounds when terminal fee-free-surplus state is hidden
- programmatic callers can omit quote metadata, or provide a zero minimum, and let the hook derive its route from TWAP
- hook configuration should usually be locked after validation, and pool choices should be treated as sticky once set
- fee-on-transfer and partial-fill behaviors are part of the main threat model

## For AI Agents

- Treat this repo as a route selector between Juicebox-native and market-native execution.
- If the question is about pool swap mechanics or oracle observations, move to `univ4-router-v6`.
- Use the registry tests and FOT/partial-fill tests before claiming a path is safe or deterministic.
