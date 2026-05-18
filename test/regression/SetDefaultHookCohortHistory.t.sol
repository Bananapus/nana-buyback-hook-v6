// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";

/// @notice Changing the default hook must not orphan projects that were created while the previous default was active.
/// @dev A project created in the window between two `setDefaultHook` calls inherited the prior default implicitly.
/// After the next `setDefaultHook` call, the resolver must still return that prior default for the project — not
/// `address(0)`, which would silently disable the buyback routing and cause cash-outs to revert at
/// `controller.mintTokensOf` because the orphaned hook has no mint permission.
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

    function test_coldStartCohort_remainsUnrouted() public {
        // Cold start: there were already 50 projects when the first default was set. They are intentionally outside
        // the default-routing scheme (the documented "default only applies to projects created AFTER it was set"
        // property).
        _mockProjectsCount(50);
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        for (uint256 id = 1; id <= 50; ++id) {
            assertEq(address(registry.hookOf(id)), address(0), "cold-start cohort must resolve to zero");
        }
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
        // Step 1: at count = 50, set the first default (A). Projects 51..150 are created with A as their implicit
        // default.
        _mockProjectsCount(50);
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        _mockProjectsCount(150);

        // Sanity: at this point project 100 resolves to A.
        assertEq(address(registry.hookOf(100)), address(hookA), "pre-overwrite: cohort resolves to A");

        // Step 2: change the default to B at count = 150. Projects 51..150 were assigned A at creation; they must
        // still resolve to A after this call.
        vm.prank(owner);
        registry.setDefaultHook(hookB);

        // Cold-start cohort (1..50) still resolves to zero — it pre-dates every default.
        assertEq(address(registry.hookOf(1)), address(0), "cold-start cohort unaffected");
        assertEq(address(registry.hookOf(50)), address(0), "cold-start cohort unaffected at edge");

        // Prior cohort (51..150) must still resolve to A.
        assertEq(address(registry.hookOf(51)), address(hookA), "prior cohort lower edge resolves to A");
        assertEq(address(registry.hookOf(100)), address(hookA), "prior cohort middle resolves to A");
        assertEq(address(registry.hookOf(150)), address(hookA), "prior cohort upper edge resolves to A");

        // Future cohort (151..) resolves to B.
        assertEq(address(registry.hookOf(151)), address(hookB), "future cohort resolves to B");
        assertEq(address(registry.hookOf(500)), address(hookB), "future cohort resolves to B");

        // History exposes one segment recording A's cohort.
        assertEq(registry.defaultHookHistoryLength(), 1, "one segment recorded");
        assertEq(registry.defaultHookHistoryAt(0).minProjectIdExclusive, 50, "segment lower bound = first threshold");
        assertEq(registry.defaultHookHistoryAt(0).maxProjectId, 150, "segment upper bound = current count at overwrite");
        assertEq(address(registry.defaultHookHistoryAt(0).hook), address(hookA), "segment hook = outgoing default");
    }

    function test_threeDefaults_eachCohortKeepsItsHook() public {
        // count = 50: setDefaultHook(A); A applies to 51..150
        _mockProjectsCount(50);
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        _mockProjectsCount(150);
        vm.prank(owner);
        registry.setDefaultHook(hookB);

        _mockProjectsCount(300);
        vm.prank(owner);
        registry.setDefaultHook(hookC);

        // Cold start
        assertEq(address(registry.hookOf(25)), address(0), "cold start resolves to zero");
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

        assertEq(registry.defaultHookHistoryLength(), 2, "two segments recorded");
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
