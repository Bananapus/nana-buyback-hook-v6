// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IWETH9} from "./external/IWETH9.sol";

interface IJBBuybackHook is IJBPayHook, IJBRulesetDataHook {
    /// @notice Emitted when leftover terminal tokens are minted as project tokens.
    /// @param projectId The ID of the project whose tokens are being minted.
    /// @param leftoverAmount The amount of terminal tokens used for minting.
    /// @param tokenCount The number of project tokens minted.
    /// @param caller The address that triggered the mint.
    event Mint(uint256 indexed projectId, uint256 leftoverAmount, uint256 tokenCount, address caller);

    /// @notice Emitted when a pool is added for a project and terminal token pair.
    /// @param projectId The ID of the project the pool is being added for.
    /// @param terminalToken The address of the terminal token.
    /// @param poolId The ID of the Uniswap V4 pool.
    /// @param caller The address that added the pool.
    event PoolAdded(uint256 indexed projectId, address indexed terminalToken, PoolId poolId, address caller);

    /// @notice Emitted when terminal tokens are swapped for project tokens via the Uniswap V4 pool.
    /// @param projectId The ID of the project whose tokens are being swapped for.
    /// @param amountToSwapWith The amount of terminal tokens used for the swap.
    /// @param poolId The ID of the Uniswap V4 pool used.
    /// @param amountReceived The amount of project tokens received from the swap.
    /// @param caller The address that triggered the swap.
    event Swap(
        uint256 indexed projectId,
        uint256 amountToSwapWith,
        PoolId indexed poolId,
        uint256 amountReceived,
        address caller
    );

    /// @notice Emitted when the TWAP window for a project is changed.
    /// @param projectId The ID of the project whose TWAP window is being changed.
    /// @param oldWindow The previous TWAP window in seconds.
    /// @param newWindow The new TWAP window in seconds.
    /// @param caller The address that changed the TWAP window.
    event TwapWindowChanged(uint256 indexed projectId, uint256 oldWindow, uint256 newWindow, address caller);

    /// @notice The directory of terminals and controllers.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The maximum TWAP window that a project can set.
    /// @return The maximum TWAP window in seconds.
    function MAX_TWAP_WINDOW() external view returns (uint256);

    /// @notice The minimum TWAP window that a project can set.
    /// @return The minimum TWAP window in seconds.
    function MIN_TWAP_WINDOW() external view returns (uint256);

    /// @notice The Uniswap V4 PoolManager singleton.
    /// @return The pool manager contract.
    function POOL_MANAGER() external view returns (IPoolManager);

    /// @notice The contract that exposes price feeds.
    /// @return The prices contract.
    function PRICES() external view returns (IJBPrices);

    /// @notice The project registry.
    /// @return The projects contract.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice The token registry.
    /// @return The tokens contract.
    function TOKENS() external view returns (IJBTokens);

    /// @notice The denominator used when calculating TWAP slippage percent values.
    /// @return The slippage denominator.
    function TWAP_SLIPPAGE_DENOMINATOR() external view returns (uint256);

    /// @notice The wrapped native token contract (e.g. WETH on Ethereum, WMATIC on Polygon).
    /// @return The wrapped native token contract.
    function WRAPPED_NATIVE_TOKEN() external view returns (IWETH9);

    /// @notice The PoolKey for a given project and terminal token pair.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @return key The V4 PoolKey.
    function poolKeyOf(uint256 projectId, address terminalToken) external view returns (PoolKey memory key);

    /// @notice The address of each project's token.
    /// @param projectId The ID of the project.
    /// @return projectTokenOf The project's token address.
    function projectTokenOf(uint256 projectId) external view returns (address projectTokenOf);

    /// @notice The TWAP window for the given project.
    /// @param projectId The ID of the project.
    /// @return window The TWAP window in seconds.
    function twapWindowOf(uint256 projectId) external view returns (uint256 window);

    /// @notice Set the pool to use for a given project and terminal token.
    /// @param projectId The ID of the project to set the pool for.
    /// @param poolKey The V4 pool key for the pool being set.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param terminalToken The address of the terminal token that payments to the project are made in.
    function setPoolFor(
        uint256 projectId,
        PoolKey calldata poolKey,
        uint256 twapWindow,
        address terminalToken
    )
        external;

    /// @notice Set the pool to use for a given project and terminal token, constructing the PoolKey internally.
    /// @dev Uses address(0) for the hooks field. The hook sorts the project token and terminal token into the correct
    /// currency order.
    /// @param projectId The ID of the project to set the pool for.
    /// @param fee The Uniswap V4 pool fee tier.
    /// @param tickSpacing The Uniswap V4 pool tick spacing.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param terminalToken The address of the terminal token that payments to the project are made in.
    function setPoolFor(
        uint256 projectId,
        uint24 fee,
        int24 tickSpacing,
        uint256 twapWindow,
        address terminalToken
    )
        external;

    /// @notice Initialize a Uniswap V4 pool in the PoolManager and configure it as the buyback pool for a project.
    /// @dev Atomically initializes the pool (if not already initialized) and calls `_setPoolFor`. Uses
    /// `TickMath.getSqrtPriceAtTick(0)` as the initial price (1:1 ratio, suitable for an empty pool).
    /// @param projectId The ID of the project to set the pool for.
    /// @param fee The Uniswap V4 pool fee tier.
    /// @param tickSpacing The Uniswap V4 pool tick spacing.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param terminalToken The address of the terminal token that payments to the project are made in.
    function initializePoolFor(
        uint256 projectId,
        uint24 fee,
        int24 tickSpacing,
        uint256 twapWindow,
        address terminalToken
    )
        external;

    /// @notice Change the TWAP window for a project.
    /// @param projectId The ID of the project to set the TWAP window of.
    /// @param newWindow The new TWAP window.
    function setTwapWindowOf(uint256 projectId, uint256 newWindow) external;
}
