// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";

/// @notice Exact-input swaps between native ETH (currency0) and a project token.
contract ThinPoolSwapper is IUnlockCallback {
    IPoolManager internal immutable PM;

    constructor(IPoolManager pm) {
        PM = pm;
    }

    function swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn) external payable returns (uint256 out) {
        out = abi.decode(PM.unlock(abi.encode(key, zeroForOne, amountIn, msg.sender)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        BalanceDelta d = PM.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 inUsed = uint256(uint128(zeroForOne ? -d.amount0() : -d.amount1()));
        uint256 out = uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
        if (zeroForOne) {
            PM.settle{value: inUsed}();
            PM.take(key.currency1, payer, out);
        } else {
            PM.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transferFrom(payer, address(PM), inUsed);
            PM.settle();
            PM.take(key.currency0, payer, out);
        }
        return abi.encode(out);
    }
}

/// @notice Thin-pool pay routing on Base's live pools, at the block before a Base project 13 pay
/// (tx 0x21e78614…) that minted 20.35 tokens while the pool paid about 25.7. Compares the deployed buyback hook with
/// this source deployed over it, through the real terminal → REVOwner → registry → hook path.
contract ThinPoolRoutingFork is Test {
    uint256 constant BLOCK = 52_877_279;
    uint256 constant TX_AMOUNT = 406_950_545_029_679;
    address constant HOOK = 0xB222Da5A71e8FB89a5A38b7c920EaB5DfbC74B91;
    IPoolManager constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IJBTerminal constant TERMINAL = IJBTerminal(0x130f5Dd2bD8805443Cf41755253D778a75a67f53);
    address constant PAYER = address(0xBEEF);
    uint256 constant THIN = 13; // pool price about 1.3x the mint rate, thin liquidity
    uint256 constant FAR = 7; // pool price about 31x the mint rate

    ThinPoolSwapper swapper;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_BASE_MAINNET", string("https://mainnet.base.org")), BLOCK);
        swapper = new ThinPoolSwapper(PM);
        vm.deal(address(this), 1000 ether);
        vm.deal(PAYER, 1000 ether);
    }

    function _key(uint256 pid) internal view returns (PoolKey memory) {
        return JBBuybackHook(payable(HOOK)).poolKeyOf(pid, address(0));
    }

    function _token(uint256 pid) internal view returns (IERC20) {
        return IERC20(Currency.unwrap(_key(pid).currency1));
    }

    function _upgrade() internal {
        JBBuybackHook live = JBBuybackHook(payable(HOOK));
        deployCodeTo(
            "src/JBBuybackHook.sol:JBBuybackHook",
            abi.encode(
                live.DIRECTORY(),
                live.PERMISSIONS(),
                live.PRICES(),
                live.PROJECTS(),
                live.TOKENS(),
                address(0),
                live.trustedForwarder()
            ),
            HOOK
        );
    }

    function _pay(uint256 pid, uint256 amount) internal returns (uint256 tokens) {
        IERC20 token = _token(pid);
        uint256 before = token.balanceOf(PAYER);
        vm.prank(PAYER);
        TERMINAL.pay{value: amount}(pid, JBConstants.NATIVE_TOKEN, amount, PAYER, 0, "", "");
        tokens = token.balanceOf(PAYER) - before;
    }

    /// @dev Tokens from the deployed hook, then from this source, for the same pay on the same state.
    function _compare(uint256 pid, uint256 amount) internal returns (uint256 deployed, uint256 updated) {
        uint256 snap = vm.snapshotState();
        deployed = _pay(pid, amount);
        vm.revertToState(snap);
        _upgrade();
        updated = _pay(pid, amount);
        vm.revertToState(snap);
    }

    function test_reportedPay_swapsInsteadOfMinting() public {
        (uint256 deployed, uint256 updated) = _compare(THIN, TX_AMOUNT);
        assertEq(deployed, 20_347_527_251_483_950_000, "deployed hook minted 20.35");
        // The pool pays about 25.74; the floor is 98% of the expected 25.73.
        assertGt(updated, 25.7e18, "pool route");
    }

    function test_largePay_swapsWhereSigmoidGaveUp() public {
        // The deployed hook's impact cap leaves no floor at 0.3 ETH, so it mints 3,750 (2,325 to the payer after the
        // reserved split); the pool pays about 54,650 before the same split.
        (uint256 deployed, uint256 updated) = _compare(FAR, 0.3 ether);
        assertEq(deployed, 2325e18, "deployed hook minted");
        emit log_named_decimal_uint("updated", updated, 18);
        assertGt(updated, deployed * 14, "pool route");
    }

    function test_paysTheDeployedHookAlreadySwaps_unchanged() public {
        uint256[4] memory sizes = [uint256(0.0001 ether), 0.001 ether, 0.01 ether, 0.1 ether];
        for (uint256 i; i < sizes.length; i++) {
            (uint256 deployed, uint256 updated) = _compare(FAR, sizes[i]);
            assertEq(updated, deployed, "same route and output");
        }
        (uint256 d, uint256 u) = _compare(THIN, 0.0001 ether);
        assertEq(u, d, "same route and output");
    }

    /// @dev Across sizes, both pools, and a pool a third party just pumped or dumped in the same block (spot off the
    /// TWAP, which the hook cannot tell from a front-run), the payer never gets less than from the deployed hook.
    function test_neverBelowTheDeployedHook() public {
        uint256[8] memory sizes =
            [uint256(0.0002 ether), 0.002 ether, 0.003 ether, 0.01 ether, 0.03 ether, 0.3 ether, 1 ether, 3 ether];
        for (uint256 p; p < 2; p++) {
            uint256 pid = p == 0 ? THIN : FAR;
            for (uint256 m; m < 3; m++) {
                uint256 snap = vm.snapshotState();
                if (m == 1) swapper.swap{value: 0.001 ether}(_key(pid), true, 0.001 ether);
                if (m == 2) {
                    vm.prank(PAYER);
                    TERMINAL.pay{value: 0.01 ether}(pid, JBConstants.NATIVE_TOKEN, 0.01 ether, address(this), 0, "", "");
                    uint256 held = _token(pid).balanceOf(address(this));
                    _token(pid).approve(address(swapper), held);
                    swapper.swap(_key(pid), false, held);
                }
                for (uint256 i; i < sizes.length; i++) {
                    (uint256 deployed, uint256 updated) = _compare(pid, sizes[i]);
                    assertGe(updated, deployed, "payer never gets less");
                }
                vm.revertToState(snap);
            }
        }
    }

    /// @dev A sandwich around the reported pay on the new route: the payer keeps at least the 98% floor, which beats
    /// the mint, and no front-run size nets the attacker more than the 2% buffer of the payment.
    function test_sandwich_boundedByTheBuffer() public {
        _upgrade();
        uint256 best;
        for (uint256 k; k < 12; k++) {
            uint256 x = TX_AMOUNT * (1 << k) / 32;
            uint256 snap = vm.snapshotState();
            uint256 bought = swapper.swap{value: x}(_key(THIN), true, x);
            uint256 victim = _pay(THIN, TX_AMOUNT);
            _token(THIN).approve(address(swapper), bought);
            uint256 back = swapper.swap(_key(THIN), false, bought);
            vm.revertToState(snap);

            assertGe(victim, 20_347_527_251_483_950_000, "never below the mint");
            if (back > x && back - x > best) best = back - x;
        }
        assertLe(best, TX_AMOUNT * 2 / 100, "attacker takes at most the buffer");
    }
}
