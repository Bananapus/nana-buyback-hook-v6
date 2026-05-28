// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {Test} from "forge-std/Test.sol";

import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";

/// @notice F-BUY-21 confirmation POC.
///
/// Hypothesis under test: the `expectedHook` parameter on `lockHookFor` is fragile against
/// a registry-owner front-run that changes the default hook between when the project owner
/// reads the active default and when their lock transaction lands. The TRIAGE asks: does the
/// race give the registry owner an "exploit window" by either
///   (1) locking the project to a stale historical hook the owner did not intend, or
///   (2) failing the lock when it should have succeeded (leaving the project unlocked and
///       vulnerable to a subsequent default-change attack).
///
/// What we find (and assert):
///   * Cohort-history (`_defaultHookHistory`) snapshots the OUTGOING default for the cohort
///     `(prevThreshold, count]` so projects in that window keep resolving to the hook that
///     was active at their creation, even after `setDefaultHook` rotates.
///   * Therefore, when a project owner reads `defaultHook == D` and submits
///     `lockHookFor(projectId, D)`, a front-running `setDefaultHook(E)` does NOT change the
///     resolved hook for that project — `_resolvedHookOf` walks history and returns D.
///   * The `expectedHook` check passes, the lock succeeds, and the project is pinned to D.
///   * The only way the lock fails is when the project owner's expectation is genuinely
///     wrong (they passed `E` when the resolved hook is `D`, or vice versa), which is the
///     documented purpose of the parameter.
///
/// Conclusion: F-BUY-21 is NOT exploitable. The race window the report worried about is
/// closed by the cohort-history design (`SetDefaultHookCohortHistory` regression). This file
/// pins that conclusion with concrete POC scenarios so future refactors of `_resolvedHookOf`
/// or `setDefaultHook` cannot silently regress it.
contract CodexNemesisLockHookDefaultFrontRunTest is Test {
    JBBuybackHookRegistry internal registry;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    address internal registryOwner = makeAddr("registryOwner");
    address internal projectOwner = makeAddr("projectOwner");
    address internal trustedForwarder = makeAddr("forwarder");

    IJBRulesetDataHook internal hookD = IJBRulesetDataHook(makeAddr("hookD"));
    IJBRulesetDataHook internal hookE = IJBRulesetDataHook(makeAddr("hookE"));
    IJBRulesetDataHook internal hookF = IJBRulesetDataHook(makeAddr("hookF"));

    uint256 internal constant PROJECT_ID = 75;

    function setUp() public {
        registry = new JBBuybackHookRegistry(permissions, projects, registryOwner, trustedForwarder);

        // Project ownership is fixed; `_requirePermissionFrom` reads ownerOf to resolve the account argument.
        vm.mockCall(
            address(projects), abi.encodeWithSignature("ownerOf(uint256)", PROJECT_ID), abi.encode(projectOwner)
        );

        // Permissions are open: this isolates the race-condition analysis from access control.
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature("hasPermission(address,address,uint256,uint256,bool,bool)"),
            abi.encode(true)
        );

        // Allow the candidate hooks so `setDefaultHook` / `setHookFor` don't short-circuit on the allowlist.
        vm.startPrank(registryOwner);
        registry.allowHook(hookD);
        registry.allowHook(hookE);
        registry.allowHook(hookF);
        vm.stopPrank();
    }

    function _mockCount(uint256 c) internal {
        vm.mockCall(address(projects), abi.encodeWithSignature("count()"), abi.encode(c));
    }

    //*********************************************************************//
    // --- F-BUY-21 race scenarios -------------------------------------- //
    //*********************************************************************//

    /// @notice Race scenario described in TRIAGE: project owner reads default == D,
    /// registry owner front-runs `setDefaultHook(E)`, project owner's `lockHookFor(_, D)`
    /// lands afterwards. The lock MUST succeed and pin D — cohort history preserves the
    /// project's eligibility for D even though `defaultHook` now points at E.
    function test_frontRunDefaultChange_preservesExpectedHookAndPinsHistoricalDefault() public {
        // Cold-start the registry with default = D when count = 50, so projects in (50, count]
        // resolve to D via the "current default" branch (projectId > threshold).
        _mockCount(50);
        vm.prank(registryOwner);
        registry.setDefaultHook(hookD);

        // Project 75 exists in the cohort that inherits D. Confirm the resolver agrees.
        _mockCount(100);
        assertEq(address(registry.hookOf(PROJECT_ID)), address(hookD), "pre-race: project resolves to D");

        // Project owner reads default = D and submits lockHookFor(PROJECT_ID, D).
        // BEFORE that transaction lands, the registry owner rotates the default to E.
        vm.prank(registryOwner);
        registry.setDefaultHook(hookE);

        // After the rotation: defaultHook = E, threshold = 100, history records (50, 100, D).
        // The project's resolution should walk history back to D, NOT mistakenly return E.
        assertEq(
            address(registry.hookOf(PROJECT_ID)), address(hookD), "post-rotation: cohort still resolves to historical D"
        );

        // Project owner's lock transaction lands. The `expectedHook == D` check must pass.
        vm.prank(projectOwner);
        registry.lockHookFor(PROJECT_ID, hookD);

        // Lock is permanent and pinned to D — the registry owner cannot retarget the project.
        assertTrue(registry.hasLockedHook(PROJECT_ID), "project is locked");
        assertEq(address(registry.hookOf(PROJECT_ID)), address(hookD), "project pinned to D, not E");
    }

    /// @notice Second variant: registry owner rotates the default TWICE before the lock tx
    /// lands. The cohort history must still walk back to D — a multi-rotation front-run does
    /// not open the window either.
    function test_frontRunMultipleDefaultChanges_stillResolvesToHistoricalD() public {
        _mockCount(50);
        vm.prank(registryOwner);
        registry.setDefaultHook(hookD);

        _mockCount(100);
        assertEq(address(registry.hookOf(PROJECT_ID)), address(hookD), "pre-race: cohort D");

        // Front-run #1: D -> E. Snapshots (50, 100, D).
        vm.prank(registryOwner);
        registry.setDefaultHook(hookE);

        // Front-run #2: E -> F. Snapshots (100, count_at_step, E). If `count` did not change
        // between the two rotations, the second segment is empty `(100, 100]`. Either way,
        // the segment that covers PROJECT_ID (=75) is the first one and still points at D.
        vm.prank(registryOwner);
        registry.setDefaultHook(hookF);

        assertEq(
            address(registry.hookOf(PROJECT_ID)), address(hookD), "two rotations cannot retarget historical cohort"
        );

        // Lock succeeds and pins D.
        vm.prank(projectOwner);
        registry.lockHookFor(PROJECT_ID, hookD);
        assertTrue(registry.hasLockedHook(PROJECT_ID), "locked");
        assertEq(address(registry.hookOf(PROJECT_ID)), address(hookD), "still D");
    }

    /// @notice Third variant: a NEW project (id == 200) is born in the window where E is the
    /// active default. The project owner reads default = E and submits lockHookFor(200, E).
    /// Registry owner front-runs with setDefaultHook(F). After the front-run, project 200
    /// still resolves to E via the second history segment, so the lock succeeds at E.
    function test_postRotationCohort_isAlsoProtected() public {
        // Cold-start with D, then rotate to E. After this, projects with id > 100 resolve to E.
        _mockCount(50);
        vm.prank(registryOwner);
        registry.setDefaultHook(hookD);

        _mockCount(100);
        vm.prank(registryOwner);
        registry.setDefaultHook(hookE);

        // Project 200 is created in E's cohort (count goes to 200).
        _mockCount(200);
        uint256 newProjectId = 200;
        vm.mockCall(
            address(projects), abi.encodeWithSignature("ownerOf(uint256)", newProjectId), abi.encode(projectOwner)
        );
        assertEq(address(registry.hookOf(newProjectId)), address(hookE), "project 200 inherits current default E");

        // Registry owner front-runs setDefaultHook(F). This snapshots (100, 200, E).
        vm.prank(registryOwner);
        registry.setDefaultHook(hookF);

        // Project 200 still resolves to E.
        assertEq(address(registry.hookOf(newProjectId)), address(hookE), "project 200 keeps historical E");

        // Lock succeeds at E.
        vm.prank(projectOwner);
        registry.lockHookFor(newProjectId, hookE);
        assertTrue(registry.hasLockedHook(newProjectId));
        assertEq(address(registry.hookOf(newProjectId)), address(hookE), "pinned to E");
    }

    /// @notice The protective intent of `expectedHook` actually fires: when the project owner
    /// submits a STALE expectation that does NOT match the resolved hook, the lock reverts.
    /// This proves the parameter is wired correctly even when the resolver returns a non-zero
    /// hook (so the early `HookNotSet` revert isn't masking the mismatch path).
    function test_mismatchedExpectedHook_revertsRatherThanLockingWrongHook() public {
        _mockCount(50);
        vm.prank(registryOwner);
        registry.setDefaultHook(hookD);
        _mockCount(100);

        // Project owner thinks the resolved hook is E but it's actually D — the lock reverts.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookMismatch.selector, hookD, hookE)
        );
        registry.lockHookFor(PROJECT_ID, hookE);

        assertFalse(registry.hasLockedHook(PROJECT_ID), "stale expectation must not lock");
        // CRITICAL: even though `_hookOf` is written before the mismatch revert, the revert
        // rolls back ALL state mutations. The pin from the failed call must not persist.
        assertEq(
            address(registry.hookOf(PROJECT_ID)),
            address(hookD),
            "resolver still walks the default path (no leftover pin from reverted tx)"
        );
    }

    //*********************************************************************//
    // --- F-BUY-20 corollary: setHookFor(p, 0) regresses to history --- //
    //*********************************************************************//

    /// @notice F-BUY-20: an authorized caller can clear a project's explicit hook by calling
    /// `setHookFor(p, address(0))` (this is documented as the intended "unset" path). But the
    /// resolver then walks history and may return a STALE default, not the CURRENT default.
    /// This POC documents the regression so the explicit "fall back to CURRENT default" fix
    /// can be tested against it.
    function test_setHookForZero_resolvesToHistoricalNotCurrentDefault() public {
        // Step 1: cold-start default = D, project 75 inherits D.
        _mockCount(50);
        vm.prank(registryOwner);
        registry.setDefaultHook(hookD);
        _mockCount(100);

        // Step 2: project owner picks a different explicit hook (E) and the registry owner
        // also allows address(0) so a later `setHookFor(_, 0)` can clear back to default.
        vm.prank(projectOwner);
        registry.setHookFor(PROJECT_ID, hookE);
        vm.prank(registryOwner);
        registry.allowHook(IJBRulesetDataHook(address(0)));
        assertEq(address(registry.hookOf(PROJECT_ID)), address(hookE), "explicit E set");

        // Step 3: registry owner rotates the default forward: D -> F. After this, NEW
        // projects in (100, count] should inherit F.
        vm.prank(registryOwner);
        registry.setDefaultHook(hookF);

        // Step 4: project owner clears their explicit hook back to "default".
        vm.prank(projectOwner);
        registry.setHookFor(PROJECT_ID, IJBRulesetDataHook(address(0)));

        // EXPECTED (intuitive): project now follows the CURRENT default F.
        // ACTUAL: project resolves to D — the historical default for its cohort — because
        // `_resolvedHookOf` walks `_defaultHookHistory` for ids `<= defaultHookProjectIdThreshold`.
        // This is the F-BUY-20 stale-default regression.
        assertEq(
            address(registry.hookOf(PROJECT_ID)),
            address(hookD),
            "F-BUY-20: setHookFor(_, 0) regresses to historical default D, not current default F"
        );
        assertTrue(
            address(registry.hookOf(PROJECT_ID)) != address(registry.defaultHook()),
            "F-BUY-20: resolver disagrees with the current `defaultHook` field"
        );
    }
}
