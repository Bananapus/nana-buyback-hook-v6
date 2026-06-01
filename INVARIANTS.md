# Invariants of `nana-buyback-hook-v6`

Scope: the two production contracts in `src/` — `JBBuybackHook` and `JBBuybackHookRegistry` — plus the helpers in `src/libraries/JBSwapLib.sol`. The hook is a data hook + pay hook + cash-out hook that compares the Juicebox-native bonding-curve route against a Uniswap V4 pool route on every pay and cash out, and routes through whichever benefits the user more. The registry is the project-facing data hook: it resolves which `JBBuybackHook` implementation applies to a given project (project-specific pin, default cohort, or none), forwards the data-hook callbacks to that resolved hook, and exposes mint permission only for the resolved hook.

This file is the per-repo scoped invariants doc. The protocol-wide guarantees for the seven deployed revnets live in [`../INVARIANTS.md`](../INVARIANTS.md); section C.11 there summarizes this repo from the protocol's perspective.

---

# Section A — Guarantees to Paying Users + Token Holders

## A.1 Pay path

- **A.1.1 Mint floor.** A user paying through a configured buyback hook never receives fewer project tokens than the direct bonding-curve mint at the ruleset weight. If the pool ask is worse than the mint rate, `beforePayRecordedWith` returns `noop=true` and the terminal mints at the weight unchanged. If the pool ask is better, the hook routes the payment through the pool and any unswapped input is minted at the issuance rate (see the floor + ceiling arbitrage NatSpec on `JBBuybackHook.beforePayRecordedWith`, lines 902–928 of `src/JBBuybackHook.sol`).
- **A.1.2 Combined-output floor.** When the pool path is chosen, `afterPayRecordedWith` enforces `exactSwapAmountOut + partialMintTokenCount ≥ minimumSwapAmountOut`. Explicit caller minima (`hasUserSpecifiedQuote`) are hard floors even when the swap reverts; oracle-derived minima are routing hints and may degrade to mint-only fallback (`src/JBBuybackHook.sol:436–444`).
- **A.1.3 Reserved-rate preservation.** Tokens received from the pool swap are burned and re-minted through the controller with `useReservedPercent: true`, so the reserved-rate split applies identically whether the route was pool or mint (`src/JBBuybackHook.sol:454–460`).
- **A.1.4 Issuance-rate price limit.** The swap's `sqrtPriceLimit` is derived from `tokenCountWithoutHook`, so the pool fills only while the rate beats minting; remaining input falls back to the mint path (`src/JBBuybackHook.sol:374–380`).
- **A.1.5 Slippage revert.** If the swap successfully partially fills but the combined output falls short of `minimumSwapAmountOut`, the call reverts `JBBuybackHook_SpecifiedSlippageExceeded` rather than silently delivering less than promised.
- **A.1.6 Pay-side fee-on-transfer safety.** Leftover terminal tokens are computed as `balanceAfter − balanceBefore` (delta accounting), and `partialMintTokenCount` is derived from the amount the terminal actually re-acquired (`src/JBBuybackHook.sol:382–435`). Pre-existing token balances on the hook are never swept into a user's mint count.

## A.2 Cash out path

