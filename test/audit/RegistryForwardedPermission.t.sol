// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";

contract DenyAllPermissions is IJBPermissions {
    function WILDCARD_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function hasPermission(address, address, uint256, uint256, bool, bool) external pure returns (bool) {
        return false;
    }

    function hasPermissions(address, address, uint256, uint256[] calldata, bool, bool) external pure returns (bool) {
        return false;
    }

    function permissionsOf(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function setPermissionsFor(address, JBPermissionsData calldata) external {}
}

contract ProjectsOwnerMock {
    address internal immutable _owner;

    constructor(address owner) {
        _owner = owner;
    }

    function ownerOf(uint256) external view returns (address) {
        return _owner;
    }
}

contract RegistryForwardedPermissionPoC is Test {
    uint256 internal constant PROJECT_ID = 77;

    address internal admin = makeAddr("admin");
    address internal projectOwner = makeAddr("projectOwner");
    address internal trustedForwarder = makeAddr("trustedForwarder");
    address internal terminalToken = makeAddr("terminalToken");

    DenyAllPermissions internal permissions;
    ProjectsOwnerMock internal projects;
    JBBuybackHook internal hook;
    JBBuybackHookRegistry internal registry;

    function setUp() public {
        permissions = new DenyAllPermissions();
        projects = new ProjectsOwnerMock(projectOwner);

        address directory = makeAddr("directory");
        address prices = makeAddr("prices");
        address tokens = makeAddr("tokens");
        address poolManager = makeAddr("poolManager");
        address oracleHook = makeAddr("oracleHook");

        vm.etch(directory, hex"00");
        vm.etch(prices, hex"00");
        vm.etch(tokens, hex"00");
        vm.etch(poolManager, hex"00");
        vm.etch(oracleHook, hex"00");

        hook = new JBBuybackHook({
            directory: IJBDirectory(directory),
            permissions: permissions,
            prices: IJBPrices(prices),
            projects: IJBProjects(address(projects)),
            tokens: IJBTokens(tokens),
            poolManager: IPoolManager(poolManager),
            oracleHook: IHooks(oracleHook),
            trustedForwarder: trustedForwarder
        });

        registry = new JBBuybackHookRegistry({
            permissions: permissions,
            projects: IJBProjects(address(projects)),
            owner: admin,
            trustedForwarder: trustedForwarder
        });

        vm.prank(admin);
        registry.setDefaultHook(hook);
    }

    function test_registrySetPoolFor_revertsBecauseHookAuthenticatesRegistrySender() public {
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                projectOwner,
                address(registry),
                PROJECT_ID,
                JBPermissionIds.SET_BUYBACK_POOL
            )
        );

        registry.setPoolFor({
            projectId: PROJECT_ID, fee: 3000, tickSpacing: 60, twapWindow: 5 minutes, terminalToken: terminalToken
        });
    }

    function test_registryInitializePoolFor_revertsBecauseHookAuthenticatesRegistrySender() public {
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                projectOwner,
                address(registry),
                PROJECT_ID,
                JBPermissionIds.SET_BUYBACK_POOL
            )
        );

        registry.initializePoolFor({
            projectId: PROJECT_ID,
            fee: 3000,
            tickSpacing: 60,
            twapWindow: 5 minutes,
            terminalToken: terminalToken,
            sqrtPriceX96: 1
        });
    }
}
