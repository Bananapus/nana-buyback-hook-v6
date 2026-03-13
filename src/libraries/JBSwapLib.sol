// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGeomeanOracle} from "../interfaces/IGeomeanOracle.sol";

/// @notice Shared library for oracle queries, slippage tolerance, and price calculations
/// used by both JBBuybackHook and JBSwapTerminal.
library JBSwapLib {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice The denominator used for slippage tolerance basis points.
    uint256 internal constant SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice The maximum slippage ceiling (88%).
    uint256 internal constant MAX_SLIPPAGE = 8800;

    /// @notice The precision multiplier for impact calculations.
    /// @dev Using 1e18 instead of 1e5 (10 * SLIPPAGE_DENOMINATOR) gives 13 extra orders of magnitude,
    ///      preventing small-swap-in-deep-pool impacts from rounding to zero.
    uint256 internal constant IMPACT_PRECISION = 1e18;

    /// @notice The K parameter for the sigmoid curve, scaled to match IMPACT_PRECISION.
    /// @dev Preserves the same sigmoid shape as the original K=5000 with amplifier=1e5:
    ///      K_new / IMPACT_PRECISION = K_old / (10 * SLIPPAGE_DENOMINATOR)
    ///      → K_new = 5000 * 1e18 / 1e5 = 5e16
    uint256 internal constant SIGMOID_K = 5e16;

    //*********************************************************************//
    // ----------------------- Oracle Query ------------------------------ //
    //*********************************************************************//

    /// @notice Query a V4 oracle hook for TWAP data. Returns 0 if the oracle is unavailable.
    /// @param poolManager The V4 PoolManager.
    /// @param key The pool key (whose `hooks` field points to the oracle hook).
    /// @param twapWindow The TWAP window in seconds.
    /// @param amountIn The amount of base tokens to get a quote for.
    /// @param baseToken The base token address (the token being swapped in).
    /// @param quoteToken The quote token address (the token being swapped out).
    /// @return amountOut The quoted amount of quote tokens for `amountIn` base tokens.
    /// @return arithmeticMeanTick The TWAP tick over the window.
    /// @return harmonicMeanLiquidity The harmonic mean liquidity over the window.
    function getQuoteFromOracle(
        IPoolManager poolManager,
        PoolKey memory key,
        uint32 twapWindow,
        uint128 amountIn,
        address baseToken,
        address quoteToken
    )
        internal
        view
        returns (uint256 amountOut, int24 arithmeticMeanTick, uint128 harmonicMeanLiquidity)
    {
        // If no TWAP window, use spot price from PoolManager state.
        if (twapWindow == 0) {
            PoolId poolId = key.toId();
            // slither-disable-next-line unused-return
            (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
            if (sqrtPriceX96 == 0) return (0, 0, 0);
            arithmeticMeanTick = tick;
            harmonicMeanLiquidity = poolManager.getLiquidity(poolId);
            amountOut = getQuoteAtTick({
                tick: arithmeticMeanTick, baseAmount: amountIn, baseToken: baseToken, quoteToken: quoteToken
            });
            return (amountOut, arithmeticMeanTick, harmonicMeanLiquidity);
        }

        // Try querying the oracle hook.
        try IGeomeanOracle(address(key.hooks)).observe({key: key, secondsAgos: _makeSecondsAgos(twapWindow)}) returns (
            int56[] memory tickCumulatives, uint136[] memory secondsPerLiquidityCumulativeX128s
        ) {
            // Compute arithmetic mean tick from tick cumulatives.
            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            // Safe: twapWindow is a uint32 (max ~4.3B), fits in int32 (max ~2.1B) because realistic TWAP windows
            // are bounded to MAX_TWAP_WINDOW (2 days = 172800). The division result fits in int24 because valid
            // Uniswap tick values are bounded to [-887272, 887272].
            // forge-lint: disable-next-line(unsafe-typecast)
            arithmeticMeanTick = int24(tickCumulativesDelta / int56(int32(twapWindow)));

            // Round towards negative infinity.
            // Safe: same reasoning as above — twapWindow fits in int32 within realistic bounds.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(int32(twapWindow)) != 0)) {
                arithmeticMeanTick--;
            }

            // Compute harmonic mean liquidity from seconds-per-liquidity cumulatives.
            uint136 secondsPerLiquidityDelta =
                secondsPerLiquidityCumulativeX128s[1] - secondsPerLiquidityCumulativeX128s[0];

            if (secondsPerLiquidityDelta > 0) {
                // Safe: the result of (twapWindow << 128) / secondsPerLiquidityDelta fits in uint128 because
                // twapWindow is at most MAX_TWAP_WINDOW (172800) and secondsPerLiquidityDelta > 0 in this branch.
                // forge-lint: disable-next-line(unsafe-typecast)
                harmonicMeanLiquidity = uint128((uint256(twapWindow) << 128) / uint256(secondsPerLiquidityDelta));
            }

            // Get the quote at the mean tick.
            amountOut = getQuoteAtTick({
                tick: arithmeticMeanTick, baseAmount: amountIn, baseToken: baseToken, quoteToken: quoteToken
            });
        } catch {
            // Oracle hook not available — fall back to spot price from the PoolManager.
            // This ensures buybacks still work for callers that don't provide their own quote.
            PoolId poolId = key.toId();
            // slither-disable-next-line unused-return
            (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
            if (sqrtPriceX96 == 0) return (0, 0, 0);
            arithmeticMeanTick = tick;
            harmonicMeanLiquidity = poolManager.getLiquidity(poolId);
            amountOut = getQuoteAtTick({
                tick: arithmeticMeanTick, baseAmount: amountIn, baseToken: baseToken, quoteToken: quoteToken
            });
        }
    }

    //*********************************************************************//
    // -------------------- Slippage Tolerance -------------------------- //
    //*********************************************************************//

    /// @notice Compute a continuous sigmoid slippage tolerance based on swap impact and pool fee.
    /// @dev tolerance = minSlippage + (maxSlippage - minSlippage) * impact / (impact + K)
    ///      When impact is 0 (negligible swap in deep pool), returns minSlippage.
    ///      The caller is responsible for not calling this when there is no pool data at all.
    /// @param impact The estimated price impact from calculateImpact (scaled by IMPACT_PRECISION).
    /// @param poolFeeBps The pool fee in basis points (e.g., 30 for 0.3%).
    /// @return tolerance The slippage tolerance in basis points of SLIPPAGE_DENOMINATOR.
    function getSlippageTolerance(uint256 impact, uint256 poolFeeBps) internal pure returns (uint256) {
        // If pool fee alone meets/exceeds the ceiling, return the ceiling.
        if (poolFeeBps >= MAX_SLIPPAGE) return MAX_SLIPPAGE;

        // Minimum slippage: at least pool fee + 1% buffer, with a floor of 2%.
        uint256 minSlippage = poolFeeBps + 100;
        if (minSlippage < 200) minSlippage = 200;
        if (minSlippage >= MAX_SLIPPAGE) return MAX_SLIPPAGE;

        // When impact is 0 (negligible swap or no data), sigmoid returns minSlippage directly.
        if (impact == 0) return minSlippage;

        // For extreme impact values, cap to prevent overflow in (impact + K).
        if (impact > type(uint256).max - SIGMOID_K) return MAX_SLIPPAGE;

        // Sigmoid: minSlippage + (maxSlippage - minSlippage) * impact / (impact + K)
        uint256 range = MAX_SLIPPAGE - minSlippage;
        uint256 tolerance = minSlippage + FullMath.mulDiv({a: range, b: impact, denominator: impact + SIGMOID_K});

        return tolerance;
    }

    //*********************************************************************//
    // -------------------- Impact Calculation -------------------------- //
    //*********************************************************************//

    /// @notice Estimate the price impact of a swap, scaled by IMPACT_PRECISION.
    /// @dev Uses 1e18 precision to capture sub-basis-point impacts for small swaps in deep pools.
    ///      Returns 0 only when liquidity or sqrtP is 0 (truly no data).
    /// @param amountIn The amount of tokens being swapped in.
    /// @param liquidity The pool's in-range liquidity.
    /// @param sqrtP The sqrt price in Q96 format.
    /// @param zeroForOne Whether the swap is token0 → token1.
    /// @return impact The estimated price impact scaled by IMPACT_PRECISION.
    function calculateImpact(
        uint256 amountIn,
        uint128 liquidity,
        uint160 sqrtP,
        bool zeroForOne
    )
        internal
        pure
        returns (uint256 impact)
    {
        if (liquidity == 0 || sqrtP == 0) return 0;

        // Base ratio: amountIn * IMPACT_PRECISION / liquidity
        // IMPACT_PRECISION (1e18) gives 13 more orders of magnitude than the old 1e5 amplifier,
        // so a 1 ETH swap in a 1M ETH pool returns 1e12 instead of rounding to 0.
        uint256 base = FullMath.mulDiv({a: amountIn, b: IMPACT_PRECISION, denominator: uint256(liquidity)});

        // Normalize by sqrtP for direction.
        impact = zeroForOne
            ? FullMath.mulDiv({a: base, b: uint256(sqrtP), denominator: uint256(1) << 96})
            : FullMath.mulDiv({a: base, b: uint256(1) << 96, denominator: uint256(sqrtP)});
    }

    //*********************************************************************//
    // -------------------- Quote at Tick ------------------------------- //
    //*********************************************************************//

    /// @notice Get the amount of quote tokens for a given amount of base tokens at a specific tick.
    /// @dev Ported from Uniswap V3 OracleLibrary.getQuoteAtTick — pure math, no V3 dependency.
    /// @param tick The tick to get the quote at.
    /// @param baseAmount The amount of base tokens.
    /// @param baseToken The address of the base token.
    /// @param quoteToken The address of the quote token.
    /// @return quoteAmount The amount of quote tokens.
    function getQuoteAtTick(
        int24 tick,
        uint128 baseAmount,
        address baseToken,
        address quoteToken
    )
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself.
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv({a: ratioX192, b: baseAmount, denominator: 1 << 192})
                : FullMath.mulDiv({a: 1 << 192, b: baseAmount, denominator: ratioX192});
        } else {
            uint256 ratioX128 = FullMath.mulDiv({a: sqrtRatioX96, b: sqrtRatioX96, denominator: 1 << 64});
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv({a: ratioX128, b: baseAmount, denominator: 1 << 128})
                : FullMath.mulDiv({a: 1 << 128, b: baseAmount, denominator: ratioX128});
        }
    }

    //*********************************************************************//
    // -------------------- Price Limit -------------------------------- //
    //*********************************************************************//

    /// @notice Compute a sqrtPriceLimitX96 from input/output amounts so the swap stops
    ///         if the execution price would be worse than the minimum acceptable rate.
    /// @dev When `minimumAmountOut == 0`, returns extreme values (no limit, current behaviour).
    /// @param amountIn The amount of tokens being swapped in.
    /// @param minimumAmountOut The minimum acceptable output (from payer quote or TWAP).
    /// @param zeroForOne True when selling token0 for token1 (price decreases).
    /// @return sqrtPriceLimit The V4-compatible sqrtPriceLimitX96.
    function sqrtPriceLimitFromAmounts(
        uint256 amountIn,
        uint256 minimumAmountOut,
        bool zeroForOne
    )
        internal
        pure
        returns (uint160 sqrtPriceLimit)
    {
        // No minimum specified → no limit (legacy behaviour).
        if (minimumAmountOut == 0 || amountIn == 0) {
            return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        // sqrtPriceX96 = sqrt(price) * 2^96
        // price = token1 / token0
        //
        // zeroForOne (selling token0, buying token1):
        //   Minimum acceptable price = minimumAmountOut / amountIn  (token1 per token0)
        //   sqrtPriceLimit = sqrt(minimumAmountOut / amountIn) * 2^96
        //                  = sqrt(minimumAmountOut * 2^192 / amountIn)
        //   Clamp to >= MIN_SQRT_PRICE + 1
        //
        // !zeroForOne (selling token1, buying token0):
        //   Maximum acceptable price = amountIn / minimumAmountOut  (token1 per token0)
        //   sqrtPriceLimit = sqrt(amountIn / minimumAmountOut) * 2^96
        //                  = sqrt(amountIn * 2^192 / minimumAmountOut)
        //   Clamp to <= MAX_SQRT_PRICE - 1

        // Determine the numerator and denominator for the price ratio.
        // FullMath.mulDiv(num, 2^192, den) reverts when the 256-bit result overflows,
        // which happens when num / den >= 2^64.
        uint256 num;
        uint256 den;
        if (zeroForOne) {
            num = minimumAmountOut;
            den = amountIn;
        } else {
            num = amountIn;
            den = minimumAmountOut;
        }

        uint256 sqrtResult;

        if (num / den >= (uint256(1) << 128)) {
            // Ratio too large for any valid sqrtPriceX96 — fall back to no limit.
            return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        } else if (num / den >= (uint256(1) << 64)) {
            // Extended range: use ratioX128 to avoid mulDiv overflow, then shift.
            uint256 ratioX128 = FullMath.mulDiv({a: num, b: uint256(1) << 128, denominator: den});
            sqrtResult = Math.sqrt(ratioX128) * (uint256(1) << 32);
        } else {
            // Normal range: full precision via ratioX192.
            uint256 ratioX192 = FullMath.mulDiv({a: num, b: uint256(1) << 192, denominator: den});
            sqrtResult = Math.sqrt(ratioX192);
        }

        // Clamp to valid V4 range.
        if (zeroForOne) {
            if (sqrtResult <= uint256(TickMath.MIN_SQRT_PRICE)) {
                return TickMath.MIN_SQRT_PRICE + 1;
            }
            if (sqrtResult >= uint256(TickMath.MAX_SQRT_PRICE)) {
                return TickMath.MAX_SQRT_PRICE - 1;
            }
            // Safe: sqrtResult is clamped above to < MAX_SQRT_PRICE (a uint160), so it fits in uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160(sqrtResult);
        } else {
            if (sqrtResult >= uint256(TickMath.MAX_SQRT_PRICE)) {
                return TickMath.MAX_SQRT_PRICE - 1;
            }
            if (sqrtResult <= uint256(TickMath.MIN_SQRT_PRICE)) {
                return TickMath.MIN_SQRT_PRICE + 1;
            }
            // Safe: sqrtResult is clamped above to < MAX_SQRT_PRICE (a uint160), so it fits in uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160(sqrtResult);
        }
    }

    //*********************************************************************//
    // ----------------------- Internal --------------------------------- //
    //*********************************************************************//

    /// @notice Build a uint32[] array of [twapWindow, 0] for the oracle observe call.
    function _makeSecondsAgos(uint32 twapWindow) private pure returns (uint32[] memory secondsAgos) {
        secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;
    }
}
