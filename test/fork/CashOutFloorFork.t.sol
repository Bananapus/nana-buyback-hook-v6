// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {JBSwapLib} from "src/libraries/JBSwapLib.sol";

/// @notice Exact-input swaps with a price limit on a native/project-token pool.
contract CashOutFloorSwapper is IUnlockCallback {
    IPoolManager internal immutable PM;

    constructor(IPoolManager pm) {
        PM = pm;
    }

    receive() external payable {}

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 limit
    )
        external
        payable
        returns (uint256 used, uint256 out)
    {
        (used, out) =
            abi.decode(PM.unlock(abi.encode(key, zeroForOne, amountIn, limit, msg.sender)), (uint256, uint256));
        if (address(this).balance != 0) payable(msg.sender).transfer(address(this).balance);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, uint160, address));
        BalanceDelta d = PM.swap({
            key: key,
            params: SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
            hookData: ""
        });
        uint256 used = uint256(uint128(zeroForOne ? -d.amount0() : -d.amount1()));
        uint256 out = uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
        if (zeroForOne) {
            PM.settle{value: used}();
            PM.take({currency: key.currency1, to: payer, amount: out});
        } else {
            PM.sync(key.currency1);
            require(IERC20(Currency.unwrap(key.currency1)).transferFrom(payer, address(PM), used));
            PM.settle();
            PM.take({currency: key.currency0, to: payer, amount: out});
        }
        return abi.encode(used, out);
    }
}

