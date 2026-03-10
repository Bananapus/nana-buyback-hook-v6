// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

import "src/JBBuybackHookRegistry.sol";

/// @notice setDefaultHook(address(0)) should revert.
contract DefaultHookZeroCheck is Test {
    JBBuybackHookRegistry registry;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    address owner = makeAddr("owner");
    address trustedForwarder = makeAddr("forwarder");

    function setUp() public {
        registry = new JBBuybackHookRegistry(permissions, projects, owner, trustedForwarder);
    }

    /// @notice Setting address(0) as default hook should revert with JBBuybackHookRegistry_ZeroHook.
    function test_setDefaultHook_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(JBBuybackHookRegistry.JBBuybackHookRegistry_ZeroHook.selector);
        registry.setDefaultHook(IJBRulesetDataHook(address(0)));
    }

    /// @notice Setting a non-zero address as default hook should succeed.
    function test_setDefaultHook_succeedsWithNonZero() public {
        IJBRulesetDataHook hook = IJBRulesetDataHook(makeAddr("validHook"));

        vm.prank(owner);
        registry.setDefaultHook(hook);

        assertEq(address(registry.defaultHook()), address(hook), "defaultHook should be set");
        assertTrue(registry.isHookAllowed(hook), "hook should be allowed");
    }
}
