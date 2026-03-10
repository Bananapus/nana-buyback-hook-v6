// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

interface IJBBuybackHookRegistry is IJBRulesetDataHook {
    /// @notice Emitted when a hook is allowed for use by projects.
    /// @param hook The hook that was allowed.
    event JBBuybackHookRegistry_AllowHook(IJBRulesetDataHook hook);

    /// @notice Emitted when a hook is disallowed from being used by projects.
    /// @param hook The hook that was disallowed.
    event JBBuybackHookRegistry_DisallowHook(IJBRulesetDataHook hook);

    /// @notice Emitted when a project's hook is locked, preventing it from being changed.
    /// @param projectId The ID of the project whose hook was locked.
    event JBBuybackHookRegistry_LockHook(uint256 projectId);

    /// @notice Emitted when the default hook is set.
    /// @param hook The hook that was set as the default.
    event JBBuybackHookRegistry_SetDefaultHook(IJBRulesetDataHook hook);

    /// @notice Emitted when a hook is set for a specific project.
    /// @param projectId The ID of the project the hook was set for.
    /// @param hook The hook that was set.
    event JBBuybackHookRegistry_SetHook(uint256 indexed projectId, IJBRulesetDataHook hook);

    /// @notice The project registry.
    /// @return The projects contract.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice The default hook used when a project has not set a specific hook.
    /// @return The default data hook.
    function defaultHook() external view returns (IJBRulesetDataHook);

    /// @notice Whether the hook for the given project is locked and cannot be changed.
    /// @param projectId The ID of the project.
    /// @return Whether the hook is locked.
    function hasLockedHook(uint256 projectId) external view returns (bool);

    /// @notice The hook for the given project, or the default hook if none is set.
    /// @param projectId The ID of the project.
    /// @return The data hook for the project.
    function hookOf(uint256 projectId) external view returns (IJBRulesetDataHook);

    /// @notice Whether the given hook is allowed to be set for projects.
    /// @param hook The hook to check.
    /// @return Whether the hook is allowed.
    function isHookAllowed(IJBRulesetDataHook hook) external view returns (bool);

    /// @notice Allow a hook to be used by projects.
    /// @param hook The hook to allow.
    function allowHook(IJBRulesetDataHook hook) external;

    /// @notice Disallow a hook from being used by projects.
    /// @param hook The hook to disallow.
    function disallowHook(IJBRulesetDataHook hook) external;

    /// @notice Lock the hook for a project, preventing it from being changed.
    /// @param projectId The ID of the project to lock the hook for.
    /// @param expectedHook The hook the caller expects to lock. Prevents race conditions where the hook changes
    /// between transaction submission and execution.
    function lockHookFor(uint256 projectId, IJBRulesetDataHook expectedHook) external;

    /// @notice Set the default hook used when a project has not set a specific hook.
    /// @param hook The hook to set as the default.
    function setDefaultHook(IJBRulesetDataHook hook) external;

    /// @notice Set the hook for a specific project.
    /// @param projectId The ID of the project to set the hook for.
    /// @param hook The hook to set.
    function setHookFor(uint256 projectId, IJBRulesetDataHook hook) external;

    /// @notice Set the Uniswap V4 pool for a project, forwarding to the resolved buyback hook implementation.
    /// @dev Resolves the hook for the project (or the default), then calls setPoolFor on it.
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
        external;
}
