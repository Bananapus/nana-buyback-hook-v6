// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {JBBuybackHookRegistry} from "../../src/JBBuybackHookRegistry.sol";
import {DefaultHookSegment} from "../../src/structs/DefaultHookSegment.sol";

/// @notice Stateful functional-correctness harnesses for `JBBuybackHookRegistry`'s hook-resolution semantics.
///
/// @dev The registry's load-bearing spec is the cohort-resolution rule (NatSpec / contract header):
///   "The first-ever default hook applies to every project that exists when it is set. After that, a default
///    CHANGE only applies to projects created after the change — earlier cohorts keep the default that was
///    active when they were created, preventing the registry owner from unilaterally re-routing the mint
///    permission of projects that pre-date the change."
///
/// The existing `Registry.t.sol` spot-checks specific (count, projectId) scenarios. These harnesses generalize
/// the property to ARBITRARY monotonic sequences of `setDefaultHook` calls and arbitrary project IDs, via fuzz
/// and a Foundry invariant (the resolution walks a dynamic history array, so this is stateful, not symbolic).
contract RegistryResolutionProperties is Test {
    JBBuybackHookRegistry internal registry;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    address internal owner = makeAddr("owner");
    address internal forwarder = makeAddr("forwarder");
    address internal projectOwner = makeAddr("projectOwner");

    // A small fixed pool of distinct, non-zero candidate hooks.
    IJBRulesetDataHook[] internal hooks;

    // Mirror of the count() the registry will read, advanced by the harness.
    uint256 internal currentCount;

    function setUp() public {
        registry = new JBBuybackHookRegistry(permissions, projects, owner, forwarder);

        hooks.push(IJBRulesetDataHook(makeAddr("hook1")));
        hooks.push(IJBRulesetDataHook(makeAddr("hook2")));
        hooks.push(IJBRulesetDataHook(makeAddr("hook3")));
        hooks.push(IJBRulesetDataHook(makeAddr("hook4")));

        // Permissions always pass for authorized owner-paths; ownerOf returns a fixed owner.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
        vm.mockCall(address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector), abi.encode(projectOwner));

        _setCount(0);
    }

    function _setCount(uint256 c) internal {
        currentCount = c;
        vm.mockCall(address(projects), abi.encodeWithSignature("count()"), abi.encode(c));
    }

    //*********************************************************************//
    // ----------- The spec property, computed independently ------------- //
    //*********************************************************************//

    /// @notice An independent re-derivation of the expected resolved hook for a never-pinned project, computed by
    /// replaying the registry's PUBLIC history view. If the registry's `hookOf` ever disagrees with this oracle,
    /// the cohort-resolution spec is violated.
    /// @dev For a never-pinned project the rule is:
    ///   - if projectId > current threshold => current default
    ///   - else find the unique history segment with `minProjectIdExclusive < projectId <= maxProjectId`
    ///   - else (pre-dates all defaults) => address(0)
    function _expectedHookForUnpinned(uint256 projectId) internal view returns (IJBRulesetDataHook) {
        if (projectId > registry.defaultHookProjectIdThreshold()) return registry.defaultHook();

        uint256 len = registry.defaultHookHistoryLength();
        for (uint256 i; i < len; ++i) {
            DefaultHookSegment memory seg = registry.defaultHookHistoryAt(i);
            if (projectId > seg.minProjectIdExclusive && projectId <= seg.maxProjectId) {
                return seg.hook;
            }
        }
        return IJBRulesetDataHook(address(0));
    }

    //*********************************************************************//
    // -------- PROPERTY R1: hookOf matches the cohort oracle ------------ //
    //*********************************************************************//

    /// @notice Drive an arbitrary monotonic sequence of default changes, then assert `hookOf(projectId)` for a
    /// never-pinned project equals the independently-computed cohort hook. This proves the production walk in
    /// `_resolvedHookOf` and the spec re-derivation always agree.
    function testFuzz_hookOfMatchesCohortOracle(
        uint8[8] calldata hookChoices,
        uint16[8] calldata countSteps,
        uint256 projectId
    )
        public
    {
        uint256 count = 0;
        for (uint256 i; i < 8; ++i) {
            // Project count only grows over time (monotone): add the step before each default change.
            count += uint256(countSteps[i]);
            _setCount(count);

            vm.prank(owner);
            registry.setDefaultHook(hooks[hookChoices[i] % hooks.length]);
        }

        // A project the registry has not had a specific hook pinned for.
        projectId = bound(projectId, 0, count + 1000);

        assertEq(
            address(registry.hookOf(projectId)),
            address(_expectedHookForUnpinned(projectId)),
            "hookOf must equal the independently-derived cohort hook"
        );
        // hasMintPermissionFor must agree with hookOf: only the resolved hook may mint.
        IJBRulesetDataHook resolved = registry.hookOf(projectId);
        JBRuleset memory rs;
        if (address(resolved) != address(0)) {
            assertTrue(
                registry.hasMintPermissionFor(projectId, rs, address(resolved)),
                "resolved hook must hold mint permission"
            );
        }
        assertFalse(
            registry.hasMintPermissionFor(projectId, rs, address(0xBAD)),
            "a non-resolved address must never hold mint permission"
        );
    }

    //*********************************************************************//
    // -------- PROPERTY R2: defaults never retroactively re-route ------- //
    //*********************************************************************//

    /// @notice The core anti-rug invariant: once a project resolves to some default, a SUBSEQUENT default change
    /// (for a strictly higher project count) must NEVER change that earlier project's resolved hook. We snapshot
    /// the resolution of a set of project IDs, perform another default change at a higher count, and assert every
    /// earlier project's resolution is unchanged.
    function testFuzz_laterDefaultDoesNotRerouteEarlierCohort(
        uint8 firstHook,
        uint8 secondHook,
        uint16 firstCount,
        uint16 extraCount,
        uint256 probeId
    )
        public
    {
        uint256 c1 = uint256(firstCount);
        _setCount(c1);
        vm.prank(owner);
        registry.setDefaultHook(hooks[firstHook % hooks.length]);

        // Probe a project that existed at-or-before the first default's threshold (i.e. in or before the first cohort).
        probeId = bound(probeId, 0, c1);
        address resolvedBefore = address(registry.hookOf(probeId));

        // A second default change at a strictly-greater-or-equal count.
        uint256 c2 = c1 + uint256(extraCount);
        _setCount(c2);
        vm.prank(owner);
        registry.setDefaultHook(hooks[secondHook % hooks.length]);

        address resolvedAfter = address(registry.hookOf(probeId));
        assertEq(resolvedAfter, resolvedBefore, "a later default change must not re-route an earlier project");
    }

    //*********************************************************************//
    // -------- PROPERTY R3: pinned hook always wins & is stable --------- //
    //*********************************************************************//

    /// @notice Spec: a project-specific hook set via `setHookFor` overrides the default and is immune to later
    /// default changes. After pinning, `hookOf` must return the pinned hook regardless of any default activity.
    function testFuzz_pinnedHookOverridesDefault(
        uint8 pinChoice,
        uint8 laterDefaultChoice,
        uint16 countAtPin,
        uint16 extraCount,
        uint256 pinnedProjectId
    )
        public
    {
        // Allow + set a project-specific hook.
        IJBRulesetDataHook pinned = hooks[pinChoice % hooks.length];
        vm.prank(owner);
        registry.allowHook(pinned);

        pinnedProjectId = bound(pinnedProjectId, 0, type(uint128).max);
        vm.prank(projectOwner);
        registry.setHookFor(pinnedProjectId, pinned);

        assertEq(address(registry.hookOf(pinnedProjectId)), address(pinned), "pin must take effect immediately");

        // Now perform a default change at a higher count.
        _setCount(uint256(countAtPin) + uint256(extraCount) + 1);
        vm.prank(owner);
        registry.setDefaultHook(hooks[laterDefaultChoice % hooks.length]);

        assertEq(
            address(registry.hookOf(pinnedProjectId)),
            address(pinned),
            "a pinned hook must survive later default changes"
        );
    }

    //*********************************************************************//
    // -------- PROPERTY R4: a project is matched by <= 1 history segment  //
    //*********************************************************************//

    /// @notice Spec (NatSpec): "A projectId is matched by exactly one segment (or none)." The history segments
    /// must partition the project-ID space into disjoint half-open windows; no project ID may fall inside two
    /// segments. This guarantees the linear walk in `_resolvedHookOf` is deterministic.
    function testFuzz_historySegmentsDisjoint(
        uint8[6] calldata hookChoices,
        uint16[6] calldata countSteps,
        uint256 probeId
    )
        public
    {
        uint256 count;
        for (uint256 i; i < 6; ++i) {
            count += uint256(countSteps[i]);
            _setCount(count);
            vm.prank(owner);
            registry.setDefaultHook(hooks[hookChoices[i] % hooks.length]);
        }

        probeId = bound(probeId, 0, count + 100);

        uint256 len = registry.defaultHookHistoryLength();
        uint256 matches;
        for (uint256 i; i < len; ++i) {
            DefaultHookSegment memory seg = registry.defaultHookHistoryAt(i);
            if (probeId > seg.minProjectIdExclusive && probeId <= seg.maxProjectId) matches++;
        }
        assertLe(matches, 1, "no project ID may be matched by more than one history segment");
    }

    //*********************************************************************//
    // -------- PROPERTY R5: threshold equals last count ----------------- //
    //*********************************************************************//

    /// @notice Spec: `defaultHookProjectIdThreshold` is set to `PROJECTS.count()` on every default change, and the
    /// newest segment's `maxProjectId` equals that same count. Projects strictly above the threshold resolve to the
    /// (current) default; everything at-or-below walks the history. This ties the two storage fields together.
    function testFuzz_thresholdTracksCount(uint8 hookChoice, uint16 count) public {
        _setCount(uint256(count));
        vm.prank(owner);
        registry.setDefaultHook(hooks[hookChoice % hooks.length]);

        assertEq(registry.defaultHookProjectIdThreshold(), uint256(count), "threshold must equal count at last change");

        uint256 len = registry.defaultHookHistoryLength();
        assertGt(len, 0, "a segment must have been pushed");
        DefaultHookSegment memory last = registry.defaultHookHistoryAt(len - 1);
        assertEq(last.maxProjectId, uint256(count), "newest segment maxProjectId must equal the count");

        // Any project strictly above the threshold resolves to the just-set default.
        assertEq(
            address(registry.hookOf(uint256(count) + 1)),
            address(hooks[hookChoice % hooks.length]),
            "project above threshold resolves to current default"
        );
    }
}
