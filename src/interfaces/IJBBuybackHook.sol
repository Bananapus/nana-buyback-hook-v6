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
        uint256 indexed projectId, uint256 amountToSwapWith, PoolId indexed poolId, uint256 amountReceived, address caller
    );
    event Mint(uint256 indexed projectId, uint256 leftoverAmount, uint256 tokenCount, address caller);
    event PoolAdded(uint256 indexed projectId, address indexed terminalToken, PoolId poolId, address caller);
    event TwapWindowChanged(uint256 indexed projectId, uint256 oldWindow, uint256 newWindow, address caller);

    function DIRECTORY() external view returns (IJBDirectory);
    function PRICES() external view returns (IJBPrices);
    function PROJECTS() external view returns (IJBProjects);
    function TOKENS() external view returns (IJBTokens);
    function MAX_TWAP_WINDOW() external view returns (uint256);
    function MIN_TWAP_WINDOW() external view returns (uint256);
    function TWAP_SLIPPAGE_DENOMINATOR() external view returns (uint256);
    function UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE() external view returns (uint256);

    function POOL_MANAGER() external view returns (IPoolManager);
    function WETH() external view returns (IWETH9);

    function poolKeyOf(uint256 projectId, address terminalToken)
        external
        view
        returns (PoolKey memory key);
    function projectTokenOf(uint256 projectId) external view returns (address projectTokenOf);
    function twapWindowOf(uint256 projectId) external view returns (uint256 window);

    function setPoolFor(
        uint256 projectId,
        PoolKey calldata poolKey,
        uint256 twapWindow,
        address terminalToken
    ) external;
    function setTwapWindowOf(uint256 projectId, uint256 newWindow) external;
}
