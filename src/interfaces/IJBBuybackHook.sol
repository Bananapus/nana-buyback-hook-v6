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

/// @notice A hook that facilitates buybacks of project tokens using Uniswap V4 pools.
interface IJBBuybackHook is IJBPayHook, IJBRulesetDataHook {
    /// @notice Emitted when tokens are minted instead of swapped.
    /// @param projectId The ID of the project whose tokens were minted.
    /// @param leftoverAmount The amount left over after minting.
    /// @param tokenCount The number of tokens minted.
    /// @param caller The address that called the function.
    event Mint(uint256 indexed projectId, uint256 leftoverAmount, uint256 tokenCount, address caller);

    /// @notice Emitted when a pool is added for a project and terminal token.
    /// @param projectId The ID of the project the pool was added for.
    /// @param terminalToken The terminal token address.
    /// @param poolId The ID of the Uniswap V4 pool.
    /// @param caller The address that called the function.
    event PoolAdded(uint256 indexed projectId, address indexed terminalToken, PoolId poolId, address caller);

    /// @notice Emitted when a swap is performed through the buyback hook.
    /// @param projectId The ID of the project the swap was performed for.
    /// @param amountToSwapWith The amount used for the swap.
    /// @param poolId The ID of the Uniswap V4 pool used.
    /// @param amountReceived The amount of project tokens received from the swap.
    /// @param caller The address that called the function.
    event Swap(
        uint256 indexed projectId,
        uint256 amountToSwapWith,
        PoolId indexed poolId,
        uint256 amountReceived,
        address caller
    );

    /// @notice Emitted when the TWAP window is changed for a project.
    /// @param projectId The ID of the project whose TWAP window was changed.
    /// @param oldWindow The previous TWAP window value.
    /// @param newWindow The new TWAP window value.
    /// @param caller The address that called the function.
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

    /// @notice The Uniswap V4 pool manager.
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

    /// @notice The WETH contract.
    /// @return The WETH9 contract.
    function WETH() external view returns (IWETH9);

    /// @notice The Uniswap V4 pool key for a given project and terminal token.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @return key The pool key.
    function poolKeyOf(uint256 projectId, address terminalToken) external view returns (PoolKey memory key);

    /// @notice The project token address for a given project.
    /// @param projectId The ID of the project.
    /// @return projectTokenOf The project token address.
    function projectTokenOf(uint256 projectId) external view returns (address projectTokenOf);

    /// @notice The TWAP window for a given project.
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

    /// @notice Set the TWAP window for a given project.
    /// @param projectId The ID of the project to set the TWAP window for.
    /// @param newWindow The new TWAP window in seconds.
    function setTwapWindowOf(uint256 projectId, uint256 newWindow) external;
}