/// @notice Cash-outs on Base's live projects 7 (10% tax, pool about 38x the reclaim rate) and 13 (50% tax, thin pool),
/// through the real terminal -> REVOwner -> registry -> hook path, comparing the deployed 1.4 hook with this source
/// deployed over it and with reclaiming everything.
/// @dev A holder's value is the ETH received plus any returned project tokens valued at what reclaiming them right
/// after pays (a plain cash-out through the same path, so it includes the revnet's fee tranche on those tokens).
contract CashOutFloorFork is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant BLOCK = 52_877_279;
    address constant HOOK = 0xB222Da5A71e8FB89a5A38b7c920EaB5DfbC74B91;
    address constant REGISTRY = 0x72F55a54CD53410a5Ff175508a5A384227081788;
    IPoolManager constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IJBCashOutTerminal constant TERMINAL = IJBCashOutTerminal(0x130f5Dd2bD8805443Cf41755253D778a75a67f53);
    address constant HOLDER = address(0xCA5401);

    CashOutFloorSwapper swapper;
    bytes deployedCode;
    bytes updatedCode;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("base", BLOCK);
        swapper = new CashOutFloorSwapper(PM);
        vm.deal(address(this), 1_000_000 ether);
        deployedCode = HOOK.code;
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
        updatedCode = HOOK.code;
        // The constructor only sets immutables, so etching the deployed code back restores the deployed hook.
        vm.etch(HOOK, deployedCode);
    }

    function _key(uint256 pid) internal view returns (PoolKey memory) {
        return JBBuybackHook(payable(HOOK)).poolKeyOf(pid, address(0));
    }

    function _token(uint256 pid) internal view returns (IERC20) {
        return IERC20(Currency.unwrap(_key(pid).currency1));
    }

    function _skip() internal pure returns (bytes memory) {
        return JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId("cashOut", REGISTRY),
            dataToAdd: abi.encode(uint256(0), true)
        });
    }

    function sellPool(uint256 pid, uint256 m, uint160 limit) public returns (uint256 used, uint256 got) {
        IERC20 t = _token(pid);
        deal(address(t), address(this), t.balanceOf(address(this)) + m);
        t.approve(address(swapper), m);
        (used, got) = swapper.swap(_key(pid), false, m, limit);
    }

    function buyPool(uint256 pid, uint256 ethIn, uint160 limit) public returns (uint256 used, uint256 got) {
        (used, got) = swapper.swap{value: ethIn}(_key(pid), true, ethIn, limit);
    }

    function _sqrtP(uint256 pid) internal view returns (uint160 sp) {
        (sp,,,) = PM.getSlot0(_key(pid).toId());
    }

    /// @dev Gross reclaim per token at a small size, in wei per 1e18 tokens.
    function _smallRate(uint256 pid) internal view returns (uint256) {
        uint256 n = pid == 7 ? 1000e18 : 1e18;
        (, uint256 g,,) =
            TERMINAL.previewCashOutFrom(HOLDER, pid, n, JBConstants.NATIVE_TOKEN, payable(HOLDER), _skip());
        return g * 1e18 / n;
    }

    /// @dev Pool states. 0 as-is; 1 a third party buys until ETH per token is 25% higher; 2 and 3 a third party sells
    /// until the pool's marginal net rate is 1.5x and 0.8x the small net reclaim rate; 4 spot 20% below the TWAP. Each
    /// moved state is held for `held` seconds (0, a quarter or half of the TWAP window, or the whole window, after
    /// which a dust swap writes the observation).
    function _setState(uint256 pid, uint256 state, uint256 held) internal returns (bool) {
        if (state == 0) return true;
        uint160 sp = _sqrtP(pid);
        if (state == 1) {
            buyPool(pid, 10_000 ether, uint160(uint256(sp) * 1e9 / 1_118_033_989));
        } else if (state == 4) {
            sellPool(pid, 1e30, uint160(uint256(sp) * 1_118_033_989 / 1e9));
        } else {
            uint256 net = _smallRate(pid) * 975 / 1000 * 975 / 1000;
            uint256 target = state == 2 ? net * 3 / 2 : net * 4 / 5;
            // tokens per ETH at a net rate, after the pool's 1% fee
            uint160 limit = uint160(Math.sqrt(Math.mulDiv(99e16, uint256(1) << 192, target)));
            if (limit <= sp) return false;
            sellPool(pid, 1e30, limit);
        }
        if (held != 0) {
            vm.warp(block.timestamp + held);
            vm.roll(block.number + held / 2);
            if (held >= 1800 && PM.getLiquidity(_key(pid).toId()) != 0) {
                sellPool(pid, 1e9, TickMath.MAX_SQRT_PRICE - 1);
            }
        }
        return true;
    }

    /// @dev The holder's ETH and returned tokens for cashing out `n`, plus what reclaiming the returned tokens pays.
    function cashOut(uint256 pid, uint256 n, bytes memory metadata) public returns (uint256 value, uint256 back) {
        IERC20 t = _token(pid);
        deal(address(t), HOLDER, n);
        uint256 before = HOLDER.balance;
        vm.prank(HOLDER);
        TERMINAL.cashOutTokensOf(HOLDER, pid, n, JBConstants.NATIVE_TOKEN, 0, payable(HOLDER), metadata);
        back = t.balanceOf(HOLDER);
        if (back != 0) {
            vm.prank(HOLDER);
            TERMINAL.cashOutTokensOf(HOLDER, pid, back, JBConstants.NATIVE_TOKEN, 0, payable(HOLDER), _skip());
        }
        value = HOLDER.balance - before;
    }

    function _sizes(uint256 pid) internal pure returns (uint256[7] memory) {
        return pid == 7
            ? [uint256(1000e18), 10_000e18, 100_000e18, 300_000e18, 1_000_000e18, 3_000_000e18, 10_000_000e18]
            : [uint256(1e18), 5e18, 20e18, 50e18, 100e18, 200e18, 400e18];
    }

    /// @dev Holder value through the deployed hook, this source, and reclaiming everything, on the current state, and
    /// the tokens this source returned unsold.
    function compare(
        uint256 pid,
        uint256 n
    )
        public
        returns (uint256 deployed, uint256 updated, uint256 reclaim, uint256 returned)
    {
        uint256 snap = vm.snapshotState();
        (deployed,) = cashOut(pid, n, "");
        vm.revertToState(snap);
        (reclaim,) = cashOut(pid, n, _skip());
        vm.revertToState(snap);
        vm.etch(HOOK, updatedCode);
        (updated, returned) = cashOut(pid, n, "");
        vm.revertToStateAndDelete(snap);
    }

    /// @dev One pool state for one project, every size. Returns the cells where this source gives the holder less than
    /// reclaiming everything but no less than the deployed hook (`inherited`), and the cells where it gives less than
    /// the deployed hook (`staleDump`). Each must be one of the accepted exceptions.
    function stateRow(uint256 pid, uint256 state, uint256 held)
        external
        returns (uint256 inherited, uint256 staleDump)
    {
        if (!_setState(pid, state, held)) return (0, 0);
        uint256[7] memory sizes = _sizes(pid);
        for (uint256 i; i < 7; i++) {
            (uint256 deployed, uint256 updated, uint256 reclaim, uint256 returned) = this.compare(pid, sizes[i]);
            emit log_named_string(
                "row",
                string.concat(
                    vm.toString(pid),
                    " s",
                    vm.toString(state),
                    " h",
                    vm.toString(held),
                    " n",
                    vm.toString(sizes[i] / 1e18),
                    " 1.4=",
                    vm.toString(deployed),
                    " 2.0=",
                    vm.toString(updated),
                    " reclaim=",
                    vm.toString(reclaim),
                    " returned=",
                    vm.toString(returned / 1e18)
                )
            );
            if (updated < deployed) {
                // Accepted: a dump inside the TWAP window leaves a stale quote that routes a large cash-out to the
                // pool. Spot is past the sale's limit, but the pool holds little depth before it, so the sale fills
                // a small part and reclaiming the returned tokens pays the revnet's 2.5% token tranche a second time.
                assertTrue(pid == 7 && state == 2 && held < 1800, "below 1.4 outside a stale dump");
                assertGe(updated, deployed * 974 / 1000, "stale dump costs at most the second tranche");
                staleDump++;
            } else if (updated < reclaim) {
                // Accepted: the deployed hook lands on the same value, below reclaiming everything.
                inherited++;
            }
            if (updated < reclaim) assertGe(updated, reclaim * 974 / 1000, "at most the second tranche below reclaim");
        }
    }

    /// @dev Holder value is the ETH received plus what reclaiming any returned tokens right after pays. States: as-is,
    /// a 25% pump, dumps to 1.5x and 0.8x the reclaim rate, and spot 20% below the TWAP, each held 0 seconds, a
    /// quarter or half of the 30-minute TWAP window, or the whole window.
    function _grid(uint256 pid) internal returns (uint256 inherited, uint256 staleDump) {
        uint256[5] memory states = [uint256(0), 1, 2, 3, 4];
        uint256[4] memory helds = [uint256(0), 450, 900, 1800];
        for (uint256 s; s < 5; s++) {
            for (uint256 h; h < 4; h++) {
                if (s == 0 && h != 0) continue;
                uint256 snap = vm.snapshotState();
                (uint256 a, uint256 b) = this.stateRow(pid, states[s], helds[h]);
                vm.revertToStateAndDelete(snap);
                inherited += a;
                staleDump += b;
            }
        }
    }

    function test_cashOutsNeverBelowTheDeployedHookOrReclaim_project7() public {
        (uint256 inherited, uint256 staleDump) = _grid(7);
        assertEq(inherited, 20, "cells below reclaim exactly as with the deployed hook");
        assertEq(staleDump, 4, "stale-dump cells below the deployed hook");
    }

    function test_cashOutsNeverBelowTheDeployedHookOrReclaim_project13() public {
        (uint256 inherited, uint256 staleDump) = _grid(13);
        assertEq(inherited, 0, "cells below reclaim exactly as with the deployed hook");
        assertEq(staleDump, 0, "stale-dump cells below the deployed hook");
    }

    /// @dev An attacker sells `d` tokens into the pool, the victim cashes out `n`, and the attacker buys back with the
    /// ETH from the first sale. Returns the victim's value and the attacker's token gain.
    function sandwich(uint256 pid, uint256 n, uint256 d, bool updated) external returns (uint256 victim, int256 gain) {
        uint256 snap = vm.snapshotState();
        if (updated) vm.etch(HOOK, updatedCode);
        uint256 got;
        if (d != 0) (, got) = sellPool(pid, d, TickMath.MAX_SQRT_PRICE - 1);
        (victim,) = cashOut(pid, n, "");
        if (d != 0) {
            (, uint256 back) = buyPool(pid, got, TickMath.MIN_SQRT_PRICE + 1);
            gain = int256(back) - int256(d);
        }
        vm.revertToStateAndDelete(snap);
    }

    /// @dev The attacker's best front-run from 1/64 to 8x the cash-out, with each hook. Under this source the victim
    /// keeps at least what the deployed hook's victim keeps under its own best attack, and never falls more than the
    /// second token tranche below reclaiming everything.
    function test_cashOutSandwichBestResponse_project7() public {
        _sandwichSearch(7);
    }

    function test_cashOutSandwichBestResponse_project13() public {
        _sandwichSearch(13);
    }

    function _sandwichSearch(uint256 pid) internal {
        uint256[7] memory sizes = _sizes(pid);
        for (uint256 i; i < 7; i++) {
            (,, uint256 reclaim,) = this.compare(pid, sizes[i]);
            uint256 deployedVictim;
            for (uint256 u; u < 2; u++) {
                (uint256 honest,) = this.sandwich(pid, sizes[i], 0, u == 1);
                int256 bestGain;
                uint256 bestD;
                uint256 victimAtBest = honest;
                for (uint256 k; k < 10; k++) {
                    uint256 d = sizes[i] * (1 << k) / 64;
                    (uint256 victim, int256 gain) = this.sandwich(pid, sizes[i], d, u == 1);
                    if (gain > bestGain) (bestGain, bestD, victimAtBest) = (gain, d, victim);
                }
                emit log_named_string(
                    "sandwich",
                    string.concat(
                        vm.toString(pid),
                        u == 1 ? " 2.0" : " 1.4",
                        " n",
                        vm.toString(sizes[i] / 1e18),
                        " d",
                        vm.toString(bestD / 1e18),
                        " gain",
                        vm.toString(bestGain),
                        " honest",
                        vm.toString(honest),
                        " victim",
                        vm.toString(victimAtBest)
                    )
                );
                if (u == 0) {
                    deployedVictim = victimAtBest;
                    continue;
                }
                assertGe(victimAtBest, reclaim * 974 / 1000, "at most the second tranche below reclaim");
                assertGe(victimAtBest, deployedVictim, "attacked at or above the deployed hook's attacked victim");
            }
        }
    }

    /// @dev Over any surplus, supply and tax on the live pools in each grid state, a cash-out routed on the
    /// expected-output floor has a sale limit at or above net reclaim and below that floor, with spot short of the
    /// limit's price, so the sale can start and never undercuts reclaiming, and it is at most half the supply, where
    /// the limit is exact.
    function testFuzz_expectedOutputRoutesOnlyWhenTheSaleCanStart(
        bool p7,
        uint256 count,
        uint256 supply,
        uint256 surplus,
        uint256 tax,
        uint8 state
    )
        public
    {
        if (!_setState(p7 ? 7 : 13, state % 5, 0)) return;
        vm.etch(HOOK, updatedCode);
        supply = bound(supply, 1e18, 1e30);
        count = bound(count, 1, supply);
        surplus = bound(surplus, 0, 1e24);
        tax = bound(tax, 0, JBConstants.MAX_CASH_OUT_TAX_RATE);
        vm.prank(address(TERMINAL));
        (,,,, JBCashOutHookSpecification[] memory specs) = JBBuybackHook(payable(HOOK))
            .beforeCashOutRecordedWith(
                JBBeforeCashOutRecordedContext({
                terminal: address(TERMINAL),
                holder: HOLDER,
                projectId: p7 ? 7 : 13,
                rulesetId: 0,
                cashOutCount: count,
                totalSupply: supply,
                surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: surplus
            }),
                scopeCashOutsToLocalBalances: false,
                cashOutTaxRate: tax,
                beneficiaryIsFeeless: false,
                metadata: ""
            })
            );
        if (specs.length == 0 || specs[0].noop) return;
        (uint256 floor,, uint256 netDirect,,,,,, uint256 limit) =
            abi.decode(specs[0].metadata, (uint256, uint256, uint256, int24, uint128, PoolId, uint256, bool, uint256));
        if (limit == 0) return;
        assertGt(floor, limit, "the expected output beats the count at the limit rate");
        assertGe(limit, netDirect, "the limit is at or above net reclaim");
        assertLe(2 * count, supply, "at most half the supply");
        assertLt(
            _sqrtP(p7 ? 7 : 13),
            JBSwapLib.sqrtPriceLimitFromAmounts({amountIn: count, minimumAmountOut: limit, zeroForOne: false}),
            "spot is short of the limit, so the sale can start"
        );
    }
}
