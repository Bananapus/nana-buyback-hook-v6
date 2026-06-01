// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";

/// @notice The default hook must resolve correctly for every cohort of projects.
/// @dev The first-ever default applies to projects that already existed when it was set (so pre-existing, non-pinned
/// projects resolve to it). Changing the default afterward must not re-route projects that were created while a
/// previous default was active — the resolver must still return that prior default for them, not `address(0)`, which
/// would silently disable buyback routing and cause cash-outs to revert at `controller.mintTokensOf` because the
/// unrouted hook has no mint permission. A project that pinned its own hook always keeps that pin.
contract SetDefaultHookCohortHistoryTest is Test {
    JBBuybackHookRegistry registry;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    address owner = makeAddr("owner");
    address trustedForwarder = makeAddr("forwarder");

    IJBRulesetDataHook hookA = IJBRulesetDataHook(makeAddr("hookA"));
    IJBRulesetDataHook hookB = IJBRulesetDataHook(makeAddr("hookB"));
    IJBRulesetDataHook hookC = IJBRulesetDataHook(makeAddr("hookC"));

    function setUp() public {
        registry = new JBBuybackHookRegistry(permissions, projects, owner, trustedForwarder);
    }

    function _mockProjectsCount(uint256 count) internal {
        vm.mockCall(address(projects), abi.encodeWithSignature("count()"), abi.encode(count));
    }

    function test_firstDefault_appliesToPreExistingProjects() public {
        // There were already 50 projects when the first default was set. The first-ever default applies to them, so
        // every pre-existing, non-pinned project resolves to it.
        _mockProjectsCount(50);
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        for (uint256 id = 1; id <= 50; ++id) {
            assertEq(address(registry.hookOf(id)), address(hookA), "pre-existing project resolves to first default");
        }

        // The first call records one segment covering the already-existing cohort, mapped to the new hook.
        assertEq(registry.defaultHookHistoryLength(), 1, "first call records one segment");
        assertEq(registry.defaultHookHistoryAt(0).minProjectIdExclusive, 0, "segment lower bound = 0");
        assertEq(registry.defaultHookHistoryAt(0).maxProjectId, 50, "segment upper bound = count at first call");
        assertEq(address(registry.defaultHookHistoryAt(0).hook), address(hookA), "segment hook = the new default");
    }

    function test_postFirstDefault_appliesToNewlyCreatedProjects() public {
        _mockProjectsCount(50);
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        // Project ID 51 is created after the first default was set — it should resolve to A.
        assertEq(address(registry.hookOf(51)), address(hookA), "post-threshold project resolves to current default");
        assertEq(
            address(registry.hookOf(150)), address(hookA), "any post-threshold project resolves to current default"
        );
    }

    function test_setDefaultHook_doesNotOrphanPriorCohort() public {
        // Step 1: at count = 50, set the first default (A). Projects 1..50 already existed and now resolve to A;
        // projects 51..150 are created with A as their implicit default.
        _mockProjectsCount(50);
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        _mockProjectsCount(150);

        // Sanity: at this point project 100 resolves to A.
        assertEq(address(registry.hookOf(100)), address(hookA), "pre-overwrite: cohort resolves to A");

        // Step 2: change the default to B at count = 150. Projects 1..150 were assigned A while it was the active
        // default; they must still resolve to A after this call.
        vm.prank(owner);
        registry.setDefaultHook(hookB);

        // Pre-existing cohort (1..50) keeps A — the change does not retroactively re-route it.
        assertEq(address(registry.hookOf(1)), address(hookA), "pre-existing cohort keeps A");
        assertEq(address(registry.hookOf(50)), address(hookA), "pre-existing cohort keeps A at edge");

        // Prior cohort (51..150) must still resolve to A.
        assertEq(address(registry.hookOf(51)), address(hookA), "prior cohort lower edge resolves to A");
        assertEq(address(registry.hookOf(100)), address(hookA), "prior cohort middle resolves to A");
        assertEq(address(registry.hookOf(150)), address(hookA), "prior cohort upper edge resolves to A");

        // Future cohort (151..) resolves to B.
        assertEq(address(registry.hookOf(151)), address(hookB), "future cohort resolves to B");
        assertEq(address(registry.hookOf(500)), address(hookB), "future cohort resolves to B");

        // History exposes two segments, both recording A's cohort: the pre-existing cohort and the (50, 150] window.
        assertEq(registry.defaultHookHistoryLength(), 2, "two segments recorded");
        assertEq(registry.defaultHookHistoryAt(0).minProjectIdExclusive, 0, "first segment lower bound = 0");
        assertEq(registry.defaultHookHistoryAt(0).maxProjectId, 50, "first segment upper bound = first threshold");
        assertEq(address(registry.defaultHookHistoryAt(0).hook), address(hookA), "first segment hook = A");
        assertEq(
            registry.defaultHookHistoryAt(1).minProjectIdExclusive, 50, "second segment lower bound = first threshold"
        );
        assertEq(registry.defaultHookHistoryAt(1).maxProjectId, 150, "second segment upper bound = count at overwrite");
        assertEq(
            address(registry.defaultHookHistoryAt(1).hook), address(hookA), "second segment hook = outgoing default"
        );
    }

    function test_threeDefaults_eachCohortKeepsItsHook() public {
        // count = 50: setDefaultHook(A); A applies to pre-existing 1..50 and to 51..150
        _mockProjectsCount(50);
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        _mockProjectsCount(150);
        vm.prank(owner);
        registry.setDefaultHook(hookB);

        _mockProjectsCount(300);
        vm.prank(owner);
        registry.setDefaultHook(hookC);

        // Pre-existing cohort keeps A
        assertEq(address(registry.hookOf(25)), address(hookA), "pre-existing cohort resolves to A");
        // A's cohort
        assertEq(address(registry.hookOf(75)), address(hookA), "A's cohort resolves to A");
        assertEq(address(registry.hookOf(150)), address(hookA), "A's upper edge resolves to A");
        // B's cohort
        assertEq(address(registry.hookOf(151)), address(hookB), "B's lower edge resolves to B");
        assertEq(address(registry.hookOf(225)), address(hookB), "B's cohort resolves to B");
        assertEq(address(registry.hookOf(300)), address(hookB), "B's upper edge resolves to B");
        // C (current default)
        assertEq(address(registry.hookOf(301)), address(hookC), "C's cohort resolves to C");
        assertEq(address(registry.hookOf(999)), address(hookC), "future projects resolve to C");

        assertEq(registry.defaultHookHistoryLength(), 3, "three segments recorded");
    }

    function test_explicitHookOf_wins_overHistoricalDefault() public {
        _mockProjectsCount(50);
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        _mockProjectsCount(150);

        // Allow hookB and set it explicitly for project 75.
        vm.prank(owner);
        registry.allowHook(hookB);

        // Mock the projects.ownerOf check for setHookFor's permission gate.
        address projectOwner = makeAddr("projectOwner");
        vm.mockCall(
            address(projects), abi.encodeWithSignature("ownerOf(uint256)", uint256(75)), abi.encode(projectOwner)
        );
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature(
                "hasPermission(address,address,uint256,uint8,bool,bool)",
                projectOwner,
                projectOwner,
                uint256(75),
                uint8(0),
                true,
                true
            ),
            abi.encode(true)
        );

        vm.prank(projectOwner);
        registry.setHookFor(75, hookB);

        // Now move the default to C and verify project 75 still resolves to its explicit hookB.
        vm.prank(owner);
        registry.setDefaultHook(hookC);

        assertEq(address(registry.hookOf(75)), address(hookB), "explicit hook wins over historical default");
        assertEq(address(registry.hookOf(76)), address(hookA), "neighbor in same cohort still resolves to A");
    }
}
