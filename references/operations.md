# Buyback Hook Operations

## Configuration surface

- [`src/JBBuybackHookRegistry.sol`](../src/JBBuybackHookRegistry.sol) is the first stop for project-specific hook assignment, default-hook behavior, allowlisting, and locking.
- [`src/JBBuybackHook.sol`](../src/JBBuybackHook.sol) owns per-project pool setup and TWAP-window changes.
- [`script/Deploy.s.sol`](../script/Deploy.s.sol) is the deployment entry point when you need the current wiring, not just contract behavior.

## Change checklist

- If you edit route comparison logic, re-check both payment and cash-out paths.
- If you edit pool or TWAP configuration, verify the permissions and lock behavior still match the intended governance model.
- If you change route activation, verify current PoolManager liquidity and TWAP liquidity are both handled intentionally.
- If you change swap math or quotes, inspect [`src/libraries/JBSwapLib.sol`](../src/libraries/JBSwapLib.sol) and the dedicated tests before assuming behavior is unchanged.
- If you touch sell-side behavior, verify `hookMetadata`-encoded sell counts, not just the terminal's original `cashOutCount`.
- If you touch fallback behavior, verify that liveness branches still degrade safely instead of hiding a new execution-quality regression.
- If you touch external integration assumptions, confirm whether the behavior actually lives in this repo or in the connected Uniswap hook/oracle surface.

## Common failure modes

- Hook is correct but the wrong pool, hook, or TWAP window is configured for the project.
- Pool is initialized and has historical TWAP observations, but current in-range liquidity is zero or dust.
- A liveness-preserving fallback accidentally hides an execution-quality regression.
- Route-selection edits break parity between the view/quote path and the mutative execution path.
- Registry changes appear safe but reopen governance risk because lock or allowlist behavior drifted.

## Useful proof points

- [`test/Registry.t.sol`](../test/Registry.t.sol) for registry and lock behavior.
- [`test/CrossCurrency_Unit.t.sol`](../test/CrossCurrency_Unit.t.sol) for denomination-sensitive behavior.
- [`test/JBSwapLib.t.sol`](../test/JBSwapLib.t.sol) for library math assumptions.
- [`test/invariant/BuybackHookInvariant.t.sol`](../test/invariant/BuybackHookInvariant.t.sol) for route-level invariants.
- [`test/regression/CurrentLiquidityRouteSelection.t.sol`](../test/regression/CurrentLiquidityRouteSelection.t.sol) for live-liquidity route activation.
- [`test/regression/CashOutMetadataInflation.t.sol`](../test/regression/CashOutMetadataInflation.t.sol) and [`test/regression/RegistryForwardedPermission.t.sol`](../test/regression/RegistryForwardedPermission.t.sol) for the easiest governance and sell-side mistakes to reintroduce.
- [`test/TestRegressionGaps.sol`](../test/TestRegressionGaps.sol) for pinned edge cases worth preserving.
