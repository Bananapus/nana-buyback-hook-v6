// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {Test} from "forge-std/Test.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

/// @notice Reverting beneficiary used to demonstrate native-delivery failure.
contract RevertingReceiver {
    receive() external payable {
        revert("no native here");
    }
}

/// @notice Local accountant that mimics the relevant delivery branch of `JBBuybackHook.afterCashOutRecordedWith` for
/// the native token path. Keeping the math out of the full hook lets the test exercise the delivery semantics under
/// realistic conditions (reverting beneficiary, holder fallback, both-reject) without spinning up the full V4 +
/// terminal + controller stack — the production code path is just the four lines below the `Address.sendValue`
/// replacement.
contract NativeDeliveryHarness {
    error NativeDeliveryFailed(address beneficiary, address holder);

    event FellBackToHolder(address indexed beneficiary, address indexed holder, uint256 amount);

    function deliver(address payable beneficiary, address payable holder, uint256 amount) external payable {
        (bool delivered,) = beneficiary.call{value: amount}("");
        if (!delivered) {
            (bool fallbackDelivered,) = holder.call{value: amount}("");
            if (!fallbackDelivered) revert NativeDeliveryFailed(beneficiary, holder);
            emit FellBackToHolder(beneficiary, holder, amount);
        }
    }
}

contract CashOutSwapNativeFallbackTest is Test {
    NativeDeliveryHarness private _harness;
    RevertingReceiver private _badReceiver;
    address payable private _eoaHolder = payable(makeAddr("eoaHolder"));

    function setUp() public {
        _harness = new NativeDeliveryHarness();
        _badReceiver = new RevertingReceiver();
    }

    function test_eoaBeneficiary_receivesProceeds() public {
        vm.deal(address(_harness), 1 ether);
        uint256 balBefore = _eoaHolder.balance;
        _harness.deliver(_eoaHolder, _eoaHolder, 1 ether);
        assertEq(_eoaHolder.balance, balBefore + 1 ether, "EOA beneficiary receives proceeds");
    }

    function test_revertingBeneficiary_fallsBackToHolder() public {
        vm.deal(address(_harness), 1 ether);
        uint256 balBefore = _eoaHolder.balance;
        vm.expectEmit(true, true, true, true);
        emit NativeDeliveryHarness.FellBackToHolder(address(_badReceiver), _eoaHolder, 1 ether);
        _harness.deliver(payable(address(_badReceiver)), _eoaHolder, 1 ether);
        assertEq(_eoaHolder.balance, balBefore + 1 ether, "holder gets the fallback proceeds");
    }

    function test_bothReject_reverts() public {
        // Holder is also a reverting contract.
        RevertingReceiver badHolder = new RevertingReceiver();
        vm.deal(address(_harness), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                NativeDeliveryHarness.NativeDeliveryFailed.selector, address(_badReceiver), address(badHolder)
            )
        );
        _harness.deliver(payable(address(_badReceiver)), payable(address(badHolder)), 1 ether);
    }
}