- **A.2.1 Reclaim floor.** A holder cashing out through the buyback hook never receives less than the net direct bonding-curve reclaim. `beforeCashOutRecordedWith` computes the gross direct reclaim via `JBCashOuts.cashOutFrom`, applies the terminal's exact fee policy via `_netAfterTerminalFee`, and only chooses the pool route when `minimumSwapAmountOut > netDirectCashOutAmount` (`src/JBBuybackHook.sol:833–865`). The "floor arbitrage" NatSpec at lines 748–763 documents this guarantee.
- **A.2.2 Explicit-minimum honored on noop.** The `cashOut` metadata entry is decoded as `(uint256 minimumSwapAmountOut, bool skip)`. If the user supplies a non-zero `minimumSwapAmountOut` and the hook takes the direct/passthrough path (no pool configured, no project token, zero count, or `skip=true`), the conservative net direct reclaim is checked against the user minimum and reverts `JBBuybackHook_SpecifiedSlippageExceeded` if it falls short (`JBBuybackHook.beforeCashOutRecordedWith`, fallback block).
- **A.2.8 `skip` venue override.** When the caller sets `skip=true` in the `cashOut` entry, `beforeCashOutRecordedWith` short-circuits to the direct protocol cash-out path — it never reads the pool quote and returns no hook specification — even if the pool would pay more. This is a deliberate venue selection, not a slippage waiver: the `minimumSwapAmountOut` floor is still enforced against the net direct reclaim (A.2.2), so an unmeetable floor reverts rather than silently routing to the AMM. Defaults to `false` (pool routing enabled).
- **A.2.3 Sell-count integrity.** `afterCashOutRecordedWith` clamps `cashOutCountToSell ≤ context.cashOutCount`, so a wrapper-supplied metadata count can only shrink the sell, never inflate it above what the terminal burned (`src/JBBuybackHook.sol:240`).
- **A.2.4 Successful-fill minimum: explicit hard floor, derived soft floor.** When the swap succeeds and delivers proceeds, only a caller-specified minimum (`shouldEnforceMinimumSwapAmountOut == true`) is a hard floor: if `amountReceived` falls short the call reverts `JBBuybackHook_SpecifiedSlippageExceeded`. A floor derived during route selection (`shouldEnforceMinimumSwapAmountOut == false`) is a soft floor — a successful-but-partial fill below it soft-lands instead of reverting (partial proceeds to the beneficiary, unsold residue to the holder), symmetric with the swap-revert branch (A.2.5). Delivery in ERC-20 is measured by recipient balance-delta so fee-on-transfer tokens cannot bypass an explicit floor (`src/JBBuybackHook.sol:300–328`).
- **A.2.5 Swap revert returns project tokens, not silence.** If the pool reverts entirely, the reminted project tokens are returned to the holder (not the beneficiary), the holder keeps their position, and a `SellSwapReverted` event is emitted. If the user explicitly demanded a non-zero terminal-token minimum, that minimum cannot be satisfied with project tokens — the call reverts instead of silently settling in the wrong token (`src/JBBuybackHook.sol:268–282`).
- **A.2.6 Partial-fill residue returned to holder.** When the pool fills only part of the reminted token count, the unsold remint is transferred back to `context.holder`, never swept (`src/JBBuybackHook.sol:290–296`).
- **A.2.7 Sell-side fee-on-transfer safety.** The remint count used to compute the sell is measured as `balanceAfterMint − balanceBefore` (`src/JBBuybackHook.sol:246–258`) and the terminal-token delivery to the beneficiary uses a recipient balance-delta check (`src/JBBuybackHook.sol:303–308`).

## A.3 Pool integrity (front-run resistance)

- **A.3.1 Front-run-resistant pool initialization.** `initializePoolFor` reads `slot0` after attempting `poolManager.initialize` and reverts `PoolInitializedAtWrongPrice` if the on-chain price does not match the caller's expected `sqrtPriceX96`. Because the project token address is CREATE2-predictable, an attacker can squat the canonical PoolKey at an arbitrary price; this check defeats that (`src/JBBuybackHook.sol:493–507`).
- **A.3.2 Pool keys immutable once set.** `_setPoolFor` reverts `PoolAlreadySet` on a second write for the same `(projectId, terminalToken)` pair. Buyback routing for an existing pair cannot be repointed by anyone — including the project owner — once configured (`src/JBBuybackHook.sol:1102–1105`).
- **A.3.3 Pool currencies must match.** `_setPoolFor` requires `poolKey.currency0` and `poolKey.currency1` to be exactly `{projectToken, normalizedTerminalToken}` in either order (`src/JBBuybackHook.sol:1127–1132`), and rejects `terminalToken == projectToken` (`src/JBBuybackHook.sol:1115–1120`). A pool whose currencies don't match the project + terminal pair can never be installed.
- **A.3.4 Project must have a token.** `_setPoolFor` reverts `ZeroProjectToken` if the project has not issued an ERC-20 (`src/JBBuybackHook.sol:1112–1113`).
- **A.3.5 Pool must be initialized.** `_setPoolFor` reads `slot0.sqrtPriceX96` and reverts `PoolNotInitialized` if it is zero (`src/JBBuybackHook.sol:1122–1125`).

