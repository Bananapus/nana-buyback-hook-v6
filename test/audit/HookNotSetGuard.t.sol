// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

// Foundry test harness.
import {Test} from "forge-std/Test.sol";

// Core interfaces used by the registry constructor.
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";

// Structs needed to build the beforePayRecordedWith context.
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

// NATIVE_TOKEN sentinel used in the pay context.
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

// Contract under test.
import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";

/// @notice Regression tests proving that `initializePoolFor`, `setPoolFor`, and
///         `beforePayRecordedWith` all revert with `HookNotSet` when neither a
///         project-specific hook nor a default hook has been configured.
contract HookNotSetGuardTest is Test {
    // --- State ----------------------------------------------------------

    // The registry instance under test.
    JBBuybackHookRegistry registry;

    // Mocked core dependencies (never called in these paths).
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));

    // Addresses used across tests.
    address owner = makeAddr("owner");
    address trustedForwarder = makeAddr("forwarder");
    address projectOwner = makeAddr("projectOwner");

    // The project that has NO hook configured.
    uint256 projectId = 99;

    // --- Setup ----------------------------------------------------------

    function setUp() public {
        // Deploy the registry with no default hook and no per-project hook.
        registry = new JBBuybackHookRegistry(permissions, projects, owner, trustedForwarder);

        // Mock PROJECTS.ownerOf so permission checks pass where needed.
        vm.mockCall(address(projects), abi.encodeWithSignature("ownerOf(uint256)", projectId), abi.encode(projectOwner));

        // Mock permissions.hasPermission to always return true (we are not testing auth here).
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
    }

    // --- initializePoolFor revert test ----------------------------------

    /// @notice `initializePoolFor` must revert with `HookNotSet` when
    ///         `_hookOf[projectId]` is zero AND `defaultHook` is zero.
    function test_initializePoolFor_revertsWhenNoHookSet() public {
        // Confirm neither a project-specific hook nor a default hook is set.
        assertEq(address(registry.hookOf(projectId)), address(0), "hookOf should be zero before test");

        // Build the expected revert payload.
        bytes memory expectedRevert =
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookNotSet.selector, projectId);

        // Expect the HookNotSet revert.
        vm.expectRevert(expectedRevert);

        // Call initializePoolFor as the project owner.
        vm.prank(projectOwner);
        registry.initializePoolFor({
            projectId: projectId,
            fee: 10_000,
            tickSpacing: 60,
            twapWindow: 2 days,
            terminalToken: address(0xEEEe),
            sqrtPriceX96: 1 // Arbitrary; we never reach the forwarding call.
        });
    }

    // --- setPoolFor revert test -----------------------------------------

    /// @notice `setPoolFor` must revert with `HookNotSet` when
    ///         `_hookOf[projectId]` is zero AND `defaultHook` is zero.
    function test_setPoolFor_revertsWhenNoHookSet() public {
        // Confirm neither a project-specific hook nor a default hook is set.
        assertEq(address(registry.hookOf(projectId)), address(0), "hookOf should be zero before test");

        // Build the expected revert payload.
        bytes memory expectedRevert =
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookNotSet.selector, projectId);

        // Expect the HookNotSet revert.
        vm.expectRevert(expectedRevert);

        // Call setPoolFor as the project owner.
        vm.prank(projectOwner);
        registry.setPoolFor({
            projectId: projectId, fee: 10_000, tickSpacing: 60, twapWindow: 2 days, terminalToken: address(0xEEEe)
        });
    }

    // --- beforePayRecordedWith revert test ------------------------------

    /// @notice `beforePayRecordedWith` must revert with `HookNotSet` when
    ///         `_hookOf[projectId]` is zero AND `defaultHook` is zero.
    function test_beforePayRecordedWith_revertsWhenNoHookSet() public {
        // Confirm neither a project-specific hook nor a default hook is set.
        assertEq(address(registry.hookOf(projectId)), address(0), "hookOf should be zero before test");

        // Build a minimal pay context for the project with no hook.
        JBBeforePayRecordedContext memory context = JBBeforePayRecordedContext({
            terminal: makeAddr("terminal"), // Arbitrary terminal address.
            payer: makeAddr("payer"), // Arbitrary payer address.
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN, // Pay with native token.
                value: 1 ether, // 1 ETH payment.
                decimals: 18, // 18-decimal precision.
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)) // Currency matches token.
            }),
            projectId: projectId, // The project with no hook.
            rulesetId: 0, // Not relevant for this test.
            beneficiary: makeAddr("beneficiary"), // Arbitrary beneficiary.
            weight: 1e18, // Arbitrary weight.
            reservedPercent: 0, // No reserved tokens.
            metadata: "" // Empty metadata.
        });

        // Build the expected revert payload.
        bytes memory expectedRevert =
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookNotSet.selector, projectId);

        // Expect the HookNotSet revert.
        vm.expectRevert(expectedRevert);

        // Call beforePayRecordedWith (a view function, but reverts are still caught).
        registry.beforePayRecordedWith(context);
    }
}
