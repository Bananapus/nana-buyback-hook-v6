# Juicebox Buyback Hook

A Juicebox data hook, pay hook, and cash-out hook that automatically routes both buy-side payments and sell-side cash outs through the better of the protocol path or a Uniswap V4 pool. On the buy side it compares direct minting against buying from the pool. On the sell side it compares protocol cash out value against selling reminted tokens into the pool. The project's reserved rate applies uniformly on the buy side.

_If you're having trouble understanding this contract, take a look at the [core protocol contracts](https://github.com/Bananapus/nana-core-v6) and the [documentation](https://docs.juicebox.money/) first. If you have questions, reach out on [Discord](https://discord.com/invite/ErQYmth4dS)._

## Architecture

| Contract | Description |
|----------|-------------|
| `JBBuybackHook` | Core hook. Implements `IJBRulesetDataHook` (checked before recording payment/cash out), `IJBPayHook`, `IJBCashOutHook`, and `IUnlockCallback` (Uniswap V4 swap settlement). Compares protocol mint/cash-out value against Uniswap V4 pool execution and takes the better route. Buy-side swapped tokens are burned, then re-minted through the controller to apply the reserved rate uniformly. Sell-side cash outs can burn, remint to the hook, and sell into the pool when that route is better. Stores an immutable `ORACLE_HOOK` -- all pools created via `setPoolFor` or `initializePoolFor` use this oracle hook in their `PoolKey` for TWAP price protection. |
| `JBBuybackHookRegistry` | A proxy data hook that delegates `beforePayRecordedWith` to a per-project or default `JBBuybackHook` instance. The registry owner manages an allowlist of hook implementations. Project owners choose (and can permanently lock) which buyback hook their project uses. |
| `JBSwapLib` | Shared library for oracle queries, slippage tolerance, price impact estimation, and `sqrtPriceLimitX96` calculations. Uses a continuous sigmoid formula for smooth dynamic slippage across all swap sizes. |

## How It Works

```mermaid
sequenceDiagram
    participant Terminal
    participant Buyback hook
    participant V4 PoolManager
    participant Controller
    Note right of Terminal: User calls pay(...) to pay the project
    Terminal->>Buyback hook: Calls beforePayRecordedWith(...) with payment data
    Buyback hook->>Terminal: If swap is better: weight=0, active pay hook specification
    Buyback hook->>Terminal: If mint is better: weight=normal, noop pay hook specification with diagnostics
    Terminal->>Buyback hook: Calls afterPayRecordedWith(...) with specification
    Buyback hook->>V4 PoolManager: unlock() -> unlockCallback() executes swap
    Buyback hook->>Controller: Burns swapped tokens, re-mints with reserved rate
```

1. A payment is made to a project's terminal.
2. The terminal calls `beforePayRecordedWith(context)` on the data hook (this contract).
3. The hook calculates how many tokens the payer would get by minting directly (`weight * amount / weightRatio`).
4. It compares that against a Uniswap V4 quote. The TWAP-based quote uses the pool's oracle hook (if available) or forces the mint path when unavailable, then applies sigmoid-based slippage tolerance. The payer/frontend can also supply their own quote in metadata -- the hook uses whichever is higher (more protective).
5. If the swap yields more tokens, the hook returns `weight = 0` and specifies itself as a pay hook with the swap amount.
6. If minting yields more tokens and a pool is configured, the hook returns the original `weight` plus a noop pay hook specification carrying routing diagnostics. The terminal skips `afterPayRecordedWith` for noop specs.
7. When swap is selected, the terminal calls `afterPayRecordedWith(context)` on the pay hook.
8. The hook executes the swap via `POOL_MANAGER.unlock()`, burns the received project tokens, adds any leftover terminal tokens back to the project's balance, and mints the total (swapped + leftover mint) through the controller with `useReservedPercent: true`.

If the swap fails (slippage, insufficient liquidity, etc.), `_swap` catches the revert and returns `(0, swapFailed = true)`. `afterPayRecordedWith` then skips the slippage check, returns the unspent payment amount to the terminal balance, and mints via the normal fallback path.

