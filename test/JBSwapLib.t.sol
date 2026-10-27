// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {JBSwapLib} from "../src/libraries/JBSwapLib.sol";
import {MockOracleHook} from "./mock/MockOracleHook.sol";
import {MockPoolManager} from "./mock/MockPoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Tests for JBSwapLib — sigmoid slippage, 1e18 impact, sqrtPriceLimit.
contract JBSwapLibTest is Test {
    //*********************************************************************//
    // ----- Oracle Quote Freshness Tests --------------------------------//
    //*********************************************************************//

    /// @notice A hook oracle quote uses the longest retained best-effort window when the requested window is
    /// under-covered.
    function test_getQuoteFromOracle_usesBestEffortObservationCoverage() public {
        MockPoolManager poolManager = new MockPoolManager();
        MockOracleHook oracleHook = new MockOracleHook();

        address baseToken = makeAddr("baseToken");
        address quoteToken = makeAddr("quoteToken");
        (address currency0, address currency1) =
            baseToken < quoteToken ? (baseToken, quoteToken) : (quoteToken, baseToken);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 3000,
            tickSpacing: int24(60),
            hooks: IHooks(address(oracleHook))
        });

        uint32 twapWindow = 5 minutes;
        uint32 retainedWindow = 2 minutes;
        int24 currentTick = 1234;
        uint128 harmonicLiquidity = 1_000_000 ether;
        uint160 secondsPerLiquidityDelta = uint160((uint256(retainedWindow) << 128) / uint256(harmonicLiquidity));
        oracleHook.setObserveData(
            0, int56(int24(currentTick)) * int56(uint56(retainedWindow)), 0, secondsPerLiquidityDelta
        );
        oracleHook.setObservationCoverage(retainedWindow);

        (uint256 amountOut, int24 arithmeticMeanTick, uint128 returnedLiquidity) = JBSwapLib.getQuoteFromOracle({
            poolManager: IPoolManager(address(poolManager)),
            key: key,
            twapWindow: twapWindow,
            amountIn: 1 ether,
            baseToken: baseToken,
            quoteToken: quoteToken
        });

        assertEq(arithmeticMeanTick, currentTick, "partial coverage used the retained window denominator");
        assertApproxEqAbs(
            uint256(returnedLiquidity), uint256(harmonicLiquidity), 1e18, "quote used the retained liquidity window"
        );
        assertEq(
            amountOut,
            JBSwapLib.getQuoteAtTick({
                tick: currentTick, baseAmount: 1 ether, baseToken: baseToken, quoteToken: quoteToken
            }),
            "best-effort quote was priced from the oracle tick"
        );
    }

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
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);
        uint256 impact = JBSwapLib.calculateImpact(1e18, 1_000_000e18, sqrtP, true);
        // With old 1e5 precision, this would be 0. With 1e18, it should be ~1e12.
        assert(impact > 0);
    }

    /// @notice Zero liquidity should return zero impact.
    function test_impactZeroLiquidity() public pure {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);
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
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(100);
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
        assertEq(limit, TickMath.MIN_SQRT_PRICE + 1);

        limit = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 0, false);
        assertEq(limit, TickMath.MAX_SQRT_PRICE - 1);
    }

    /// @notice sqrtPriceLimit should be within valid V3 range.
    function test_sqrtPriceLimitInRange() public pure {
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 5e17, true);
        assert(limit >= TickMath.MIN_SQRT_PRICE);
        assert(limit <= TickMath.MAX_SQRT_PRICE);

        limit = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 5e17, false);
        assert(limit >= TickMath.MIN_SQRT_PRICE);
        assert(limit <= TickMath.MAX_SQRT_PRICE);
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
        assert(limit > TickMath.MIN_SQRT_PRICE);
        assert(limit < TickMath.MAX_SQRT_PRICE);
    }

    /// @notice Zero amountIn should return extreme values.
    function test_sqrtPriceLimitZeroAmountIn() public pure {
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(0, 1e18, true);
        assertEq(limit, TickMath.MIN_SQRT_PRICE + 1);
    }

    /// @notice Extended range: ratio in [2^64, 2^128) should compute a valid limit, not fall back.
    function test_sqrtPriceLimitExtendedRange() public pure {
        // Simulate USDC (6 dec) → memecoin (18 dec) at ~18.4M tokens per USDC.
        // ratio = 18.4e6 * 1e18 / (1 * 1e6) = 1.84e19 > 2^64 (~1.84e19) but < 2^128.
        uint256 amountIn = 1e6; // 1 USDC
        uint256 minOut = 18_500_000e18; // 18.5M tokens

        uint160 limitZfo = JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, minOut, true);
        // Should NOT fall back to MIN_SQRT_PRICE + 1 — should compute a real limit.
        assert(limitZfo > TickMath.MIN_SQRT_PRICE + 1);
        assert(limitZfo <= TickMath.MAX_SQRT_PRICE);

        uint160 limitOfz = JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, minOut, false);
        assert(limitOfz >= TickMath.MIN_SQRT_PRICE);
        assert(limitOfz < TickMath.MAX_SQRT_PRICE - 1);
    }

    /// @notice Extreme ratios should fall back to the normal direction-specific no-limit values.
    function test_sqrtPriceLimitExtremeRatioFallback() public pure {
        // zeroForOne: num = minOut, den = amountIn. A ratio of 2^128 is outside the representable V4 range, so the
        // library cannot express the floor as a sqrt price limit. Settlement code must enforce the actual output.
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(1, uint256(1) << 128, true);
        assertEq(limit, TickMath.MIN_SQRT_PRICE + 1);

        // !zeroForOne: num = amountIn, den = minOut. The same unrepresentable case falls back to the upper no-limit
        // value for the opposite direction.
        limit = JBSwapLib.sqrtPriceLimitFromAmounts(uint256(1) << 128, 1, false);
        assertEq(limit, TickMath.MAX_SQRT_PRICE - 1);
    }

    //*********************************************************************//
    // ----- Expected Output Tests --------------------------------------- //
    //*********************************************************************//

    /// @dev The exact constant-liquidity output of an exact-input swap with a fee taken from the input.
    function _singleRangeOut(
        uint160 sqrtP,
        uint128 liquidity,
        uint256 amountIn,
        uint256 feeBps,
        bool zeroForOne
    )
        internal
        pure
        returns (uint256)
    {
        uint256 inAfterFee = amountIn * (10_000 - feeBps) / 10_000;
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtP, liquidity, inAfterFee, zeroForOne);
        return zeroForOne
            ? SqrtPriceMath.getAmount1Delta(next, sqrtP, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(sqrtP, next, liquidity, false);
    }

    /// @notice The expected output matches a real single-range swap, from tiny to range-exhausting sizes, both ways.
    function test_expectedAmountOutMatchesSingleRangeSwap() public pure {
        address token0 = address(1);
        address token1 = address(2);
        int24 tick = 110_927; // Base project 13's pool on 2026-10-21
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint128 liquidity = 3_692_864_483_889_946_900;
        uint256[5] memory sizes = [uint256(1e12), 1e14, 406_950_545_029_679, 3e15, 1e17];
        for (uint256 i; i < sizes.length; i++) {
            for (uint256 d; d < 2; d++) {
                bool zeroForOne = d == 0;
                uint256 amountIn = zeroForOne ? sizes[i] : sizes[i] * 65_000; // similar value the other way
                uint256 quote = JBSwapLib.getQuoteAtTick({
                    tick: tick,
                    baseAmount: uint128(amountIn),
                    baseToken: zeroForOne ? token0 : token1,
                    quoteToken: zeroForOne ? token1 : token0
                });
                uint256 impact = JBSwapLib.calculateImpact({
                    amountIn: amountIn, liquidity: liquidity, sqrtP: sqrtP, zeroForOne: zeroForOne
                });
                assertApproxEqRel(
                    JBSwapLib.getExpectedAmountOut({quote: quote, impact: impact, poolFeeBps: 100}),
                    _singleRangeOut(sqrtP, liquidity, amountIn, 100, zeroForOne),
                    1e12, // 0.0001%
                    "single-range output"
                );
            }
        }
    }

    /// @notice An unrepresentable impact gives no expected output instead of overflowing the denominator.
    function test_expectedAmountOutMaxImpact() public pure {
        assertEq(JBSwapLib.getExpectedAmountOut({quote: 1e22, impact: type(uint256).max, poolFeeBps: 0}), 0);
    }

    /// @notice With no impact, the expected output is the quote less the fee.
    function test_expectedAmountOutZeroImpact() public pure {
        assertEq(JBSwapLib.getExpectedAmountOut({quote: 1e22, impact: 0, poolFeeBps: 30}), 1e22 * 9970 / 10_000);
    }

    /// @notice With no issuance or no impact, nothing stops the swap, so the whole input swaps.
    function test_expectedSettlementFullFill() public pure {
        uint256 expected = JBSwapLib.getExpectedAmountOut({quote: 1000e18, impact: 1e17, poolFeeBps: 100});
        (uint256 swapAmountOut, uint256 issuedAmountOut) =
            JBSwapLib.getExpectedSettlement({quote: 1000e18, impact: 1e17, poolFeeBps: 100, issuanceTokenCount: 0});
        assertEq(swapAmountOut, expected);
        assertEq(issuedAmountOut, 0);
        (swapAmountOut, issuedAmountOut) =
            JBSwapLib.getExpectedSettlement({quote: 1000e18, impact: 0, poolFeeBps: 100, issuanceTokenCount: 500e18});
        assertEq(swapAmountOut, 1000e18 * 9900 / 10_000);
        assertEq(issuedAmountOut, 0);
    }

    /// @notice The expected settlement matches a real single-range swap limited to the issuance price, with the
    /// unconsumed input minted at issuance, across pool-to-issuance ratios and sizes that do and do not hit the limit.
    function test_expectedSettlementMatchesIssuanceLimitedSwap() public pure {
        int24 tick = 110_927; // Base project 13's pool on 2026-10-21
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint128 liquidity = 3_692_864_483_889_946_900;
        uint256[4] memory sizes = [uint256(1e15), 3e15, 1e16, 1e17];
        uint256[3] memory issuancePercents = [uint256(50), 77, 95];
        for (uint256 i; i < sizes.length; i++) {
            for (uint256 r; r < issuancePercents.length; r++) {
                for (uint256 d; d < 2; d++) {
                    bool zeroForOne = d == 0;
                    uint256 amountIn = zeroForOne ? sizes[i] : sizes[i] * 65_000; // similar value the other way
                    uint256 quote = JBSwapLib.getQuoteAtTick({
                        tick: tick,
                        baseAmount: uint128(amountIn),
                        baseToken: zeroForOne ? address(1) : address(2),
                        quoteToken: zeroForOne ? address(2) : address(1)
                    });
                    uint256 issuance = quote * issuancePercents[r] / 100;

                    // The real swap stops at the issuance price; the input it leaves mints at issuance.
                    (, uint256 used, uint256 out, uint256 fee) = SwapMath.computeSwapStep({
                        sqrtPriceCurrentX96: sqrtP,
                        sqrtPriceTargetX96: JBSwapLib.sqrtPriceLimitFromAmounts({
                            amountIn: amountIn, minimumAmountOut: issuance, zeroForOne: zeroForOne
                        }),
                        liquidity: liquidity,
                        amountRemaining: -int256(amountIn),
                        feePips: 10_000
                    });
                    uint256 settled = out + issuance * (amountIn - used - fee) / amountIn;

                    (uint256 swapAmountOut, uint256 issuedAmountOut) = JBSwapLib.getExpectedSettlement({
                        quote: quote,
                        impact: JBSwapLib.calculateImpact({
                            amountIn: amountIn, liquidity: liquidity, sqrtP: sqrtP, zeroForOne: zeroForOne
                        }),
                        poolFeeBps: 100,
                        issuanceTokenCount: issuance
                    });
                    assertApproxEqRel(swapAmountOut + issuedAmountOut, settled, 1e13, "issuance-limited settlement");
                }
            }
        }
    }

    /// @notice A pool whose spot rate is no better than issuance takes nothing, so the whole input mints.
    function test_expectedSettlementPoolNoBetterThanIssuance() public pure {
        (uint256 swapAmountOut, uint256 issuedAmountOut) = JBSwapLib.getExpectedSettlement({
            quote: 1000e18, impact: 1e16, poolFeeBps: 100, issuanceTokenCount: 1000e18
        });
        assertEq(swapAmountOut, 0);
        assertEq(issuedAmountOut, 1000e18);
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
        assert(limit >= TickMath.MIN_SQRT_PRICE);
        assert(limit <= TickMath.MAX_SQRT_PRICE);
    }

    /// @notice Fuzz: the expected output never reverts over the whole input domain and never exceeds the quote.
    function testFuzz_expectedAmountOutBounded(uint256 quote, uint256 impact, uint16 feeBps) public pure {
        uint256 out = JBSwapLib.getExpectedAmountOut({
            quote: quote, impact: impact, poolFeeBps: bound(uint256(feeBps), 0, 10_000)
        });
        assertLe(out, quote);
    }

    /// @notice Fuzz: across ticks, liquidity, sizes, directions and issuance rates, the expected settlement tracks a
    /// real single-range swap limited to the issuance price, in fills that do and do not hit the limit.
    function testFuzz_expectedSettlementMatchesIssuanceLimitedSwap(
        int24 tick,
        uint128 liquidity,
        uint128 amountIn,
        uint256 issuancePercent,
        bool zeroForOne
    )
        public
        pure
    {
        tick = int24(bound(tick, -200_000, 200_000));
        liquidity = uint128(bound(liquidity, 1e15, 1e27));
        amountIn = uint128(bound(amountIn, 1e9, 1e27));
        issuancePercent = bound(issuancePercent, 10, 99);
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 quote = JBSwapLib.getQuoteAtTick({
            tick: tick,
            baseAmount: amountIn,
            baseToken: zeroForOne ? address(1) : address(2),
            quoteToken: zeroForOne ? address(2) : address(1)
        });
        // Keep to quotes with enough precision to compare at 0.01%.
        vm.assume(quote > 1e12);
        uint256 issuance = quote * issuancePercent / 100;

        (, uint256 used, uint256 out, uint256 fee) = SwapMath.computeSwapStep({
            sqrtPriceCurrentX96: sqrtP,
            sqrtPriceTargetX96: JBSwapLib.sqrtPriceLimitFromAmounts({
                amountIn: amountIn, minimumAmountOut: issuance, zeroForOne: zeroForOne
            }),
            liquidity: liquidity,
            amountRemaining: -int256(uint256(amountIn)),
            feePips: 10_000
        });
        uint256 settled = out + issuance * (amountIn - used - fee) / amountIn;

        (uint256 swapAmountOut, uint256 issuedAmountOut) = JBSwapLib.getExpectedSettlement({
            quote: quote,
            impact: JBSwapLib.calculateImpact({
                amountIn: amountIn, liquidity: liquidity, sqrtP: sqrtP, zeroForOne: zeroForOne
            }),
            poolFeeBps: 100,
            issuanceTokenCount: issuance
        });
        assertApproxEqRel(swapAmountOut + issuedAmountOut, settled, 1e14, "issuance-limited settlement");
    }

    /// @notice Fuzz: the expected settlement never reverts over amounts far past any token supply, and never estimates
    /// more than the better of the quote and issuance.
    function testFuzz_expectedSettlementBounded(
        uint256 quote,
        uint256 impact,
        uint16 feeBps,
        uint256 issuance
    )
        public
        pure
    {
        quote = bound(quote, 0, 1e50);
        issuance = bound(issuance, 0, 1e50);
        (uint256 swapAmountOut, uint256 issuedAmountOut) = JBSwapLib.getExpectedSettlement({
            quote: quote, impact: impact, poolFeeBps: bound(uint256(feeBps), 0, 10_000), issuanceTokenCount: issuance
        });
        assertLe(swapAmountOut + issuedAmountOut, (quote > issuance ? quote : issuance) + 2);
    }
}
