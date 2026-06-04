# User Journeys

## Repo purpose

This repo decides whether a project-facing buy or sell should execute through Juicebox-native economics or a UniV4 market path. It owns route comparison and registry-level pool selection. It does not own the lower-level UniV4 hook it depends on for market execution and oracle observations.

## Primary actors

- projects that want market-aware routing on buys and sells
- operators selecting and locking a project's hook and pool configuration
- traders or supporters whose route may go through Juicebox or UniV4 depending on price
- auditors reviewing comparison logic, minima, and pool-selection governance

## Key surfaces

- `JBBuybackHook`: compares protocol and market routes and executes the better one
- `JBBuybackHookRegistry`: stores and optionally locks which hook and pool a project uses
- `setHookFor(...)` / `setPoolFor(...)`: main project-configuration entrypoints
- `JBSwapLib`: shared swap and oracle helper logic

## Journey 1: Attach buyback routing to a project

**Actor:** project operator.

**Intent:** configure a project so routing can compare protocol and market execution.

**Preconditions**
- the project already has a Juicebox treasury and a relevant market pool
- the operator knows which hook and pool the project should trust
- the surrounding governance surface is ready to lock the choice if needed

**Main Flow**
1. Deploy `JBBuybackHook` with the expected project-token and pool assumptions.
2. Register the project's hook and pool in `JBBuybackHookRegistry` with the appropriate setter surfaces.
3. Lock the choice once operational confidence is high.
4. Frontends and downstream flows can now treat that routing surface as canonical.

**Failure Modes**
- the wrong pool or hook is registered
- teams leave governance mutable longer than intended
- reviewers inspect `JBBuybackHook` but ignore registry lock state

**Postconditions**
- the project's buyback routing surface is registered and can be treated as the canonical comparison path

## Journey 2: Pay through the better of Juicebox or the pool

**Actor:** payer or router or integration acting for a payer.

**Intent:** buy project exposure through whichever path yields the better result.

**Preconditions**
- the project's hook and pool configuration are already registered
- the oracle and pool state are usable enough for route comparison
- caller minima and metadata are shaped for the path being attempted

**Main Flow**
1. Compare the Juicebox mint path with the UniV4 swap path.
2. Decide the route using project config, pool state, and oracle assumptions.
3. If the protocol path is better, preserve ordinary Juicebox issuance behavior.
4. If the market path is better, execute through the pool and return the market-backed result.

**Failure Modes**
- oracle failure or immature oracle history
- fee-on-transfer behavior breaks route assumptions
- explicit caller minima fail or partial fills behave unexpectedly
- default-hook expectations are misconfigured around the chosen path

**Postconditions**
- the payment uses whichever route is better under the hook's configured comparison model

## Journey 3: Cash out through the better exit path

**Actor:** holder exiting a position.

**Intent:** cash out through the higher-value route without bypassing project protections.

**Preconditions**
- the project's buyback route is configured and live
- the holder understands the best exit may be protocol or market depending on conditions

**Main Flow**
1. Compare terminal reclaim value against the pool-side sell route.
2. Execute whichever route is better under current conditions.
3. Use registry and expected-hook checks to ensure the intended routing surface is active.

**Opt-out variant:** a holder who wants deterministic terminal settlement can set `skip=true` in the `cashOut` metadata entry (`(uint256 minimumSwapAmountOut, bool skip)`). The hook then skips the pool comparison entirely and settles through the bonding-curve/terminal path even if the pool would pay more. Any `minimumSwapAmountOut` floor is still enforced against the direct reclaim, so it reverts rather than under-delivering.

**Failure Modes**
- leftover balances or partial swap settlement
- sandwich-sensitive movement between preview and execution
- sell-side validation differs from pay-side assumptions in ways the caller did not expect

**Postconditions**
- the holder exits through the higher-value permitted path under current market and protocol conditions

## Journey 4: Operate oracle and pool assumptions safely

**Actor:** operator or auditor.

**Intent:** keep route-comparison assumptions valid after deployment.

**Preconditions**
- the project is already live and routing quality now depends on pool and oracle health

**Main Flow**
1. Monitor whether the referenced pool still reflects a sane market.
2. Treat oracle degradation as a routing-risk event, not just an analytics issue.
3. Revisit registry lock decisions only through the intended governance path.

**Failure Modes**
- the market stays live but no longer represents healthy execution
- teams trust the presence of a pool more than the quality of its observations

**Postconditions**
- operators know whether the project's routing assumptions still justify leaving the configured pool live

## Trust boundaries

- this repo trusts the UniV4 hook and oracle surface for market-side estimation
- this repo trusts core terminals for protocol-side mint and cash-out truth
- registry governance is part of the economic safety model, not just metadata

## Hand-offs

- Use [univ4-router-v6](../univ4-router-v6/USER_JOURNEYS.md) for the underlying UniV4 hook and oracle primitive this repo compares against.
- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for the canonical terminal mint and cash-out paths that remain the baseline alternative.
