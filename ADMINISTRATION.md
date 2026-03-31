# Administration

Admin privileges and their scope in nana-buyback-hook-v6.

## At A Glance

| Item | Details |
|------|---------|
| Scope | Buyback hook selection and per-project Uniswap V4 pool/TWAP configuration. |
| Operators | Registry owner for the global allowlist/default, plus each project owner or delegate for project-local hook and pool settings. |
| Highest-risk actions | Locking a project's hook choice, setting the wrong pool for a terminal token, or changing TWAP windows without understanding route quality and manipulation resistance. |
| Recovery posture | Unlocked projects can move to a new allowed hook. Locked projects keep their chosen hook, so recovery usually means migrating project configuration elsewhere. |

## Routine Operations

- Keep the registry allowlist tight and move the default hook deliberately, because many unconfigured projects inherit it.
- For each project, configure the buyback pool once per terminal token only after verifying the exact token pair, hook address, and TWAP bounds.
- Tune TWAP windows only after a pool exists and only when there is a clear oracle-quality reason to change them.
- Lock a project's hook only when the project is certain it will not need to switch implementations later.

## One-Way Or High-Risk Actions

- `lockHookFor` is irreversible at the project level.
- `setPoolFor` and `initializePoolFor` are one-time decisions per project and terminal token.
- Disallowing a hook in the registry does not remove it from projects that already selected or locked it.

## Recovery Notes

- If an unlocked project picked a bad hook, point it to a different allowlisted implementation through the registry.
- If pool configuration is wrong and cannot be edited in place, deploy and select a new hook implementation or migrate the project to a new routing arrangement before locking.

## Roles

### Registry Owner

- **How assigned:** Set in the `JBBuybackHookRegistry` constructor via OpenZeppelin `Ownable(owner)`. Transferable via `transferOwnership()` and `renounceOwnership()` (inherited from `Ownable`).
- **Scope:** Global. Controls which buyback hook implementations are available to all projects, and which implementation is the default.

### Project Owner

- **How assigned:** The owner of a project's ERC-721 NFT in `JBProjects`. Determined by `PROJECTS.ownerOf(projectId)`.
- **Scope:** Per-project. Can configure pool settings, TWAP parameters, and hook selection for their own project.

### Permissioned Delegate

- **How assigned:** Granted by a project owner via `JBPermissions`. The project owner can grant specific permission IDs (scoped to a project) to any address.
- **Scope:** Per-project, limited to the specific permission ID(s) granted. Acts on behalf of the project owner for the permitted functions.

## Privileged Functions

### JBBuybackHook

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|--------------|
| `setPoolFor(projectId, poolKey, twapWindow, terminalToken)` | Project owner or permissioned delegate | `SET_BUYBACK_POOL` (28) | Per-project, per-terminal-token. **One-time only** -- reverts with `JBBuybackHook_PoolAlreadySet` if already set. | Configures the Uniswap V4 pool for a project/terminal-token pair. Validates that the pool is initialized, currencies match the project token and terminal token, and the TWAP window is within bounds (5 min -- 2 days). Stores the pool key, TWAP window, and project token address. |
| `setPoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken)` | Project owner or permissioned delegate | `SET_BUYBACK_POOL` (28) | Per-project, per-terminal-token. **One-time only.** | Convenience overload that constructs the `PoolKey` internally using the provided fee and tick spacing (with `ORACLE_HOOK` as the hooks address), then delegates to the `PoolKey` overload. |
| `initializePoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken, sqrtPriceX96)` | Project owner or permissioned delegate | `SET_BUYBACK_POOL` (28) | Per-project, per-terminal-token. **One-time only** -- reverts with `JBBuybackHook_PoolAlreadySet` if already set. | Atomically initializes a Uniswap V4 pool (if not already initialized) and configures it as the buyback pool. Constructs the `PoolKey` using the immutable `ORACLE_HOOK`. Same validation and storage as `setPoolFor`. |
| `setTwapWindowOf(projectId, terminalToken, newWindow)` | Project owner or permissioned delegate | `SET_BUYBACK_TWAP` (27) | Per-project, per-terminal-token. Can be called multiple times. Requires a pool to be configured first. | Changes the TWAP window used for oracle-based slippage calculation for a specific terminal token. Must be between `MIN_TWAP_WINDOW` (5 minutes) and `MAX_TWAP_WINDOW` (2 days). Reverts with `JBBuybackHook_PoolNotSet` if no pool has been configured for this project/terminal token pair. |

