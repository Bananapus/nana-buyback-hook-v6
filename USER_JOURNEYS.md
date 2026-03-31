# User Journeys

## Who This Repo Serves

- project owners who want protocol trades compared against market liquidity
- traders buying or selling project exposure through the better route
- operators configuring pools, oracle settings, and slippage protections

## Journey 1: Attach Buyback Routing To A Project

**Starting state:** the project already exists, has an accepted terminal token, and a corresponding Uniswap V4 market is available or planned.

**Success:** the project is configured so buy-side and, if enabled, sell-side routing can compare protocol-native execution against the configured pool path.

**Flow**
1. Decide whether the project will use a project-specific hook or the registry's default hook.
2. If needed, call `setHookFor(...)` or `lockHookFor(...)` in `JBBuybackHookRegistry`.
3. Configure the pool with `setPoolFor(...)` or `initializePoolFor(...)`, plus the intended TWAP window.
4. Wire the resolved hook into the project's ruleset metadata for buy-side and, if intended, sell-side behavior.

## Journey 2: Pay Into A Project Through The Better Of Juicebox Or The Pool

**Starting state:** a payer wants project exposure and the project is configured with the buyback hook.

**Success:** the payer receives the better output without manually deciding whether to mint or swap.

**Flow**
1. The payer submits a normal terminal payment with the hook metadata the front end prepared.
2. The hook compares protocol-native issuance against the TWAP-protected market route.
3. If minting through Juicebox is better, the hook lets the normal protocol path win.
4. If the pool is better, the hook executes the swap path and settles the output to the payer.

## Journey 3: Cash Out Through The Better Exit Path

**Starting state:** a holder wants to exit and the project has sell-side routing configured.

**Success:** the holder receives whichever of protocol cash out or market swap produces the better output within the configured protections.

**Flow**
1. The holder initiates a normal terminal cash out.
2. The hook previews protocol cash out and compares it to the protected pool route.
3. The better route executes.
4. Slippage checks and oracle behavior prevent the hook from trusting a manipulated spot price.

**Operational note:** this repo owns project-level routing decisions. The underlying pool-hook mechanics live in [univ4-router-v6](../univ4-router-v6/USER_JOURNEYS.md).
