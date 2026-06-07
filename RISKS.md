# Juicebox Buyback Hook Risk Register

This file covers the routing, MEV, and composition risks in the buyback hook that compares Juicebox minting or cash-out against external AMM execution.

## How to use this file

- Read `Priority risks` first. Those are the routing failures with the largest user impact.
- Use the later sections for economic, MEV, and same-pool composition reasoning.
- Treat `Invariants to verify` as hard requirements before relying on this hook in production routing.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Wrong-route execution from stale estimates | If the hook mis-estimates protocol or pool output, users can be routed to a materially worse path. | Preview surfaces, TWAP-based pricing, live-liquidity checks, try/catch fallbacks, and strict slippage floors. |
| P1 | Same-pool recursion and composition complexity | Buyback composition with the V4 router creates deep call chains where an ordering bug can cascade. | Explicit recursion guards, protocol fallback behavior, and composition-focused tests. |
| P1 | MEV around route selection | Buyback routing gives attackers an incentive to manipulate the comparison boundary, especially in low-liquidity or stale-price conditions. | TWAP use, current-liquidity gating, slippage controls, and operational caution on thin markets. |
| P1 | Non-balance-conserving terminal tokens | Fee-on-transfer or rebasing-on-transfer terminal tokens can make the hook route observe different value than the direct terminal path. | Do not configure taxed terminal tokens for buyback routing; use native ETH or ordinary ERC-20 terminal tokens. |

## 1. Trust assumptions

- **Uniswap V4 PoolManager is trusted.** All swap settlement flows through it.
- **The oracle hook is trusted.** TWAP integrity depends on the `hooks` field in the pool key and the configured `ORACLE_HOOK`.
- **Current pool liquidity gates route activation.** Historical TWAP observations are advisory unless the PoolManager reports live in-range liquidity.
- **Oracle failure degrades safely.** When `observe()` reverts, oracle-dependent flows return a zero quote and can fall back toward the protocol path.
- **JB core contracts behave correctly.** The hook trusts `DIRECTORY`, `controller`, and token operations in core.
- **Registry owner centralization is scoped.** The first-ever default hook applies to every project that already exists when it is set (so pre-existing, non-pinned projects resolve to it). After that, *changing* the default only affects projects created after the change (`projectId > defaultHookProjectIdThreshold`); earlier cohorts keep their creation-time default and a project can pin its own hook via `setHookFor`.

## 2. Economic risks

- **Mint-vs-swap routing can be manipulated.** The comparison at `beforePayRecordedWith` depends on either explicit caller quote data or TWAP-derived quoting.
- **TWAP window selection is a tradeoff.** Short windows are easier to manipulate. Long windows lag real markets.
- **Sigmoid slippage has edge cases.** Hardcoded parameters can tolerate large price movement in thin pools and may not fit every market.
- **Non-18-decimal token handling is less tested.** The functional risk is conservative slippage rather than direct over-issuance, but coverage is thinner.
- **Cross-currency weight ratios depend on `JBPrices`.** Bad or missing price feeds can route incorrectly or revert.
- **`amountToSwapWith` defaults to the full payment.** Partial minting only happens through explicit metadata.
- **Pool immutability is a tradeoff.** Once a pool is set for a project and terminal token, it cannot be changed.
- **Drained or dust-liquidity pools degrade to protocol routing.** This is safer than activating an impossible AMM path, but it can surprise operators who only check initialization or historical observations.
- **Direct cash-out comparison requires local settlement.** Aggregate or cross-chain surplus can price a direct reclaim that the selected terminal cannot locally pay. The hook only lets direct reclaim beat a live AMM route when the selected terminal can settle the gross direct amount.
- **Pool key `hooks` is trusted owner input.** A project can point itself at a bad or malicious pool hook.
- **Dynamic-fee pool LP fees can move between preview and execution.** Final minimum-output and price-limit checks still protect value.

## 3. MEV and sandwich risks

- **There is a three-layer protection pipeline.** The hook combines explicit minima or TWAP floors, sigmoid slippage, and a `sqrtPriceLimit` circuit breaker.
- **Sandwich attacks can force protocol fallback.** When the circuit breaker trips, the intended result is mint/direct-reclaim fallback rather than silent overpayment.
- **TWAP manipulation is expensive but not impossible.** Risk is lower in deep pools and higher for large trades or thin markets.
- **Dust liquidity is treated as unsafe routing depth when impact reaches the max-impact guard.**
- **Oracle warmup creates a protocol-only period for no-quote flows.** This is intentional. Explicit quote metadata can still use the swap path during warmup if live liquidity exists.
- **Attackers can front-run the routing decision.** TWAP and explicit minima reduce the practical value of that manipulation but do not remove the incentive.