## A.4 Oracle integrity

- **A.4.1 TWAP-based quote, no spot fallback.** `_getQuote` queries `JBSwapLib.getQuoteFromOracle` with the configured TWAP window. If the oracle returns zero (cold pool, insufficient history) or liquidity is zero, the function returns `(0, 0, ...)` and the hook degrades to the mint/direct-reclaim path. There is no spot-price fallback (`src/JBBuybackHook.sol:1320–1351`). This is a MEV-protection invariant: cold pools cannot be sandwich-routed.
- **A.4.2 TWAP window bounds.** `setTwapWindowOf` and `_setPoolFor` reject windows outside `[MIN_TWAP_WINDOW = 5 minutes, MAX_TWAP_WINDOW = 2 days]` via `JBBuybackHook_InvalidTwapWindow` (`src/JBBuybackHook.sol:626–628`, `1107–1110`).
- **A.4.3 Sigmoid slippage scales with impact.** `_getQuote` computes price impact from amount-in, liquidity, and the TWAP tick, then calls `JBSwapLib.getSlippageTolerance(impact, poolFeeBps)`. When tolerance reaches `TWAP_SLIPPAGE_DENOMINATOR`, the quote is zeroed and the route degrades to mint (`src/JBBuybackHook.sol:1353–1369`). Larger trades against thin pools face stricter slippage automatically.

## A.5 Preview API (diagnostic metadata in noop spec)

- **A.5.1 Noop hook specs carry routing diagnostics.** Both `beforePayRecordedWith` and `beforeCashOutRecordedWith` return a `JBPayHookSpecification` / `JBCashOutHookSpecification` even when `noop=true`. The metadata encodes `twapTick`, `twapLiquidity`, `poolId`, `rawSwapQuote`, the weight ratio (pay side), and the conservative comparison value used to decide the route. Off-chain clients (frontends, arbitrage bots, indexers) can preview the routing decision without forcing the terminal to execute. The NatSpec at `src/JBBuybackHook.sol:760–763` and `911–914` explicitly mark this as the protocol's public preview API surface — do not optimize it away. Exception: a `skip=true` cash-out (A.2.8) deliberately opts out of pool routing, so it returns no spec and no diagnostics — there is no route to preview.

---

# Section B — Guarantees to Operators (per-project)

Operator surface is granted via `JBPermissions` per project ID. The matrix below shows which permission ID gates which entry point.

## B.1 `JBBuybackHook` operator surface

| Function | Permission required | Effect | Notes |
|---|---|---|---|
| `initializePoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken, sqrtPriceX96)` | `SET_BUYBACK_POOL` (29) | Try-initializes a V4 pool, validates on-chain price equals expected, then calls `_setPoolFor`. | One-shot per `(projectId, terminalToken)`; front-run-resistant. |
| `setPoolFor(projectId, PoolKey, twapWindow, terminalToken)` | `SET_BUYBACK_POOL` (29) | Configures an existing initialized pool as the buyback pool. | Pool key immutable once set. WARNING in NatSpec: the `poolKey.hooks` field is NOT validated by the contract — caller responsibility. |
| `setPoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken)` | `SET_BUYBACK_POOL` (29) | Same as above but constructs the PoolKey internally using `oracleHook`. | Pool key immutable once set. |
| `setTwapWindowOf(projectId, terminalToken, newWindow)` | `SET_BUYBACK_TWAP` (28) | Updates the TWAP window for an existing pool config. | Window ∈ `[5min, 2days]`; pool must already be set. |

