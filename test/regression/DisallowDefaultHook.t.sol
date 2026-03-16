// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";

/// @notice Regression test: disallowHook clears defaultHook, breaking payments for default-reliant projects.
/// @dev Before the fix, `disallowHook` would set `defaultHook = address(0)` when the disallowed hook
///      matched the current default. This caused `beforePayRecordedWith` to call methods on address(0),
///      which reverts, breaking all payments for projects relying on the default hook.
///      The fix makes `disallowHook` revert when attempting to disallow the current default hook.
contract DisallowDefaultHook is Test {
    JBBuybackHookRegistry registry;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    address registryOwner = makeAddr("registryOwner");
    address trustedForwarder = makeAddr("forwarder");

    IJBRulesetDataHook hookA = IJBRulesetDataHook(makeAddr("hookA"));
    IJBRulesetDataHook hookB = IJBRulesetDataHook(makeAddr("hookB"));

    uint256 projectId = 42;

    function setUp() public {
        registry = new JBBuybackHookRegistry(permissions, projects, registryOwner, trustedForwarder);

        // Mock permissions to return true by default.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
    }

    /// @notice Disallowing the current default hook should revert with CannotDisallowDefaultHook.
    /// @dev Before the fix, this would succeed and set defaultHook to address(0).
    function test_disallowHook_revertsWhenHookIsDefault() public {
        // Set hookA as the default.
        vm.prank(registryOwner);
        registry.setDefaultHook(hookA);
        assertEq(address(registry.defaultHook()), address(hookA), "default should be hookA");

        // Attempt to disallow hookA (the current default) — should revert.
        vm.prank(registryOwner);
        vm.expectRevert(JBBuybackHookRegistry.JBBuybackHookRegistry_CannotDisallowDefaultHook.selector);
        registry.disallowHook(hookA);

        // Verify the default hook was NOT cleared.
        assertEq(address(registry.defaultHook()), address(hookA), "default should remain hookA after failed disallow");
    }

    /// @notice Disallowing a non-default hook should still succeed normally.
    function test_disallowHook_succeedsWhenHookIsNotDefault() public {
        // Set hookA as the default.
        vm.prank(registryOwner);
        registry.setDefaultHook(hookA);

        // Allow hookB separately.
        vm.prank(registryOwner);
        registry.allowHook(hookB);
        assertTrue(registry.isHookAllowed(hookB), "hookB should be allowed");

        // Disallow hookB (which is NOT the default) — should succeed.
        vm.prank(registryOwner);
        registry.disallowHook(hookB);

        assertFalse(registry.isHookAllowed(hookB), "hookB should be disallowed");
        // Default should remain unchanged.
        assertEq(address(registry.defaultHook()), address(hookA), "default should remain hookA");
    }

    /// @notice After the fix, the payment path (beforePayRecordedWith) should never encounter
    ///         address(0) as the default hook because disallowHook prevents clearing it.
    /// @dev This test demonstrates the bug scenario that the fix prevents:
    ///      1. Set hookA as default
    ///      2. Try to disallow hookA (now reverts — before fix would clear default to address(0))
    ///      3. Verify payments still work (beforePayRecordedWith does not revert on address(0))
    function test_paymentPathSafeAfterDisallowAttempt() public {
        // Set hookA as the default.
        vm.prank(registryOwner);
        registry.setDefaultHook(hookA);

        // Attempt to disallow hookA — reverts (fix).
        vm.prank(registryOwner);
        vm.expectRevert(JBBuybackHookRegistry.JBBuybackHookRegistry_CannotDisallowDefaultHook.selector);
        registry.disallowHook(hookA);

        // Build a pay context for a project that uses the default hook.
        JBBeforePayRecordedContext memory context = JBBeforePayRecordedContext({
            terminal: makeAddr("terminal"),
            payer: makeAddr("payer"),
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 1 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            projectId: projectId,
            rulesetId: 0,
            beneficiary: makeAddr("beneficiary"),
            weight: 100,
            reservedPercent: 0,
            metadata: ""
        });

        // Mock hookA.beforePayRecordedWith to return valid data.
        vm.mockCall(
            address(hookA),
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(100), new bytes(0))
        );

        // The payment path should work because the default hook was NOT cleared.
        // Before the fix, this would revert because the hook was address(0).
        (uint256 weight,) = registry.beforePayRecordedWith(context);
        assertEq(weight, 100, "payment should succeed via the default hook");
    }
}
