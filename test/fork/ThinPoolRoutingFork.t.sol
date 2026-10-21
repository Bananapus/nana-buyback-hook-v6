// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
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
    uint256 constant MINTED = 20_347_527_251_483_950_000; // the reported pay's tokens from issuance
    uint256 constant THIN_PAYER_RATE = 50_000; // tokens per ETH a mint gives the payer
    uint256 constant FAR_PAYER_RATE = 7750; // after project 7's reserved split

    ThinPoolSwapper swapper;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("base", BLOCK);
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
        assertEq(deployed, MINTED, "deployed hook minted 20.35");
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
            assertGt(deployed, sizes[i] * FAR_PAYER_RATE, "the deployed hook swaps");
            assertEq(updated, deployed, "same route and output");
        }
        (uint256 d, uint256 u) = _compare(THIN, 0.0001 ether);
        assertGt(d, 0.0001 ether * THIN_PAYER_RATE, "the deployed hook swaps");
        assertEq(u, d, "same route and output");
    }

    /// @dev The raw quote word in the hook spec, for a pay with an explicit quote.
    function _explicitQuoteRaw(
        uint256 pid,
        uint256 amount,
        uint256 weight,
        uint256 reservedPercent
    )
        internal
        view
        returns (uint256 raw)
    {
        bytes memory metadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId("pay", HOOK),
            dataToAdd: abi.encode(amount, uint256(1), false)
        });
        (, JBPayHookSpecification[] memory specs) = JBBuybackHook(payable(HOOK))
            .beforePayRecordedWith(
                JBBeforePayRecordedContext({
                terminal: address(TERMINAL),
                payer: PAYER,
                amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: amount
            }),
                projectId: pid,
                rulesetId: 0,
                beneficiary: PAYER,
                weight: weight,
                reservedPercent: reservedPercent,
                metadata: metadata
            })
            );
        bytes memory word = specs[0].metadata;
        // The raw quote is the 14th word of the spec metadata.
        assembly {
            raw := mload(add(word, mul(14, 32)))
        }
    }

    /// @dev An explicit-quote pay past the impact cap reports no raw quote, as the deployed hook does, so routers
    /// scoring routes by the larger of the raw quote and the minimum do not overrate it.
    function test_explicitQuotePastTheImpactCap_reportsNoRawQuote() public {
        uint256 deployed = _explicitQuoteRaw(FAR, 0.3 ether, 12_500e18, 3800);
        _upgrade();
        assertEq(_explicitQuoteRaw(FAR, 0.3 ether, 12_500e18, 3800), deployed, "same raw quote");
        assertEq(deployed, 0, "no raw quote past the cap");
    }

    /// @dev Pays `amount` for tokens, then sells them all into the pool.
    function dump(uint256 pid, uint256 amount) external {
        vm.prank(PAYER);
        TERMINAL.pay{value: amount}(pid, JBConstants.NATIVE_TOKEN, amount, address(this), 0, "", "");
        uint256 held = _token(pid).balanceOf(address(this));
        _token(pid).approve(address(swapper), held);
        swapper.swap(_key(pid), false, held);
    }

    /// @dev Across sizes, both pools, and a pool a third party just pumped or dumped by various amounts in the same
    /// block (spot off the TWAP, which the hook cannot tell from a front-run), the payer never gets less than from the
    /// deployed hook. Dumps push spot toward the issuance rate, where swaps partially fill.
    function test_neverBelowTheDeployedHook() public {
        uint256[8] memory sizes =
            [uint256(0.0002 ether), 0.002 ether, 0.003 ether, 0.01 ether, 0.03 ether, 0.3 ether, 1 ether, 3 ether];
        uint256[6] memory dumps = [uint256(0), 0.001 ether, 0.003 ether, 0.01 ether, 0.03 ether, 0.3 ether];
        for (uint256 p; p < 2; p++) {
            uint256 pid = p == 0 ? THIN : FAR;
            for (uint256 m; m < dumps.length + 1; m++) {
                uint256 snap = vm.snapshotState();
                if (m == dumps.length) {
                    swapper.swap{value: 0.001 ether}(_key(pid), true, 0.001 ether);
                } else if (dumps[m] != 0) {
                    // Skip dumps the pool cannot absorb.
                    try this.dump(pid, dumps[m]) {}
                    catch {
                        emit log_named_uint("skipped dump on project", pid);
                        vm.revertToState(snap);
                        continue;
                    }
                }
                for (uint256 i; i < sizes.length; i++) {
                    (uint256 deployed, uint256 updated) = _compare(pid, sizes[i]);
                    assertGe(updated, deployed, "payer never gets less");
                }
                vm.revertToState(snap);
            }
        }
    }

    /// @dev Sandwiches around a pay on the new route, front-run sizes `step` apart. The floor covers the whole
    /// settlement, so a front-run that forces a partial fill at the issuance-rate price limit cannot pass it with a
    /// diluted share: the payer keeps at least the floor, or the swap unwinds and the whole pay mints.
    function _sandwich(uint256 amount, uint256 minted, uint256 step) internal returns (uint256 best) {
        _upgrade();
        uint256 start = vm.snapshotState();
        uint256 honest = _pay(THIN, amount);
        vm.revertToState(start);
        for (uint256 k = 1; k < 30; k++) {
            uint256 x = k * step;
            uint256 snap = vm.snapshotState();
            uint256 bought = swapper.swap{value: x}(_key(THIN), true, x);
            uint256 victim = _pay(THIN, amount);
            _token(THIN).approve(address(swapper), bought);
            uint256 back = swapper.swap(_key(THIN), false, bought);
            vm.revertToState(snap);

            // The floor is 98% of a modeled output a little under `honest`.
            assertTrue(
                victim == minted || victim >= honest * 96 / 100, "the floor or a full mint, never a diluted fill"
            );
            if (back > x && back - x > best) best = back - x;
        }
    }

    function test_sandwich_reportedPay() public {
        uint256 best = _sandwich(TX_AMOUNT, MINTED, TX_AMOUNT / 16);
        // Observed on this state, not a bound the hook guarantees: up to about 1.3% of the pay.
        assertLt(best, TX_AMOUNT * 2 / 100, "attacker profit");
    }

    /// @dev At 0.003 ETH the floor (about 159) sits close to the 150-token mint. A floor pro-rated by consumed input
    /// let 0.0006-0.001 ETH front-runs force partial fills paying the victim 153.5-156.8 while netting the attacker up
    /// to
    /// 4.1% of the pay; checked on the whole settlement, those front-runs make the pay mint and lose the attacker
    /// money.
    function test_sandwich_partialFillCannotDiluteTheFloor() public {
        uint256 best = _sandwich(0.003 ether, 150e18, 0.0002 ether);
        // Observed on this sweep, not a bound: about 2.9% of the pay (4.1% when pro-rated); the best front-run is 3.1%.
        assertLt(best, 0.003 ether * 3 / 100, "attacker profit");
    }
}
