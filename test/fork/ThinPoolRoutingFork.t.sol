// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
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

    /// @dev Pays larger than the pool can take above the issuance rate swap until the pool reaches that rate and mint
    /// the rest. Project 13's pool takes about 0.0021 ETH for 14.28 extra tokens; project 7's about 1.23 ETH for about
    /// 43,100 extra tokens after the reserved split.
    function test_largePay_swapsToTheIssuanceRateAndMintsTheRest() public {
        (uint256 deployed, uint256 updated) = _compare(THIN, 0.01 ether);
        assertEq(deployed, 500e18, "deployed hook minted");
        assertGt(updated, 514.28e18, "pool leg plus mint");

        (deployed, updated) = _compare(FAR, 10 ether);
        assertEq(deployed, 77_500e18, "deployed hook minted");
        assertGt(updated, 120_611e18, "pool leg plus mint");
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

    /// @dev The raw quote word in the hook spec, for a pay with the given payer metadata.
    function _rawQuote(
        uint256 pid,
        uint256 amount,
        uint256 weight,
        uint256 reservedPercent,
        bytes memory metadata
    )
        internal
        view
        returns (uint256 raw)
    {
        bytes memory word =
            _spec({
            pid: pid, amount: amount, weight: weight, reservedPercent: reservedPercent, metadata: metadata, payer: PAYER
        }).metadata;
        // The raw quote is the 14th word of the spec metadata.
        assembly {
            raw := mload(add(word, mul(14, 32)))
        }
    }

    /// @dev The hook spec for a pay from `payer`.
    function _spec(
        uint256 pid,
        uint256 amount,
        uint256 weight,
        uint256 reservedPercent,
        bytes memory metadata,
        address payer
    )
        internal
        view
        returns (JBPayHookSpecification memory)
    {
        (, JBPayHookSpecification[] memory specs) = JBBuybackHook(payable(HOOK))
            .beforePayRecordedWith(
                JBBeforePayRecordedContext({
                terminal: address(TERMINAL),
                payer: payer,
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
        return specs[0];
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
        returns (uint256)
    {
        return _rawQuote({
            pid: pid,
            amount: amount,
            weight: weight,
            reservedPercent: reservedPercent,
            metadata: JBMetadataResolver.addToMetadata({
                originalMetadata: "",
                idToAdd: JBMetadataResolver.getId("pay", HOOK),
                dataToAdd: abi.encode(amount, uint256(1), false)
            })
        });
    }

    /// @dev An explicit-quote pay past the impact cap reports no raw quote, as the deployed hook does, so routers
    /// scoring routes by the larger of the raw quote and the minimum do not overrate it.
    function test_explicitQuotePastTheImpactCap_reportsNoRawQuote() public {
        uint256 deployed = _explicitQuoteRaw(FAR, 0.3 ether, 12_500e18, 3800);
        _upgrade();
        assertEq(_explicitQuoteRaw(FAR, 0.3 ether, 12_500e18, 3800), deployed, "same raw quote");
        assertEq(deployed, 0, "no raw quote past the cap");
    }

    /// @dev A no-quote pay publishes its expected settlement as the raw quote, so route scorers rank it by what it
    /// settles. Across sigmoid-mode, full-input-floor and partial-fill pays on both pools, the published quote
    /// matches the tokens the pay settles, scaled to the payer's share of a reserved split, within 0.02%.
    function test_rawQuote_matchesSettledTokens() public {
        _upgrade();
        uint256[6] memory pids = [FAR, FAR, FAR, FAR, THIN, THIN];
        uint256[6] memory sizes = [uint256(0.1 ether), 0.3 ether, 3 ether, 10 ether, 0.01 ether, 10 ether];
        for (uint256 i; i < sizes.length; i++) {
            bool far = pids[i] == FAR;
            uint256 raw = _rawQuote({
                pid: pids[i],
                amount: sizes[i],
                weight: far ? 12_500e18 : 50_000e18,
                reservedPercent: far ? 3800 : 0,
                metadata: ""
            });
            uint256 snap = vm.snapshotState();
            uint256 settled = _pay(pids[i], sizes[i]);
            vm.revertToState(snap);
            emit log_named_decimal_uint("published quote", raw, 18);
            emit log_named_decimal_uint("payer tokens", settled, 18);
            assertApproxEqRel(far ? raw * 6200 / 10_000 : raw, settled, 2e14, "quote matches settlement");
        }
    }

    /// @dev A same-terminal split forwards the hook only its post-fee amount, so the reported pay arriving as one
    /// mints, as it does on the deployed hook, while the same pay from an outside payer routes to the pool.
    function test_sameTerminalSplit_keepsTheSigmoidRoute() public {
        _upgrade();
        JBPayHookSpecification memory outside =
            _spec({pid: THIN, amount: TX_AMOUNT, weight: 50_000e18, reservedPercent: 0, metadata: "", payer: PAYER});
        JBPayHookSpecification memory split = _spec({
            pid: THIN, amount: TX_AMOUNT, weight: 50_000e18, reservedPercent: 0, metadata: "", payer: address(TERMINAL)
        });
        assertFalse(outside.noop, "outside pay routes");
        assertTrue(split.noop, "split pay mints");
    }

    /// @dev A pay larger than the pool can take above the issuance rate, right after a small buy moved the pool, keeps
    /// the full-input floor (98% of the expected output) wherever that floor routes. Flooring every such pay at its
    /// partial-fill settlement instead mints these at 38,750.
    function test_largePayAfterABuy_keepsTheFullInputFloor() public {
        uint256[3] memory buys = [uint256(0.01 ether), 0.03 ether, 0.1 ether];
        uint256[3] memory minimums = [uint256(79_000e18), 75_000e18, 65_000e18];
        for (uint256 i; i < buys.length; i++) {
            uint256 snap = vm.snapshotState();
            swapper.swap{value: buys[i]}(_key(FAR), true, buys[i]);
            (uint256 deployed, uint256 updated) = _compare(FAR, 5 ether);
            vm.revertToState(snap);
            assertEq(deployed, 38_750e18, "deployed hook minted");
            emit log_named_decimal_uint("updated", updated, 18);
            assertGt(updated, minimums[i], "pool route");
        }
    }

    /// @dev Pays `amount` for tokens, then sells them all into the pool.
    function dump(uint256 pid, uint256 amount) external {
        vm.prank(PAYER);
        TERMINAL.pay{value: amount}(pid, JBConstants.NATIVE_TOKEN, amount, address(this), 0, "", "");
        uint256 held = _token(pid).balanceOf(address(this));
        _token(pid).approve(address(swapper), held);
        swapper.swap(_key(pid), false, held);
    }

    bytes deployedCode;
    bytes updatedCode;

    /// @dev Captures the deployed hook's code and this source's code, deployed over it with the same immutables. The
    /// constructor only sets immutables, so etching the deployed code back restores the deployed hook.
    function _captureCodes() internal {
        deployedCode = HOOK.code;
        _upgrade();
        updatedCode = HOOK.code;
        vm.etch(HOOK, deployedCode);
    }

    /// @dev Whether a pay of `amount` succeeds, and the tokens the payer receives. Mode 0 is a plain pay, 1 skips the
    /// reserved split, 2 sends an explicit quote 1% over issuance, and 3 pays from the terminal itself, as a
    /// same-terminal split does (without that split's fee deduction).
    function payAs(uint256 pid, uint256 amount, uint256 mode) external returns (bool paid, uint256 tokens) {
        bytes memory metadata;
        if (mode == 1 || mode == 2) {
            metadata = JBMetadataResolver.addToMetadata({
                originalMetadata: "",
                idToAdd: JBMetadataResolver.getId("pay", HOOK),
                dataToAdd: abi.encode(
                    uint256(0), mode == 2 ? amount * (pid == FAR ? 12_500 : 50_000) * 101 / 100 : 0, mode == 1
                )
            });
        }
        address payer = mode == 3 ? address(TERMINAL) : PAYER;
        vm.deal(payer, payer.balance + amount);
        uint256 before = _token(pid).balanceOf(PAYER);
        vm.prank(payer);
        try TERMINAL.pay{value: amount, gas: 30_000_000}(
            pid, JBConstants.NATIVE_TOKEN, amount, PAYER, 0, "", metadata
        ) {
            (paid, tokens) = (true, _token(pid).balanceOf(PAYER) - before);
        } catch {}
    }

    /// @dev On the current state, each size pays at least as many tokens through this source as through the deployed
    /// hook, and reverts exactly when the deployed hook reverts (explicit quotes the pool cannot meet).
    function checkSizes(uint256 pid, uint256 mode) external {
        uint256[11] memory sizes = [
            uint256(0.0001 ether),
            0.0003 ether,
            0.001 ether,
            0.003 ether,
            0.01 ether,
            0.03 ether,
            0.1 ether,
            0.3 ether,
            1 ether,
            5 ether,
            10 ether
        ];
        for (uint256 i; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            (bool deployedPaid, uint256 deployed) = this.payAs(pid, sizes[i], mode);
            vm.revertToState(snap);
            vm.etch(HOOK, updatedCode);
            (bool updatedPaid, uint256 updated) = this.payAs(pid, sizes[i], mode);
            vm.revertToStateAndDelete(snap);
            assertEq(updatedPaid, deployedPaid, "reverts only where the deployed hook does");
            assertGe(updated, deployed, "payer never gets less than from the deployed hook");
        }
    }

    /// @dev Pool states: as-is, then a third party's same-block buy or dump of 0.001, 0.01 or 0.1 ETH, each also with
    /// spot held there for a quarter and half of the TWAP window (so the TWAP partly follows it). The hook cannot tell
    /// these from a front-run. Dumps pay through the deployed hook and sell the payer's tokens back into the pool.
    function _everyState(uint256 mode) internal {
        _captureCodes();
        uint256[3] memory moves = [uint256(0.001 ether), 0.01 ether, 0.1 ether];
        for (uint256 p; p < 2; p++) {
            uint256 pid = p == 0 ? THIN : FAR;
            uint256 window = JBBuybackHook(payable(HOOK)).twapWindowOf(pid, address(0));
            this.checkSizes(pid, mode);
            for (uint256 m; m < moves.length * 2; m++) {
                uint256 snap = vm.snapshotState();
                if (m < moves.length) {
                    swapper.swap{value: moves[m]}(_key(pid), true, moves[m]);
                } else {
                    // Project 13's pool cannot absorb its largest dump; skip it.
                    try this.dump(pid, moves[m - moves.length]) {}
                    catch {
                        vm.revertToStateAndDelete(snap);
                        continue;
                    }
                }
                this.checkSizes(pid, mode);
                vm.warp(block.timestamp + window / 4);
                vm.roll(block.number + window / 8);
                this.checkSizes(pid, mode);
                vm.warp(block.timestamp + window / 4);
                vm.roll(block.number + window / 8);
                this.checkSizes(pid, mode);
                vm.revertToStateAndDelete(snap);
            }
        }
    }

    /// @dev Across sizes from 0.0001 to 10 ETH, both pools and every pool state above, the payer never gets fewer
    /// tokens than from the deployed hook. Accepted exceptions: none.
    function test_neverBelowTheDeployedHook_plainPays() public {
        _everyState(0);
    }

    function test_neverBelowTheDeployedHook_skipSplitsPays() public {
        _everyState(1);
    }

    function test_neverBelowTheDeployedHook_explicitQuotePays() public {
        _everyState(2);
    }

    function test_neverBelowTheDeployedHook_sameTerminalPays() public {
        _everyState(3);
    }

    /// @dev Victim's tokens after a front-run of `x`.
    function attacked(uint256 pid, uint256 amount, uint256 x) external returns (bool, uint256) {
        swapper.swap{value: x}(_key(pid), true, x);
        return this.payAs(pid, amount, 0);
    }

    /// @dev For the same front-run buy, an attacked payer never gets fewer tokens than from the deployed hook.
    /// Accepted exceptions: none.
    function test_neverBelowTheDeployedHook_attackedPays() public {
        _captureCodes();
        uint256[5] memory far = [uint256(0.001 ether), 0.01 ether, 0.1 ether, 1 ether, 5 ether];
        uint256[5] memory thin = [TX_AMOUNT, 0.003 ether, 0.01 ether, 0.03 ether, 0.3 ether];
        for (uint256 p; p < 2; p++) {
            uint256 pid = p == 0 ? THIN : FAR;
            for (uint256 i; i < 5; i++) {
                uint256 amount = p == 0 ? thin[i] : far[i];
                for (uint256 k; k < 8; k++) {
                    uint256 x = amount * (2 ** k) / 8;
                    uint256 snap = vm.snapshotState();
                    (bool deployedPaid, uint256 deployed) = this.attacked(pid, amount, x);
                    vm.revertToState(snap);
                    vm.etch(HOOK, updatedCode);
                    (bool updatedPaid, uint256 updated) = this.attacked(pid, amount, x);
                    vm.revertToStateAndDelete(snap);
                    assertEq(updatedPaid, deployedPaid, "reverts only where the deployed hook does");
                    assertGe(updated, deployed, "attacked payer never gets less than from the deployed hook");
                }
            }
        }
    }

    /// @dev The holder's ETH received and project tokens left after cashing out `count`.
    function _cashOut(uint256 pid, uint256 count) internal returns (uint256 eth, uint256 tokens) {
        uint256 before = PAYER.balance;
        vm.prank(PAYER);
        IJBCashOutTerminal(address(TERMINAL))
            .cashOutTokensOf(PAYER, pid, count, JBConstants.NATIVE_TOKEN, 0, payable(PAYER), "");
        return (PAYER.balance - before, _token(pid).balanceOf(PAYER));
    }

    /// @dev Cash-outs settle exactly as through the deployed hook (the holder's ETH and project tokens, which include
    /// any hook swap proceeds sent straight to the beneficiary), as-is, after a buy and after a dump.
    function test_cashOuts_matchTheDeployedHook() public {
        _captureCodes();
        for (uint256 p; p < 2; p++) {
            uint256 pid = p == 0 ? THIN : FAR;
            _pay(pid, 1 ether);
            for (uint256 s; s < 3; s++) {
                uint256 snap = vm.snapshotState();
                if (s == 1) swapper.swap{value: 0.01 ether}(_key(pid), true, 0.01 ether);
                if (s == 2) this.dump(pid, 0.003 ether);
                uint256 held = _token(pid).balanceOf(PAYER);
                for (uint256 d = 2; d <= 2000; d *= 10) {
                    uint256 inner = vm.snapshotState();
                    (uint256 deployedEth, uint256 deployedTokens) = _cashOut(pid, held / d);
                    vm.revertToState(inner);
                    vm.etch(HOOK, updatedCode);
                    (uint256 updatedEth, uint256 updatedTokens) = _cashOut(pid, held / d);
                    vm.revertToStateAndDelete(inner);
                    assertEq(updatedEth, deployedEth, "same ETH to the holder");
                    assertEq(updatedTokens, deployedTokens, "same project tokens left");
                }
                vm.revertToStateAndDelete(snap);
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
            assertGe(victim, minted, "never below issuance");
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

    /// @dev A 0.01 ETH pay swaps only the pool's leg above the issuance rate and mints the rest, so a sandwich can only
    /// work that leg. Without the settlement floor this pay mints, so the attacker takes part of the gain over
    /// issuance, never the issuance itself.
    function test_sandwich_largePay() public {
        uint256 best = _sandwich(0.01 ether, 500e18, 0.000_05 ether);
        // Observed on this state, not a bound the hook guarantees: about 0.4% of the pay.
        assertLt(best, 0.01 ether / 100, "attacker profit");
    }
}
