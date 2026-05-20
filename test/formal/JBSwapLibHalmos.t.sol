// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBSwapLib} from "../../src/libraries/JBSwapLib.sol";

/// @notice Small Halmos entrypoints for the buyback hook's slippage tolerance math.
/// @dev These proofs deliberately avoid oracle and TickMath paths so the CI target stays fast and deterministic.
contract JBSwapLibHalmos {
    /// @notice The hard ceiling used by `JBSwapLib.getSlippageTolerance`.
    uint256 internal constant _MAX_SLIPPAGE = 8800;

    /// @notice Proves zero impact returns the minimum tolerance floor exactly.
    /// @param poolFeeBps The pool fee in basis points.
    function check_zeroImpactReturnsFloor(uint16 poolFeeBps) public pure {
        uint256 tolerance = JBSwapLib.getSlippageTolerance({impact: 0, poolFeeBps: uint256(poolFeeBps)});

        uint256 expectedFloor = uint256(poolFeeBps) + 100;
        if (expectedFloor < 200) expectedFloor = 200;
        if (expectedFloor > _MAX_SLIPPAGE) expectedFloor = _MAX_SLIPPAGE;

        assert(tolerance == expectedFloor);
    }

    /// @notice Proves pool fees at or above the ceiling always return the ceiling.
    /// @param impact The estimated price impact. The function returns before using it in this branch.
    /// @param excessFeeBps Extra basis points added to the ceiling.
    function check_poolFeeAtCeilingReturnsCeiling(uint256 impact, uint16 excessFeeBps) public pure {
        uint256 poolFeeBps = _MAX_SLIPPAGE + uint256(excessFeeBps);

        assert(JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps}) == _MAX_SLIPPAGE);
    }

    /// @notice Proves overflow-risk impact values return the ceiling before adding the sigmoid constant.
    /// @param excessImpact The extra amount above the overflow guard threshold.
    /// @param poolFeeBps The pool fee in basis points.
    function check_overflowImpactReturnsCeiling(uint32 excessImpact, uint16 poolFeeBps) public pure {
        uint256 impact = type(uint256).max - 5e16 + 1 + uint256(excessImpact);

        assert(JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: uint256(poolFeeBps)}) == _MAX_SLIPPAGE);
    }
}