## 4. Composition with `JBUniswapV4Hook`

- **Same-pool composition is expected.** In production, the buyback hook often queries the oracle and swaps against the same V4 hook-backed pool.
- **Reentrancy path matters.** Router-hook recursion is blocked by the `_routing` guard in `JBUniswapV4Hook`.
- **`hookData` format is intentional.** `abi.encode(uint256(0))` delegates minimum-output enforcement to the V4 hook's own routing floor.
- **Double fallback exists by design.** If the swap path cannot execute safely, the buyback hook catches the failure and falls back to minting on the buy side.
- **Oracle warmup interacts with composition.** During early pool life, both layers degrade conservatively rather than falling back to unsafe spot behavior.

## 5. Multi-pool risks

- **Each terminal token has an independent pool configuration.**
- **TWAP window is per-project and per-terminal-token.**
- **Two projects can point at the same underlying pool.**
- **There is no pool migration path.**
- **The shared oracle hook is immutable at construction unless a custom pool key is set manually.**

## 6. Access control

- **`SET_BUYBACK_POOL` controls pool setup.** It is required at both registry and hook level.
- **`SET_BUYBACK_TWAP` controls TWAP changes.** It is bounded, repeatable, and project-scoped.
- **`SET_BUYBACK_HOOK` controls hook choice and locking.**
- **Registry owner controls allowlisting and the global default.**
- **`unlockCallback` is gated to `POOL_MANAGER`.**
- **`afterPayRecordedWith` and `afterCashOutRecordedWith` are gated to verified terminals.**
- **Registry pool setup requires explicit permission grant.** Non-revnet integrators who use `JBBuybackHookRegistry` to manage buyback pools must grant `SET_BUYBACK_POOL` permission to the registry contract for their project. The `REVDeployer` handles this automatically for revnet deployments (it grants this permission in its constructor with a wildcard project ID). Custom deployers that bypass `REVDeployer` need to explicitly grant this permission or pool setup calls through the registry will fail.

## 7. DoS vectors

- **`JBPrices` can revert.** Cross-currency buyback-routed payments then halt.
- **Controller mint or burn can revert.** There is no fallback around that.
- **`addToBalanceOf` can revert.** That can trap the flow after a failed swap.
- **Pool state can become unusable.** If current liquidity is zero, liquidity is only dust, or quotes collapse to zero, the hook can fall back to protocol-only behavior.
- **Fee-on-transfer terminal tokens are unsupported.** The hook does not compensate for terminal-token transfer taxes because doing so would either under-deliver versus direct execution or over-mint/over-pay against value the project did not receive.
- **Gas exhaustion can force the fallback branch.** Explicit caller minima can still turn that failure into a revert.

## 8. Invariants to verify

- users always get at least their specified explicit minimum
- explicit minima are hard floors; direct or noop cash-out paths that cannot guarantee the floor under the conservative net bound must revert
- cash-out beneficiaries always get at least their explicit minimum, and holders keep any project tokens the pool
  does not buy on a partial sell-side fill
- cash-out sell count matches data-hook intent, not necessarily the terminal's full original count
- swap fallback to mint works correctly on the buy side
- there is no value extraction gap between swap boundary and mint rate
- leftover accounting is delta-based
- terminal tokens configured for buyback routing are balance-conserving
- direct cash-out routes only beat live AMM routes when the selected terminal can locally settle the gross reclaim
- pool key immutability holds
- token supply stays coherent through burn and re-mint paths
- live PoolManager liquidity gates both TWAP-derived and explicit quote route activation
- TWAP window bounds stay enforced
- registry lock prevents later hook changes

## 9. Accepted behaviors

### 9.1 Oracle warmup forces a protocol-only period for no-quote flows

New pools lack enough observation history at first. During that period, oracle-dependent flows fall back to minting on pay and direct reclaim on cash-out. This is intentional because the previous spot-price fallback was too easy to sandwich.
Programmatic callers do not need an offchain quote after the oracle is warm: they can omit quote metadata, or pass a zero minimum in quote metadata, and the hook will derive the route from TWAP.

### 9.2 Pool immutability prevents migration to better liquidity

