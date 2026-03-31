# User Journeys

## Who This Repo Serves

- projects that want market-aware routing on buys and sells
- operators selecting and locking a project's buyback hook and pool configuration
- traders or supporters whose route may go through Juicebox or UniV4 depending on price
- integrators consuming geomean-oracle-aware routing decisions

## Journey 1: Attach Buyback Routing To A Project

**Starting state:** the project has a Juicebox treasury and a relevant UniV4 pool, and wants dynamic routing between them.

**Success:** the project has a registered buyback hook and pool configuration that its terminals and frontends can rely on.

**Flow**
1. Deploy `JBBuybackHook` and choose the Juicebox project token plus market pool it should compare against.
2. Register the project's hook and pool choice in `JBBuybackHookRegistry`.
3. Optionally lock the configuration to prevent later substitution or pool drift.
4. From that point on, project-facing payment and cash-out surfaces can ask this repo which path is better.

## Journey 2: Pay Into A Project Through The Better Of Juicebox Or The Pool

**Starting state:** a user wants to buy into the project and either a protocol mint or a market swap could be the better execution.

**Success:** the user gets the better result and the project still respects its configured hooks and accounting model.

**Flow**
1. The buyback hook compares the Juicebox mint path with the UniV4 swap path.
2. It uses the project configuration, pool state, and oracle assumptions to decide which route should execute.
3. If the terminal path is better, it preserves ordinary Juicebox issuance behavior.
4. If the market path is better, it routes through the pool and returns the market-backed result.

**Failure cases that matter:** oracle failure, fee-on-transfer tokens, minimum-output mismatches, partial fills, and misconfigured default hooks that leave the project believing a path is protected when it is not.

## Journey 3: Cash Out Through The Better Exit Path

**Starting state:** a holder wants out and either the protocol cash-out curve or the market pool might offer the better exit.

**Success:** the holder exits through the higher-value route without bypassing the project's configured protections.

**Flow**
1. The hook compares reclaim value from the Juicebox terminal against the pool-side sell route.
2. It executes whichever path is better under current conditions.
3. Registry state and expected-hook checks make sure the project is using the intended routing surface.

**Edge conditions that change user experience:** leftover balances after a swap, sandwich-sensitive pool movement, slippage windows, and sell-side hook validation that differs from pay-side assumptions.

## Journey 4: Operate Oracle And Pool Assumptions Safely

**Starting state:** the project is live and routing quality now depends on pool health and oracle behavior.

**Success:** operators understand that this repo owns comparison logic, not just a one-time deployment.

**Flow**
1. Monitor whether the referenced pool still reflects a sane market for the project token.
2. Treat geomean or other oracle failures as materially important because they can collapse the route-comparison premise.
3. Revisit registry lock decisions only through the governance surface intended for the project.

## Hand-Offs

- Use [univ4-router-v6](../univ4-router-v6/USER_JOURNEYS.md) for the underlying UniV4 hook and oracle primitive this repo compares against.
- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for the canonical terminal mint and cash-out paths that remain the baseline alternative.
