// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {Test} from "forge-std/Test.sol";

import {JBBuybackHookRegistry} from "../../src/JBBuybackHookRegistry.sol";

contract CodexNemesisRegistryHistoryGasTest is Test {
    IJBProjects internal constant PROJECTS = IJBProjects(address(0x1234));

    JBBuybackHookRegistry internal registry;

    function setUp() public {
        registry = new JBBuybackHookRegistry({
            permissions: IJBPermissions(address(0xBEEF)),
            projects: PROJECTS,
            owner: address(this),
            trustedForwarder: address(0)
        });
    }

    function test_historicalDefaultResolutionExceedsBoundedGasAfterManyDefaultRotations() public {
        uint256 rotations = 300;

        _mockProjectCount(0);
        registry.setDefaultHook(IJBRulesetDataHook(address(0x1000)));

        for (uint256 i = 1; i <= rotations; ++i) {
            _mockProjectCount(i);
            // Safe in this bounded test: i <= rotations == 300, so 0x1000 + i fits in uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            registry.setDefaultHook(IJBRulesetDataHook(address(uint160(0x1000 + i))));
        }

        uint256 targetHistoricalProjectId = rotations;
        (bool ok,) = address(registry).staticcall{gas: 100_000}(
            abi.encodeCall(JBBuybackHookRegistry.hookOf, (targetHistoricalProjectId))
        );

        assertFalse(ok, "historical default lookup should exceed a small bounded gas budget");
    }

    function _mockProjectCount(uint256 count) internal {
        vm.mockCall(address(PROJECTS), abi.encodeCall(IJBProjects.count, ()), abi.encode(count));
    }
}