## B.2 `JBBuybackHookRegistry` operator surface

| Function | Permission required | Effect | Notes |
|---|---|---|---|
| `setHookFor(projectId, hook)` | `SET_BUYBACK_HOOK` (30) | Pins a specific allowlisted hook for the project. `address(0)` is allowlisted and clears the assignment back to default resolution. | Reverts `HookLocked` if already locked, `HookNotAllowed` if not on allowlist. |
| `lockHookFor(projectId, expectedHook)` | `SET_BUYBACK_HOOK` (30) | Snapshots the resolved hook into `_hookOf[projectId]` (if not already pinned) and permanently sets `hasLockedHook[projectId] = true`. | Race-safe: reverts `HookMismatch` if resolved ≠ expected. **Irreversible** — a locked project is permanently immune to default-hook changes. |
| `initializePoolFor(...)` | `SET_BUYBACK_POOL` (29) | Forwarder to resolved hook's `initializePoolFor`. | Reverts `HookNotSet` if no hook resolved. |
| `setPoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken)` | `SET_BUYBACK_POOL` (29) | Forwarder to resolved hook's `setPoolFor`. | Reverts `HookNotSet` if no hook resolved. |

**Operator floor.** No matter what the operator does with pool configuration, swap routing, or TWAP tuning, the user-side invariants A.1.1 (mint floor) and A.2.1 (reclaim floor) hold by construction. An operator cannot configure a "bad pool" that lets users get fewer tokens than direct mint or less than the bonding-curve reclaim — only worse swap execution (mint fallback) or a stuck pool.

---

# Section C — Per-Contract Operation Inventory

## C.1 `JBBuybackHook` — `src/JBBuybackHook.sol`

### Deployer-only one-shot
- **`setChainSpecificConstants(IPoolManager newPoolManager, IHooks newOracleHook)`** — caller must be `_DEPLOYER`; reverts `Unauthorized` otherwise. Reverts `AlreadyConfigured` if `poolManager != address(0)`. Sets the V4 PoolManager and oracle hook once for the contract's lifetime. Pattern mirrors `JBOptimismSuckerDeployer.setChainSpecificConstants` so the CREATE2 inputs are byte-identical across chains. `_DEPLOYER` is held internal-immutable (not public) per repo style.

### Permissioned (project-scoped)
- **`initializePoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken, sqrtPriceX96)`** — `SET_BUYBACK_POOL`. See B.1.
- **`setPoolFor(projectId, PoolKey, twapWindow, terminalToken)`** — `SET_BUYBACK_POOL`. See B.1.
- **`setPoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken)`** — `SET_BUYBACK_POOL`. See B.1.
- **`setTwapWindowOf(projectId, terminalToken, newWindow)`** — `SET_BUYBACK_TWAP`. See B.1.

### Terminal-only callbacks
- **`afterPayRecordedWith(JBAfterPayRecordedContext) payable`** — only a registered terminal of the project (`DIRECTORY.isTerminalOf`). Executes the buy-side swap with the issuance-rate price limit, mints the swap-output + leftover at the ruleset rate. Invariants: A.1.1, A.1.2, A.1.3, A.1.4, A.1.5, A.1.6.
- **`afterCashOutRecordedWith(JBAfterCashOutRecordedContext) payable`** — only a registered terminal of the project. Remints `cashOutCountToSell` to itself, sells via V4, delivers proceeds to the beneficiary. Invariants: A.2.3, A.2.4, A.2.5, A.2.6, A.2.7.

### PoolManager-only callback
- **`unlockCallback(bytes data) returns (bytes)`** — only `poolManager`; reverts `CallerNotPoolManager` otherwise. Executes the swap with a `sqrtPriceLimit` derived from `JBSwapLib.sqrtPriceLimitFromAmounts` and settles input / takes output. Uses balance-delta accounting on the take side for fee-on-transfer safety (`src/JBBuybackHook.sol:715–726`).

### Receive
- **`receive() external payable`** — accepts native ETH for V4 `take()` settlement.