### JBBuybackHookRegistry

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|--------------|
| `allowHook(hook)` | Registry owner | N/A (`onlyOwner`) | Global | Adds a buyback hook implementation to the allowlist. Projects can only use hooks that are on the allowlist. |
| `disallowHook(hook)` | Registry owner | N/A (`onlyOwner`) | Global | Removes a buyback hook implementation from the allowlist. Reverts with `JBBuybackHookRegistry_CannotDisallowDefaultHook` if the hook is the current default -- the owner must call `setDefaultHook` to change the default first. Does **not** affect projects that have already set or locked this hook. |
| `setDefaultHook(hook)` | Registry owner | N/A (`onlyOwner`) | Global | Sets the default buyback hook used by projects that have not explicitly chosen one. Also adds the hook to the allowlist. Reverts if `hook` is `address(0)`. |
| `setHookFor(projectId, hook)` | Project owner or permissioned delegate | `SET_BUYBACK_HOOK` (29) | Per-project | Sets which buyback hook implementation a project uses. The hook must be on the allowlist. Reverts if the project's hook is locked. |
| `lockHookFor(projectId, expectedHook)` | Project owner or permissioned delegate | `SET_BUYBACK_HOOK` (29) | Per-project. **Irreversible.** | Permanently locks the hook for a project. If the project is using the default (no explicit hook set), the current default is snapshotted into storage before locking. Requires a non-zero resolved hook. The `expectedHook` parameter prevents race conditions where the hook changes between transaction submission and execution. |
| `setPoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken)` | Project owner or permissioned delegate | `SET_BUYBACK_POOL` (28) | Per-project, per-terminal-token | Delegates to the resolved hook's `setPoolFor` (fee/tickSpacing overload). |
| `initializePoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken, sqrtPriceX96)` | Project owner or permissioned delegate | `SET_BUYBACK_POOL` (28) | Per-project, per-terminal-token | Delegates to the resolved hook's `initializePoolFor`. |
| `transferOwnership(newOwner)` | Registry owner | N/A (`onlyOwner`) | Global | Transfers registry ownership to a new address. Inherited from OpenZeppelin `Ownable`. |
| `renounceOwnership()` | Registry owner | N/A (`onlyOwner`) | Global | Permanently renounces registry ownership, setting the owner to `address(0)`. Inherited from OpenZeppelin `Ownable`. After renouncing, no new hooks can be allowed/disallowed, and the default hook cannot be changed. |

## Registry Ownership

The `JBBuybackHookRegistry` owner has three powers:

1. **Allowlisting hooks** (`allowHook`) -- Gate which hook implementations projects can use. Only allowlisted hooks can be set via `setHookFor`. By design, the owner may also allow `address(0)` so authorized project operators can clear an explicit project hook assignment and return to the registry default.
2. **Disallowing hooks** (`disallowHook`) -- Remove hooks from the allowlist. Reverts if the hook is the current default (the owner must change the default first). Projects that already set or locked the hook are unaffected.
3. **Setting the default hook** (`setDefaultHook`) -- Choose the hook that projects use when they have not explicitly set one. Also allowlists the hook.

The owner cannot force a hook onto a project that has already set or locked its own hook. The owner cannot unlock a locked hook.

Ownership is transferable via `transferOwnership()` and can be permanently renounced via `renounceOwnership()`, both inherited from OpenZeppelin's `Ownable`.

## Hook Resolution

When the Juicebox controller queries for a project's buyback hook, the resolution follows this order:

1. If the project has called `setHookFor(projectId, hook)` with a non-zero hook, that explicit hook is used.
2. If no explicit hook is set, the registry's `defaultHook` is used.
3. If neither exists (default is `address(0)` and no explicit hook), no buyback hook is active.

**Clearing back to default:** If the registry owner has allowlisted `address(0)`, a project owner or delegate can call `setHookFor(projectId, IJBRulesetDataHook(address(0)))` to clear the explicit assignment and return to default-hook resolution.

**Lock semantics:** When `lockHookFor()` is called on a project that has no explicit hook, the current default is snapshot into `_hookOf[projectId]` before locking. This means the project becomes independent of future default changes.

