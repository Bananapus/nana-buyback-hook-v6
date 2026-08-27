// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
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
import {DefaultHookSegment} from "./structs/DefaultHookSegment.sol";

/// @notice A registry that maps projects to their buyback hook implementation. Projects can set a specific hook or
/// inherit the protocol default. Hooks can be locked to prevent changes. Acts as the data hook for the terminal —
/// it resolves the correct buyback hook for each project and forwards `beforePayRecordedWith` /
/// `beforeCashOutRecordedWith` calls to it.
/// @dev The first-ever default hook applies to every project that exists when it is set (so pre-existing, non-pinned
/// projects resolve to it). After that, a default CHANGE only applies to projects created after the change — earlier
/// cohorts keep the default that was active when they were created, preventing the registry owner from unilaterally
/// re-routing the mint permission of projects that pre-date the change.
contract JBBuybackHookRegistry is IJBBuybackHookRegistry, ERC2771Context, JBPermissioned, Ownable {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when attempting to disallow the hook that is currently set as the protocol-wide default.
    error JBBuybackHookRegistry_CannotDisallowDefaultHook(IJBRulesetDataHook hook);

    /// @notice Thrown when attempting to change a project's hook after it has been locked.
    error JBBuybackHookRegistry_HookLocked(uint256 projectId);

    /// @notice Thrown when the project's resolved hook does not match the hook the caller expected to lock.
    error JBBuybackHookRegistry_HookMismatch(IJBRulesetDataHook currentHook, IJBRulesetDataHook expectedHook);

    /// @notice Thrown when attempting to set a hook for a project that is not on the allowed list.
    error JBBuybackHookRegistry_HookNotAllowed(IJBRulesetDataHook hook);

    /// @notice Thrown when a project has no hook set and no default hook applies.
    error JBBuybackHookRegistry_HookNotSet(uint256 projectId);

    /// @notice Thrown when attempting to set the zero address as the protocol-wide default hook.
    error JBBuybackHookRegistry_ZeroHook(IJBRulesetDataHook hook);

    //*********************************************************************//
    // -------------------- public immutable properties ------------------ //
    //*********************************************************************//

    /// @notice The Juicebox project registry used to verify project existence and ownership.
    IJBProjects public immutable override PROJECTS;

    //*********************************************************************//
    // -------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    /// @notice Pre-computed metadata ID for the registry's own "cashOut" purpose.
    /// @dev Only the registry-scoped ID (`getId("cashOut", address(this))`) is hoisted here — callers key their
    /// sell-side directive to the registry address, so this is constant for a deployed registry and deterministic
    /// under CREATE2. The hook-scoped ID it re-keys into (`getId("cashOut", resolvedHook)`) depends on the per-call
    /// resolved hook address and therefore stays computed inline.
    bytes4 internal immutable _REGISTRY_CASH_OUT_ID;

    /// @notice Pre-computed metadata ID for the registry's own "pay" purpose.
    /// @dev Same rationale as `_REGISTRY_CASH_OUT_ID`: the registry-scoped ID is constant and hoisted; the hook-scoped
    /// re-key target varies per call and stays inline.
    bytes4 internal immutable _REGISTRY_PAY_ID;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The default buyback hook used when a project hasn't set a project-specific one.
    IJBRulesetDataHook public override defaultHook;

    /// @notice The project ID threshold at or below which the CURRENT default hook does not apply directly.
    /// @dev Set to the project count whenever the default is set or changed. Only projects with IDs above this
    /// threshold resolve to the current default; projects at or below it resolve via `_defaultHookHistory` to the
    /// default that was active when they were created. This prevents the registry owner from unilaterally re-routing
    /// the hook (and its mint permission) of projects that pre-date a default change.
    uint256 public override defaultHookProjectIdThreshold;

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

    /// @notice Snapshots of the default hook that applied to each past cohort of projects, keyed by the project-count
    /// window each one covered. @dev Each `setDefaultHook` call pushes one segment whose `maxProjectId` is the project
    /// count at that moment. On the first-ever call the segment covers the already-existing projects and maps them to
    /// the new default, so projects that existed before the first default still resolve to it. On every later call the
    /// segment maps the just-closed window to the OUTGOING default, so a project whose ID is
    /// `<= defaultHookProjectIdThreshold` (i.e. one already issued the last time the default changed) walks this list
    /// to find the default that was active when it was created — a default change never retroactively re-routes an
    /// earlier cohort.
    DefaultHookSegment[] internal _defaultHookHistory;

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

        // Pre-compute the registry-scoped metadata IDs so their purpose strings are hashed once here rather than on
        // every cash-out/pay re-key. The hook-scoped IDs cannot be hoisted because they depend on the resolved hook.
        _REGISTRY_CASH_OUT_ID = JBMetadataResolver.getId("cashOut");
        _REGISTRY_PAY_ID = JBMetadataResolver.getId("pay");
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Adds a buyback hook implementation to the allowlist so projects can select it.
    /// @dev Only the owner can allow a hook.
    /// @dev Allowing address(0) lets authorized operators clear a project's hook assignment via setHookFor, returning
    /// it to the default hook. This is the intended way to "unset" a project-specific hook.
    /// @param hook The hook to allow.
    function allowHook(IJBRulesetDataHook hook) external onlyOwner {
        // Allow the hook.
        isHookAllowed[hook] = true;

        emit JBBuybackHookRegistry_AllowHook({hook: hook, caller: _msgSender()});
    }

    /// @notice Removes a buyback hook implementation from the allowlist, preventing new projects from selecting it.
    /// @dev Only the owner can disallow a hook. Cannot disallow the current default (would break existing projects).
    /// @param hook The hook to disallow.
    function disallowHook(IJBRulesetDataHook hook) external onlyOwner {
        // Revert if the hook is the current default — disallowing it would break payments
        // for projects that rely on the default hook (beforePayRecordedWith calls methods on it).
        if (defaultHook == hook) revert JBBuybackHookRegistry_CannotDisallowDefaultHook(hook);

        // Disallow the hook.
        isHookAllowed[hook] = false;

        emit JBBuybackHookRegistry_DisallowHook({hook: hook, caller: _msgSender()});
    }

    /// @notice Initialize a Uniswap V4 pool and configure it as the buyback pool for a project, forwarding to the
    /// resolved buyback hook implementation.
    /// @param projectId The ID of the project to set the pool for.
    /// @param fee The Uniswap V4 pool fee tier.
    /// @param tickSpacing The Uniswap V4 pool tick spacing.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param terminalToken The address of the terminal token that payments to the project are made in.
    function initializePoolFor(
        uint256 projectId,
        uint24 fee,
        int24 tickSpacing,
        uint256 twapWindow,
        address terminalToken,
        uint160 sqrtPriceX96
    )
        external
        override
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        // Get the hook for the project (project-specific or default if eligible).
        IJBRulesetDataHook hook = _resolvedHookOf(projectId);

        // Revert if there is no hook to forward to.
        if (address(hook) == address(0)) revert JBBuybackHookRegistry_HookNotSet(projectId);

        // Forward the call to the resolved hook.
        IJBBuybackHook(address(hook))
            .initializePoolFor({
            projectId: projectId,
            fee: fee,
            tickSpacing: tickSpacing,
            twapWindow: twapWindow,
            terminalToken: terminalToken,
            sqrtPriceX96: sqrtPriceX96
        });
    }

    /// @notice Permanently locks a project's buyback hook assignment, preventing future changes. Once locked, the
    /// project is also immune to default-hook changes.
    /// @dev Only the project's owner or an address with the `JBPermissionIds.SET_BUYBACK_HOOK` permission from the
    /// owner can lock a hook for a project.
    /// @dev Atomic set-and-lock (calling setHookFor then lockHookFor in one transaction) lets trusted operators
    /// configure and finalize hook settings in a single transaction, reducing the window for front-running or
    /// configuration changes between set and lock.
    /// @param projectId The ID of the project to lock the hook for.
    /// @param expectedHook The hook the caller expects to lock. Prevents race conditions where the hook changes
    /// between transaction submission and execution.
    function lockHookFor(uint256 projectId, IJBRulesetDataHook expectedHook) external {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_HOOK
        });

        // Require a non-zero hook before locking. Either the project has one set, or the default applies.
        IJBRulesetDataHook hook = _resolvedHookOf(projectId);
        if (hook == IJBRulesetDataHook(address(0))) revert JBBuybackHookRegistry_HookNotSet(projectId);

        // Pin the resolved hook so the project is not affected by future default changes.
        if (_hookOf[projectId] == IJBRulesetDataHook(address(0))) {
            _hookOf[projectId] = hook;
        }

        // Verify the resolved hook matches what the caller expects to lock.
        if (hook != expectedHook) {
            revert JBBuybackHookRegistry_HookMismatch({currentHook: hook, expectedHook: expectedHook});
        }

        // Set the hook to locked.
        hasLockedHook[projectId] = true;

        emit JBBuybackHookRegistry_LockHook({projectId: projectId, caller: _msgSender()});
    }

    /// @notice Sets the protocol-wide default buyback hook. The first-ever default also applies to projects that
    /// already existed when it was set (so pre-existing, non-pinned projects resolve to it). A later default change
    /// only affects projects created AFTER it — earlier cohorts keep their previously-active default, and any project
    /// that pinned its own hook via `setHookFor` keeps that pin.
    /// @dev Only the owner can set the default hook. Pushes one `_defaultHookHistory` segment per call: the first call
    /// maps the already-existing cohort to the new hook; later calls map the just-closed window to the outgoing
    /// default so a default change never retroactively re-routes an earlier cohort to `address(0)` or a newer hook.
    /// @param hook The hook to set as the default.
    function setDefaultHook(IJBRulesetDataHook hook) external onlyOwner {
        // Prevent setting address(0) as the default hook — it would mark address(0) as allowed,
        // causing payments to revert when projects without a specific hook try to use the default.
        if (address(hook) == address(0)) revert JBBuybackHookRegistry_ZeroHook(hook);

        // Record a history segment covering the cohort `(prevThreshold, currentCount]` — the projects whose IDs were
        // issued while the current threshold was in effect. On the FIRST-EVER call (`defaultHook == 0`) this cohort is
        // the set of already-existing projects `(0, currentCount]`; map it to the NEW hook so those pre-existing,
        // non-pinned projects resolve to it instead of `address(0)`. On every later call there IS an outgoing default,
        // so the segment is mapped to that outgoing hook: this keeps the earlier cohort on its original default and
        // prevents a default change from retroactively re-routing projects that pre-dated it.
        _defaultHookHistory.push(
            DefaultHookSegment({
                minProjectIdExclusive: defaultHookProjectIdThreshold,
                maxProjectId: PROJECTS.count(),
                hook: address(defaultHook) == address(0) ? hook : defaultHook
            })
        );

        // Set the default hook.
        defaultHook = hook;

        // Only apply the new default to future projects.
        defaultHookProjectIdThreshold = PROJECTS.count();

        // Allow the default hook.
        isHookAllowed[hook] = true;

        emit JBBuybackHookRegistry_SetDefaultHook({hook: hook, caller: _msgSender()});
    }

    /// @notice Assigns a specific buyback hook implementation to a project, overriding the default.
    /// @dev Only the project's owner or an address with the `JBPermissionIds.SET_BUYBACK_HOOK` permission from the
    /// owner can set the hook for a project. Reverts if the hook is not on the allowlist or is already locked.
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

        emit JBBuybackHookRegistry_SetHook({projectId: projectId, hook: hook, caller: _msgSender()});
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

        // Get the hook for the project (project-specific or default if eligible).
        IJBRulesetDataHook hook = _resolvedHookOf(projectId);

        // Revert if there is no hook to forward to.
        if (address(hook) == address(0)) revert JBBuybackHookRegistry_HookNotSet(projectId);

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

    /// @notice Forward the cash-out data-hook call to the resolved buyback hook for the project.
    /// @dev Uses the project-specific hook when configured, otherwise falls back to the default hook.
    /// If neither exists, the cash-out values are passed through unchanged.
    /// @param context Standard Juicebox cash-out data-hook context.
    /// @return cashOutTaxRate The tax rate returned by the resolved hook, or the original context value.
    /// @return cashOutCount The cash-out count returned by the resolved hook, or the original context value.
    /// @return totalSupply The total supply returned by the resolved hook, or the original context value.
    /// @return effectiveSurplusValue The surplus returned by the resolved hook, or the original context surplus value.
    /// @return hookSpecifications Any cash-out hook specifications returned by the resolved hook.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // Resolve the hook: project-specific first, then default (only for eligible projects).
        IJBRulesetDataHook hook = _resolvedHookOf(context.projectId);

        // If no hook is configured at all, leave the terminal's cash-out values untouched.
        if (address(hook) == address(0)) {
            return (
                context.cashOutTaxRate,
                context.cashOutCount,
                context.totalSupply,
                context.surplus.value,
                hookSpecifications
            );
        }

        // Remap any `cashOut` metadata addressed to the registry into metadata addressed to the resolved
        // hook. This single entry packs both the slippage floor and the `skip` venue override, so one remap
        // forwards the entire caller-provided sell-side intent.
        (bool found, bytes memory cashOutData) =
            JBMetadataResolver.getDataFor({id: _REGISTRY_CASH_OUT_ID, metadata: context.metadata});

        if (found) {
            bytes4 hookCashOutId = JBMetadataResolver.getId({purpose: "cashOut", target: address(hook)});
            bytes memory rekeyedMetadata = JBMetadataResolver.addToMetadata({
                originalMetadata: context.metadata, idToAdd: hookCashOutId, dataToAdd: cashOutData
            });
            JBBeforeCashOutRecordedContext memory modifiedContext = JBBeforeCashOutRecordedContext({
                terminal: context.terminal,
                holder: context.holder,
                projectId: context.projectId,
                rulesetId: context.rulesetId,
                cashOutCount: context.cashOutCount,
                totalSupply: context.totalSupply,
                surplus: context.surplus,
                scopeCashOutsToLocalBalances: context.scopeCashOutsToLocalBalances,
                cashOutTaxRate: context.cashOutTaxRate,
                beneficiaryIsFeeless: context.beneficiaryIsFeeless,
                metadata: rekeyedMetadata
            });
            return hook.beforeCashOutRecordedWith(modifiedContext);
        }

        // Forward the full cash-out context to the resolved hook unchanged.
        return hook.beforeCashOutRecordedWith(context);
    }

    /// @notice Forward the pay data-hook call to the resolved buyback hook for the project.
    /// @dev Uses the project-specific hook when configured, otherwise falls back to the default hook.
    /// If neither exists, the payment values are passed through unchanged — this allows the registry to be deployed
    /// on chains where no Uniswap V4 PoolManager is available (and thus no buyback hook exists). Projects function
    /// normally without buyback optimization; they simply mint at the ruleset weight.
    /// @param context Standard Juicebox pay data-hook context.
    /// @return weight The weight returned by the resolved hook, or the original context weight.
    /// @return hookSpecifications Any pay hook specifications returned by the resolved hook.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        // Resolve the hook: project-specific first, then default (only for eligible projects).
        IJBRulesetDataHook hook = _resolvedHookOf(context.projectId);

        // If no hook is configured at all, leave the terminal's pay values untouched.
        if (address(hook) == address(0)) {
            return (context.weight, hookSpecifications);
        }

        // By design — a project's hook choice is sovereign. Disallowing a hook only prevents NEW
        // projects from selecting it via setHookFor; it does not override existing assignments.
        // The registry admin should not be able to unilaterally degrade a project's payment flow.

        // Remap any `pay` metadata addressed to the registry into metadata addressed to the resolved hook.
        // This lets payers scope their swap quote to the registry address while the underlying hook receives
        // it under its own ID.
        (bool found, bytes memory payData) =
            JBMetadataResolver.getDataFor({id: _REGISTRY_PAY_ID, metadata: context.metadata});

        if (found) {
            // Build rekeyed metadata with the hook-scoped `pay` ID.
            bytes4 hookPayId = JBMetadataResolver.getId({purpose: "pay", target: address(hook)});
            bytes memory rekeyedMetadata = JBMetadataResolver.addToMetadata({
                originalMetadata: context.metadata, idToAdd: hookPayId, dataToAdd: payData
            });

            // Forward a context copy with the rekeyed metadata via staticcall (view-safe).
            JBBeforePayRecordedContext memory modifiedContext = JBBeforePayRecordedContext({
                terminal: context.terminal,
                payer: context.payer,
                amount: context.amount,
                projectId: context.projectId,
                rulesetId: context.rulesetId,
                beneficiary: context.beneficiary,
                weight: context.weight,
                reservedPercent: context.reservedPercent,
                metadata: rekeyedMetadata
            });
            return hook.beforePayRecordedWith(modifiedContext);
        }

        // Forward the call to the hook unchanged.
        return hook.beforePayRecordedWith(context);
    }

    /// @notice The segment of the default-hook history at the given index, in insertion (chronological) order.
    /// @param index The history index. Reverts on out-of-bounds.
    /// @return segment The segment at that index.
    function defaultHookHistoryAt(uint256 index) external view override returns (DefaultHookSegment memory segment) {
        return _defaultHookHistory[index];
    }

    /// @notice The number of segments in the default-hook history.
    /// @return length The number of historical default-hook segments.
    function defaultHookHistoryLength() external view override returns (uint256 length) {
        return _defaultHookHistory.length;
    }

    /// @notice Returns true only if `addr` is the resolved hook for the project — this grants the hook (and only the
    /// hook) permission to mint tokens on the project's behalf.
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
        // Get the hook for the project (project-specific or default if eligible).
        IJBRulesetDataHook hook = _resolvedHookOf(projectId);

        // Make sure the hook has mint permission.
        return addr == address(hook);
    }

    /// @notice Returns the resolved hook for a project: the project-specific hook if set, or the default hook if the
    /// project was created after the default was configured.
    /// @param projectId The ID of the project to get the hook for.
    /// @return hook The hook for the project.
    function hookOf(uint256 projectId) external view override returns (IJBRulesetDataHook hook) {
        hook = _resolvedHookOf(projectId);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates whether this registry supports an interface.
    /// @param interfaceId The interface ID to check.
    /// @return Whether the interface is supported.
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

    /// @notice Resolve the hook for a project. Returns the project-specific hook if set, otherwise the default that
    /// was active when the project was created (current default for future projects, historical default for projects
    /// in a prior default's cohort), otherwise address(0) for projects that pre-date any default.
    /// @param projectId The ID of the project.
    /// @return hook The resolved hook, or address(0) if none applies.
    function _resolvedHookOf(uint256 projectId) internal view returns (IJBRulesetDataHook hook) {
        hook = _hookOf[projectId];
        if (hook != IJBRulesetDataHook(address(0))) return hook;

        if (projectId > defaultHookProjectIdThreshold) return defaultHook;

        // Project ID was issued before the current default was set. Walk the history segments to find the default
        // that was active at this project's creation. Segments are appended in chronological order; each one covers a
        // half-open range of project IDs `(minProjectIdExclusive, maxProjectId]`. A projectId is matched by exactly
        // one segment (or none, in which case the project pre-dates every recorded default).
        uint256 len = _defaultHookHistory.length;
        for (uint256 i; i < len; ++i) {
            DefaultHookSegment storage segment = _defaultHookHistory[i];
            if (projectId > segment.minProjectIdExclusive && projectId <= segment.maxProjectId) {
                return segment.hook;
            }
        }
    }
}
