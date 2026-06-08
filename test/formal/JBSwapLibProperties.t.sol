// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBSwapLib} from "../../src/libraries/JBSwapLib.sol";

/// @notice Functional-correctness harnesses for the pure slippage/price-limit/impact math in `JBSwapLib`.
///
/// @dev Each property is DUAL-implemented: a `check_<name>` entrypoint for Halmos (symbolic) and a
/// `testFuzz_<name>` entrypoint for the Foundry fuzzer. Symbolic entrypoints are bounded to widths the SMT
/// solver can discharge quickly (uint128 impact, uint16 fee). The 512-bit `FullMath.mulDiv` and the integer
/// `Math.sqrt` paths are verified by fuzz only — pointing Halmos at those domains times out (matching the core
/// team's HalmosSmoke-vs-FeeProperties split). These extend, and do not duplicate, the existing
/// `JBSwapLibHalmos` edge-case proofs (floor / pool-fee ceiling / overflow ceiling).
contract JBSwapLibProperties is Test {
    /// @notice The hard slippage ceiling used by `JBSwapLib.getSlippageTolerance` (88%).
    uint256 internal constant _MAX_SLIPPAGE = 8800;

    /// @notice The half-saturation constant of the sigmoid, scaled to 1e18 impact precision.
    uint256 internal constant _SIGMOID_K = 5e16;

    /// @notice The basis-points denominator for slippage.
    uint256 internal constant _SLIPPAGE_DENOMINATOR = 10_000;

    //*********************************************************************//
    // ---- Helper: the spec-level expected minimum (floor) for a fee --- //
    //*********************************************************************//

    /// @notice The documented minimum tolerance for a given pool fee: `max(poolFee + 100, 200)`, capped to ceiling.
    /// @dev This mirrors the NatSpec "at least pool fee + 1% buffer, with a floor of 2%".
    function _expectedFloor(uint256 poolFeeBps) internal pure returns (uint256 floor) {
        if (poolFeeBps >= _MAX_SLIPPAGE) return _MAX_SLIPPAGE;
        floor = poolFeeBps + 100;
        if (floor < 200) floor = 200;
        if (floor >= _MAX_SLIPPAGE) floor = _MAX_SLIPPAGE;
    }

    //*********************************************************************//
    // -------- PROPERTY 1: tolerance is always within [floor, ceiling] -- //
    //*********************************************************************//

    /// @notice Spec: tolerance ∈ [minSlippage, MAX_SLIPPAGE] for all inputs. The result never under-protects
    /// (below the fee+buffer floor) and never exceeds the 88% ceiling.
    /// @dev Verified by FUZZ only — the sigmoid branch uses `FullMath.mulDiv`, whose 512-bit reasoning makes the
    /// symbolic solver TIME OUT (observed ~113s in `models`). There is intentionally no `check_` twin for this
    /// property; the SMT-tractable floor/ceiling sub-cases are proven symbolically by `check_zeroImpactIsFloor`
    /// (here) and `JBSwapLibHalmos.check_poolFeeAtCeilingReturnsCeiling`.
    function testFuzz_toleranceWithinBounds(uint256 impact, uint256 poolFeeBps) public pure {
        uint256 tolerance = JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps});
        uint256 floor = _expectedFloor(poolFeeBps);

        assertLe(tolerance, _MAX_SLIPPAGE, "tolerance must not exceed ceiling");
        assertGe(tolerance, floor, "tolerance must not fall below the fee+buffer floor");
    }

    //*********************************************************************//
    // -------- PROPERTY 2: tolerance is monotonic non-decreasing in impact //
    //*********************************************************************//

    /// @notice Spec: the sigmoid `min + range * impact/(impact+K)` is non-decreasing in `impact` for a fixed fee.
    /// A larger swap (more impact) can only widen the acceptable slippage, never tighten it. This is what makes
    /// the buyback route prefer minting over a worse-and-worse pool execution as size grows.
    /// @dev Verified by FUZZ only — like the bounds property, the sigmoid `FullMath.mulDiv` causes the symbolic
    /// solver to TIME OUT (observed ~234s in `models`). No `check_` twin; fuzz is authoritative (4096 runs).
    function testFuzz_monotonicInImpact(uint256 impactA, uint256 impactB, uint256 poolFeeBps) public pure {
        (uint256 lo, uint256 hi) = impactA <= impactB ? (impactA, impactB) : (impactB, impactA);
        uint256 tLo = JBSwapLib.getSlippageTolerance({impact: lo, poolFeeBps: poolFeeBps});
        uint256 tHi = JBSwapLib.getSlippageTolerance({impact: hi, poolFeeBps: poolFeeBps});
        assertGe(tHi, tLo, "tolerance must be non-decreasing in impact");
    }

    //*********************************************************************//
    // -------- PROPERTY 3: zero impact returns exactly the floor -------- //
    //*********************************************************************//

    /// @notice Spec (NatSpec): "When impact is 0 (negligible swap or no data), sigmoid returns minSlippage directly."
    /// @dev Distinct from the existing `check_zeroImpactReturnsFloor` (uint16 fee) — this covers the full uint256 fee
    /// domain symbolically to confirm the floor identity holds even above the ceiling fee.
    function check_zeroImpactIsFloor(uint256 poolFeeBps) public pure {
        uint256 tolerance = JBSwapLib.getSlippageTolerance({impact: 0, poolFeeBps: poolFeeBps});
        assert(tolerance == _expectedFloor(poolFeeBps));
    }

    function testFuzz_zeroImpactIsFloor(uint256 poolFeeBps) public pure {
        assertEq(JBSwapLib.getSlippageTolerance({impact: 0, poolFeeBps: poolFeeBps}), _expectedFloor(poolFeeBps));
    }

    //*********************************************************************//
    // -------- PROPERTY 4: tolerance is monotonic in pool fee ----------- //
    //*********************************************************************//

    /// @notice Spec: a higher pool fee can only raise (or hold) the tolerance, never lower it — the minimum is
    /// `poolFee + 100` and the sigmoid offset rises with the minimum. Confirms a deeper-fee pool is treated as
    /// at least as risky for slippage as a cheaper one.
    function testFuzz_monotonicInPoolFee(uint256 impact, uint256 feeA, uint256 feeB) public pure {
        (uint256 lo, uint256 hi) = feeA <= feeB ? (feeA, feeB) : (feeB, feeA);
        uint256 tLo = JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: lo});
        uint256 tHi = JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: hi});
        assertGe(tHi, tLo, "tolerance must be non-decreasing in pool fee");
    }

    //*********************************************************************//
    // -------- PROPERTY 5: sqrtPriceLimit always in valid V4 range ------ //
    //*********************************************************************//

    /// @notice Spec: `sqrtPriceLimitFromAmounts` always returns a value strictly inside V4's representable price
    /// band `[MIN_SQRT_PRICE+1, MAX_SQRT_PRICE-1]` — the swap can always be submitted to the PoolManager without a
    /// price-range revert. Verified by fuzz (the function contains `Math.sqrt`, which Halmos cannot discharge).
    function testFuzz_sqrtPriceLimitInRange(uint256 amountIn, uint256 minimumOut, bool zeroForOne) public pure {
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: amountIn, minimumAmountOut: minimumOut, zeroForOne: zeroForOne
        });
        assertGe(uint256(limit), uint256(TickMath.MIN_SQRT_PRICE + 1), "limit must be >= MIN_SQRT_PRICE+1");
        assertLe(uint256(limit), uint256(TickMath.MAX_SQRT_PRICE - 1), "limit must be <= MAX_SQRT_PRICE-1");
    }

    //*********************************************************************//
    // -------- PROPERTY 6: zero minimum => directional no-limit bound --- //
    //*********************************************************************//

    /// @notice Spec (NatSpec): "When `minimumAmountOut == 0`, returns the direction's extreme price bound (no
    /// swap-price limit)." Same for `amountIn == 0`. This is the "no explicit floor" passthrough.
    function check_zeroMinimumReturnsExtreme(uint256 amountIn, bool zeroForOne) public pure {
        uint160 limit =
            JBSwapLib.sqrtPriceLimitFromAmounts({amountIn: amountIn, minimumAmountOut: 0, zeroForOne: zeroForOne});
        uint160 expected = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        assert(limit == expected);
    }

    /// @notice Fuzz: zero amountIn also yields the directional extreme.
    function testFuzz_zeroAmountInReturnsExtreme(uint256 minimumOut, bool zeroForOne) public pure {
        uint160 limit =
            JBSwapLib.sqrtPriceLimitFromAmounts({amountIn: 0, minimumAmountOut: minimumOut, zeroForOne: zeroForOne});
        uint160 expected = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        assertEq(limit, expected, "zero amountIn must yield the directional no-limit bound");
    }

    //*********************************************************************//
    // -------- PROPERTY 7: calculateImpact zero-data => 0, never reverts  //
    //*********************************************************************//

    /// @notice Spec (NatSpec): "Returns 0 only when liquidity or sqrtP is 0 (truly no data)." And the function is
    /// pure arithmetic that must never revert for any in-range V4 inputs. Verified by fuzz (512-bit mulDiv).
    function testFuzz_calculateImpactZeroDataAndNoRevert(
        uint256 amountIn,
        uint128 liquidity,
        uint160 sqrtP,
        bool zeroForOne
    )
        public
        pure
    {
        // Constrain sqrtP to the valid V4 band so getSqrtPrice-derived inputs are realistic and the !zeroForOne
        // division by sqrtP is well-defined. (The zero case is checked explicitly below.)
        sqrtP = uint160(bound(uint256(sqrtP), uint256(TickMath.MIN_SQRT_PRICE), uint256(TickMath.MAX_SQRT_PRICE)));
        // Bound amountIn so the intermediate `amountIn * 1e18` mulDiv stays representable (realistic token amounts).
        amountIn = bound(amountIn, 0, type(uint128).max);

        uint256 impact =
            JBSwapLib.calculateImpact({amountIn: amountIn, liquidity: liquidity, sqrtP: sqrtP, zeroForOne: zeroForOne});

        if (liquidity == 0) {
            assertEq(impact, 0, "zero liquidity must yield zero impact");
        }
        // A non-revert is itself the assertion for the live-data path.
    }

    /// @notice Spec: explicit zero-sqrtP also yields zero impact.
    function testFuzz_calculateImpactZeroSqrtP(uint256 amountIn, uint128 liquidity, bool zeroForOne) public pure {
        uint256 impact =
            JBSwapLib.calculateImpact({amountIn: amountIn, liquidity: liquidity, sqrtP: 0, zeroForOne: zeroForOne});
        assertEq(impact, 0, "zero sqrtP must yield zero impact");
    }

    //*********************************************************************//
    // -------- PROPERTY 8: calculateImpact monotonic in amountIn -------- //
    //*********************************************************************//

    /// @notice Spec intuition: a larger swap into the same pool state has at least as much price impact. This is
    /// what couples PROPERTY 2 (tolerance up with impact) to swap size: more input => more impact => wider tolerance.
    function testFuzz_calculateImpactMonotonicInAmountIn(
        uint256 amountA,
        uint256 amountB,
        uint128 liquidity,
        uint160 sqrtP,
        bool zeroForOne
    )
        public
        pure
    {
        vm.assume(liquidity != 0);
        sqrtP = uint160(bound(uint256(sqrtP), uint256(TickMath.MIN_SQRT_PRICE), uint256(TickMath.MAX_SQRT_PRICE)));
        amountA = bound(amountA, 0, type(uint128).max);
        amountB = bound(amountB, 0, type(uint128).max);
        (uint256 lo, uint256 hi) = amountA <= amountB ? (amountA, amountB) : (amountB, amountA);

        uint256 iLo =
            JBSwapLib.calculateImpact({amountIn: lo, liquidity: liquidity, sqrtP: sqrtP, zeroForOne: zeroForOne});
        uint256 iHi =
            JBSwapLib.calculateImpact({amountIn: hi, liquidity: liquidity, sqrtP: sqrtP, zeroForOne: zeroForOne});
        assertGe(iHi, iLo, "impact must be non-decreasing in amountIn");
    }
}
