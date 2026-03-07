// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// @notice Minimal mock of the Uniswap V4 PoolManager for testing.
/// Implements only the methods needed by JBBuybackHook:
///   - unlock (calls back IUnlockCallback on msg.sender)
///   - swap (returns configurable deltas)
///   - settle / sync / take (handle token transfers)
///   - extsload (returns configurable slot data for StateLibrary.getSlot0 / getLiquidity)
contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    //*********************************************************************//
    // ---------------------- configurable storage ---------------------- //
    //*********************************************************************//

    /// @notice Storage slots readable via extsload, keyed by slot hash.
    mapping(bytes32 => bytes32) public slots;

    /// @notice Configurable swap deltas returned by swap().
    int128 public mockDelta0;
    int128 public mockDelta1;

    /// @notice Whether swap was called during the current unlock.
    bool public swapCalled;

    /// @notice If true, unlock() reverts instead of calling back.
    bool public shouldRevertOnUnlock;

    //*********************************************************************//
    // ---------------------- configuration setters --------------------- //
    //*********************************************************************//

    /// @notice Store a raw bytes32 at a given slot key.
    function setSlot(bytes32 slot, bytes32 value) external {
        slots[slot] = value;
    }

    /// @notice Convenience: encode and store Slot0 data for a given PoolId.
    /// @dev Matches the StateLibrary layout:
    ///   lower 160 bits = sqrtPriceX96
    ///   bits [160..183] = tick (int24, sign-extended from 24 bits)
    ///   bits [184..207] = protocolFee (uint24)
    ///   bits [208..231] = lpFee (uint24)
    /// @param poolId The pool ID to set Slot0 for.
    /// @param sqrtPriceX96 The sqrt price.
    /// @param tick The current tick.
    /// @param lpFee The LP fee (in hundredths of a bip).
    function setSlot0(PoolId poolId, uint160 sqrtPriceX96, int24 tick, uint24 lpFee) external {
        // POOLS_SLOT = bytes32(uint256(6)) per StateLibrary
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(uint256(6))));
        // Pack: sqrtPriceX96 in lower 160, tick in next 24, protocolFee in next 24, lpFee in next 24
        bytes32 data = bytes32(uint256(sqrtPriceX96))
            | bytes32(uint256(uint24(tick)) << 160)
            | bytes32(uint256(lpFee) << 208);
        slots[stateSlot] = data;
    }

    /// @notice Convenience: store the liquidity value for a given PoolId.
    /// @dev StateLibrary.LIQUIDITY_OFFSET = 3, so liquidity is at stateSlot + 3.
    function setLiquidity(PoolId poolId, uint128 liquidity) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(uint256(6))));
        bytes32 liquiditySlot = bytes32(uint256(stateSlot) + 3);
        slots[liquiditySlot] = bytes32(uint256(liquidity));
    }

    /// @notice Set the deltas that swap() will return.
    function setMockDeltas(int128 delta0, int128 delta1) external {
        mockDelta0 = delta0;
        mockDelta1 = delta1;
    }

    /// @notice If true, unlock() will revert.
    function setShouldRevertOnUnlock(bool _shouldRevert) external {
        shouldRevertOnUnlock = _shouldRevert;
    }

    //*********************************************************************//
    // ---------------------- IExtsload (partial) ----------------------- //
    //*********************************************************************//

    /// @notice Single-slot extsload used by StateLibrary.getSlot0 and getLiquidity.
    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }

    /// @notice Multi-slot extsload used by StateLibrary for multi-word reads.
    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        for (uint256 i = 0; i < nSlots; i++) {
            values[i] = slots[bytes32(uint256(startSlot) + i)];
        }
    }

    /// @notice Batch extsload (sparse reads).
    function extsload(bytes32[] calldata requestedSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](requestedSlots.length);
        for (uint256 i = 0; i < requestedSlots.length; i++) {
            values[i] = slots[requestedSlots[i]];
        }
    }

    //*********************************************************************//
    // ---------------------- IPoolManager methods ---------------------- //
    //*********************************************************************//

    /// @notice Calls unlockCallback on msg.sender (simulates V4 unlock flow).
    function unlock(bytes calldata data) external returns (bytes memory) {
        if (shouldRevertOnUnlock) revert("MockPoolManager: forced revert");
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    /// @notice Returns the pre-configured mock deltas.
    function swap(PoolKey memory, SwapParams memory, bytes calldata) external returns (BalanceDelta) {
        swapCalled = true;
        return toBalanceDelta(mockDelta0, mockDelta1);
    }

    /// @notice No-op settle. Returns msg.value for native, 0 for ERC-20.
    function settle() external payable returns (uint256) {
        return msg.value;
    }

    /// @notice No-op sync (checkpoint for ERC-20 balance accounting).
    function sync(Currency) external {}

    /// @notice Transfers tokens from this mock to the recipient.
    /// @dev For tests, the mock must be pre-funded with project tokens.
    function take(Currency currency, address to, uint256 amount) external {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            require(success, "MockPoolManager: ETH transfer failed");
        } else {
            bool success = IERC20(token).transfer(to, amount);
            require(success, "MockPoolManager: ERC20 transfer failed");
        }
    }

    /// @notice Accept ETH (for native token settlements).
    receive() external payable {}
}
