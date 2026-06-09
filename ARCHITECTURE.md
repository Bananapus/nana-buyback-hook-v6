# Architecture

## Purpose

`nana-buyback-hook-v6` gives a Juicebox project market-aware entry and exit routing. On pay, it compares the protocol mint path with a Uniswap V4 buy path. On cash out, it compares the protocol reclaim path with selling reminted project tokens into the pool. It chooses the better route without replacing core treasury accounting.

## System overview

`JBBuybackHook` is the runtime route selector and executor. `JBBuybackHookRegistry` is not just configuration storage. It is also the project-facing wrapper that resolves the active hook for a project and forwards hook callbacks to that resolved implementation. `JBSwapLib` provides quoting and slippage helpers.

The TWAP oracle surface comes from `univ4-router-v6`, while settlement truth remains in `nana-core-v6`.

## Core invariants

- the hook must never create alternate treasury accounting
- oracle failure should degrade toward the safer protocol path
- a configured and initialized pool is not enough to route; market execution also requires live in-range liquidity
- registry allowlisting and lock status are part of the security model
- buy-side fallback and sell-side fallback are intentionally asymmetric
- the registry may intentionally act as a pass-through data hook when no concrete buyback hook exists on that chain
- a project's chosen hook remains sovereign once assigned
- noop hook specs may carry diagnostics, but not funds
- buyback-routed terminal tokens must be balance-conserving

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBBuybackHook` | Data-hook, pay-hook, cash-out-hook, and swap callback logic | Runtime core |
| `JBBuybackHookRegistry` | Project-to-hook configuration, locking, and runtime forwarding to the resolved hook | Governance and wrapper surface |
| `JBSwapLib` | Quoting, slippage, and price-limit helpers | Shared routing math |

## Trust boundaries

- core accounting, token minting, and permissions remain in `nana-core-v6`
- oracle observations and pool-level market data come from `univ4-router-v6` and Uniswap V4
- projects should not be able to point at arbitrary hook implementations once locked
- the registry is trusted to resolve the correct active hook for project-facing callback flows

## Critical flows

### Hook resolution

```text
registry resolves a project's hook (_resolvedHookOf)
  -> if the project pinned a hook via setHookFor, return that pin (pins always win)
  -> else if the project's id is above the current threshold, return the current default hook
  -> else walk the cohort history and return the default that was active when the project was created
```

The first-ever `setDefaultHook` records a history segment mapping the projects that already existed to that new default, so a pre-existing, non-pinned project resolves to it instead of resolving to nothing. Every later default change records the outgoing default for the window it covered, so a change never retroactively re-routes an earlier cohort. A per-project pin always takes precedence over any default.

### Buy side

```text
payment arrives
  -> hook estimates direct mint output
  -> hook estimates pool output from explicit quote metadata or TWAP-derived quoting
  -> if the pool has live liquidity but no usable TWAP liquidity yet, a bounded bootstrap quote can price the first buy
  -> hook confirms the configured pool currently has in-range liquidity
  -> if pool wins, hook returns an active pay-hook spec and later executes the swap
  -> swapped tokens are burned and re-minted through the controller so reserved-rate semantics still apply
  -> if the swap fully fails, explicit caller minima still revert but oracle-derived minima can degrade to mint fallback