### Views (permissionless)
- **`beforePayRecordedWith(JBBeforePayRecordedContext) view → (weight, hookSpecifications)`** — data-hook callback; route comparison. Returns `(0, [activePayHookSpec])` on pool win and `(context.weight, [noopPayHookSpec])` on mint win. Both branches carry diagnostic metadata (see A.5.1).
- **`beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext) view → (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, hookSpecifications)`** — data-hook callback; route comparison. On pool win, returns `MAX_CASH_OUT_TAX_RATE` and zero effective surplus so the terminal does not reclaim surplus directly; on mint win, returns context values unchanged. Both branches carry diagnostic metadata.
- **`hasMintPermissionFor(uint256, JBRuleset, address) pure → false`** — the hook itself never claims mint permission; mint authority flows through the registry's resolved-hook check (`hasMintPermissionFor` on the registry returns `true` only for the resolved hook).
- **`poolKeyOf(projectId, terminalToken) view → PoolKey`** — exposes the configured pool key.
- **`supportsInterface(bytes4) pure → bool`** — ERC-165 for `IJBRulesetDataHook`, `IJBPayHook`, `IJBCashOutHook`, `IJBBuybackHook`, `IJBPermissioned`, `IERC165`.
- **`projectTokenOf(projectId) view → address`**, **`twapWindowOf(projectId, terminalToken) view → uint256`**, **`poolManager() view → IPoolManager`**, **`oracleHook() view → IHooks`** — public storage getters.
- **`MAX_TWAP_WINDOW() / MIN_TWAP_WINDOW() / TWAP_SLIPPAGE_DENOMINATOR()`** — public constants.
- **`DIRECTORY() / PRICES() / PROJECTS() / TOKENS() / PERMISSIONS()`** — public immutables.

## C.2 `JBBuybackHookRegistry` — `src/JBBuybackHookRegistry.sol`

### Owner-only (Ownable)
- **`allowHook(IJBRulesetDataHook hook)`** — adds to allowlist. Allowing `address(0)` is intentional: it lets operators clear a project's pinned hook back to default resolution.
- **`disallowHook(IJBRulesetDataHook hook)`** — removes from allowlist. **Reverts `CannotDisallowDefaultHook` if `hook == defaultHook`** — disallowing the current default would brick payments for every project relying on the default.
- **`setDefaultHook(IJBRulesetDataHook hook)`** — sets the protocol-wide default. Reverts `ZeroHook` on `address(0)`. Snapshots the outgoing default into `_defaultHookHistory` with `maxProjectId = PROJECTS.count()` so the existing cohort keeps resolving to its creation-time default. Sets `defaultHookProjectIdThreshold = PROJECTS.count()` so the new default only applies to projects created strictly after this call. Also allowlists the new default.

### Permissioned (project-scoped)
- **`setHookFor(projectId, hook)`** — `SET_BUYBACK_HOOK`. See B.2.
- **`lockHookFor(projectId, expectedHook)`** — `SET_BUYBACK_HOOK`. See B.2.
- **`initializePoolFor(...)`** — `SET_BUYBACK_POOL`, forwarder.
- **`setPoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken)`** — `SET_BUYBACK_POOL`, forwarder.

### Data-hook callbacks (view, called by terminal)
- **`beforePayRecordedWith(JBBeforePayRecordedContext) view → (weight, hookSpecifications)`** — resolves the project's hook; if `address(0)`, returns `(context.weight, [])` (pass-through). Otherwise rekeys any registry-scoped `"pay"` metadata to the resolved hook's address and forwards.
- **`beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext) view → (...)`** — resolves the project's hook; if `address(0)`, returns context values unchanged. Otherwise rekeys any registry-scoped `"cashOut"` metadata to the resolved hook's address and forwards.

