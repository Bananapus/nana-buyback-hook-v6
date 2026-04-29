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

- `JBBuybackHookRegistry` is globally `Ownable`
- projects opt into an allowlisted hook through the registry
- project-local operators use `JBPermissions` for `SET_BUYBACK_HOOK`, `SET_BUYBACK_POOL`, and `SET_BUYBACK_TWAP`
- the hook contract itself is mostly immutable runtime logic; the main mutable surface is per-project pool and TWAP setup

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

- `lockHookFor(...)` is irreversible
- pool setup for a project and terminal token is a one-time commitment
- registry disallowing a hook does not evict projects already using or locking it
- constructor dependencies such as directory, projects, tokens, prices, pool manager, and oracle hook are immutable

## Operational Notes

- keep the registry allowlist narrow
- changing the default hook only affects projects created after the change (those with `projectId > defaultHookProjectIdThreshold`); existing projects must explicitly opt in via `setHookFor`
- lock project hooks only after validating pool setup and expected runtime behavior
- treat TWAP window changes as oracle-quality changes, not cosmetic tuning
- remember that failed swaps can degrade into mint fallback behavior

## Machine Notes

- do not assume registry ownership implies project override power; locked projects remain locked
- treat `src/JBBuybackHookRegistry.sol` and `src/JBBuybackHook.sol` as separate control surfaces with different actors
- if pool identity, terminal token, or TWAP assumptions differ from deployed state, stop before documenting or executing admin changes
- if swap execution is reverting or quoting zero, inspect whether the hook is legitimately falling back to mint-only behavior before assuming the buyback path is active

## Recovery

- unlocked projects can move to a new allowlisted hook
- locked projects cannot be unlocked by the registry
- bad pool configuration usually means a new hook path or broader project migration rather than in-place repair
- a broken swap path may still leave the project operational through mint fallback, but that is not the same as a healthy buyback configuration

## Admin Boundaries

- the registry owner cannot force a new hook onto a locked project
- project operators cannot set a hook that is not allowlisted
- project operators cannot rewrite a pool key once the pool is set
- nobody can hot-edit the runtime route-selection logic of an already deployed hook

## Source Map

- `src/JBBuybackHook.sol`
- `src/JBBuybackHookRegistry.sol`
- `src/libraries/JBSwapLib.sol`
- `test/`
