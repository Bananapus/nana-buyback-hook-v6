// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Data passed through to the unlock callback.
/// @custom:member key The pool key to swap against.
/// @custom:member zeroForOne Whether the swap moves from `currency0` to `currency1`.
/// @custom:member amountIn The exact amount of input tokens to swap.
/// @custom:member minimumSwapAmountOut The minimum acceptable amount of output tokens.
struct SwapCallbackData {
    PoolKey key;
    bool zeroForOne;
    uint256 amountIn;
    uint256 minimumSwapAmountOut;
}
