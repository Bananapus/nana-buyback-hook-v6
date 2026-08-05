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
- [CHANGELOG.md](./CHANGELOG.md) — verified V5-to-V6 delta.
- [STYLE_GUIDE.md](./STYLE_GUIDE.md) — Solidity and repo-layout conventions across the V6 ecosystem.
- [references/operations.md](./references/operations.md) — configuration surface, change checklist, and common failure modes.
- [references/runtime.md](./references/runtime.md) — contract roles, the runtime routing path, and high-risk areas.

## Overview

The hook is designed for projects that want a market-backed buyback surface without giving up Juicebox-native economics. On payment it can either:

- mint through the terminal if the protocol path is better
- swap through a Uniswap V4 pool if market execution is better and the pool has live in-range liquidity

On sell-side flows it makes the same comparison for cash outs. A companion registry controls which hook and pool a project uses and can lock that choice once configured.

Use this repo when a project wants market-aware issuance and redemption routing. Do not use it when deterministic terminal-only economics are the goal.

If the question is "how does the pool-side routing primitive work?" you may need to start in `univ4-router-v6` first. This repo is where Juicebox chooses whether to use that market path.

## Token behavior assumptions

Buyback routing assumes the terminal token is balance-conserving: transferring `N` terminal tokens moves exactly `N`
terminal tokens. Native ETH and ordinary ERC-20s satisfy this. Fee-on-transfer, rebasing-on-transfer, or otherwise
taxed terminal tokens are not a supported terminal-token configuration for this hook, because the hook route adds
terminal-to-hook and hook-to-terminal/beneficiary transfers that the direct terminal path does not. Those extra
transfers can make an otherwise safe market route settle below the direct Juicebox path.

Fee-on-transfer project-token behavior is covered separately with balance-delta accounting tests. That coverage does
not imply fee-on-transfer terminal tokens are safe to route through the buyback hook.

## Key contracts

| Contract | Role |
| --- | --- |
| `JBBuybackHook` | Main data hook that compares protocol and market routes, then executes the better one. |
| `JBBuybackHookRegistry` | Registry that stores which hook and pool a project uses and exposes locking controls. |
| `JBSwapLib` | Shared swap-path helper logic. |

## Mental model

There are two separate responsibilities here:

1. `JBBuybackHook` decides between protocol-native and market-native execution
2. `JBBuybackHookRegistry` decides which hook and pool configuration a project is allowed to use

Operational bugs often come from the second part. Economic bugs often come from the first.

## Caller-provided metadata

Callers can shape the route through `JBMetadataResolver`-keyed entries in the terminal's `metadata` argument. Address the entry to the hook (or to the registry, which rekeys it to the resolved hook).

### Building the metadata bytes

An entry's id is `getId(purpose, target)`. The single-arg `getId(purpose)` resolves `target` to `address(this)`, so an
**external** caller must use the two-arg form keyed to the hook (or to the registry, which rekeys forwarded metadata to
the resolved hook) — keying it to your own address produces an id the hook will never read. `addToMetadata` then packs
the id-keyed, 32-byte-padded data into the `metadata` bytes you pass to `pay(...)`:

```solidity
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";

// `buybackHook` is the JBBuybackHook (or the registry, which rekeys to the resolved hook).
bytes4 payId = JBMetadataResolver.getId("pay", address(buybackHook));

// Buy side: (amountToSwapWith, minimumSwapAmountOut). abi.encode pads to 32-byte words.
bytes memory data = abi.encode(amountToSwapWith, minimumSwapAmountOut);

// Append the entry to any existing metadata (pass "" if you have none).
bytes memory metadata = JBMetadataResolver.addToMetadata(existingMetadata, payId, data);

// metadata is now ready to forward to terminal.pay(...). For the sell side, swap the key for
// "cashOut" and encode (uint256 minimumSwapAmountOut, bool skip) before cashOutTokensOf(...).
```