Cash outs follow the same best-execution philosophy. `beforeCashOutRecordedWith` compares protocol cash-out value against a pool sell quote. If the pool route is better, it returns a cash-out hook spec so `afterCashOutRecordedWith` remints the burned project tokens to the hook, sells them into the pool, and forwards the proceeds to the beneficiary.

## Registry

The `JBBuybackHookRegistry` sits between the terminal and individual hook implementations:

- **Owner-managed allowlist**: The registry owner calls `allowHook(hook)` / `disallowHook(hook)` to control which implementations projects can use.
- **Default hook**: The owner calls `setDefaultHook(hook)` to set the fallback for projects that have not explicitly chosen one. Setting a default also adds it to the allowlist.
- **Per-project override**: Project owners call `setHookFor(projectId, hook)` to select an allowed hook. Permission: `SET_BUYBACK_HOOK` (ID 27).
- **Locking**: Project owners call `lockHookFor(projectId)` to permanently freeze their hook choice. Once locked, the hook cannot be changed. Same permission: `SET_BUYBACK_HOOK` (ID 27). Locking requires a non-zero hook (either explicitly set or inherited from default). If the project is using the default, locking snapshots that default into the project's storage.
- **Mint permission delegation**: `hasMintPermissionFor` returns `true` only for the address of the hook active for the project, enabling the hook to mint tokens through the controller.

`disallowHook` reverts if the hook being disallowed is the current default. The owner must call `setDefaultHook` to change the default before disallowing the old hook.

## Install

For projects using `npm` to manage dependencies (recommended):

```bash
npm install @bananapus/buyback-hook-v6
```

For projects using `forge` to manage dependencies:

```bash
forge install Bananapus/nana-buyback-hook-v6
```

If you're using `forge`, add `@bananapus/buyback-hook-v6/=lib/nana-buyback-hook-v6/` to `remappings.txt`.

This package depends on `@bananapus/univ4-router-v6` (for the oracle hook deployment used in the deployment script).

## Develop

