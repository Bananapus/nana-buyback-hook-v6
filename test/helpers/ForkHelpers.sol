// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";

/// @notice Simple mintable/burnable ERC20 for test project tokens.
contract ForkProjectToken is ERC20 {
    constructor() ERC20("ForkProjectToken", "FPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Simple mintable ERC20 for ERC-20 terminal token tests.
contract ForkTerminalToken is ERC20 {
    constructor() ERC20("ForkTerminalToken", "FTT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Helper that adds liquidity to a V4 pool via the unlock/callback pattern.
contract ForkLiquidityHelper is IUnlockCallback {
    IPoolManager public immutable POOL_MANAGER;

    struct AddLiqParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    constructor(IPoolManager _poolManager) {
        POOL_MANAGER = _poolManager;
    }

    function addLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    )
        external
        payable
    {
        bytes memory data = abi.encode(
            AddLiqParams({key: key, tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta})
        );
        POOL_MANAGER.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "only PM");

        AddLiqParams memory params = abi.decode(data, (AddLiqParams));

        (BalanceDelta callerDelta,) = POOL_MANAGER.modifyLiquidity(
            params.key,
            ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        // Settle negative deltas (caller owes pool).
        _settleIfNegative(params.key.currency0, callerDelta.amount0());
        _settleIfNegative(params.key.currency1, callerDelta.amount1());

        // Take positive deltas (pool owes caller). Unlikely when adding liquidity, but handle it.
        _takeIfPositive(params.key.currency0, callerDelta.amount0());
        _takeIfPositive(params.key.currency1, callerDelta.amount1());

        return abi.encode(callerDelta);
    }

    function _settleIfNegative(Currency currency, int128 delta) internal {
        if (delta >= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(uint128(-delta));

        if (currency.isAddressZero()) {
            POOL_MANAGER.settle{value: amount}();
        } else {
            POOL_MANAGER.sync(currency);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        }
    }

    function _takeIfPositive(Currency currency, int128 delta) internal {
        if (delta <= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(uint128(delta));
        POOL_MANAGER.take(currency, address(this), amount);
    }

    receive() external payable {}
}

/// @notice Minimal controller that actually mints/burns project tokens for fork tests.
/// @dev Used instead of a blanket `vm.mockCall` so that the hook's balance-delta
/// accounting in `afterCashOutRecordedWith` (L-24 FOT fix) sees real token movements.
contract ForkController {
    ForkProjectToken internal immutable TOKEN;

    constructor(ForkProjectToken token) {
        TOKEN = token;
    }

    function mintTokensOf(
        uint256,
        uint256 tokenCount,
        address beneficiary,
        string memory,
        bool
    )
        external
        returns (uint256)
    {
        TOKEN.mint(beneficiary, tokenCount);
        return tokenCount;
    }

    function burnTokensOf(address holder, uint256, uint256 tokenCount, string memory) external {
        TOKEN.burn(holder, tokenCount);
    }
}

/// @notice Test harness exposing internal state for fork tests.
contract ForTest_BuybackHook is JBBuybackHook {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBPrices prices,
        IJBProjects projects,
        IJBTokens tokens,
        IPoolManager poolManager,
        IHooks oracleHook,
        address trustedForwarder
    )
        JBBuybackHook(directory, permissions, prices, projects, tokens, poolManager, oracleHook, trustedForwarder)
    {}
}
