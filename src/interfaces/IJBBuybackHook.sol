// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import {IWETH9} from "./external/IWETH9.sol";

interface IJBBuybackHook is IJBPayHook, IJBRulesetDataHook, IUniswapV3SwapCallback {
    event Swap(
        uint256 indexed projectId, uint256 amountToSwapWith, IUniswapV3Pool pool, uint256 amountReceived, address caller
    );
    event Mint(uint256 indexed projectId, uint256 leftoverAmount, uint256 tokenCount, address caller);
    event PoolAdded(uint256 indexed projectId, address indexed terminalToken, address pool, address caller);
    event TwapWindowChanged(uint256 indexed projectId, uint256 oldWindow, uint256 newWindow, address caller);

    /// @notice The directory of terminals and controllers.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The contract that exposes price feeds.
    /// @return The prices contract.
    function PRICES() external view returns (IJBPrices);

    /// @notice The project registry.
    /// @return The projects contract.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice The token registry.
    /// @return The tokens contract.
    function TOKENS() external view returns (IJBTokens);

    /// @notice The maximum TWAP window that a project can set.
    /// @return The maximum TWAP window in seconds.
    function MAX_TWAP_WINDOW() external view returns (uint256);

    /// @notice The minimum TWAP window that a project can set.
    /// @return The minimum TWAP window in seconds.
    function MIN_TWAP_WINDOW() external view returns (uint256);

    /// @notice The denominator used when calculating TWAP slippage percent values.
    /// @return The slippage denominator.
    function TWAP_SLIPPAGE_DENOMINATOR() external view returns (uint256);

    /// @notice The uncertain slippage tolerance allowed when the swap size relative to liquidity is ambiguous.
    /// @return The uncertain TWAP slippage tolerance.
    function UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE() external view returns (uint256);

    /// @notice The address of the Uniswap v3 factory. Used to calculate pool addresses.
    /// @return The factory address.
    function UNISWAP_V3_FACTORY() external view returns (address);

    /// @notice The wETH contract.
    /// @return The WETH9 contract.
    function WETH() external view returns (IWETH9);

    /// @notice The Uniswap pool where a given project's token and terminal token pair are traded.
    /// @param projectId The ID of the project whose token is traded in the pool.
    /// @param terminalToken The address of the terminal token that the project accepts for payments.
    /// @return pool The Uniswap v3 pool.
    function poolOf(uint256 projectId, address terminalToken) external view returns (IUniswapV3Pool pool);

    /// @notice The address of each project's token.
    /// @param projectId The ID of the project.
    /// @return The address of the project's token.
    function projectTokenOf(uint256 projectId) external view returns (address);

    /// @notice The TWAP window for the given project, the period of time over which the TWAP is computed.
    /// @param projectId The ID of the project.
    /// @return window The TWAP window in seconds.
    function twapWindowOf(uint256 projectId) external view returns (uint256 window);

    /// @notice Set the pool to use for a given project and terminal token.
    /// @param projectId The ID of the project to set the pool for.
    /// @param fee The fee used in the pool being set.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param terminalToken The address of the terminal token that payments to the project are made in.
    /// @return newPool The pool that was set for the project and terminal token.
    function setPoolFor(
        uint256 projectId,
        uint24 fee,
        uint256 twapWindow,
        address terminalToken
    )
        external
        returns (IUniswapV3Pool newPool);

    /// @notice Change the TWAP window for a project.
    /// @param projectId The ID of the project to set the TWAP window of.
    /// @param newWindow The new TWAP window in seconds.
    function setTwapWindowOf(uint256 projectId, uint256 newWindow) external;
}