### Views (permissionless)
- **`hasMintPermissionFor(projectId, JBRuleset, addr) view → bool`** — returns `true` iff `addr == _resolvedHookOf(projectId)`. **This is the only path by which mint permission is granted** to the buyback hook (see Section D).
- **`hookOf(projectId) view → IJBRulesetDataHook`** — public resolution lookup.
- **`defaultHookHistoryAt(uint256 index) view → DefaultHookSegment`**, **`defaultHookHistoryLength() view → uint256`** — read the chronological cohort-default snapshots.
- **`defaultHook() / defaultHookProjectIdThreshold() / hasLockedHook(projectId) / isHookAllowed(hook) / PROJECTS() / PERMISSIONS()`** — public state.
- **`supportsInterface(bytes4) pure → bool`** — ERC-165 for `IJBBuybackHookRegistry`, `IJBRulesetDataHook`, `IERC165`.

---

# Section D — Cross-Cutting Invariants

- **D.1 Mint authority is registry-resolved only.** `JBBuybackHook.hasMintPermissionFor` returns `false` unconditionally. The only path by which a `JBBuybackHook` instance gains mint permission is through `JBBuybackHookRegistry.hasMintPermissionFor`, which returns `true` iff the queried address equals `_resolvedHookOf(projectId)` (project pin, cohort default, or `address(0)`). The controller routes mint-permission checks to the project's data hook (the registry), so a hook implementation that is not the resolved hook cannot mint, even if allowlisted.
- **D.2 Cohort-stable defaults.** `_defaultHookHistory` snapshots every outgoing default with the project-ID window it applied to. A project whose ID falls within a historical segment continues to resolve to that segment's hook forever, unless it explicitly pins via `setHookFor`. This means a registry-owner default change can never silently re-route the existing cohort. NatSpec at `src/JBBuybackHookRegistry.sol:78–85` and the resolver at lines 520–542 implement this.
- **D.3 Lock makes project sovereign.** Once `lockHookFor` runs, `_hookOf[projectId]` is populated and `hasLockedHook[projectId] = true`. Subsequent `setHookFor` calls revert `HookLocked`; default-hook changes are bypassed because `_resolvedHookOf` returns the pinned `_hookOf[projectId]` first.
- **D.4 Cold/uninitialized pools degrade to mint.** A `(projectId, terminalToken)` pair with `_poolIsSet == false` causes `beforeCashOutRecordedWith` to return the protocol cash-out values unchanged (subject to A.2.2) and causes `beforePayRecordedWith` to fall through to the no-pool branch (subject to the A.1.1 mint floor + explicit-minimum revert at `src/JBBuybackHook.sol:1047–1054`). A pool with no liquidity or no TWAP history makes `_getQuote` return zero (A.4.1), so the hook again degrades to mint.
- **D.5 Pool currencies match project + terminal.** A.3.3 plus A.3.5 mean every configured pool is initialized, in the right pair, with the right project's token.
- **D.6 Reentrancy on `unlockCallback` is gated to PoolManager.** Any caller other than `poolManager` reverts `CallerNotPoolManager` (`src/JBBuybackHook.sol:656`). The settlement logic inside the callback (`settle`, `sync`, `take`) interacts only with PoolManager. The after-hook flows that lead to `unlockCallback` (afterPay / afterCashOut) are themselves gated to project terminals.
- **D.7 Balance-delta accounting throughout.** Both `unlockCallback` (take side, `src/JBBuybackHook.sol:715–726`), `afterPayRecordedWith` (leftover computation, `src/JBBuybackHook.sol:382–425`), and `afterCashOutRecordedWith` (remint count and ERC-20 delivery, `src/JBBuybackHook.sol:246–258`, `303–308`) compute deltas rather than reading absolute balances. Fee-on-transfer tokens cannot bypass minimum-output checks; pre-existing balances on the hook cannot be swept into a user mint or delivery.
- **D.8 Floor + ceiling arbitrage as documented routing primitive.** The NatSpec on `beforePayRecordedWith` (lines 902–928) and `beforeCashOutRecordedWith` (lines 738–763) is part of the public contract surface. It documents that the hook auto-applies (a) the **ceiling arbitrage** path (Path 3 in `revnet-core-v6/ARBITRAGE.md`) on pay — user gets the lower of AMM ask / mint rate — and (b) the **floor arbitrage** path (Path 2) on cash out — user gets the higher of AMM bid / bonding-curve reclaim. The protocol-health side effect is that ordinary terminal users auto-capture the same arbitrage incentive that sophisticated actors would otherwise extract: pay-path arbitrage drives the AMM price down toward the issuance rate (payment lands in surplus); cash-out arbitrage drives the AMM price up toward fair value (tax retained boosts per-token backing).
- **D.9 The `noop` spec carries diagnostics, not funds.** Both data-hook callbacks always populate a `hookSpecifications[0]` with the routing comparison metadata, even when `noop=true`. Off-chain preview clients (frontends, arbitrage bots, indexers) depend on this; the metadata schema (described in the NatSpec) is the protocol's public preview API.

