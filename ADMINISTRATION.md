# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Global hook allowlisting plus project-local buyback hook, pool, and TWAP configuration |
| Control posture | Mixed registry-owner and project-local delegated control |
| Highest-risk actions | Setting the default hook, locking a project hook, and binding a project to the wrong pool |
| Recovery posture | Unlocked projects can move; locked projects and one-time pool setup sharply limit in-place recovery |

## Purpose

`nana-buyback-hook-v6` splits administration between a global registry and project-local pool configuration. The registry owner controls which hook implementations are available and which one is the default. Project owners or delegates control which hook they use, whether they lock it, and how their pool and TWAP settings are configured.

## Control Model

- `JBBuybackHookRegistry` is globally `Ownable`.
- Projects opt into an allowlisted hook through the registry.
- Project-local operators use `JBPermissions` for `SET_BUYBACK_HOOK`, `SET_BUYBACK_POOL`, and `SET_BUYBACK_TWAP`.
- The hook contract itself is mostly immutable runtime logic; the main mutable surface is per-project pool and TWAP setup.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Registry owner | `Ownable(owner)` | Global | Controls allowlist and default hook |
| Project owner | `JBProjects.ownerOf(projectId)` | Per project | May delegate through `JBPermissions` |
| Hook delegate | `JBPermissions` grant | Per project | Usually `SET_BUYBACK_HOOK`, `SET_BUYBACK_POOL`, or `SET_BUYBACK_TWAP` |

## Privileged Surfaces

| Contract | Function | Who Can Call | Effect |
| --- | --- | --- | --- |
| `JBBuybackHookRegistry` | `allowHook(...)`, `disallowHook(...)`, `setDefaultHook(...)` | Registry owner | Controls global hook availability and fallback hook |
| `JBBuybackHookRegistry` | `setHookFor(...)` | Project owner or `SET_BUYBACK_HOOK` delegate | Sets a project's explicit hook |
| `JBBuybackHookRegistry` | `lockHookFor(...)` | Project owner or `SET_BUYBACK_HOOK` delegate | Irreversibly locks a project's hook selection |
| `JBBuybackHook` | `setPoolFor(...)`, `initializePoolFor(...)` | Project owner or `SET_BUYBACK_POOL` delegate | One-time pool setup per project and terminal token |
| `JBBuybackHook` | `setTwapWindowOf(...)` | Project owner or `SET_BUYBACK_TWAP` delegate | Adjusts TWAP window after pool setup |

## Immutable And One-Way

- `lockHookFor(...)` is irreversible.
- Pool setup for a project and terminal token is a one-time commitment.
- Registry disallowing a hook does not evict projects already using or locking it.
- Constructor dependencies such as directory, projects, tokens, prices, pool manager, and oracle hook are immutable.

## Operational Notes

- Keep the registry allowlist narrow.
- Change the default hook carefully because every unconfigured project inherits it.
- Lock project hooks only after validating pool setup and expected runtime behavior.
- Treat TWAP window changes as oracle-quality changes, not cosmetic tuning.
- Remember that failed swaps can degrade into mint fallback behavior; pool configuration is not just a routing preference, it can change whether buyback actually executes.

## Machine Notes

- Do not assume registry ownership implies project override power; locked projects remain locked.
- Treat `src/JBBuybackHookRegistry.sol` and `src/JBBuybackHook.sol` as separate control surfaces with different actors.
- If pool identity, terminal token, or TWAP assumptions differ from deployed state, stop before documenting or executing admin changes.
- If swap execution is reverting or quoting zero, inspect whether the hook is legitimately falling back to mint-only behavior before assuming the buyback path is active.

## Recovery

- Unlocked projects can move to a new allowlisted hook.
- Locked projects cannot be unlocked by the registry.
- Bad pool configuration usually means a new hook path or broader project migration rather than in-place repair.
- A broken swap path may still leave the project operational through mint fallback, but that is not equivalent to a healthy buyback configuration.

## Admin Boundaries

- The registry owner cannot force a new hook onto a locked project.
- Project operators cannot set a hook that is not allowlisted.
- Project operators cannot rewrite a pool key once the pool is set.
- Nobody can hot-edit the runtime route-selection logic of an already deployed hook.

## Source Map

- `src/JBBuybackHook.sol`
- `src/JBBuybackHookRegistry.sol`
- `src/libraries/JBSwapLib.sol`
- `test/`
