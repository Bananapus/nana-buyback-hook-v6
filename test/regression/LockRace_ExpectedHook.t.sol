// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

import "src/JBBuybackHookRegistry.sol";

/// @notice Regression test for lock-race: lockHookFor now requires an `expectedHook` parameter
///         to prevent race conditions where the hook changes between transaction submission and
///         execution. If the resolved hook differs from expectedHook, it reverts with
///         JBBuybackHookRegistry_HookMismatch.
contract LockRace_ExpectedHook is Test {
    JBBuybackHookRegistry registry;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    address registryOwner = makeAddr("registryOwner");
    address projectOwner = makeAddr("projectOwner");
    address trustedForwarder = makeAddr("forwarder");

    IJBRulesetDataHook hookA = IJBRulesetDataHook(makeAddr("hookA"));
    IJBRulesetDataHook hookB = IJBRulesetDataHook(makeAddr("hookB"));

    uint256 projectId = 1;

    function setUp() public {
        registry = new JBBuybackHookRegistry(permissions, projects, registryOwner, trustedForwarder);

        // Mock project ownership.
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(projectOwner));

        // Mock permissions — allow all.
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature("hasPermission(address,address,uint256,uint256,bool,bool)"),
            abi.encode(true)
        );

        // Allow both hooks.
        vm.startPrank(registryOwner);
        registry.allowHook(hookA);
        registry.allowHook(hookB);
        vm.stopPrank();
    }

    /// @notice lockHookFor succeeds when expectedHook matches the resolved hook.
    function test_lockHookFor_succeedsWithMatchingExpectedHook() public {
        // Set hookA for the project.
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookA);

        // Lock with correct expectedHook.
        vm.prank(projectOwner);
        registry.lockHookFor(projectId, hookA);

        assertTrue(registry.hasLockedHook(projectId), "hook should be locked");
    }

    /// @notice lockHookFor reverts with HookMismatch when expectedHook differs from the resolved hook.
    function test_lockHookFor_revertsOnMismatch() public {
        // Set hookA for the project.
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookA);

        // Try to lock with hookB as expected — should revert.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookMismatch.selector, hookA, hookB)
        );
        registry.lockHookFor(projectId, hookB);

        assertFalse(registry.hasLockedHook(projectId), "hook should NOT be locked after mismatch");
    }

    /// @notice lockHookFor with default hook: when no explicit hook is set, the default is used.
    ///         The caller must pass the default as expectedHook.
    function test_lockHookFor_withDefaultHook_matchesExpected() public {
        // Set hookA as the default.
        vm.prank(registryOwner);
        registry.setDefaultHook(hookA);

        // Lock with correct expectedHook (the default).
        vm.prank(projectOwner);
        registry.lockHookFor(projectId, hookA);

        assertTrue(registry.hasLockedHook(projectId), "hook should be locked");
        // The default should have been snapshotted into _hookOf.
        assertEq(address(registry.hookOf(projectId)), address(hookA), "hookOf should return snapshotted default");
    }

    /// @notice lockHookFor with default hook: reverts when expectedHook does not match default.
    function test_lockHookFor_withDefaultHook_revertsOnMismatch() public {
        // Set hookA as the default.
        vm.prank(registryOwner);
        registry.setDefaultHook(hookA);

        // Try to lock with hookB as expected — the resolved hook is hookA (default), so should revert.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookMismatch.selector, hookA, hookB)
        );
        registry.lockHookFor(projectId, hookB);

        assertFalse(registry.hasLockedHook(projectId), "hook should NOT be locked");
    }

    /// @notice Simulates the race condition: owner sets hookA, someone calls lockHookFor(hookA),
    ///         but between submission and execution the owner changes to hookB.
    ///         The lock should revert because the resolved hook (hookB) differs from expected (hookA).
    function test_lockHookFor_preventsRaceCondition() public {
        // Owner initially sets hookA.
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookA);

        // Simulate: between lock tx submission and execution, owner changes hook to hookB.
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookB);

        // The lock tx executes with expectedHook = hookA, but resolved hook is now hookB.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookMismatch.selector, hookB, hookA)
        );
        registry.lockHookFor(projectId, hookA);

        assertFalse(registry.hasLockedHook(projectId), "hook should NOT be locked after race condition");
    }
}