---

# Section E — Centralization Caveats

## E.1 `JBBuybackHookRegistry` Ownable

The registry is `Ownable`. The owner can:

1. **Allowlist hooks** via `allowHook`. New hooks must be reviewed before allowlisting; an allowlisted-but-malicious hook can be selected by any project owner via `setHookFor`.
2. **Disallow hooks** via `disallowHook`, **except** the current default (which is structurally protected to prevent default-using projects from breaking, see Section C.2).
3. **Rotate the default hook** via `setDefaultHook`. **The rotation only affects projects created strictly after the call** (`projectId > defaultHookProjectIdThreshold`); the existing cohort is snapshotted into `_defaultHookHistory` and continues to resolve to its creation-time default (D.2).

The owner **cannot**:

- override a project's explicit pin (`setHookFor` is operator-only).
- unlock a locked project (D.3).
- re-route an existing project's resolved hook silently (D.2).
- mint any project's tokens.
- alter pool configuration for any project.
- bypass any of the A-section user-facing invariants.

In the production V6 deploy, the registry owner is `_CRITICAL_INFRA_OWNER` (the NANA ops Safe) post-deploy. See `../INVARIANTS.md` Section H for the broader infra-ownership inventory.

## E.2 `JBBuybackHook` not Ownable

`JBBuybackHook` itself has no admin role beyond the one-shot `_DEPLOYER` for `setChainSpecificConstants`. Once that single setter has run, the contract is effectively a pure runtime: no owner, no admin, no upgrade hook. All mutating entry points are either permissioned per-project, terminal-gated, or PoolManager-gated.

---

# Section F — Key Code References

