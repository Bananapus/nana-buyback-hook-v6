# Administration

Admin privileges and their scope in nana-buyback-hook-v6.

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
| `setPoolFor(projectId, poolKey, twapWindow, terminalToken)` | Project owner or permissioned delegate | `SET_BUYBACK_POOL` (26) | Per-project, per-terminal-token. **One-time only** -- reverts with `JBBuybackHook_PoolAlreadySet` if already set. | Configures the Uniswap V4 pool for a project/terminal-token pair. Validates that the pool is initialized, currencies match the project token and terminal token, and the TWAP window is within bounds (5 min -- 2 days). Stores the pool key, TWAP window, and project token address. |
| `setTwapWindowOf(projectId, newWindow)` | Project owner or permissioned delegate | `SET_BUYBACK_TWAP` (25) | Per-project. Can be called multiple times. | Changes the TWAP window used for oracle-based slippage calculation. Must be between `MIN_TWAP_WINDOW` (5 minutes) and `MAX_TWAP_WINDOW` (2 days). |

### JBBuybackHookRegistry

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|--------------|
| `allowHook(hook)` | Registry owner | N/A (`onlyOwner`) | Global | Adds a buyback hook implementation to the allowlist. Projects can only use hooks that are on the allowlist. |
| `disallowHook(hook)` | Registry owner | N/A (`onlyOwner`) | Global | Removes a buyback hook implementation from the allowlist. If the disallowed hook is the current default, clears the default to `address(0)`. Does **not** affect projects that have already set or locked this hook. |
| `setDefaultHook(hook)` | Registry owner | N/A (`onlyOwner`) | Global | Sets the default buyback hook used by projects that have not explicitly chosen one. Also adds the hook to the allowlist. Reverts if `hook` is `address(0)`. |
| `setHookFor(projectId, hook)` | Project owner or permissioned delegate | `SET_BUYBACK_HOOK` (27) | Per-project | Sets which buyback hook implementation a project uses. The hook must be on the allowlist. Reverts if the project's hook is locked. |
| `lockHookFor(projectId, expectedHook)` | Project owner or permissioned delegate | `SET_BUYBACK_HOOK` (27) | Per-project. **Irreversible.** | Permanently locks the hook for a project. If the project is using the default (no explicit hook set), the current default is snapshotted into storage before locking. Requires a non-zero resolved hook. The `expectedHook` parameter prevents race conditions where the hook changes between transaction submission and execution. |
| `transferOwnership(newOwner)` | Registry owner | N/A (`onlyOwner`) | Global | Transfers registry ownership to a new address. Inherited from OpenZeppelin `Ownable`. |
| `renounceOwnership()` | Registry owner | N/A (`onlyOwner`) | Global | Permanently renounces registry ownership, setting the owner to `address(0)`. Inherited from OpenZeppelin `Ownable`. After renouncing, no new hooks can be allowed/disallowed, and the default hook cannot be changed. |

## Registry Ownership

The `JBBuybackHookRegistry` owner has three powers:

1. **Allowlisting hooks** (`allowHook`) -- Gate which hook implementations projects can use. Only allowlisted hooks can be set via `setHookFor`.
2. **Disallowing hooks** (`disallowHook`) -- Remove hooks from the allowlist. Clears the default if the disallowed hook was the default. Projects that already set or locked the hook are unaffected.
3. **Setting the default hook** (`setDefaultHook`) -- Choose the hook that projects use when they have not explicitly set one. Also allowlists the hook.

The owner cannot force a hook onto a project that has already set or locked its own hook. The owner cannot unlock a locked hook.

Ownership is transferable via `transferOwnership()` and can be permanently renounced via `renounceOwnership()`, both inherited from OpenZeppelin's `Ownable`.

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
- **No one can call `unlockCallback` except the PoolManager.** The V4 swap callback is gated to `msg.sender == POOL_MANAGER`.
