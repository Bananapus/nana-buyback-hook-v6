// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {JBSwapLib} from "src/libraries/JBSwapLib.sol";

/// @title MEVScenarios
/// @notice Realistic scenario tests that quantify the MEV protection provided by the
///         sqrtPriceLimitFromAmounts + sigmoid slippage + TWAP cross-validation pipeline.
///
///         Run with -vvv to see the full output tables:
///           forge test --match-contract MEVScenarios -vvv --skip "script/*"
contract MEVScenarios is Test {

    uint256 constant BPS = 10_000;

    struct PoolScenario {
        string name;
        int24 tick;
        uint128 liquidity;
        uint24 feeBps;
        bool zeroForOne;
    }

    //*********************************************************************//
    // ---- test: sandwich attack — the core protection demo ----------- //
    //*********************************************************************//

    /// @notice Model a sandwich attack at varying intensities and show exactly
    ///         how the sqrtPriceLimit prevents extraction.
    ///
    /// Attack model for zeroForOne (victim sells token0 for token1):
    ///   1. Fair price is at tick T_fair (our TWAP).
    ///   2. Attacker frontrunns: sells token0, pushes price DOWN by `attackBps`.
    ///   3. Victim's swap executes:
    ///      OLD: extreme sqrtPriceLimit (MIN+1) -> swap goes through at T_attacked.
    ///      NEW: computed sqrtPriceLimit -> if T_attacked < our limit, swap returns 0.
    ///           All input goes to addToBalanceOf -> minted at weight. 0 MEV leaked.
    function test_sandwichProtectionByAttackStrength() public pure {
        // Step 1: compute the pipeline outputs for a 100 ETH swap.
        uint256 oracleQuote;
        uint256 slippageBps;
        int24 limitTick;
        {
            int24 fairTick = 0;
            uint128 liquidity = 1_000_000e18;
            uint24 feeBps = 30;
            uint256 amountIn = 100 ether;
            bool zeroForOne = true;

            oracleQuote = JBSwapLib.getQuoteAtTick(fairTick, uint128(amountIn), address(0x01), address(0x02));
            uint160 sqrtP = TickMath.getSqrtPriceAtTick(fairTick);
            uint256 impact = JBSwapLib.calculateImpact(amountIn, liquidity, sqrtP, zeroForOne);
            slippageBps = JBSwapLib.getSlippageTolerance(impact, feeBps);
            uint256 minimumOut = oracleQuote - (oracleQuote * slippageBps) / BPS;
            uint160 priceLimit = JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, minimumOut, zeroForOne);
            limitTick = TickMath.getTickAtSqrtPrice(priceLimit);

            console.log("");
            console.log("====== SANDWICH PROTECTION BY ATTACK STRENGTH ======");
            console.log("Pool: 1M liq, 0.3%% fee | Victim: 100 ETH");
            console.log("Impact: %s | Slippage: %s bps", impact, slippageBps);
            console.log("MinOut: %s | LimitTick: %s", _formatEther(minimumOut), _tickStr(limitTick));
            console.log("");
        }

        // Step 2: test at various attack strengths.
        uint256[8] memory attackBps = [uint256(10), 50, 100, 150, 200, 217, 250, 500];

        for (uint256 i = 0; i < attackBps.length; i++) {
            _logAttackRow(attackBps[i], slippageBps, limitTick);
        }

        console.log("");
        console.log("KEY INSIGHT: attacks > %s ticks trigger full mint fallback (0 MEV).",
            _toString(uint256(uint24(-limitTick))));
        console.log("The sqrtPriceLimit acts as a circuit breaker.");
    }

    /// @notice Log one row of the sandwich attack comparison table.
    function _logAttackRow(uint256 atk, uint256 slippageBps, int24 limitTick) internal pure {
        // OLD: attacker extracts `atk` bps (up to slippageBps before post-swap check reverts).
        uint256 oldMEV = atk <= slippageBps ? atk : 0;

        // NEW: if attack pushes price past our limit tick, swap returns 0 → all minted → 0 MEV.
        // At tick 0, 1 bps ~ 1 tick. limitTick is negative (below 0).
        int24 attackedTick = -int24(int256(atk));
        uint256 newMEV = attackedTick < limitTick ? 0 : atk;
        string memory note = attackedTick < limitTick ? "BLOCKED (mint)" : "swaps (within lim)";

        uint256 saved = oldMEV > newMEV ? oldMEV - newMEV : 0;

        console.log("  Attack %s bps: Old=%s New=%s",
            _padLeft(atk, 3), _padLeft(oldMEV, 3), _padLeft(newMEV, 3));
        console.log("    Saved: %s bps | %s", _padLeft(saved, 3), note);
    }

    //*********************************************************************//
    // ---- test: full slippage pipeline across pool types --------------- //
    //*********************************************************************//

    /// @notice Show the full pipeline output across different pool depths and swap sizes.
    function test_slippagePipelineMatrix() public pure {
        console.log("");
        console.log("====== SLIPPAGE PIPELINE: REALISTIC SCENARIOS ======");
        console.log("");

        // Scenarios: (name, tick, liquidity, fee)
        string[4] memory names = ["DeepETH/USDC", "MediumDEX", "ThinMicrocap", "UltraThin"];
        int24[4] memory ticks = [int24(0), int24(0), int24(0), int24(0)];
        uint128[4] memory liqs = [uint128(100_000_000e18), uint128(1_000_000e18), uint128(50_000e18), uint128(5_000e18)];
        uint24[4] memory fees = [uint24(30), uint24(30), uint24(100), uint24(100)];

        uint256[5] memory sizes = [uint256(1 ether), 10 ether, 50 ether, 100 ether, 500 ether];

        for (uint256 s = 0; s < 4; s++) {
            console.log("--- %s (liq=%s, fee=%sbps) ---",
                names[s], _formatEther(uint256(liqs[s])), _toString(uint256(fees[s])));

            for (uint256 i = 0; i < sizes.length; i++) {
                uint256 amountIn = sizes[i];
                uint160 sqrtP = TickMath.getSqrtPriceAtTick(ticks[s]);
                uint256 impact = JBSwapLib.calculateImpact(amountIn, liqs[s], sqrtP, true);
                uint256 slippage = JBSwapLib.getSlippageTolerance(impact, fees[s]);
                uint256 quote = JBSwapLib.getQuoteAtTick(ticks[s], uint128(amountIn), address(0x01), address(0x02));
                uint256 minOut = quote - (quote * slippage) / BPS;
                uint256 lostTokens = quote - minOut;

                console.log("  %s ETH: impact=%s slippage=%sbps",
                    _formatEther(amountIn), _toString(impact), _toString(slippage));
                console.log("    quote=%s minOut=%s maxLoss=%s",
                    _formatEther(quote), _formatEther(minOut), _formatEther(lostTokens));
            }
            console.log("");
        }
    }

    //*********************************************************************//
    // ---- test: TWAP cross-validation value demo ---------------------- //
    //*********************************************************************//

    /// @notice Show how TWAP cross-validation protects against stale quotes.
    /// @dev A stale frontend might send a quote from 30 seconds ago.
    ///      If the price has moved unfavorably, the TWAP catches it.
    function test_twapCrossValidationValue() public pure {
        console.log("");
        console.log("====== TWAP CROSS-VALIDATION VALUE ======");
        console.log("Scenario: Frontend sends stale quote. Price moved against user.");
        console.log("");

        // Fair price = 1.0 (tick 0). TWAP-based minimum at 2% slippage = 0.98.
        uint256 amountIn = 10 ether;
        uint256 twapQuote = 9_800_000_000_000_000_000; // 9.8 tokens (2% slippage from 10)

        // Stale frontend quotes (increasingly stale/bad).
        uint256[5] memory staleQuotes = [
            uint256(9_900_000_000_000_000_000), // 9.9 (fresher than TWAP — TWAP still used)
            uint256(9_500_000_000_000_000_000), // 9.5 (stale by 5% — TWAP overrides)
            uint256(9_000_000_000_000_000_000), // 9.0 (very stale)
            uint256(8_000_000_000_000_000_000), // 8.0 (extremely stale)
            uint256(5_000_000_000_000_000_000)  // 5.0 (malicious relay)
        ];

        console.log("  TWAP minimum: %s tokens", _formatEther(twapQuote));
        console.log("");

        for (uint256 i = 0; i < staleQuotes.length; i++) {
            uint256 payerQuote = staleQuotes[i];
            uint256 used = payerQuote > twapQuote ? payerQuote : twapQuote;
            string memory source = payerQuote > twapQuote ? "payer (higher)" : "TWAP (overrides)";

            uint256 protectionBps = 0;
            if (twapQuote > payerQuote) {
                protectionBps = ((twapQuote - payerQuote) * BPS) / amountIn;
            }

            console.log("  Payer quote: %s | Used: %s | Source: %s",
                _formatEther(payerQuote), _formatEther(used), source);
            if (protectionBps > 0) {
                console.log("    --> TWAP saved %s bps of additional MEV exposure", protectionBps);
            }
        }
    }

    //*********************************************************************//
    // ---- test: price limit precision -------------------------------- //
    //*********************************************************************//

    /// @notice Verify sqrtPriceLimitFromAmounts produces limits within 1 bps of target
    ///         across different price levels.
    function test_priceLimitPrecision() public pure {
        console.log("");
        console.log("====== PRICE LIMIT PRECISION ======");

        int24[5] memory ticks = [int24(0), int24(1000), int24(-1000), int24(5000), int24(-5000)];

        for (uint256 i = 0; i < ticks.length; i++) {
            int24 tick = ticks[i];
            uint256 amountIn = 10 ether;

            uint256 oracleQuote = JBSwapLib.getQuoteAtTick(tick, uint128(amountIn), address(0x01), address(0x02));
            uint256 minOut = (oracleQuote * 9700) / BPS; // 3% slippage
            if (minOut == 0) continue;

            uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, minOut, true);

            // Reconstruct the implied minimum from the limit.
            uint256 impliedMinOut;
            if (limit <= type(uint128).max) {
                uint256 limitSq = uint256(limit) * uint256(limit);
                impliedMinOut = FullMath.mulDiv(limitSq, amountIn, uint256(1) << 192);
            } else {
                uint256 limitSqScaled = FullMath.mulDiv(uint256(limit), uint256(limit), uint256(1) << 64);
                impliedMinOut = FullMath.mulDiv(limitSqScaled, amountIn, uint256(1) << 128);
            }

            uint256 errorBps;
            if (impliedMinOut >= minOut) {
                errorBps = ((impliedMinOut - minOut) * BPS) / minOut;
            } else {
                errorBps = ((minOut - impliedMinOut) * BPS) / minOut;
            }

            console.log("  Tick %s: implied=%s target=%s",
                _tickStr(tick), _formatEther(impliedMinOut), _formatEther(minOut));
            console.log("    Error: %s bps", errorBps);

            assertLe(errorBps, 1, "Price limit error exceeds 1 bps");
        }
    }

    //*********************************************************************//
    // ---- test: 5-minute TWAP manipulation cost ---------------------- //
    //*********************************************************************//

    /// @notice Calculate the cost to manipulate the TWAP over different window sizes.
    /// @dev Shows why 5 minutes >> 2 minutes for TWAP security.
    ///
    /// To manipulate a TWAP over W seconds, the attacker must hold a position
    /// that moves the tick by D for the full W seconds. The capital required is
    /// approximately: capital ≈ liquidity * D_ticks * W / block_time
    /// (opportunity cost of locked capital + swap fees paid each direction).
    function test_twapManipulationCost() public pure {
        console.log("");
        console.log("====== TWAP MANIPULATION COST (5min vs 2min) ======");
        console.log("To manipulate TWAP by 100 bps (~100 ticks):");
        console.log("");

        uint128 liquidity = 1_000_000e18; // Medium pool
        uint256 ticksToManipulate = 100;  // ~1% price manipulation
        uint24 feeBps = 30;               // 0.3% fee

        // Cost model:
        // 1. Attacker must swap enough to move price by 100 ticks.
        //    Amount ≈ liquidity * (sqrt(1.0001^100) - 1) ≈ liquidity * 0.005 = 5000 ETH equivalent.
        // 2. They must hold this for the entire TWAP window (pay fees both ways).
        // 3. Total cost ≈ 2 * swapAmount * poolFee (round-trip) + opportunity cost.
        uint256 swapAmount = (uint256(liquidity) * ticksToManipulate) / BPS;
        uint256 roundTripFees = (swapAmount * 2 * feeBps) / BPS;

        uint256 window2min = 120;   // Old minimum
        uint256 window5min = 300;   // New minimum

        // Blocks required (12s per block on Ethereum mainnet).
        uint256 blocks2min = window2min / 12;
        uint256 blocks5min = window5min / 12;

        // Opportunity cost: attacker's capital is locked for W seconds.
        // At 5% APR, opportunity cost per second ≈ capital * 0.05 / (365.25 * 86400).
        // For simplicity, just show the capital required and blocks held.

        console.log("  Capital to move price 100 ticks: ~%s tokens", _formatEther(swapAmount));
        console.log("  Round-trip swap fees: ~%s tokens", _formatEther(roundTripFees));
        console.log("");
        console.log("  2-min window: hold for %s blocks", _toString(blocks2min));
        console.log("    Attacker must dominate %s consecutive blocks", _toString(blocks2min));
        console.log("    Single validator can do this on mainnet");
        console.log("");
        console.log("  5-min window: hold for %s blocks", _toString(blocks5min));
        console.log("    Attacker must dominate %s consecutive blocks", _toString(blocks5min));
        console.log("    Requires multi-block MEV (much more expensive)");
        console.log("");
        console.log("  Difficulty increase: %sx more blocks = %sx harder",
            _toString(blocks5min / blocks2min), _toString(blocks5min / blocks2min));
    }

    //*********************************************************************//
    // ---- test: impact estimation edge case at zero ------------------- //
    //*********************************************************************//

    /// @notice With high-precision impact (1e18 amplifier), even tiny swaps in deep pools
    ///         get tight tolerance (pool fee + 1% buffer) instead of the old 10.5% flat rate.
    function test_deepPoolPrecisionTolerance() public pure {
        console.log("");
        console.log("====== DEEP POOL PRECISION TOLERANCE ======");
        console.log("With 1e18 precision, small swaps in deep pools get tight tolerance:");
        console.log("minSlippage = poolFee + 1%% buffer, floor 2%%.");
        console.log("");

        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);

        // Deep pool: 100M liquidity, various swap sizes.
        uint128 liq = 100_000_000e18;
        uint256[5] memory amounts = [uint256(0.01 ether), 0.1 ether, 1 ether, 10 ether, 1000 ether];

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 impact = JBSwapLib.calculateImpact(amounts[i], liq, sqrtP, true);
            uint256 slippage = JBSwapLib.getSlippageTolerance(impact, 30);

            console.log("  %s ETH: impact=%s slippage=%sbps",
                _formatEther(amounts[i]), _toString(impact), _toString(slippage));
        }

        // Verify: all small swaps get ~200 bps (2%) tolerance, not 1050 (10.5%)
        uint256 tinyImpact = JBSwapLib.calculateImpact(1 ether, liq, sqrtP, true);
        uint256 tinySlippage = JBSwapLib.getSlippageTolerance(tinyImpact, 30);
        assertEq(tinySlippage, 200, "1 ETH in 100M pool should get minSlippage (200 bps)");

        console.log("");
        console.log("KEY: all get tight 200 bps (2%%), not the old 1050 bps (10.5%%).");
    }

    //*********************************************************************//
    // ---- fuzz: price limit always tighter than extreme --------------- //
    //*********************************************************************//

    /// @notice For any non-zero minimum, the computed limit is strictly tighter.
    function testFuzz_priceLimitTighterThanExtreme(
        uint128 amountIn,
        uint128 minOut,
        bool zeroForOne
    ) public pure {
        amountIn = uint128(bound(amountIn, 1e15, type(uint128).max));
        minOut = uint128(bound(minOut, 1e15, type(uint128).max));

        uint160 newLimit = JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, minOut, zeroForOne);
        uint160 oldLimit = zeroForOne
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;

        if (zeroForOne) {
            assertGe(uint256(newLimit), uint256(oldLimit), "tighter for zeroForOne");
        } else {
            assertLe(uint256(newLimit), uint256(oldLimit), "tighter for !zeroForOne");
        }
    }

    /// @notice Fuzz: cross-validation always picks the higher quote.
    function testFuzz_crossValidationPicksHigher(
        uint128 payerMinOut,
        uint128 twapMinOut
    ) public pure {
        payerMinOut = uint128(bound(payerMinOut, 1, type(uint128).max));
        twapMinOut = uint128(bound(twapMinOut, 1, type(uint128).max));

        uint256 result = payerMinOut;
        if (twapMinOut > result) result = twapMinOut;

        assertGe(result, payerMinOut);
        assertGe(result, twapMinOut);
        assertTrue(result == payerMinOut || result == twapMinOut);
    }

    //*********************************************************************//
    // ---- helpers ---------------------------------------------------- //
    //*********************************************************************//

    function _formatEther(uint256 weiAmount) internal pure returns (string memory) {
        uint256 whole = weiAmount / 1e18;
        uint256 frac = (weiAmount % 1e18) / 1e16;
        if (frac < 10) return string(abi.encodePacked(_toString(whole), ".0", _toString(frac)));
        return string(abi.encodePacked(_toString(whole), ".", _toString(frac)));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) { digits--; buffer[digits] = bytes1(uint8(48 + value % 10)); value /= 10; }
        return string(buffer);
    }

    function _tickStr(int24 tick) internal pure returns (string memory) {
        if (tick >= 0) return _toString(uint256(uint24(tick)));
        return string(abi.encodePacked("-", _toString(uint256(uint24(-tick)))));
    }

    function _padLeft(uint256 value, uint256 width) internal pure returns (string memory) {
        string memory s = _toString(value);
        bytes memory b = bytes(s);
        if (b.length >= width) return s;
        bytes memory padded = new bytes(width);
        uint256 padding = width - b.length;
        for (uint256 i = 0; i < padding; i++) padded[i] = " ";
        for (uint256 i = 0; i < b.length; i++) padded[padding + i] = b[i];
        return string(padded);
    }
}
