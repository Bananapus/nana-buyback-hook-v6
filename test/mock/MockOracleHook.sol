// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Mock oracle hook that returns configurable tick cumulatives and seconds-per-liquidity data.
/// Implements the IGeomeanOracle.observe interface for testing TWAP-based quotes.
contract MockOracleHook {
    int56 public tickCumulative0;
    int56 public tickCumulative1;
    uint160 public secPerLiq0;
    uint160 public secPerLiq1;
    bool public shouldRevert;

    /// @notice Configure the observe return data.
    /// @param _tickCumulative0 Tick cumulative at secondsAgo[0] (the older observation).
    /// @param _tickCumulative1 Tick cumulative at secondsAgo[1] (current, typically 0 seconds ago).
    /// @param _secPerLiq0 Seconds-per-liquidity cumulative at secondsAgo[0].
    /// @param _secPerLiq1 Seconds-per-liquidity cumulative at secondsAgo[1].
    function setObserveData(
        int56 _tickCumulative0,
        int56 _tickCumulative1,
        uint160 _secPerLiq0,
        uint160 _secPerLiq1
    ) external {
        tickCumulative0 = _tickCumulative0;
        tickCumulative1 = _tickCumulative1;
        secPerLiq0 = _secPerLiq0;
        secPerLiq1 = _secPerLiq1;
    }

    /// @notice If true, observe() reverts (simulating an unsupported oracle).
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /// @notice IGeomeanOracle.observe implementation.
    /// @dev Returns arrays of length 2 matching the [twapWindow, 0] secondsAgos pattern.
    function observe(PoolKey calldata, uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (shouldRevert) revert("MockOracle: unsupported");

        tickCumulatives = new int56[](2);
        tickCumulatives[0] = tickCumulative0;
        tickCumulatives[1] = tickCumulative1;

        secondsPerLiquidityCumulativeX128s = new uint160[](2);
        secondsPerLiquidityCumulativeX128s[0] = secPerLiq0;
        secondsPerLiquidityCumulativeX128s[1] = secPerLiq1;
    }
}
