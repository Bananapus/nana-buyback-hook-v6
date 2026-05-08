# Audit Instructions

This repo routes Juicebox payments or cash outs toward a Uniswap V4 market when the market is better than native protocol pricing. Audit it as an economic-routing primitive with fallback behavior.

## Audit Objective

There is a billion dollars of well-meaning projects' money in the Juicebox Money Engine, growing exponentially. Your job is to hack it before anyone else. Whoever hacks it first saves/steals the money, and you are obsessed with being this winner, while also being a steward of the protocol and wanting it to keep growing safely.

Suggestions of where to look:

- route through the wrong path and lose user or treasury value
- let attackers manipulate estimates, slippage, or fallback behavior
- break accounting between buyback execution and native Juicebox mint or cash-out logic
- grant incorrect pool, hook, or registry trust
- create reentrancy or callback ordering bugs during swap settlement

## Scope

In scope:

- `src/JBBuybackHook.sol`
- `src/JBBuybackHookRegistry.sol`
- `src/interfaces/`
- `src/libraries/JBSwapLib.sol`
- `src/structs/`
- deployment scripts in `script/`

Key dependencies:

- `nana-core-v6`
- `univ4-router-v6`

## Start Here

1. `src/JBBuybackHook.sol`
2. `src/JBBuybackHookRegistry.sol`
3. `src/libraries/JBSwapLib.sol`

## Security Model

The buyback hook is used during Juicebox payment and cash-out flows. It:

- compares native protocol economics against a Uniswap V4 route
- returns hook specs and routing hints
- optionally executes swap-based fulfillment
- falls back to native minting or cash-out when swap execution is unavailable or inferior

The registry governs which hook configuration a project uses.

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Project authority | Opt into a hook configuration | Must not accidentally inherit unsafe defaults |
| Registry controller | Set defaults or project overrides | Must not widen trust to arbitrary hooks or pools |
| Router or oracle hook | Supply estimates and execution path | Must not make fallback logic unsafe |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-core-v6` | Native previews reflect executable economics | Best-path selection breaks |
| `univ4-router-v6` | Oracle and route estimates are directionally sound | Users can be forced onto the worse path |

## Critical Invariants

1. Best-path routing must not create value.  
   Choosing swap versus native protocol should only change where value is sourced, not increase user output beyond what either real path can support.
2. Fallback behavior is safe.  
   If the external swap route reverts, misquotes, or becomes unavailable, the protocol must either honor an explicit caller minimum or degrade to the intended native path without trapping funds.
3. Price and amount estimates are coherent.  
   Preview logic, execution logic, and callback settlement must agree on direction, token roles, and minimum-return semantics.
4. Registry trust is narrow.  
   Projects must not accidentally inherit an unsafe default hook or a hook whose expected external oracle or router is not actually set.

## Attack Surfaces

- `beforePayRecordedWith` and `beforeCashOutRecordedWith`
- quote computation and swap settlement deltas
- registry defaults and project-specific override rules
- fallback branches after failed external calls
- sell-side execution after `MAX_CASH_OUT_TAX_RATE` routing, especially hard-failure behavior
- any path that assumes a valid oracle hook or initialized pool exists

## Accepted Risks Or Behaviors

- Falling back to native protocol behavior is preferable to trapping funds when an external market path fails.

## Verification

- `npm install`
- `forge build --deny notes`
- `forge test --deny notes`
