// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IWETH9} from "./external/IWETH9.sol";

interface IJBBuybackHook is IJBPayHook, IJBRulesetDataHook {
    event Swap(
        uint256 indexed projectId,
        uint256 amountToSwapWith,
        PoolId indexed poolId,
        uint256 amountReceived,
        address caller
    );
    event Mint(uint256 indexed projectId, uint256 leftoverAmount, uint256 tokenCount, address caller);
    event PoolAdded(uint256 indexed projectId, address indexed terminalToken, PoolId poolId, address caller);
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

    function POOL_MANAGER() external view returns (IPoolManager);
    function WETH() external view returns (IWETH9);

    function poolKeyOf(uint256 projectId, address terminalToken) external view returns (PoolKey memory key);
    function projectTokenOf(uint256 projectId) external view returns (address projectTokenOf);
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
    function setTwapWindowOf(uint256 projectId, uint256 newWindow) external;
}