| Invariant | File:lines |
|---|---|
| A.1.1, A.1.4, D.8 (ceiling arbitrage NatSpec) | `src/JBBuybackHook.sol:902–928` |
| A.1.2 (combined-output floor + explicit-vs-oracle minima) | `src/JBBuybackHook.sol:436–444` |
| A.1.3 (reserved-rate preservation) | `src/JBBuybackHook.sol:454–460` |
| A.1.4 (issuance-rate price limit) | `src/JBBuybackHook.sol:374–380` |
| A.1.6 (pay-side balance-delta + FoT) | `src/JBBuybackHook.sol:355–435` |
| A.2.1, D.8 (floor arbitrage NatSpec) | `src/JBBuybackHook.sol:738–763` |
| A.2.1 (direct vs pool reclaim comparison) | `src/JBBuybackHook.sol:833–865` |
| A.2.2 (explicit-minimum honored on noop) | `src/JBBuybackHook.sol:803–822` |
| A.2.3 (sell-count clamp) | `src/JBBuybackHook.sol:240` |
| A.2.4 (successful-fill minimum) | `src/JBBuybackHook.sol:285–308` |
| A.2.5 (swap revert → return to holder) | `src/JBBuybackHook.sol:268–282` |
| A.2.6 (partial-fill residue to holder) | `src/JBBuybackHook.sol:290–296` |
| A.2.7 (sell-side balance-delta + FoT) | `src/JBBuybackHook.sol:246–258`, `303–308` |
| A.3.1 (front-run-resistant initialization) | `src/JBBuybackHook.sol:493–507` |
| A.3.2 (pool key immutability) | `src/JBBuybackHook.sol:1102–1105` |
| A.3.3 (pool currency match) | `src/JBBuybackHook.sol:1127–1132` |
| A.3.4 (zero project token guard) | `src/JBBuybackHook.sol:1112–1113` |
| A.3.5 (pool initialized check) | `src/JBBuybackHook.sol:1122–1125` |
| A.4.1 (TWAP-only, no spot fallback) | `src/JBBuybackHook.sol:1320–1351` |
| A.4.2 (TWAP window bounds) | `src/JBBuybackHook.sol:626–628`, `1107–1110` |
| A.4.3 (sigmoid slippage) | `src/JBBuybackHook.sol:1353–1369` |
| A.5.1 (noop spec diagnostic metadata) | `src/JBBuybackHook.sol:760–763`, `869–884`, `911–914`, `1023–1043` |
| B (permission gates) | `src/JBBuybackHook.sol:485–490`, `554–559`, `597–601`, `619–623` |
| C.1 deployer one-shot | `src/JBBuybackHook.sol:518–530` |
| C.1 terminal gate (afterPay) | `src/JBBuybackHook.sol:329–333` |
| C.1 terminal gate (afterCashOut) | `src/JBBuybackHook.sol:208–212` |
| C.1 PoolManager gate (unlockCallback) | `src/JBBuybackHook.sol:654–656` |
| C.1 `hasMintPermissionFor → false` | `src/JBBuybackHook.sol:1059–1061` |
| C.2 owner gates (allow/disallow/setDefault) | `src/JBBuybackHookRegistry.sol:118–137`, `223–253` |
| C.2 cannot-disallow-default | `src/JBBuybackHookRegistry.sol:128–131` |
| C.2 setHookFor, lockHookFor | `src/JBBuybackHookRegistry.sol:190–214`, `260–275` |
| D.1 registry-resolved mint permission | `src/JBBuybackHookRegistry.sol:462–477` |
| D.2 cohort-stable default snapshots | `src/JBBuybackHookRegistry.sol:78–85`, `223–253`, `520–542` |
| D.3 lock → default-change immune | `src/JBBuybackHookRegistry.sol:520–542` |
| D.6 reentrancy gate on unlockCallback | `src/JBBuybackHook.sol:654–656` |
| E.1 registry Ownable | `src/JBBuybackHookRegistry.sol:30–106` |
| E.2 deployer one-shot, no owner on hook | `src/JBBuybackHook.sol:518–530` |

---

# Doc audit notes

Audit pass over the eight existing top-level docs:

- **README.md** — current; references all sibling docs and the build commands. No staleness flags.
- **ARCHITECTURE.md** — current; the buy/sell flow tables align with the source. Wording around "noop hook specs may carry diagnostics, but not funds" is consistent with the new INVARIANTS.md (D.9).
- **RISKS.md** — current; sections 8 ("Invariants to verify") and 9 ("Accepted behaviors") overlap with this INVARIANTS.md but at a higher altitude — kept intentionally; this file is the systematic per-contract enumeration, RISKS.md is the threat-model rationale. No edits.
- **USER_JOURNEYS.md** — current.
- **ADMINISTRATION.md** — current; permission matrix matches Section B.
- **AUDIT_INSTRUCTIONS.md** — current.
- **SKILLS.md** — current; entry-point map matches source.
- **CHANGELOG.md** — `0.0.46` notes are the most recent narrated entry while the current `package.json` version is `0.0.61`. The file narrates major changes only, consistent with how other repos in the workspace track entries; the unwritten `0.0.47` – `0.0.61` patch bumps are out of scope for this doc pass.
- **STYLE_GUIDE.md** — repo-internal style ref, unaffected.

No duplications worth deleting. No staleness corrections needed.
