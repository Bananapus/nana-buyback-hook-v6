# Juicebox Buyback Hook Risk Register

This file covers the routing, MEV, and composition risks in the buyback hook that compares Juicebox minting or cash-out against external AMM execution.

## How To Use This File

- Read `Priority risks` first. Those are the routing failures with the largest user impact.
- Use the later sections for economic, MEV, and same-pool composition reasoning.
- Treat `Invariants to verify` as hard requirements before relying on this hook in production routing.

## Priority Risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Wrong-route execution from stale estimates | If the hook mis-estimates protocol or pool output, users can be routed to a materially worse path. | Preview surfaces, TWAP-based pricing, try/catch fallbacks, and strict slippage floors. |
| P1 | Same-pool recursion and composition complexity | Buyback composition with the V4 router creates deep call chains where an ordering bug can cascade. | Explicit recursion guards, fallback-to-mint behavior, and composition-focused tests. |
| P1 | MEV around route selection | Buyback routing gives attackers an incentive to manipulate the comparison boundary, especially in low-liquidity or stale-price conditions. | TWAP use, slippage controls, and operational caution on thin markets. |

## 1. Trust Assumptions

- **Uniswap V4 PoolManager is trusted.** All swap settlement flows through it.
- **The oracle hook is trusted.** TWAP integrity depends on the `hooks` field in the pool key and the configured `ORACLE_HOOK`.
- **Oracle failure degrades safely.** When `observe()` reverts, oracle-dependent flows return a zero quote and can fall back toward the protocol path.
- **JB core contracts behave correctly.** The hook trusts `DIRECTORY`, `controller`, and token operations in core.
- **Registry owner centralization is real.** Changing the default hook silently redirects all unlocked projects.

## 2. Economic Risks

- **Mint-vs-swap routing can be manipulated.** The comparison at `beforePayRecordedWith` depends on either explicit caller quote data or TWAP-derived quoting.
- **TWAP window selection is a tradeoff.** Short windows are easier to manipulate. Long windows lag real markets.
- **Sigmoid slippage has edge cases.** Hardcoded parameters can tolerate large price movement in thin pools and may not fit every market.
- **Non-18-decimal token handling is less tested.** The functional risk is conservative slippage rather than direct over-issuance, but coverage is thinner.
- **Cross-currency weight ratios depend on `JBPrices`.** Bad or missing price feeds can route incorrectly or revert.
- **`amountToSwapWith` defaults to the full payment.** Partial minting only happens through explicit metadata.
- **Pool immutability is a tradeoff.** Once a pool is set for a project and terminal token, it cannot be changed.
- **Pool key `hooks` is trusted owner input.** A project can point itself at a bad or malicious pool hook.
- **Dynamic-fee pool LP fees can move between preview and execution.** Final minimum-output and price-limit checks still protect value.

## 3. MEV And Sandwich Risks

- **There is a three-layer protection pipeline.** The hook combines explicit minima or TWAP floors, sigmoid slippage, and a `sqrtPriceLimit` circuit breaker.
- **Sandwich attacks can force mint fallback.** When the circuit breaker trips, the intended result is mint fallback rather than silent overpayment.
- **TWAP manipulation is expensive but not impossible.** Risk is lower in deep pools and higher for large trades or thin markets.
- **Oracle warmup creates a mint-only period for no-quote flows.** This is intentional. Explicit quote metadata can still use the swap path during warmup.
- **Attackers can front-run the routing decision.** TWAP and explicit minima reduce the practical value of that manipulation but do not remove the incentive.

## 4. Composition With `JBUniswapV4Hook`

- **Same-pool composition is expected.** In production, the buyback hook often queries the oracle and swaps against the same V4 hook-backed pool.
- **Reentrancy path matters.** Router-hook recursion is blocked by the `_routing` guard in `JBUniswapV4Hook`.
- **`hookData` format is intentional.** `abi.encode(uint256(0))` delegates minimum-output enforcement to the V4 hook's own routing floor.
- **Double fallback exists by design.** If the swap path cannot execute safely, the buyback hook catches the failure and falls back to minting on the buy side.
- **Oracle warmup interacts with composition.** During early pool life, both layers degrade conservatively rather than falling back to unsafe spot behavior.

## 5. Multi-Pool Risks

