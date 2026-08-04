// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Data passed through to the unlock callback.
/// @custom:member key The pool key to swap against.
/// @custom:member zeroForOne Whether the swap moves from `currency0` to `currency1`.
/// @custom:member amountIn The exact amount of input tokens to swap.
/// @custom:member minimumSwapAmountOut The minimum acceptable amount of output tokens.
/// @custom:member derivedFloorAmountOut An oracle-derived floor on the output, pro-rated by consumed input and
/// enforced inside the unlock so a miss unwinds the swap and the caller's try/catch can fall back to minting.
/// 0 = no derived floor (explicit caller minima are enforced by the caller on the combined output instead).
struct SwapCallbackData {
    PoolKey key;
    bool zeroForOne;
    uint256 amountIn;
    uint256 minimumSwapAmountOut;
    uint256 derivedFloorAmountOut;
}
