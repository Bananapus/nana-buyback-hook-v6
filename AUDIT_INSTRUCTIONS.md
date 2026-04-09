# Audit Instructions

This repo routes Juicebox payments or cash-outs toward a Uniswap V4 market when the market is better than native protocol pricing. Audit it as an economic-routing primitive with fallback behavior.

## Objective

Find issues that:
- route through the wrong path and lose user or treasury value
- let attackers manipulate estimates, slippage, or fallback behavior
- break accounting between buyback execution and native Juicebox mint/cash-out logic
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

## System Model

The buyback hook is used during Juicebox payment and cash-out flows. It:
- compares native protocol economics against a Uniswap V4 route
- returns hook specs and routing hints
- optionally executes swap-based fulfillment
- falls back to native minting or cash-out when swap execution is unavailable or inferior

The registry governs which hook configuration a project uses.

## Critical Invariants

1. Best-path routing must not create value
Choosing swap versus native protocol should only change where value is sourced, not increase user output beyond what either real path can support.

2. Fallback behavior is safe
If the external swap route reverts, misquotes, or becomes unavailable, the protocol must either honor an explicit caller minimum or degrade to the intended native path without trapping funds. Oracle-derived routing minimums are not user promises.

3. Price and amount estimates are coherent
Preview logic, execution logic, and callback settlement must agree on direction, token roles, and minimum-return semantics.

4. Registry trust is narrow
Projects must not accidentally inherit an unsafe default hook or a hook whose expected external oracle or router is not actually set.

## Threat Model

Prioritize:
- flash-manipulated market conditions
- fee-on-transfer or non-standard ERC-20 behavior
- default-hook misconfiguration
- hook-recursion or reentry through V4 callbacks
- mismatches between estimated and realized outputs under partial fills

## Hotspots

- `beforePayRecordedWith` and `beforeCashOutRecordedWith`
- quote computation and swap settlement deltas
- registry defaults and project-specific override rules
- fallback branches after failed external calls
- sell-side execution after `MAX_CASH_OUT_TAX_RATE` routing, especially hard-failure behavior
- any path that assumes a valid oracle hook or initialized pool exists

## Build And Verification

Standard workflow:
- `npm install`
- `forge build`
- `forge test`

Current tests focus on:
- oracle reverts and stale windows
- fee-on-transfer behavior
- partial fill, leftover delta, and cash-out residue regressions
- V4 fork scenarios and sandwich resistance

Strong findings here usually demonstrate that a user can receive materially better-than-real economics or that the hook can force users onto a worse path than the contract believes it selected.
