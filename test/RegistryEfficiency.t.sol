// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";
import {DefaultHookSegment} from "src/structs/DefaultHookSegment.sol";

/// @notice Unit tests for the binary-search optimization in `JBBuybackHookRegistry._resolvedHookOf` (A3).
/// @dev Mocks `PROJECTS.count()` to advance the project counter between `setDefaultHook` calls, exercising the
///      historical default lookup path that the binary search replaces.
contract Test_RegistryEfficiency_BinarySearchHistory is Test {
    JBBuybackHookRegistry registry;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    address owner = makeAddr("owner");
    address trustedForwarder = makeAddr("forwarder");
    address projectOwner = makeAddr("projectOwner");

    function setUp() public {
        registry = new JBBuybackHookRegistry(permissions, projects, owner, trustedForwarder);

        // Default permissions pass so we don't fight with auth in these tests.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
    }

    /// @dev Advance the mocked `PROJECTS.count()` so `setDefaultHook` records a new segment for that range.
    function _mockProjectCount(uint256 count) internal {
        vm.mockCall(address(projects), abi.encodeWithSignature("count()"), abi.encode(count));
    }

    /// @dev Mock `PROJECTS.ownerOf(projectId)` so calls that read project ownership return our test owner.
    function _mockProjectOwner(uint256 projectId, address ownerAddr) internal {
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(IERC721.ownerOf.selector, projectId),
            abi.encode(ownerAddr)
        );
    }

    /// @notice Linear reference: walk the entire history and find the matching segment for `projectId`.
    /// @dev Mirrors the old O(N) scan exactly so we can fuzz the binary-search implementation against it.
    function _linearResolve(uint256 projectId) internal view returns (IJBRulesetDataHook hook) {
        uint256 len = registry.defaultHookHistoryLength();
        for (uint256 i; i < len; ++i) {
            DefaultHookSegment memory seg = registry.defaultHookHistoryAt(i);
            if (projectId > seg.minProjectIdExclusive && projectId <= seg.maxProjectId) {
                return seg.hook;
            }
        }
    }

    //*********************************************************************//
    // --- core scenarios ------------------------------------------------ //
    //*********************************************************************//

    /// @notice Push 8 distinct default segments via repeated `setDefaultHook` and verify each cohort resolves to the
    ///         right segment hook.
    /// @dev Sequence of (projectCount, hookAddress) snapshots:
    ///         t0: count=0, set hook0 (first call ever — no segment pushed yet, just sets threshold=0)
    ///         t1: count=10, set hook1 -> segment {minExcl=0, max=10, hook=hook0}, threshold=10
    ///         t2: count=25, set hook2 -> segment {minExcl=10, max=25, hook=hook1}, threshold=25
    ///         ... and so on for 8 total rotations after the initial set, leaving 8 historical segments.
    function test_resolvedHookOf_binarySearchAcrossManyDefaults() public {
        // First setDefaultHook does NOT push a segment (defaultHook is address(0)).
        _mockProjectCount(0);
        IJBRulesetDataHook hook0 = IJBRulesetDataHook(makeAddr("hook0"));
        vm.prank(owner);
        registry.setDefaultHook(hook0);

        // Now push 8 historical segments by rotating the default at increasing project counts.
        uint256[9] memory counts = [uint256(0), 10, 25, 50, 100, 150, 200, 300, 500];
        IJBRulesetDataHook[9] memory hooks;
        hooks[0] = hook0;
        for (uint256 i = 1; i <= 8; ++i) {
            _mockProjectCount(counts[i]);
            hooks[i] = IJBRulesetDataHook(makeAddr(string.concat("hook", vm.toString(i))));
            vm.prank(owner);
            registry.setDefaultHook(hooks[i]);
        }

        // 8 segments recorded.
        assertEq(registry.defaultHookHistoryLength(), 8, "should have 8 historical segments after 8 rotations");

        // For each segment, pick a projectId inside it and assert it resolves to the segment's hook.
        // Segment i: hook=hooks[i], range = (counts[i], counts[i+1]].
        for (uint256 i; i < 8; ++i) {
            uint256 minExcl = counts[i];
            uint256 maxIncl = counts[i + 1];
            // Project right above the min (inclusive low boundary).
            uint256 idLow = minExcl + 1;
            _mockProjectOwner(idLow, projectOwner);
            assertEq(
                address(registry.hookOf(idLow)),
                address(hooks[i]),
                string.concat(
                    "low-boundary projectId ",
                    vm.toString(idLow),
                    " should resolve to segment ",
                    vm.toString(i),
                    " hook"
                )
            );

            // Project at the inclusive max boundary.
            _mockProjectOwner(maxIncl, projectOwner);
            assertEq(
                address(registry.hookOf(maxIncl)),
                address(hooks[i]),
                string.concat(
                    "high-boundary projectId ",
                    vm.toString(maxIncl),
                    " should resolve to segment ",
                    vm.toString(i),
                    " hook"
                )
            );

            // Project somewhere in the middle.
            if (maxIncl > minExcl + 1) {
                uint256 idMid = (minExcl + maxIncl) / 2;
                if (idMid > minExcl && idMid <= maxIncl) {
                    _mockProjectOwner(idMid, projectOwner);
                    assertEq(
                        address(registry.hookOf(idMid)),
                        address(hooks[i]),
                        string.concat(
                            "mid projectId ",
                            vm.toString(idMid),
                            " should resolve to segment ",
                            vm.toString(i),
                            " hook"
                        )
                    );
                }
            }
        }

        // Project above the latest threshold resolves to the current default (hooks[8]).
        uint256 futureProjectId = counts[8] + 50;
        _mockProjectOwner(futureProjectId, projectOwner);
        assertEq(
            address(registry.hookOf(futureProjectId)),
            address(hooks[8]),
            "projectId above last threshold should resolve to current default"
        );
    }

    /// @notice A project whose ID predates every recorded default returns `address(0)`.
    /// @dev When the very first `setDefaultHook` call happens with PROJECTS.count() > 0, the cohort of projects
    ///      created BEFORE that first call has no segment covering them and so must resolve to address(0).
    function test_resolvedHookOf_projectPredatesAllDefaults() public {
        // 5 projects existed before the first default was set; they fall outside any recorded segment.
        _mockProjectCount(5);
        IJBRulesetDataHook hook0 = IJBRulesetDataHook(makeAddr("hook0_pre"));
        vm.prank(owner);
        registry.setDefaultHook(hook0);

        // Rotate to a second default at count=20 — this pushes a segment for (5, 20].
        _mockProjectCount(20);
        IJBRulesetDataHook hook1 = IJBRulesetDataHook(makeAddr("hook1_pre"));
        vm.prank(owner);
        registry.setDefaultHook(hook1);

        // Projects 1..5 predate every default and must resolve to address(0).
        for (uint256 id = 1; id <= 5; ++id) {
            _mockProjectOwner(id, projectOwner);
            assertEq(
                address(registry.hookOf(id)),
                address(0),
                string.concat("project ", vm.toString(id), " predates all defaults and should resolve to address(0)")
            );
        }

        // Project 6 sits in (5, 20] -> hook0.
        _mockProjectOwner(6, projectOwner);
        assertEq(address(registry.hookOf(6)), address(hook0), "projectId 6 should resolve to hook0 segment");

        // Project 20 sits at the inclusive upper bound -> hook0.
        _mockProjectOwner(20, projectOwner);
        assertEq(address(registry.hookOf(20)), address(hook0), "projectId 20 should resolve to hook0 segment");

        // Project 21 sits above the latest threshold -> current default (hook1).
        _mockProjectOwner(21, projectOwner);
        assertEq(address(registry.hookOf(21)), address(hook1), "projectId 21 should resolve to current default hook1");
    }

    /// @notice Exercise the exact inclusive/exclusive boundary semantics of each segment.
    function test_resolvedHookOf_boundaryProjectIds() public {
        _mockProjectCount(0);
        IJBRulesetDataHook hookA = IJBRulesetDataHook(makeAddr("boundary_hookA"));
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        _mockProjectCount(100);
        IJBRulesetDataHook hookB = IJBRulesetDataHook(makeAddr("boundary_hookB"));
        vm.prank(owner);
        registry.setDefaultHook(hookB);

        _mockProjectCount(200);
        IJBRulesetDataHook hookC = IJBRulesetDataHook(makeAddr("boundary_hookC"));
        vm.prank(owner);
        registry.setDefaultHook(hookC);

        // Two segments recorded: {0, 100, hookA} and {100, 200, hookB}. Current default: hookC, threshold=200.

        // projectId == segment.minProjectIdExclusive + 1 (lower inclusive boundary of hookA segment).
        _mockProjectOwner(1, projectOwner);
        assertEq(address(registry.hookOf(1)), address(hookA), "minExcl+1 should resolve to hookA");

        // projectId == segment.maxProjectId (inclusive upper boundary of hookA segment).
        _mockProjectOwner(100, projectOwner);
        assertEq(address(registry.hookOf(100)), address(hookA), "max of hookA segment should resolve to hookA");

        // projectId == segment.minProjectIdExclusive + 1 of hookB segment.
        _mockProjectOwner(101, projectOwner);
        assertEq(address(registry.hookOf(101)), address(hookB), "minExcl+1 of hookB should resolve to hookB");

        // projectId == segment.maxProjectId of hookB segment.
        _mockProjectOwner(200, projectOwner);
        assertEq(address(registry.hookOf(200)), address(hookB), "max of hookB segment should resolve to hookB");

        // projectId == 201: above latest threshold, resolves to current default hookC.
        _mockProjectOwner(201, projectOwner);
        assertEq(address(registry.hookOf(201)), address(hookC), "above-threshold should resolve to current default");
    }

    /// @notice A project-specific hook (set via `setHookFor`) always wins over any historical default.
    function test_resolvedHookOf_explicitHookBeatsHistory() public {
        _mockProjectCount(0);
        IJBRulesetDataHook defaultA = IJBRulesetDataHook(makeAddr("defaultA"));
        vm.prank(owner);
        registry.setDefaultHook(defaultA);

        _mockProjectCount(50);
        IJBRulesetDataHook defaultB = IJBRulesetDataHook(makeAddr("defaultB"));
        vm.prank(owner);
        registry.setDefaultHook(defaultB);

        // Project 25 historically resolves to defaultA via the segment (0, 50].
        _mockProjectOwner(25, projectOwner);
        assertEq(address(registry.hookOf(25)), address(defaultA), "history default should win without explicit hook");

        // Allow a third hook and pin it on project 25.
        IJBRulesetDataHook explicitHook = IJBRulesetDataHook(makeAddr("explicit"));
        vm.prank(owner);
        registry.allowHook(explicitHook);
        vm.prank(projectOwner);
        registry.setHookFor(25, explicitHook);

        // The explicit hook now wins over the historical default.
        assertEq(
            address(registry.hookOf(25)), address(explicitHook), "explicit project hook should win over history"
        );
    }

    //*********************************************************************//
    // --- fuzz ---------------------------------------------------------- //
    //*********************************************************************//

    /// @notice Build a monotone history of segments, then fuzz `projectId` against both binary-search resolution and
    ///         the reference linear walk; the two must always agree.
    function testFuzz_resolvedHookOf_matchesLinearWalk(uint8 segmentCountSeed, uint256 projectIdSeed) public {
        uint256 segmentCount = (uint256(segmentCountSeed) % 16) + 2; // [2, 17]

        // Build monotonically non-decreasing project counts. Pin them to a deterministic spread so the cohorts have
        // non-trivial widths and the binary search has work to do.
        uint256[] memory counts = new uint256[](segmentCount + 1);
        counts[0] = 0;
        for (uint256 i = 1; i <= segmentCount; ++i) {
            // Use a multiplier > 1 to ensure strictly increasing counts (so each segment covers a positive range).
            counts[i] = counts[i - 1] + 1 + (i * 3);
        }

        // Set the first default at count=counts[0]=0 (no segment recorded).
        _mockProjectCount(counts[0]);
        IJBRulesetDataHook firstHook = IJBRulesetDataHook(makeAddr("fuzz_hook_0"));
        vm.prank(owner);
        registry.setDefaultHook(firstHook);

        // Rotate the rest, pushing one segment per rotation.
        for (uint256 i = 1; i <= segmentCount; ++i) {
            _mockProjectCount(counts[i]);
            IJBRulesetDataHook nextHook =
                IJBRulesetDataHook(makeAddr(string.concat("fuzz_hook_", vm.toString(i))));
            vm.prank(owner);
            registry.setDefaultHook(nextHook);
        }

        // Sanity: exactly `segmentCount` segments recorded.
        assertEq(registry.defaultHookHistoryLength(), segmentCount, "segment count mismatch");

        // Fuzz the queried projectId across the full historical range plus some headroom above the last threshold.
        uint256 maxQuery = counts[segmentCount] + 1000;
        uint256 projectId = (projectIdSeed % maxQuery) + 1;

        // The on-chain resolver consults `_hookOf[projectId]` first; with none set, it falls through to history /
        // current default. Make sure ownerOf is mocked in case the resolver path requires it (it doesn't, but harmless).
        _mockProjectOwner(projectId, projectOwner);

        IJBRulesetDataHook resolved = registry.hookOf(projectId);

        // Compute the reference: above-threshold -> current default; else linear walk; else address(0).
        IJBRulesetDataHook expected;
        if (projectId > registry.defaultHookProjectIdThreshold()) {
            expected = registry.defaultHook();
        } else {
            expected = _linearResolve(projectId);
        }

        assertEq(
            address(resolved),
            address(expected),
            string.concat(
                "binary search must match linear reference for projectId ", vm.toString(projectId)
            )
        );
    }
}
