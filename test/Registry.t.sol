// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import "@bananapus/core-v6/src/structs/JBRuleset.sol";
import "@bananapus/core-v6/src/libraries/JBConstants.sol";
import "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import "src/JBBuybackHookRegistry.sol";

/// @notice Unit tests for `JBBuybackHookRegistry`.
contract Test_BuybackHookRegistry_Unit is Test {
    JBBuybackHookRegistry registry;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    address owner = makeAddr("owner");
    address trustedForwarder = makeAddr("forwarder");

    address dude = makeAddr("dude");
    address projectOwner = makeAddr("projectOwner");

    uint256 projectId = 42;

    // Two mock hooks.
    IJBRulesetDataHook hookA = IJBRulesetDataHook(makeAddr("hookA"));
    IJBRulesetDataHook hookB = IJBRulesetDataHook(makeAddr("hookB"));

    // Events (from IJBBuybackHookRegistry).
    event JBBuybackHookRegistry_AllowHook(IJBRulesetDataHook hook);
    event JBBuybackHookRegistry_DisallowHook(IJBRulesetDataHook hook);
    event JBBuybackHookRegistry_SetDefaultHook(IJBRulesetDataHook hook);
    event JBBuybackHookRegistry_SetHook(uint256 indexed projectId, IJBRulesetDataHook hook);
    event JBBuybackHookRegistry_LockHook(uint256 indexed projectId);

    function setUp() public {
        registry = new JBBuybackHookRegistry(permissions, projects, owner, trustedForwarder);

        // Mock PROJECTS.ownerOf to return projectOwner for the test project.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(projectOwner)
        );

        // Mock permissions to return true by default (for authorized calls).
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
    }

    //*********************************************************************//
    // --- Constructor --------------------------------------------------- //
    //*********************************************************************//

    function test_constructor() public view {
        assertEq(address(registry.PROJECTS()), address(projects), "PROJECTS should be set");
        assertEq(registry.owner(), owner, "owner should be set");
    }

    //*********************************************************************//
    // --- allowHook ----------------------------------------------------- //
    //*********************************************************************//

    function test_allowHook_setsAllowed() public {
        assertFalse(registry.isHookAllowed(hookA), "hookA should not be allowed initially");

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit JBBuybackHookRegistry_AllowHook(hookA);
        registry.allowHook(hookA);

        assertTrue(registry.isHookAllowed(hookA), "hookA should be allowed");
    }

    function test_allowHook_revertsIfNotOwner() public {
        vm.prank(dude);
        vm.expectRevert();
        registry.allowHook(hookA);
    }

    //*********************************************************************//
    // --- disallowHook -------------------------------------------------- //
    //*********************************************************************//

    function test_disallowHook_clearsAllowed() public {
        // First allow.
        vm.prank(owner);
        registry.allowHook(hookA);
        assertTrue(registry.isHookAllowed(hookA));

        // Disallow.
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit JBBuybackHookRegistry_DisallowHook(hookA);
        registry.disallowHook(hookA);

        assertFalse(registry.isHookAllowed(hookA), "hookA should be disallowed");
    }

    function test_disallowHook_revertsIfNotOwner() public {
        vm.prank(dude);
        vm.expectRevert();
        registry.disallowHook(hookA);
    }

    //*********************************************************************//
    // --- setDefaultHook ------------------------------------------------ //
    //*********************************************************************//

    function test_setDefaultHook() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit JBBuybackHookRegistry_SetDefaultHook(hookA);
        registry.setDefaultHook(hookA);

        assertEq(address(registry.defaultHook()), address(hookA), "defaultHook should be hookA");
        assertTrue(registry.isHookAllowed(hookA), "setDefaultHook should also allow the hook");
    }

    function test_setDefaultHook_revertsIfNotOwner() public {
        vm.prank(dude);
        vm.expectRevert();
        registry.setDefaultHook(hookA);
    }

    //*********************************************************************//
    // --- setHookFor ---------------------------------------------------- //
    //*********************************************************************//

    function test_setHookFor() public {
        // Allow hookA first.
        vm.prank(owner);
        registry.allowHook(hookA);

        // Set hook for project.
        vm.prank(projectOwner);
        vm.expectEmit(true, false, false, true);
        emit JBBuybackHookRegistry_SetHook(projectId, hookA);
        registry.setHookFor(projectId, hookA);

        assertEq(address(registry.hookOf(projectId)), address(hookA), "hookOf should be hookA");
    }

    function test_setHookFor_revertsIfLocked() public {
        // Allow and set hook.
        vm.prank(owner);
        registry.allowHook(hookA);
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookA);

        // Lock.
        vm.prank(projectOwner);
        registry.lockHookFor(projectId, hookA);

        // Try to set again.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookLocked.selector, projectId)
        );
        registry.setHookFor(projectId, hookB);
    }

    function test_setHookFor_revertsIfNotAllowed() public {
        // hookA is not allowed.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookNotAllowed.selector, hookA)
        );
        registry.setHookFor(projectId, hookA);
    }

    function test_setHookFor_revertsIfUnauthorized() public {
        vm.prank(owner);
        registry.allowHook(hookA);

        // Mock permissions to return false.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false)
        );

        vm.prank(dude);
        vm.expectRevert();
        registry.setHookFor(projectId, hookA);
    }

    //*********************************************************************//
    // --- lockHookFor --------------------------------------------------- //
    //*********************************************************************//

    function test_lockHookFor() public {
        // Allow and set.
        vm.prank(owner);
        registry.allowHook(hookA);
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookA);

        assertFalse(registry.hasLockedHook(projectId), "should not be locked initially");

        // Lock.
        vm.prank(projectOwner);
        registry.lockHookFor(projectId, hookA);

        assertTrue(registry.hasLockedHook(projectId), "should be locked");
    }

    function test_lockHookFor_locksInDefault() public {
        // Set a default hook.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        // No project-specific hook set. hookOf should already return the default.
        assertEq(address(registry.hookOf(projectId)), address(hookA), "hookOf should return default before lock");

        vm.prank(projectOwner);
        registry.lockHookFor(projectId, hookA);

        assertEq(address(registry.hookOf(projectId)), address(hookA), "lockHookFor should copy default");
        assertTrue(registry.hasLockedHook(projectId), "should be locked");
    }

    //*********************************************************************//
    // --- beforePayRecordedWith ----------------------------------------- //
    //*********************************************************************//

    function test_beforePayRecordedWith_forwardsToProjectHook() public {
        // Allow and set hookA for project.
        vm.prank(owner);
        registry.allowHook(hookA);
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookA);

        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](0);

        // Mock hookA.beforePayRecordedWith to return weight=100.
        vm.mockCall(
            address(hookA),
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(100), specs)
        );

        JBBeforePayRecordedContext memory context = _makePayContext(projectId);

        (uint256 weight, JBPayHookSpecification[] memory hookSpecs) = registry.beforePayRecordedWith(context);
        assertEq(weight, 100, "should forward weight from hookA");
        assertEq(hookSpecs.length, 0, "should forward specs from hookA");
    }

    function test_beforePayRecordedWith_fallsBackToDefault() public {
        // Set default hook (no project-specific hook set).
        vm.prank(owner);
        registry.setDefaultHook(hookB);

        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](0);

        // Mock hookB.beforePayRecordedWith to return weight=200.
        vm.mockCall(
            address(hookB),
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(200), specs)
        );

        JBBeforePayRecordedContext memory context = _makePayContext(projectId);

        (uint256 weight,) = registry.beforePayRecordedWith(context);
        assertEq(weight, 200, "should use default hook when no project hook set");
    }

    //*********************************************************************//
    // --- beforeCashOutRecordedWith ------------------------------------- //
    //*********************************************************************//

    function test_beforeCashOutRecordedWith_passThrough() public {
        JBBeforeCashOutRecordedContext memory context = _makeCashOutContext(projectId);

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply, JBCashOutHookSpecification[] memory specs) =
            registry.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, context.cashOutTaxRate, "should pass through cashOutTaxRate");
        assertEq(cashOutCount, context.cashOutCount, "should pass through cashOutCount");
        assertEq(totalSupply, context.totalSupply, "should pass through totalSupply");
        assertEq(specs.length, 0, "should return empty specs");
    }

    //*********************************************************************//
    // --- hasMintPermissionFor ------------------------------------------ //
    //*********************************************************************//

    function test_hasMintPermissionFor_trueForHook() public {
        // Allow and set hookA for project.
        vm.prank(owner);
        registry.allowHook(hookA);
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookA);

        JBRuleset memory ruleset;
        assertTrue(
            registry.hasMintPermissionFor(projectId, ruleset, address(hookA)),
            "hookA address should have mint permission"
        );
    }

    function test_hasMintPermissionFor_falseForOther() public {
        // Allow and set hookA for project.
        vm.prank(owner);
        registry.allowHook(hookA);
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookA);

        JBRuleset memory ruleset;
        assertFalse(
            registry.hasMintPermissionFor(projectId, ruleset, dude), "random address should not have mint permission"
        );
    }

    function test_hasMintPermissionFor_usesDefault() public {
        // Set default hook (no project-specific hook).
        vm.prank(owner);
        registry.setDefaultHook(hookB);

        JBRuleset memory ruleset;
        assertTrue(
            registry.hasMintPermissionFor(projectId, ruleset, address(hookB)),
            "default hook address should have mint permission"
        );
        assertFalse(
            registry.hasMintPermissionFor(projectId, ruleset, address(hookA)),
            "non-default hook should not have mint permission"
        );
    }

    //*********************************************************************//
    // --- supportsInterface --------------------------------------------- //
    //*********************************************************************//

    function test_supportsInterface() public view {
        assertTrue(
            registry.supportsInterface(type(IJBRulesetDataHook).interfaceId), "should support IJBRulesetDataHook"
        );
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId), "should support IERC165");
    }

    //*********************************************************************//
    // --- hookOf default fallback --------------------------------------- //
    //*********************************************************************//

    function test_hookOf_returnsDefaultWhenNoProjectHook() public {
        // Set a default hook.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        // No project-specific hook set — hookOf should return the default.
        assertEq(address(registry.hookOf(projectId)), address(hookA), "hookOf should return defaultHook");
    }

    function test_hookOf_returnsProjectHookOverDefault() public {
        // Set default to hookA, then set project-specific to hookB.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        vm.prank(owner);
        registry.allowHook(hookB);
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookB);

        assertEq(address(registry.hookOf(projectId)), address(hookB), "hookOf should prefer project hook");
    }

    function test_hookOf_returnsZeroWhenNoDefaultAndNoProjectHook() public view {
        // No default, no project hook → address(0).
        assertEq(address(registry.hookOf(projectId)), address(0), "hookOf should be address(0) with no hooks");
    }

    //*********************************************************************//
    // --- Hook Switching ------------------------------------------------ //
    //*********************************************************************//

    function test_switchHook() public {
        // Allow both hooks.
        vm.startPrank(owner);
        registry.allowHook(hookA);
        registry.allowHook(hookB);
        vm.stopPrank();

        // Set hookA.
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookA);
        assertEq(address(registry.hookOf(projectId)), address(hookA));

        // Switch to hookB.
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookB);
        assertEq(address(registry.hookOf(projectId)), address(hookB));
    }

    //*********************************************************************//
    // --- disallowHook clears defaultHook ------------------------------- //
    //*********************************************************************//

    function test_disallowHook_clearsDefaultIfMatch() public {
        // Set hookA as default.
        vm.prank(owner);
        registry.setDefaultHook(hookA);
        assertEq(address(registry.defaultHook()), address(hookA));

        // Disallow hookA — should clear the default.
        vm.prank(owner);
        registry.disallowHook(hookA);

        assertEq(address(registry.defaultHook()), address(0), "defaultHook should be cleared when disallowed");
    }

    function test_disallowHook_doesNotClearDefaultIfNoMatch() public {
        // Set hookA as default, disallow hookB.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        vm.prank(owner);
        registry.allowHook(hookB);

        vm.prank(owner);
        registry.disallowHook(hookB);

        assertEq(
            address(registry.defaultHook()),
            address(hookA),
            "defaultHook should remain when disallowing a different hook"
        );
    }

    //*********************************************************************//
    // --- lockHookFor reverts when no hook set -------------------------- //
    //*********************************************************************//

    function test_lockHookFor_revertsWhenNoHookAndNoDefault() public {
        // No project hook, no default — should revert.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookNotSet.selector, projectId)
        );
        registry.lockHookFor(projectId, hookA);
    }

    function test_lockHookFor_revertsWhenDefaultWasDisallowed() public {
        // Set default, then disallow it (clears default).
        vm.prank(owner);
        registry.setDefaultHook(hookA);
        vm.prank(owner);
        registry.disallowHook(hookA);

        // No project hook, default is now zero — should revert.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookNotSet.selector, projectId)
        );
        registry.lockHookFor(projectId, hookA);
    }

    function test_lockHookFor_revertsOnMismatch() public {
        // Allow and set hookA.
        vm.prank(owner);
        registry.allowHook(hookA);
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookA);

        // Try to lock with hookB as expected — should revert.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHookRegistry.JBBuybackHookRegistry_HookMismatch.selector, hookA, hookB)
        );
        registry.lockHookFor(projectId, hookB);
    }

    //*********************************************************************//
    // --- setPoolFor ---------------------------------------------------- //
    //*********************************************************************//

    function test_setPoolFor_forwardsToResolvedHook() public {
        // Set hookA as default.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        // Build the expected calldata for the simplified setPoolFor overload.
        bytes memory expectedCalldata = abi.encodeWithSignature(
            "setPoolFor(uint256,uint24,int24,uint256,address)",
            projectId,
            uint24(10_000),
            int24(60),
            uint256(2 days),
            address(0xEEEe)
        );

        // Mock and expect the call on hookA.
        vm.mockCall(address(hookA), expectedCalldata, abi.encode());
        vm.expectCall(address(hookA), expectedCalldata);

        registry.setPoolFor({
            projectId: projectId, fee: 10_000, tickSpacing: 60, twapWindow: 2 days, terminalToken: address(0xEEEe)
        });
    }

    function test_setPoolFor_usesProjectSpecificHook() public {
        // Allow and set hookB for this project.
        vm.prank(owner);
        registry.allowHook(hookB);
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookB);

        // Set a different default (hookA) to prove the project hook is used.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        // Build the expected calldata.
        bytes memory expectedCalldata = abi.encodeWithSignature(
            "setPoolFor(uint256,uint24,int24,uint256,address)",
            projectId,
            uint24(3000),
            int24(10),
            uint256(1 days),
            address(0xEEEe)
        );

        // Mock and expect the call goes to hookB, NOT hookA.
        vm.mockCall(address(hookB), expectedCalldata, abi.encode());
        vm.expectCall(address(hookB), expectedCalldata);

        registry.setPoolFor({
            projectId: projectId, fee: 3000, tickSpacing: 10, twapWindow: 1 days, terminalToken: address(0xEEEe)
        });
    }

    function test_setPoolFor_revertsIfUnauthorized() public {
        // Set hookA as default.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        // Mock permissions to return false — caller has no SET_BUYBACK_POOL permission.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false)
        );

        vm.prank(dude);
        vm.expectRevert();
        registry.setPoolFor({
            projectId: projectId, fee: 10_000, tickSpacing: 60, twapWindow: 2 days, terminalToken: address(0xEEEe)
        });
    }

    function test_setPoolFor_succeedsForProjectOwner() public {
        // Set hookA as default.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        // Build expected calldata.
        bytes memory expectedCalldata = abi.encodeWithSignature(
            "setPoolFor(uint256,uint24,int24,uint256,address)",
            projectId,
            uint24(10_000),
            int24(60),
            uint256(2 days),
            address(0xEEEe)
        );

        // Mock the forwarded call on hookA.
        vm.mockCall(address(hookA), expectedCalldata, abi.encode());
        vm.expectCall(address(hookA), expectedCalldata);

        // Project owner should be able to call setPoolFor.
        vm.prank(projectOwner);
        registry.setPoolFor({
            projectId: projectId, fee: 10_000, tickSpacing: 60, twapWindow: 2 days, terminalToken: address(0xEEEe)
        });
    }

    function test_setPoolFor_succeedsForPermissionedOperator() public {
        // Set hookA as default.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        // Build expected calldata.
        bytes memory expectedCalldata = abi.encodeWithSignature(
            "setPoolFor(uint256,uint24,int24,uint256,address)",
            projectId,
            uint24(10_000),
            int24(60),
            uint256(2 days),
            address(0xEEEe)
        );

        // Mock the forwarded call on hookA.
        vm.mockCall(address(hookA), expectedCalldata, abi.encode());
        vm.expectCall(address(hookA), expectedCalldata);

        // Dude (not project owner) has permission via mock — should succeed.
        vm.prank(dude);
        registry.setPoolFor({
            projectId: projectId, fee: 10_000, tickSpacing: 60, twapWindow: 2 days, terminalToken: address(0xEEEe)
        });
    }

    //*********************************************************************//
    // --- initializePoolFor --------------------------------------------- //
    //*********************************************************************//

    function test_initializePoolFor_forwardsToResolvedHook() public {
        // Set hookA as default.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        // Build the expected calldata for initializePoolFor.
        bytes memory expectedCalldata = abi.encodeWithSignature(
            "initializePoolFor(uint256,uint24,int24,uint256,address,uint160)",
            projectId,
            uint24(10_000),
            int24(200),
            uint256(2 days),
            address(0xEEEe),
            TickMath.getSqrtPriceAtTick(0)
        );

        // Mock and expect the call on hookA.
        vm.mockCall(address(hookA), expectedCalldata, abi.encode());
        vm.expectCall(address(hookA), expectedCalldata);

        registry.initializePoolFor({
            projectId: projectId,
            fee: 10_000,
            tickSpacing: 200,
            twapWindow: 2 days,
            terminalToken: address(0xEEEe),
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0)
        });
    }

    function test_initializePoolFor_usesProjectSpecificHook() public {
        // Allow and set hookB for this project.
        vm.prank(owner);
        registry.allowHook(hookB);
        vm.prank(projectOwner);
        registry.setHookFor(projectId, hookB);

        // Set a different default (hookA) to prove the project hook is used.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        // Build the expected calldata.
        bytes memory expectedCalldata = abi.encodeWithSignature(
            "initializePoolFor(uint256,uint24,int24,uint256,address,uint160)",
            projectId,
            uint24(10_000),
            int24(200),
            uint256(2 days),
            address(0xEEEe),
            TickMath.getSqrtPriceAtTick(0)
        );

        // Mock and expect the call goes to hookB, NOT hookA.
        vm.mockCall(address(hookB), expectedCalldata, abi.encode());
        vm.expectCall(address(hookB), expectedCalldata);

        registry.initializePoolFor({
            projectId: projectId,
            fee: 10_000,
            tickSpacing: 200,
            twapWindow: 2 days,
            terminalToken: address(0xEEEe),
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0)
        });
    }

    function test_initializePoolFor_revertsIfUnauthorized() public {
        // Set hookA as default.
        vm.prank(owner);
        registry.setDefaultHook(hookA);

        // Mock permissions to return false.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false)
        );

        vm.prank(dude);
        vm.expectRevert();
        registry.initializePoolFor({
            projectId: projectId,
            fee: 10_000,
            tickSpacing: 200,
            twapWindow: 2 days,
            terminalToken: address(0xEEEe),
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0)
        });
    }

    //*********************************************************************//
    // --- Helpers ------------------------------------------------------- //
    //*********************************************************************//

    function _makePayContext(uint256 pid) internal returns (JBBeforePayRecordedContext memory) {
        return JBBeforePayRecordedContext({
            terminal: makeAddr("terminal"),
            payer: dude,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 1 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            projectId: pid,
            rulesetId: 0,
            beneficiary: dude,
            weight: 69,
            reservedPercent: 0,
            metadata: ""
        });
    }

    function _makeCashOutContext(uint256 pid) internal returns (JBBeforeCashOutRecordedContext memory) {
        return JBBeforeCashOutRecordedContext({
            terminal: makeAddr("terminal"),
            holder: dude,
            projectId: pid,
            rulesetId: 0,
            cashOutCount: 1000,
            totalSupply: 10_000,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 5 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            useTotalSurplus: false,
            cashOutTaxRate: 5000,
            metadata: ""
        });
    }
}
