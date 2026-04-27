// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";

contract RegistryDefaultHookHijackTest is Test {
    uint256 internal constant PROJECT_ID = 1;

    address internal registryOwner = makeAddr("registryOwner");
    address internal projectOwner = makeAddr("projectOwner");
    address internal trustedForwarder = makeAddr("trustedForwarder");

    MockPermissions internal permissions;
    MockProjects internal projects;
    MockHook internal hookA;
    MockHook internal hookB;
    JBBuybackHookRegistry internal registry;

    function setUp() external {
        permissions = new MockPermissions();
        projects = new MockProjects();
        hookA = new MockHook(111);
        hookB = new MockHook(222);

        projects.setOwner(PROJECT_ID, projectOwner);

        registry = new JBBuybackHookRegistry({
            permissions: IJBPermissions(address(permissions)),
            projects: IJBProjects(address(projects)),
            owner: registryOwner,
            trustedForwarder: trustedForwarder
        });
    }

    function test_DefaultHookOwnerCanRetargetUnlockedProject() external {
        vm.prank(registryOwner);
        registry.setDefaultHook(IJBRulesetDataHook(address(hookA)));

        JBBeforePayRecordedContext memory context = JBBeforePayRecordedContext({
            terminal: address(0xBEEF),
            payer: makeAddr("payer"),
            amount: JBTokenAmount({token: address(0xCAFE), value: 1e18, decimals: 18, currency: 1}),
            projectId: PROJECT_ID,
            rulesetId: 123,
            beneficiary: makeAddr("beneficiary"),
            weight: 1,
            reservedPercent: 0,
            metadata: bytes("")
        });

        (uint256 weightBefore,) = registry.beforePayRecordedWith(context);
        assertEq(weightBefore, 111, "initial default hook should be used");
        assertEq(address(registry.hookOf(PROJECT_ID)), address(hookA), "project should resolve to hook A");

        vm.prank(registryOwner);
        registry.setDefaultHook(IJBRulesetDataHook(address(hookB)));

        (uint256 weightAfter,) = registry.beforePayRecordedWith(context);
        assertEq(weightAfter, 222, "owner should be able to retarget unlocked project to hook B");
        assertEq(address(registry.hookOf(PROJECT_ID)), address(hookB), "project should now resolve to hook B");

        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 0,
            id: 0,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        assertFalse(
            registry.hasMintPermissionFor(PROJECT_ID, ruleset, address(hookA)),
            "old default hook should immediately lose mint privilege"
        );
        assertTrue(
            registry.hasMintPermissionFor(PROJECT_ID, ruleset, address(hookB)),
            "new default hook should immediately gain mint privilege"
        );
    }
}

contract MockPermissions {
    function hasPermission(address, address, uint256, uint256, bool, bool) external pure returns (bool) {
        return false;
    }
}

contract MockProjects {
    mapping(uint256 => address) internal _ownerOf;

    function setOwner(uint256 projectId, address owner) external {
        _ownerOf[projectId] = owner;
    }

    function ownerOf(uint256 projectId) external view returns (address) {
        return _ownerOf[projectId];
    }
}

contract MockHook is IJBRulesetDataHook {
    uint256 internal immutable _WEIGHT_TO_RETURN;

    constructor(uint256 weightToReturn) {
        _WEIGHT_TO_RETURN = weightToReturn;
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata)
        external
        view
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        return (_WEIGHT_TO_RETURN, hookSpecifications);
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata)
        external
        pure
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 surplus,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        return (cashOutTaxRate, cashOutCount, totalSupply, surplus, hookSpecifications);
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address addr) external view returns (bool) {
        return addr == address(this);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId;
    }
}
