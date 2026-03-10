// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBBuybackHook} from "./interfaces/IJBBuybackHook.sol";
import {IJBBuybackHookRegistry} from "./interfaces/IJBBuybackHookRegistry.sol";

contract JBBuybackHookRegistry is IJBBuybackHookRegistry, ERC2771Context, JBPermissioned, Ownable {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBBuybackHookRegistry_HookLocked(uint256 projectId);
    error JBBuybackHookRegistry_HookMismatch(IJBRulesetDataHook currentHook, IJBRulesetDataHook expectedHook);
    error JBBuybackHookRegistry_HookNotAllowed(IJBRulesetDataHook hook);
    error JBBuybackHookRegistry_HookNotSet(uint256 projectId);
    error JBBuybackHookRegistry_ZeroHook();

    //*********************************************************************//
    // -------------------- public immutable properties ------------------ //
    //*********************************************************************//

    /// @notice The project registry.
    IJBProjects public immutable override PROJECTS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The default hook to use.
    IJBRulesetDataHook public override defaultHook;

    /// @notice Whether the hook for the given project is locked.
    /// @custom:param projectId The ID of the project to get the locked hook for.
    mapping(uint256 projectId => bool) public override hasLockedHook;

    /// @notice Whether the given hook is allowed for a project.
    /// @custom:param hook The hook to check.
    mapping(IJBRulesetDataHook hook => bool) public override isHookAllowed;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice The hook explicitly set for the given project.
    /// @custom:param projectId The ID of the project to get the hook for.
    mapping(uint256 projectId => IJBRulesetDataHook) internal _hookOf;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param permissions The permissions contract.
    /// @param projects The project registry.
    /// @param owner The owner of the contract.
    /// @param trustedForwarder A trusted forwarder of transactions to this contract.
    constructor(
        IJBPermissions permissions,
        IJBProjects projects,
        address owner,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
        Ownable(owner)
    {
        PROJECTS = projects;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Allow a hook.
    /// @dev Only the owner can allow a hook.
    /// @param hook The hook to allow.
    function allowHook(IJBRulesetDataHook hook) external onlyOwner {
        // Allow the hook.
        isHookAllowed[hook] = true;

        emit JBBuybackHookRegistry_AllowHook(hook);
    }

    /// @notice Disallow a hook.
    /// @dev Only the owner can disallow a hook.
    /// @param hook The hook to disallow.
    function disallowHook(IJBRulesetDataHook hook) external onlyOwner {
        // Disallow the hook.
        isHookAllowed[hook] = false;

        // Clear default hook if it matches the hook being disallowed.
        if (defaultHook == hook) defaultHook = IJBRulesetDataHook(address(0));

        emit JBBuybackHookRegistry_DisallowHook(hook);
    }

    /// @notice Lock a hook for a project.
    /// @dev Only the project's owner or an address with the `JBPermissionIds.SET_BUYBACK_HOOK` permission from the
    /// owner can lock a hook for a project.
    /// @param projectId The ID of the project to lock the hook for.
    /// @param expectedHook The hook the caller expects to lock. Prevents race conditions where the hook changes
    /// between transaction submission and execution.
    function lockHookFor(uint256 projectId, IJBRulesetDataHook expectedHook) external {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_HOOK
        });

        // Require a non-zero hook before locking. Either the project has one set, or the default exists.
        IJBRulesetDataHook hook = _hookOf[projectId];
        if (hook == IJBRulesetDataHook(address(0))) {
            hook = defaultHook;
            if (hook == IJBRulesetDataHook(address(0))) revert JBBuybackHookRegistry_HookNotSet(projectId);
            _hookOf[projectId] = hook;
        }

        // Verify the resolved hook matches what the caller expects to lock.
        if (hook != expectedHook) {
            revert JBBuybackHookRegistry_HookMismatch(hook, expectedHook);
        }

        // Set the hook to locked.
        hasLockedHook[projectId] = true;

        emit JBBuybackHookRegistry_LockHook(projectId);
    }

    /// @notice Set the default hook.
    /// @dev Only the owner can set the default hook.
    /// @param hook The hook to set as the default.
    function setDefaultHook(IJBRulesetDataHook hook) external onlyOwner {
        // Prevent setting address(0) as the default hook — it would mark address(0) as allowed,
        // causing payments to revert when projects without a specific hook try to use the default.
        if (address(hook) == address(0)) revert JBBuybackHookRegistry_ZeroHook();

        // Set the default hook.
        defaultHook = hook;

        // Allow the default hook.
        isHookAllowed[hook] = true;

        emit JBBuybackHookRegistry_SetDefaultHook(hook);
    }

    /// @notice Set the hook for a project.
    /// @dev Only the project's owner or an address with the `JBPermissionIds.SET_BUYBACK_HOOK` permission from the
    /// owner can set the hook for a project.
    /// @param projectId The ID of the project to set the hook for.
    /// @param hook The hook to set for the project.
    function setHookFor(uint256 projectId, IJBRulesetDataHook hook) external {
        // Make sure the hook is not locked.
        if (hasLockedHook[projectId]) revert JBBuybackHookRegistry_HookLocked(projectId);

        if (!isHookAllowed[hook]) revert JBBuybackHookRegistry_HookNotAllowed(hook);

        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_HOOK
        });

        // Set the hook.
        _hookOf[projectId] = hook;

        emit JBBuybackHookRegistry_SetHook(projectId, hook);
    }

    /// @notice Set the Uniswap V4 pool for a project by forwarding to the resolved buyback hook implementation.
    /// @param projectId The ID of the project to set the pool for.
    /// @param fee The Uniswap V4 pool fee tier.
    /// @param tickSpacing The Uniswap V4 pool tick spacing.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param terminalToken The address of the terminal token that payments to the project are made in.
    function setPoolFor(
        uint256 projectId,
        uint24 fee,
        int24 tickSpacing,
        uint256 twapWindow,
        address terminalToken
    )
        external
        override
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        // Get the hook for the project (falls back to default).
        IJBRulesetDataHook hook = _hookOf[projectId];
        if (hook == IJBRulesetDataHook(address(0))) hook = defaultHook;

        // Forward the call to the resolved hook.
        IJBBuybackHook(address(hook))
            .setPoolFor({
                projectId: projectId,
                fee: fee,
                tickSpacing: tickSpacing,
                twapWindow: twapWindow,
                terminalToken: terminalToken
            });
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice To fulfill the `IJBRulesetDataHook` interface.
    /// @dev Pass cash out context back to the terminal without changes.
    /// @param context The cash out context passed in by the terminal.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory hookSpecifications)
    {
        return (context.cashOutTaxRate, context.cashOutCount, context.totalSupply, hookSpecifications);
    }

    /// @notice Forward the call to the hook for the project.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        // Get the hook for the project (falls back to default).
        IJBRulesetDataHook hook = _hookOf[context.projectId];
        if (hook == IJBRulesetDataHook(address(0))) hook = defaultHook;

        // Forward the call to the hook.
        // slither-disable-next-line unused-return
        return hook.beforePayRecordedWith(context);
    }

    /// @notice Make sure the hook has mint permission.
    /// @param projectId The ID of the project to check the mint permission for.
    /// @param addr The address to check the mint permission for.
    /// @return Whether the address has mint permission.
    function hasMintPermissionFor(
        uint256 projectId,
        JBRuleset memory,
        address addr
    )
        external
        view
        override
        returns (bool)
    {
        // Get the hook for the project (falls back to default).
        IJBRulesetDataHook hook = _hookOf[projectId];
        if (hook == IJBRulesetDataHook(address(0))) hook = defaultHook;

        // Make sure the hook has mint permission.
        return addr == address(hook);
    }

    /// @notice The hook for the given project, or the default hook if none is set.
    /// @param projectId The ID of the project to get the hook for.
    /// @return hook The hook for the project.
    function hookOf(uint256 projectId) external view override returns (IJBRulesetDataHook hook) {
        hook = _hookOf[projectId];
        if (hook == IJBRulesetDataHook(address(0))) hook = defaultHook;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBBuybackHookRegistry).interfaceId
            || interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }
}
