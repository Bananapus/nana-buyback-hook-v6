// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {JBSwapLib} from "../src/libraries/JBSwapLib.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

/// @notice Tests for JBSwapLib — sigmoid slippage, 1e18 impact, sqrtPriceLimit.
contract JBSwapLibTest is Test {
    //*********************************************************************//
    // ----- Sigmoid Continuity & Monotonicity Tests --------------------- //
    //*********************************************************************//

    /// @notice Sigmoid should be monotonically non-decreasing as impact grows.
    function test_sigmoidMonotonicity() public pure {
        uint256 prev = JBSwapLib.getSlippageTolerance(0, 30);
        for (uint256 i = 1; i <= 20; i++) {
            uint256 impact = i * 1e16; // 0.01, 0.02, ... 0.20 in 1e18 units
            uint256 curr = JBSwapLib.getSlippageTolerance(impact, 30);
            assert(curr >= prev);
            prev = curr;
        }
    }

    /// @notice At zero impact, sigmoid should return the minimum (poolFee + 100 bps, floor 200 bps).
    function test_sigmoidZeroImpact() public pure {
        // Pool fee 30 bps → min = 130 bps → floored to 200 bps
        uint256 tolerance = JBSwapLib.getSlippageTolerance(0, 30);
        assertEq(tolerance, 200);

        // Pool fee 300 bps → min = 400 bps
        tolerance = JBSwapLib.getSlippageTolerance(0, 300);
        assertEq(tolerance, 400);
    }

    /// @notice At extreme impact, sigmoid should approach MAX_SLIPPAGE.
    function test_sigmoidExtremeImpact() public pure {
        uint256 tolerance = JBSwapLib.getSlippageTolerance(type(uint128).max, 30);
        // Should be very close to MAX_SLIPPAGE (8800)
        assert(tolerance >= 8700);
        assert(tolerance <= 8800);
    }

    /// @notice Pool fee should raise the floor.
    function test_poolFeeAwarenessRaisesFloor() public pure {
        uint256 lowFee = JBSwapLib.getSlippageTolerance(1e17, 10); // 0.1% fee
        uint256 highFee = JBSwapLib.getSlippageTolerance(1e17, 300); // 3% fee
        assert(highFee > lowFee);
    }

    /// @notice Pool fee exceeding MAX_SLIPPAGE should return MAX_SLIPPAGE.
    function test_poolFeeExceedingMax() public pure {
        uint256 tolerance = JBSwapLib.getSlippageTolerance(1e17, 9000);
        assertEq(tolerance, 8800);
    }

    //*********************************************************************//
    // ----- 1e18 Impact Precision Tests --------------------------------- //
    //*********************************************************************//

    /// @notice Small swap in deep pool should not round to zero.
    function test_impactPrecisionSmallSwap() public pure {
        // 1 ETH in a pool with 1M ETH liquidity and sqrtP at tick 0
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        uint256 impact = JBSwapLib.calculateImpact(1e18, 1_000_000e18, sqrtP, true);
        // With old 1e5 precision, this would be 0. With 1e18, it should be ~1e12.
        assert(impact > 0);
    }

    /// @notice Zero liquidity should return zero impact.
    function test_impactZeroLiquidity() public pure {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        uint256 impact = JBSwapLib.calculateImpact(1e18, 0, sqrtP, true);
        assertEq(impact, 0);
    }

    /// @notice Zero sqrtP should return zero impact.
    function test_impactZeroSqrtP() public pure {
        uint256 impact = JBSwapLib.calculateImpact(1e18, 1e18, 0, true);
        assertEq(impact, 0);
    }

    /// @notice Both directions should produce positive impact.
    function test_impactBothDirections() public pure {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(100);
        uint256 impact0For1 = JBSwapLib.calculateImpact(1e18, 100e18, sqrtP, true);
        uint256 impact1For0 = JBSwapLib.calculateImpact(1e18, 100e18, sqrtP, false);
        assert(impact0For1 > 0);
        assert(impact1For0 > 0);
    }

    //*********************************************************************//
    // ----- sqrtPriceLimit Tests ---------------------------------------- //
    //*********************************************************************//

    /// @notice Zero minimumAmountOut should return extreme values.
    function test_sqrtPriceLimitNoMinimum() public pure {
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 0, true);
        assertEq(limit, TickMath.MIN_SQRT_RATIO + 1);

        limit = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 0, false);
        assertEq(limit, TickMath.MAX_SQRT_RATIO - 1);
    }

    /// @notice sqrtPriceLimit should be within valid V3 range.
    function test_sqrtPriceLimitInRange() public pure {
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 5e17, true);
        assert(limit >= TickMath.MIN_SQRT_RATIO);
        assert(limit <= TickMath.MAX_SQRT_RATIO);

        limit = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 5e17, false);
        assert(limit >= TickMath.MIN_SQRT_RATIO);
        assert(limit <= TickMath.MAX_SQRT_RATIO);
    }

    /// @notice For zeroForOne, larger minimumAmountOut should push sqrtPriceLimit higher.
    function test_sqrtPriceLimitOrderingZeroForOne() public pure {
        uint160 limitLow = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 1e17, true);
        uint160 limitHigh = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 9e17, true);
        // Higher minimum → higher acceptable price → higher sqrtPriceLimit
        assert(limitHigh >= limitLow);
    }

    /// @notice Edge case: equal amounts.
    function test_sqrtPriceLimitEqualAmounts() public pure {
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 1e18, true);
        // price = 1:1, sqrt(1) * 2^96 = 2^96
        assert(limit > TickMath.MIN_SQRT_RATIO);
        assert(limit < TickMath.MAX_SQRT_RATIO);
    }

    /// @notice Zero amountIn should return extreme values.
    function test_sqrtPriceLimitZeroAmountIn() public pure {
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(0, 1e18, true);
        assertEq(limit, TickMath.MIN_SQRT_RATIO + 1);
    }

    /// @notice Extended range: ratio in [2^64, 2^128) should compute a valid limit, not fall back.
    function test_sqrtPriceLimitExtendedRange() public pure {
        // Simulate USDC (6 dec) → memecoin (18 dec) at ~18.4M tokens per USDC.
        // ratio = 18.4e6 * 1e18 / (1 * 1e6) = 1.84e19 > 2^64 (~1.84e19) but < 2^128.
        uint256 amountIn = 1e6; // 1 USDC
        uint256 minOut = 18_500_000e18; // 18.5M tokens

        uint160 limitZfo = JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, minOut, true);
        // Should NOT fall back to MIN_SQRT_RATIO + 1 — should compute a real limit.
        assert(limitZfo > TickMath.MIN_SQRT_RATIO + 1);
        assert(limitZfo <= TickMath.MAX_SQRT_RATIO);

        uint160 limitOfz = JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, minOut, false);
        assert(limitOfz >= TickMath.MIN_SQRT_RATIO);
        assert(limitOfz < TickMath.MAX_SQRT_RATIO - 1);
    }

    /// @notice Extreme ratio >= 2^128 should fall back to no limit.
    function test_sqrtPriceLimitExtremeRatioFallback() public pure {
        // zeroForOne: num = minOut, den = amountIn → ratio = 2^128, triggers fallback.
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(1, uint256(1) << 128, true);
        assertEq(limit, TickMath.MIN_SQRT_RATIO + 1);

        // !zeroForOne: num = amountIn, den = minOut → ratio = 2^128, triggers fallback.
        limit = JBSwapLib.sqrtPriceLimitFromAmounts(uint256(1) << 128, 1, false);
        assertEq(limit, TickMath.MAX_SQRT_RATIO - 1);
    }

    //*********************************************************************//
    // ----- Fuzz Tests -------------------------------------------------- //
    //*********************************************************************//

    /// @notice Fuzz: sigmoid should always be within [minSlippage, MAX_SLIPPAGE].
    function testFuzz_sigmoidBounds(uint128 impact, uint16 feeBps) public pure {
        uint256 tolerance = JBSwapLib.getSlippageTolerance(uint256(impact), uint256(feeBps));
        assert(tolerance <= 8800);
        // Min should be at least 200 (or poolFee+100 if higher)
        uint256 expectedMin = uint256(feeBps) + 100;
        if (expectedMin < 200) expectedMin = 200;
        if (expectedMin >= 8800) expectedMin = 8800;
        assert(tolerance >= expectedMin || tolerance == 8800);
    }

    /// @notice Fuzz: sqrtPriceLimit should always be in valid V3 range.
    function testFuzz_sqrtPriceLimitValid(uint128 amountIn, uint128 minOut, bool zeroForOne) public pure {
        vm.assume(amountIn > 0);
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(uint256(amountIn), uint256(minOut), zeroForOne);
        assert(limit >= TickMath.MIN_SQRT_RATIO);
        assert(limit <= TickMath.MAX_SQRT_RATIO);
    }
}