**Buy side, key `"pay"`** — encodes `(uint256 amountToSwapWith, uint256 minimumSwapAmountOut)` (the payer's swap quote). A non-zero `minimumSwapAmountOut` is honored as an explicit floor; a zero minimum falls through to the TWAP oracle. The two have intentionally different failure behavior: an explicit floor is a settlement guarantee that hard-reverts the payment when the combined output (swap + leftover mint) falls short, while a TWAP-derived floor is a routing hint — a swap that fills below it is unwound and the full payment falls back to minting at the issuance rate, so no-quote programmatic payments never revert on a stale floor. If the oracle exposes observation coverage, no-quote routing prefers the configured full TWAP window and otherwise quotes against the longest retained best-effort window. If there is no usable coverage, the hook either uses the bounded buy-side cold-start path described below or mints through the protocol path.

When `beforePayRecordedWith` returns a `JBPayHookSpecification`, its `metadata` is the hook-internal settlement and
preview payload consumed by `afterPayRecordedWith` and by router-terminal preview consumers:

```solidity
(
  bool projectTokenIs0,
  uint256 amountToMintWith,
  uint256 minimumSwapAmountOut,
  bool hasUserSpecifiedQuote,
  IJBController controller,
  uint256 tokenCountWithoutHook,
  uint256 weightRatio,
  uint256 quotedAmountToSwapWith,
  int24 twapTick,
  uint128 twapLiquidity,
  PoolId poolId,
  uint256 minimumBeneficiaryTokenCount,
  uint256 minimumReservedTokenCount,
  uint256 rawSwapQuote,
  bool oracleUnseeded
)
```

`quotedAmountToSwapWith` is the gross quoted swap amount. It lets `afterPayRecordedWith` scale oracle-derived floors
and issuance-rate price limits when a same-terminal split forwards only a net post-fee amount. Explicit caller minima
are settlement guarantees and are not scaled.

Buy-side metadata is 480 bytes. `oracleUnseeded == true` means the configured pool has live liquidity but no usable TWAP
liquidity yet. In that state, a non-noop spec means the hook selected the bounded cold-start bootstrap path; a noop spec
means issuance still won or the fallback guardrails rejected the quote. Explicit caller quotes still supply the
settlement floor, while diagnostics can report whether the configured pool lacks usable TWAP liquidity. For an
`oracleUnseeded` no-quote active spec, `minimumSwapAmountOut` is the issuance-rate execution floor enforced inside the
swap attempt (a miss unwinds to the mint fallback); the stricter bootstrap quote is only used to decide whether the
AMM route should be selected.

**Sell side, key `"cashOut"`** — encodes `(uint256 minimumSwapAmountOut, bool skip)`:

- `minimumSwapAmountOut` is a hard slippage floor on the net terminal-token output. It is a protection value, **not** a venue selector. A non-zero floor is enforced even when the hook falls back to the direct protocol cash-out.
- `skip` (defaults to `false`) forces the cash-out through the protocol bonding-curve/terminal path and skips the pool entirely — **even when the pool would pay more**. The floor still applies: a `skip` cash-out whose `minimumSwapAmountOut` the direct reclaim cannot meet reverts rather than silently routing to the AMM. Use `skip` when you want deterministic terminal settlement (e.g. predictable accounting, or avoiding pool exposure) regardless of momentary pool pricing. Note this is distinct from setting a low `minimumSwapAmountOut`: that would surrender your slippage protection to coax a terminal route, whereas `skip` decouples venue choice from the floor.

## Read these files first

1. `src/JBBuybackHook.sol`
2. `src/JBBuybackHookRegistry.sol`
3. `src/libraries/JBSwapLib.sol`
4. `univ4-router-v6/src/JBUniswapV4Hook.sol`

## Integration traps

- this hook can fall back between market and protocol paths, so preview behavior is not the same as guaranteed execution
- oracle-derived minima and caller-supplied minima have intentionally different failure behavior: explicit minima hard-revert, derived floors unwind the swap and mint the full payment instead
- registering a pool with `twapWindow == MAX_TWAP_WINDOW` (2 days) stores the 30-minute default instead — immutable deployers bake the max in as a default, not a tuning choice; use `setTwapWindowOf` (never remapped) for a deliberate max-length window
- pool keys are intentionally immutable once set for a given project/token pair, so fixing a bad pool choice is expensive
- a configured and initialized pool is not enough to activate routing; the hook also requires current PoolManager liquidity and rejects dust/max-impact routes
- pool registration is not proof of live market availability; operators should separately verify the intended V4 hook,
  in-range liquidity, observation readiness, and expected token ordering before treating routing as enabled
- buyback buys push project-token price upward, so initial liquidity must cover the current tick and the upward side of the range
- freshly seeded pools can be `oracleUnseeded`; buy-side pays may use a bounded bootstrap quote, while cash-outs remain TWAP-only
- registry configuration is part of the economic surface because it determines which hook and pool are even eligible
- fee-on-transfer terminal tokens are not supported for buyback routing; partial-fill behavior remains a central threat-model concern

## Where state lives

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

## Deployment notes

This package is meant to compose with [`@bananapus/univ4-router-v6`](https://www.npmjs.com/package/@bananapus/univ4-router-v6), which provides the Uniswap V4 hook and TWAP oracle surface used for market comparison and protection.

## Repository layout

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

## Risks and notes

- TWAP quality depends on the oracle hook having enough history and liquidity to be meaningful
- current in-range PoolManager liquidity is checked separately from TWAP liquidity, so a warm but drained pool degrades to the protocol path
- cold-start bootstrap routing is buy-side only, requires the configured oracle hook, and exists solely to bootstrap seeded pools before the TWAP is usable
- route comparison intentionally distinguishes explicit caller minima from oracle-derived routing minima
- explicit cash-out minima are checked against conservative direct or noop bounds when terminal fee-free-surplus state is hidden
- cash-outs that use the AMM path are market exits, not terminal fee revenue, and reporting should separate pool
  execution from protocol-native reclaim accounting
- direct ETH or token balances sent to the hook or registry are ambient dust unless a supported settlement path accounts
  for them
- programmatic callers can omit quote metadata, or provide a zero minimum, and let the hook derive its route from full-window or retained best-effort TWAP
- hook configuration should usually be locked after validation, and pool choices should be treated as sticky once set
- fee-on-transfer project-token behavior and partial fills are tested, but fee-on-transfer terminal tokens must not be configured for buyback routing

## For AI agents

- Treat this repo as a route selector between Juicebox-native and market-native execution.
- If the question is about pool swap mechanics or oracle observations, move to `univ4-router-v6`.
- Use the registry tests and FOT/partial-fill tests before claiming a path is safe or deterministic. Do not infer terminal-token FOT support from those tests.

When a project wants the market to set the price but never wants to lose to it, reach for this hook.