- **Each terminal token has an independent pool configuration.**
- **TWAP window is per-project and per-terminal-token.**
- **Two projects can point at the same underlying pool.**
- **There is no pool migration path.**
- **The shared oracle hook is immutable at construction unless a custom pool key is set manually.**

## 6. Access Control

- **`SET_BUYBACK_POOL` controls pool setup.** It is required at both registry and hook level.
- **`SET_BUYBACK_TWAP` controls TWAP changes.** It is bounded, repeatable, and project-scoped.
- **`SET_BUYBACK_HOOK` controls hook choice and locking.**
- **Registry owner controls allowlisting and the global default.**
- **`unlockCallback` is gated to `POOL_MANAGER`.**
- **`afterPayRecordedWith` and `afterCashOutRecordedWith` are gated to verified terminals.**
- **Registry pool setup requires explicit permission grant.** Non-revnet integrators who use `JBBuybackHookRegistry` to manage buyback pools must grant `SET_BUYBACK_POOL` permission to the registry contract for their project. The `REVDeployer` handles this automatically for revnet deployments (it grants this permission in its constructor with a wildcard project ID). Custom deployers that bypass `REVDeployer` need to explicitly grant this permission or pool setup calls through the registry will fail.

## 7. DoS Vectors

- **`JBPrices` can revert.** Cross-currency buyback-routed payments then halt.
- **Controller mint or burn can revert.** There is no fallback around that.
- **`addToBalanceOf` can revert.** That can trap the flow after a failed swap.
- **Pool state can become unusable.** If quotes collapse to zero, the hook can fall back to mint-only behavior.
- **Gas exhaustion can force the fallback branch.** Explicit caller minima can still turn that failure into a revert.

## 8. Invariants To Verify

- users always get at least their specified explicit minimum
- cash-out beneficiaries always get at least direct protocol cash-out value when routed through the pool
- cash-out sell count matches data-hook intent, not necessarily the terminal's full original count
- swap fallback to mint works correctly on the buy side
- there is no value extraction gap between swap boundary and mint rate
- leftover accounting is delta-based
- pool key immutability holds
- token supply stays coherent through burn and re-mint paths
- TWAP window bounds stay enforced
- registry lock prevents later hook changes

## 9. Accepted Behaviors

### 9.1 Oracle warmup forces a mint-only period for no-quote flows

New pools lack enough observation history at first. During that period, oracle-dependent flows fall back to minting. This is intentional because the previous spot-price fallback was too easy to sandwich.

### 9.2 Pool immutability prevents migration to better liquidity

Once a pool is set for a `(projectId, terminalToken)` pair, it cannot be changed. This reduces governance attack surface, but it also means a drained pool can leave the project in mint-only mode for that pair.

### 9.3 Token cache cannot become stale

`projectTokenOf[projectId]` is cached on `setPoolFor()`. That is safe because JBTokens does not allow token migration once a token exists.

### 9.4 Fee-on-transfer handling is safest on the mint-fallback return path

When a swap fails and leftover terminal tokens return through `addToBalanceOf`, the hook measures the terminal's actual credited amount before minting fallback project tokens.

### 9.5 Pre-initialized pools can win the initial price race

`initializePoolFor()` catches pool initialization failures and then proceeds with whatever pool state already exists. This lets owners register already-initialized pools, but it also means a third party can win the initial price-setting race for that exact pool key.

### 9.6 Sell-side swaps degrade gracefully

When `afterCashOutRecordedWith()` attempts to sell reminted project tokens through the pool and the swap reverts (e.g., zero liquidity, pool unavailable), the hook transfers the reminted project tokens back to the beneficiary instead of reverting the entire cash-out. The user retains their project tokens and can sell them manually or retry. A `SellSwapReverted` event is emitted for offchain monitoring.

### 9.7 Unpinned projects fall back to the mutable default hook

Projects using `JBBuybackHookRegistry` as their data hook without explicitly calling `setHookOf()` fall back to the mutable `defaultHook`. The registry owner can change `defaultHook`, affecting all projects that have not pinned their hook. Always call `setHookOf(projectId, hook)` to pin your project's hook.

### 9.8 Sell-Side AMM Proceeds Are Not Fee-Metered

When the buyback hook routes a cash-out through the AMM sell path, the swap proceeds go directly to the beneficiary without passing through the terminal's fee meter. This is by design — protocol fees apply only to actual terminal cashouts, not AMM market operations. The hook's `hookSpecifications.amount = 0` reflects this intent.
