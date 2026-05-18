// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

/// @notice A segment of the default-hook history. Each segment pins the outgoing default to the range of project IDs
/// that were created while it was active, so changing the default does not retroactively orphan that cohort.
/// @custom:member minProjectIdExclusive The threshold that was active when this segment's hook first became the
/// default. The hook applies to project IDs strictly greater than this value.
/// @custom:member maxProjectId The threshold that was set when this segment's hook was overwritten. The hook applies
/// to project IDs less than or equal to this value.
/// @custom:member hook The default hook that was active for project IDs in `(minProjectIdExclusive, maxProjectId]`.
struct DefaultHookSegment {
    uint256 minProjectIdExclusive;
    uint256 maxProjectId;
    IJBRulesetDataHook hook;
}