Once a pool is set for a `(projectId, terminalToken)` pair, it cannot be changed. This reduces governance attack surface, but it also means a drained pool can leave the project in protocol-only mode for that pair.

### 9.3 Token cache cannot become stale

`projectTokenOf[projectId]` is cached on `setPoolFor()`. That is safe because JBTokens does not allow token migration once a token exists.

### 9.4 Fee-on-transfer terminal tokens are not supported routing assets

The hook uses balance-delta accounting around fallback paths, but that is defensive accounting rather than support for taxed terminal tokens. Fee-on-transfer, rebasing-on-transfer, or otherwise non-balance-conserving terminal tokens add extra value loss to the hook route that the direct terminal path does not bear. Projects should not configure those tokens for buyback routing.

### 9.5 Pre-initialized pools can win the initial price race

`initializePoolFor()` catches pool initialization failures and then proceeds with whatever pool state already exists. This lets owners register already-initialized pools, but it also means a third party can win the initial price-setting race for that exact pool key.

### 9.6 Sell-side swaps degrade gracefully

When `afterCashOutRecordedWith()` attempts to sell reminted project tokens through the pool and the swap reverts (e.g., zero liquidity, pool unavailable), the hook transfers the reminted project tokens back to the **holder** (not the beneficiary) instead of reverting the entire cash-out. The holder retains their project tokens and can sell them manually or retry. A `SellSwapReverted` event is emitted for offchain monitoring.

If the pool only partially fills before hitting the hook's price limit, the swap proceeds are still sent to the
beneficiary, but the unsold reminted project tokens are returned to the holder. This keeps a sell-side route from
destroying the part of the holder's position that the AMM did not actually buy. The underfill check is symmetric with
the full-revert fallback above: only a caller-specified minimum hard-reverts when the delivered terminal-token amount
falls below the floor. A floor derived during route selection (no explicit caller minimum) soft-lands the partial
fill — the partial proceeds reach the beneficiary and the unsold residue returns to the holder — exactly as the
full-revert branch returns project tokens to the holder rather than blocking the cash-out.

### 9.7 Unpinned projects fall back to the mutable default hook

Projects using `JBBuybackHookRegistry` as their data hook without explicitly calling `setHookFor()` resolve to the mutable `defaultHook`. The first-ever default applies to every project that exists when it is set (including projects created before any default existed); afterward, a *new* default only applies to projects created after the change (`projectId > defaultHookProjectIdThreshold`), and earlier cohorts keep their creation-time default. A later default change never retroactively re-routes an earlier project. Always call `setHookFor(projectId, hook)` to pin your project's hook if you want it fixed.

### 9.8 Sell-side AMM proceeds are not fee-metered

When the buyback hook routes a cash-out through the AMM sell path, the swap proceeds go directly to the beneficiary without passing through the terminal's fee meter. This is by design — protocol fees apply only to actual terminal cashouts, not AMM market operations. The hook's `hookSpecifications.amount = 0` reflects this intent.

### 9.9 Native delivery to a reverting beneficiary atomically reverts the cash-out

When the sell path wins and the terminal token is the native asset, `afterCashOutRecordedWith` delivers proceeds via `Address.sendValue(context.beneficiary, amountReceived)`. If the beneficiary is a contract whose `receive()` / `fallback()` reverts (multisig with unfunded fallback, contract with disabled receive, gas-stipend-overrunning logic), the entire cash-out tx atomically reverts. The holder retains their tokens — there is no fund loss — but the cash-out cannot complete through this beneficiary until the configuration is changed.

This is intentional and mirrors the direct-cash-out path in `JBMultiTerminal`, which also uses `Address.sendValue` and reverts under the same conditions. Adding a fallback path in this hook (e.g. wrap-to-WETH or re-route to the holder) would create an asymmetry: the buyback path would be more lenient than the direct path that would otherwise have been used, making the routing decision affect whether a holder with a misconfigured beneficiary can cash out at all. The right cure is on the beneficiary side: ensure contract beneficiaries can accept native value (or use an ERC-20 terminal token where `safeTransfer` handles the delivery).

### 9.10 Warm but drained pools degrade to the protocol path

TWAP observations can remain warm after live in-range liquidity is removed. The hook checks current PoolManager liquidity before activating a pay or cash-out route, and treats zero liquidity or max-impact dust liquidity as a non-executable market path. Explicit minima still remain hard floors: if the direct protocol path cannot satisfy the floor, the call reverts instead of silently using an empty pool.
