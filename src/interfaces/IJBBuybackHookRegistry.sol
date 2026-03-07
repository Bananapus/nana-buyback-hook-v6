// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

interface IJBBuybackHookRegistry is IJBRulesetDataHook {
    event JBBuybackHookRegistry_AllowHook(IJBRulesetDataHook hook);
    event JBBuybackHookRegistry_DisallowHook(IJBRulesetDataHook hook);
    event JBBuybackHookRegistry_LockHook(uint256 projectId);
    event JBBuybackHookRegistry_SetDefaultHook(IJBRulesetDataHook hook);
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
    function lockHookFor(uint256 projectId) external;

    /// @notice Set the default hook used when a project has not set a specific hook.
    /// @param hook The hook to set as the default.
    function setDefaultHook(IJBRulesetDataHook hook) external;

    /// @notice Set the hook for a specific project.
    /// @param projectId The ID of the project to set the hook for.
    /// @param hook The hook to set.
    function setHookFor(uint256 projectId, IJBRulesetDataHook hook) external;
}