**Disallow vs. lock interaction:** If the registry owner disallows a hook via `disallowHook()`, projects that have already set or locked that hook are unaffected -- they continue using it. However, projects relying on the default (without locking) could be affected if the default is changed before they lock. The registry owner must first change the default (via `setDefaultHook`) before disallowing the previous default, since `disallowHook` reverts if the target is the current default.

**No-hook edge case:** If a project has not set an explicit hook and the registry owner sets `defaultHook` to a new address, the project's resolved hook changes immediately and without notification. Projects should lock their hook to avoid unexpected changes.

## Immutable Configuration

The following are set at deploy time and cannot be changed:

### JBBuybackHook

| Property | Type | Description |
|----------|------|-------------|
| `DIRECTORY` | `IJBDirectory` | The directory of terminals and controllers. |
| `PRICES` | `IJBPrices` | The contract that exposes price feeds. |
| `PROJECTS` | `IJBProjects` | The project registry (determines project ownership). |
| `TOKENS` | `IJBTokens` | The token registry. |
| `POOL_MANAGER` | `IPoolManager` | The Uniswap V4 PoolManager singleton. |
| `ORACLE_HOOK` | `IHooks` | The oracle hook (JBUniswapV4Hook / IGeomeanOracle) used for TWAP-based slippage calculations. Set as `PoolKey.hooks` when creating pools. Provides `observe()` for tick observations. |
| `PERMISSIONS` | `IJBPermissions` | The permissions contract (inherited from `JBPermissioned`). |
| Trusted forwarder | `address` | The ERC-2771 trusted forwarder for meta-transactions. |

### JBBuybackHookRegistry

| Property | Type | Description |
|----------|------|-------------|
| `PROJECTS` | `IJBProjects` | The project registry (determines project ownership). |
| `PERMISSIONS` | `IJBPermissions` | The permissions contract (inherited from `JBPermissioned`). |
| Trusted forwarder | `address` | The ERC-2771 trusted forwarder for meta-transactions. |

### Per-Project Immutables (set once, never changeable)

| Property | Scope | Description |
|----------|-------|-------------|
| Pool key | Per project, per terminal token | Once `setPoolFor` is called for a project/terminal-token pair, the pool key (`_poolKeyOf`) and the `_poolIsSet` flag cannot be changed. The pool choice is permanent. |
| Locked hook | Per project | Once `lockHookFor` is called, `hasLockedHook[projectId]` is permanently `true`. The hook for that project cannot be changed again. |

## Admin Boundaries

Things that admins **cannot** do:

- **Registry owner cannot force a hook onto a specific project.** Projects choose their own hook via `setHookFor`, or inherit the default. The owner only controls the allowlist and the default.
- **Registry owner cannot unlock a locked hook.** Once a project's hook is locked via `lockHookFor`, no one -- not even the registry owner -- can change it.
- **Registry owner cannot change a project's pool configuration.** Pool settings (`setPoolFor`, `setTwapWindowOf`) are gated by project-level permissions, not registry ownership.
- **Project owner cannot change a pool once set.** After `setPoolFor` is called for a project/terminal-token pair, the pool key is immutable. The project owner can still change the TWAP window.
- **Project owner cannot unlock a locked hook.** `lockHookFor` is irreversible. There is no `unlockHookFor`.
- **Project owner cannot set a hook that is not allowlisted.** `setHookFor` reverts with `JBBuybackHookRegistry_HookNotAllowed` if the hook is not on the allowlist.
- **No one can withdraw or redirect swap proceeds.** The hook's `afterPayRecordedWith` is only callable by the project's payment terminals (verified via `DIRECTORY.isTerminalOf`). Swap outputs are burned and re-minted through the controller with reserves applied.
- **No one can bypass the TWAP bounds.** The TWAP window is always clamped between 5 minutes and 2 days, regardless of who calls `setPoolFor` or `setTwapWindowOf`.
- **Registry owner cannot silently change a locked project's hook.** Once locked, the hook is stored in `_hookOf[projectId]` and is no longer affected by default changes or allowlist changes. The lock is the definitive guarantee of hook immutability.
- **No one can call `unlockCallback` except the PoolManager.** The V4 swap callback is gated to `msg.sender == POOL_MANAGER`.
