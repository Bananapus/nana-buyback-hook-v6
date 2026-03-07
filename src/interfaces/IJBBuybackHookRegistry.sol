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

    function PROJECTS() external view returns (IJBProjects);

    function defaultHook() external view returns (IJBRulesetDataHook);
    function hasLockedHook(uint256 projectId) external view returns (bool);
    function hookOf(uint256 projectId) external view returns (IJBRulesetDataHook);
    function isHookAllowed(IJBRulesetDataHook hook) external view returns (bool);

    function allowHook(IJBRulesetDataHook hook) external;
    function disallowHook(IJBRulesetDataHook hook) external;
    function lockHookFor(uint256 projectId) external;
    function setDefaultHook(IJBRulesetDataHook hook) external;
    function setHookFor(uint256 projectId, IJBRulesetDataHook hook) external;
}
