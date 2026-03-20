// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Data passed through to the unlock callback.
struct SwapCallbackData {
    PoolKey key;
    bool zeroForOne;
    uint256 amountIn;
    uint256 minimumSwapAmountOut;
}
