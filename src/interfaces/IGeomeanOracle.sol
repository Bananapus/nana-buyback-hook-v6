// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Interface for V4 oracle hooks that implement the `observe` pattern (e.g. TruncGeoOracle).
/// @dev Oracle hooks are optional in V4. If a pool's hook does not implement this interface,
/// callers should fall back to minting (buyback hook) or reverting (swap terminal).
interface IGeomeanOracle {
    /// @notice Returns cumulative tick and liquidity-per-second values for the given seconds-ago offsets.
    /// @param key The pool key to observe.
    /// @param secondsAgos An array of seconds-ago offsets from the current block timestamp.
    /// @return tickCumulatives Cumulative tick values at the given offsets.
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity at the given offsets.
    function observe(
        PoolKey calldata key,
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