```

The cold-start bootstrap path is buy-side only. It exists because the V4 oracle can have an initialized observation but still lack usable full-window TWAP liquidity for a freshly seeded pool. The fallback is deliberately narrow: zero TWAP liquidity, non-zero live liquidity, the configured oracle hook, and a 5% impact cap. The live LP fee is folded into the bootstrap discount, which is 3% plus LP fee plus rounded-up estimated impact. If the fee-adjusted quote still beats issuance, the route can use the AMM; if it does not, or if the discount consumes the quote, the payment mints. If the oracle returns a valid mean tick, the hook uses that tick instead of raw slot0. Raw slot0 is only used when the configured oracle hook cannot provide a quote. Cold-start derived quotes select the route for no-quote pays; the active hook spec encodes the issuance-rate execution floor so a successful underfill below the internal bootstrap quote does not brick the payment.

### Sell side

```text
cash out requested
  -> if the caller set skip=true, the hook short-circuits to the protocol cash-out path (no pool quote, no swap)
       and still enforces any explicit minimum against the direct net reclaim
  -> otherwise hook compares protocol reclaim value with pool sell value
  -> the protocol route only wins if the selected terminal can locally settle the gross direct reclaim
  -> empty live liquidity, zero oracle liquidity, or max-impact quotes force the protocol path
  -> hook always returns sell-side diagnostics in metadata so preview clients can inspect the comparison
  -> if pool wins, hook maxes the cash-out tax so the terminal does not reclaim surplus directly
  -> after-cash-out callback remints the chosen token amount to itself and sells it
  -> if the sell-side swap fails hard, reminted tokens are returned to the holder
  -> on a successful-but-partial fill below the floor, explicit caller minima still revert but a derived floor
       soft-lands: partial proceeds go to the beneficiary and the unsold reminted residue returns to the holder
  -> if protocol wins, the hook returns diagnostics but no active swap path
  -> direct or noop sell paths with explicit minima must still satisfy the conservative net direct bound
```

The sell-side `"cashOut"` metadata entry encodes `(uint256 minimumSwapAmountOut, bool skip)`. `minimumSwapAmountOut` is a slippage floor (a protection value); `skip` is a venue override that forces terminal settlement regardless of pool pricing. The two are independent: `skip` never waives the floor, so an unmeetable floor reverts rather than routing to the pool.

## Accounting model

This repo owns route selection and swap execution logic. It does not own the canonical ledger for balances, fees, or surplus.

On the buy side, the hook uses the controller preview path to preserve beneficiary-versus-reserved-token semantics even when comparing against market quotes. On the sell side, hook metadata can describe the route comparison even when the hook leaves the protocol cash-out path unchanged.

Cash-out pricing can include aggregate surplus from multiple terminals or remote revnet state, but the selected terminal still has to settle the direct reclaim from its own local surplus. The hook treats a direct reclaim that cannot settle locally as non-executable for route comparison, so a live AMM route can win even if aggregate direct reclaim is numerically higher.

## Security model

- the danger is semantic drift between quote selection, slippage logic, and execution
- buy and sell routing are not mirror images
- explicit user minima and oracle-derived minima are not equivalent
- live PoolManager liquidity and TWAP liquidity are both part of route safety
- cold-start bootstrap routing is only a buy-side path; sell-side market routing remains TWAP-only
- seeded buy-side ranges must cover the current tick and upward price movement, because buybacks buy the project token
- sell-side routing suppresses direct protocol reclaim only when the market path wins
- reserved-rate preservation is a primary review target on the buy side
- fee-on-transfer terminal tokens are outside the supported routing model; project-token balance-delta tests do not imply terminal-token FOT support

## Safe change guide

- review quote selection, slippage bounds, and fallback behavior as one system
- if registry behavior changes, re-check the no-hook pass-through path and the rule that disallowed hooks do not override already-pinned project assignments
- if buy-side behavior changes, re-check reserved-rate application through the controller
- if sell-side callback behavior changes, inspect wrappers and preview clients that read the returned specs
- keep governance or registry mutability out of the core hook

## Canonical checks

- buy-side failure fallback and mint degradation:
  `test/regression/SwapFailureMintFallback.t.sol`
- cold-start buy-side bootstrap and warm-pool regression:
  `test/regression/ColdStartSpotFallback.t.sol`
- live-liquidity route selection:
  `test/regression/CurrentLiquidityRouteSelection.t.sol`
- sell-side metadata and callback safety:
  `test/regression/CashOutMetadataInflation.t.sol`
- routing invariants across configurations:
  `test/invariant/BuybackHookInvariant.t.sol`

## Source map

- `src/JBBuybackHook.sol`
- `src/JBBuybackHookRegistry.sol`
- `src/libraries/JBSwapLib.sol`
- `test/regression/ColdStartSpotFallback.t.sol`
- `test/regression/SwapFailureMintFallback.t.sol`
- `test/regression/CashOutMetadataInflation.t.sol`
- `test/invariant/BuybackHookInvariant.t.sol`