`nana-buyback-hook-v6` uses [npm](https://www.npmjs.com/) (version >=20.0.0) for package management and [Foundry](https://github.com/foundry-rs/foundry) for builds and tests.

```bash
npm ci && forge install
```

| Command | Description |
|---------|-------------|
| `forge build` | Compile the contracts and write artifacts to `out`. |
| `forge test` | Run the tests. |
| `forge fmt` | Lint. |
| `forge build --sizes` | Get contract sizes. |
| `forge coverage` | Generate a test coverage report. |
| `forge clean` | Remove the build artifacts and cache directories. |

### Scripts

| Command | Description |
|---------|-------------|
| `npm test` | Run local tests. |
| `npm run test:fork` | Run fork tests (for use in CI). |
| `npm run coverage` | Generate an LCOV test coverage report. |

### Configuration

Key `foundry.toml` settings:

- `solc = '0.8.26'`
- `evm_version = 'cancun'` (required for Uniswap V4's transient storage `TSTORE`/`TLOAD`)
- `optimizer_runs = 200`
- `fuzz.runs = 4096`

## Repository Layout

```
nana-buyback-hook-v6/
├── src/
│   ├── JBBuybackHook.sol             # Core buyback hook (data hook + pay hook + V4 unlock callback)
│   ├── JBBuybackHookRegistry.sol     # Per-project hook routing with allowlist and locking
│   ├── libraries/
│   │   └── JBSwapLib.sol             # Oracle queries, slippage tolerance, price limit calculations
│   └── interfaces/
│       ├── IJBBuybackHook.sol        # Buyback hook interface
│       ├── IJBBuybackHookRegistry.sol # Registry interface
│       └── IGeomeanOracle.sol        # V4 oracle hook interface (TWAP observation)
├── script/
│   └── Deploy.s.sol                  # Multi-chain deployment script (Ethereum, Optimism, Base, Arbitrum)
└── test/
    ├── V4BuybackHook.t.sol           # Core hook unit tests
    ├── Registry.t.sol                # Registry unit tests
    ├── JBSwapLib.t.sol               # Library unit tests
    ├── MEVScenarios.t.sol            # MEV attack scenario tests
    ├── fork/
    │   └── V4ForkTest.t.sol          # Mainnet fork integration tests
    └── mock/
        ├── MockOracleHook.sol        # Configurable TWAP oracle mock
        ├── MockPoolManager.sol       # V4 PoolManager mock
        └── MockSplitHook.sol         # Split hook mock
```

## Project Owner Usage Guide

### Setting The Pool

There are two ways to configure the pool:

1. **Simplified**: Call `setPoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken)`. The hook constructs the `PoolKey` automatically using the project token, terminal token, and its immutable `ORACLE_HOOK` as the pool's hooks address. The pool must already be initialized in the V4 PoolManager.
2. **Explicit**: Call `setPoolFor(projectId, poolKey, twapWindow, terminalToken)` with a full `PoolKey` struct.
3. **Atomic initialize + set**: Call `initializePoolFor(projectId, fee, tickSpacing, twapWindow, terminalToken, sqrtPriceX96)` to initialize the pool in the PoolManager (if not already initialized) and configure it in one transaction. Uses `ORACLE_HOOK` in the constructed `PoolKey`.

Pool assignments can only be set once per terminal token -- they are immutable once set to prevent swap routing manipulation.

- The `PoolKey` currencies must match the project token and the terminal token (in either order). The hook validates this on-chain.
- All pools created via the simplified or atomic overloads use the hook's immutable `ORACLE_HOOK` for TWAP price protection.
- If using ETH, pass `JBConstants.NATIVE_TOKEN` (`0x000000000000000000000000000000000000EEEe`) as `terminalToken`. The hook normalizes this to `address(0)` internally, matching Uniswap V4's native ETH representation.
- The project must have already issued an ERC-20 token (via `JBTokens`).
- Permission: `SET_BUYBACK_POOL` (ID 26).

### Setting TWAP Parameters

The TWAP window controls the time period over which the time-weighted average price is computed. A shorter window gives more accurate data but is easier to manipulate; a longer window is more stable but can lag during high volatility.

- Call `setTwapWindowOf(projectId, terminalToken, newWindow)` to change the TWAP window for a specific terminal token (min: 5 minutes, max: 2 days).
- A 30-minute window is a good starting point for high-activity pairs.
- Permission: `SET_BUYBACK_TWAP` (ID 25).
- Each terminal token has its own TWAP window, allowing different parameters for e.g. ETH vs USDC pools.

### Oracle Behavior

The hook stores an immutable `ORACLE_HOOK` (an `IHooks` address set at construction). All pools created via the simplified `setPoolFor` or `initializePoolFor` overloads embed this oracle hook in their `PoolKey`. The hook queries the oracle via the `IGeomeanOracle.observe` interface for TWAP data. If the oracle hook reverts or is not available, the hook returns 0 for the quote, forcing the mint path. Spot-price fallback was removed because it is trivially sandwich-attackable. Swaps activate once the oracle warms up (~30 min after pool creation).

When the oracle returns zero liquidity, the hook returns 0 for the quote, which causes it to fall back to minting rather than swapping -- protecting against swaps in pools with no liquidity.

### Composition with JBUniswapV4Hook

In production, `ORACLE_HOOK` is typically `JBUniswapV4Hook` -- the same contract that serves as the V4 pool hook. This means the buyback hook queries the oracle and executes swaps on the same pool managed by the same hook. When the buyback hook swaps, `JBUniswapV4Hook._beforeSwap()` fires and its routing logic may try to re-enter the buyback hook via `terminal.pay()`. A `_routing` reentrancy guard in `JBUniswapV4Hook` detects this recursion and reverts the inner swap. The buyback hook's try/catch catches the revert and falls back to minting. The hookData passed to V4 swaps is `abi.encode(uint256(0))`, which delegates slippage protection to the hook's own TWAP oracle.

### Slippage Tolerance

The buyback hook uses a continuous sigmoid formula (`JBSwapLib.getSlippageTolerance`) to dynamically calculate slippage tolerance based on the estimated price impact of the swap:

- Small swaps in deep pools get ~2% tolerance (minimum floor).
- Large swaps relative to pool liquidity approach the 88% ceiling.
- The minimum tolerance is the pool fee + 1% buffer (with an absolute floor of 2%).
- If the calculated slippage tolerance hits the 88% maximum, the hook returns 0 (triggers mint fallback) rather than attempting a swap with extreme slippage.

### Avoiding MEV

The hook provides two layers of MEV protection:

1. **sqrtPriceLimitX96**: The V4 swap is executed with a price limit computed from the minimum acceptable output (`JBSwapLib.sqrtPriceLimitFromAmounts`). This stops the swap early if the price moves unfavorably, rather than executing at a bad rate.
2. **Quote floor**: The hook always takes the higher of the payer's quote and the TWAP-based quote. A stale or manipulated payer quote cannot produce a worse deal than what the oracle suggests.

Payers/frontends should provide a reasonable minimum quote in metadata for additional protection. You can also use the [Flashbots Protect RPC](https://protect.flashbots.net/) for transactions that trigger the buyback hook.

## Payment Metadata

The hook reads metadata with key `"quote"` (resolved via `JBMetadataResolver`), encoding `(uint256 amountToSwapWith, uint256 minimumSwapAmountOut)`:

- If `amountToSwapWith == 0`, the full payment amount is used for the swap.
- If `amountToSwapWith > 0`, only that portion is swapped and the remainder is minted directly.
- If `amountToSwapWith > totalPaid`, the transaction reverts with `JBBuybackHook_InsufficientPayAmount`.
- The `minimumSwapAmountOut` is compared against the TWAP-derived minimum -- the higher value is used.

### Hook Specification Metadata

When a pool is configured, the `JBPayHookSpecification.metadata` returned by `beforePayRecordedWith` always encodes 10 fields. If swap wins, the spec is active (`noop = false`, `amount = amountToSwapWith`). If mint wins, the spec is informational (`noop = true`, `amount = 0`).

| # | Field | Type | Purpose |
|---|-------|------|---------|
| 1 | `projectTokenIs0` | `bool` | Token sort order in the V4 pool (`true` if project token is `currency0`) |
| 2 | `mintFromExcess` | `uint256` | Leftover amount to mint with (`totalPaid - amountToSwapWith`), or `0` if the full payment is swapped |
| 3 | `minimumSwapAmountOut` | `uint256` | Slippage floor -- the minimum acceptable swap output |
| 4 | `controller` | `IJBController` | Cached controller reference for burn/mint calls |
| 5 | `tokenCountWithoutHook` | `uint256` | Tokens that would have been minted without the buyback hook (informational) |
| 6 | `twapTick` | `int24` | TWAP oracle tick used for the price quote (informational) |
| 7 | `twapLiquidity` | `uint128` | Harmonic mean liquidity from the TWAP oracle (informational) |
| 8 | `poolId` | `PoolId` | V4 pool identifier used for the swap (informational) |
| 9 | `minimumBeneficiaryTokenCount` | `uint256` | Minimum beneficiary portion of `minimumSwapAmountOut` after the reserved rate |
| 10 | `minimumReservedTokenCount` | `uint256` | Minimum reserved portion of `minimumSwapAmountOut` after the reserved rate |

`afterPayRecordedWith` only decodes fields 1-4 to execute the swap. Fields 5-10 are informational -- they allow preview/simulation clients to inspect the routing decision context without replaying the computation. On mint-path noop specs, all 10 fields are still present even though no pay-hook callback will be executed.

### Interpreting the Informational Fields

**`twapTick` (int24) — TWAP Price**

The tick encodes the time-weighted average price using Uniswap V4's logarithmic scale:

```
price = 1.0001 ^ tick
```

- `tick = 0` → price = 1.0 (tokens trade 1:1)
- `tick > 0` → `currency1` is more expensive than `currency0`
- `tick < 0` → `currency0` is more expensive than `currency1`

The price is always expressed as `currency1 / currency0`. To get the human-readable price of the project token in terms of the payment token, check `projectTokenIs0`:

- If `projectTokenIs0 == true`: project token is `currency0`, so `price = 1.0001^tick` gives payment tokens per project token.
- If `projectTokenIs0 == false`: project token is `currency1`, so `1 / (1.0001^tick)` gives payment tokens per project token.

In JavaScript/TypeScript:
```js
const price = 1.0001 ** tick;
const projectTokenPrice = projectTokenIs0 ? price : 1 / price;
```

On-chain, use `TickMath.getSqrtPriceAtTick(twapTick)` to get the `sqrtPriceX96` (a Q64.96 fixed-point square root of the price), then square it:
```solidity
uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);
// price = (sqrtPriceX96 / 2^96)^2 = sqrtPriceX96^2 / 2^192
```

**`twapLiquidity` (uint128) — Pool Liquidity**

The harmonic mean of in-range liquidity over the TWAP window. This is Uniswap V4's `L` value — the amount of virtual liquidity concentrated around the current tick.

- Higher values → deeper liquidity → lower price impact for swaps, more reliable TWAP.
- Lower values → thinner liquidity → higher price impact, TWAP more susceptible to manipulation.
- `0` → no liquidity data available (the hook falls back to minting).

To estimate price impact from liquidity, use the formula: `impact ≈ amountIn / (liquidity * sqrtPrice)` for `zeroForOne` swaps (see `JBSwapLib.calculateImpact`).

Liquidity is denominated in the pool's native units (sqrt(token0 * token1)) and is not human-readable on its own. Compare it against other pools or historical values to gauge depth.

**`poolId` (PoolId / bytes32) — Pool Identifier**

The V4 pool identifier is `keccak256(abi.encode(poolKey))` where `poolKey = (currency0, currency1, fee, tickSpacing, hooks)`. Use it to:

- Look up the pool on-chain: `IPoolManager.getSlot0(poolId)` for current price/tick, `IPoolManager.getLiquidity(poolId)` for current liquidity.
- Match against a known pool: compare with `PoolIdLibrary.toId(poolKey)`.
- Display in UIs: show as a hex string (e.g. `0xabc...def`) or link to a V4 pool explorer.

To recover the full `PoolKey` from a `poolId`, use `JBBuybackHook.poolKeyOf(projectId, terminalToken)` — the pool ID alone is a one-way hash.

## Supported Chains

The deployment script (`Deploy.s.sol`) supports:

| Chain | PoolManager |
|-------|-------------|
| Ethereum Mainnet | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Optimism | `0x9a13f98cb987694c9f086b1f5eb990eea8264ec3` |
| Base | `0x498581ff718922c3f8e6a244956af099b2652b2b` |
| Arbitrum | `0x360e68faccca8ca495c1b759fd9eee466db9fb32` |

Sepolia testnets for all four chains are also supported.

## Risks

- The hook depends on liquidity in a Uniswap V4 pool. If liquidity migrates to a new pool with different `PoolKey` parameters (different fee, tickSpacing, or hooks), the hook cannot be redirected -- pool assignments are immutable once set via `setPoolFor`.
- `setPoolFor` can only be called once per project + terminal token pair. If you need to use a different pool, a new hook deployment is needed.
- If the TWAP window isn't set appropriately, payers may receive fewer tokens than expected.
- Low liquidity pools are vulnerable to TWAP manipulation by attackers.
- If the pool's oracle hook is absent or reverts, the hook forces the mint path (no swaps until the oracle warms up, ~30 min after pool creation).
- The `ORACLE_HOOK` immutable is set at construction and cannot be changed. If the oracle hook implementation has a bug or is deprecated, a new `JBBuybackHook` deployment is required.
- The registry's `lockHookFor` is irreversible. Once locked, the project cannot change its hook implementation even if a security issue is found in that implementation.
