// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/// @notice Shared library for slippage tolerance and price limit calculations.
/// @dev V3-compatible port of the V4 JBSwapLib. Uses continuous sigmoid formula instead of
///      stepped if/else brackets for smoother slippage tolerance across all swap sizes.
library JBSwapLib {
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
    // -------------------- Slippage Tolerance -------------------------- //
    //*********************************************************************//

    /// @notice Compute a continuous sigmoid slippage tolerance based on swap impact and pool fee.
    /// @dev tolerance = minSlippage + (maxSlippage - minSlippage) * impact / (impact + K)
    ///      When impact is 0 (negligible swap in deep pool), returns minSlippage.
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

        // When impact is 0, sigmoid returns minSlippage directly.
        if (impact == 0) return minSlippage;

        // For extreme impact values, cap to prevent overflow in (impact + K).
        if (impact > type(uint256).max - SIGMOID_K) return MAX_SLIPPAGE;

        // Sigmoid: minSlippage + (maxSlippage - minSlippage) * impact / (impact + K)
        uint256 range = MAX_SLIPPAGE - minSlippage;
        uint256 tolerance = minSlippage + mulDiv(range, impact, impact + SIGMOID_K);

        return tolerance;
    }

    //*********************************************************************//
    // -------------------- Impact Calculation -------------------------- //
    //*********************************************************************//

    /// @notice Estimate the price impact of a swap, scaled by IMPACT_PRECISION.
    /// @dev Uses 1e18 precision to capture sub-basis-point impacts for small swaps in deep pools.
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

        uint256 base = mulDiv(amountIn, IMPACT_PRECISION, uint256(liquidity));

        impact = zeroForOne
            ? mulDiv(base, uint256(sqrtP), uint256(1) << 96)
            : mulDiv(base, uint256(1) << 96, uint256(sqrtP));
    }

    //*********************************************************************//
    // -------------------- Price Limit -------------------------------- //
    //*********************************************************************//

    /// @notice Compute a sqrtPriceLimitX96 from input/output amounts so the swap stops
    ///         if the execution price would be worse than the minimum acceptable rate.
    /// @dev When `minimumAmountOut == 0`, returns extreme values (no limit).
    /// @param amountIn The amount of tokens being swapped in.
    /// @param minimumAmountOut The minimum acceptable output.
    /// @param zeroForOne True when selling token0 for token1 (price decreases).
    /// @return sqrtPriceLimit The V3-compatible sqrtPriceLimitX96.
    function sqrtPriceLimitFromAmounts(
        uint256 amountIn,
        uint256 minimumAmountOut,
        bool zeroForOne
    )
        internal
        pure
        returns (uint160 sqrtPriceLimit)
    {
        if (minimumAmountOut == 0 || amountIn == 0) {
            return zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        }

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
            return zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        } else if (num / den >= (uint256(1) << 64)) {
            // Extended range: use ratioX128 to avoid mulDiv overflow, then shift.
            uint256 ratioX128 = mulDiv(num, uint256(1) << 128, den);
            sqrtResult = Math.sqrt(ratioX128) * (uint256(1) << 32);
        } else {
            // Normal range: full precision via ratioX192.
            uint256 ratioX192 = mulDiv(num, uint256(1) << 192, den);
            sqrtResult = Math.sqrt(ratioX192);
        }

        if (zeroForOne) {
            if (sqrtResult <= uint256(TickMath.MIN_SQRT_RATIO)) {
                return TickMath.MIN_SQRT_RATIO + 1;
            }
            if (sqrtResult >= uint256(TickMath.MAX_SQRT_RATIO)) {
                return TickMath.MAX_SQRT_RATIO - 1;
            }
            return uint160(sqrtResult);
        } else {
            if (sqrtResult >= uint256(TickMath.MAX_SQRT_RATIO)) {
                return TickMath.MAX_SQRT_RATIO - 1;
            }
            if (sqrtResult <= uint256(TickMath.MIN_SQRT_RATIO)) {
                return TickMath.MIN_SQRT_RATIO + 1;
            }
            return uint160(sqrtResult);
        }
    }
}
