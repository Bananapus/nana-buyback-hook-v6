// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract CodexNemesisProjectToken {}

contract CodexNemesisRegistryCashOutMetadataTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant PROJECT_ID = 919;

    address internal owner = makeAddr("owner");
    address internal holder = makeAddr("holder");
    address payable internal beneficiary = payable(makeAddr("beneficiary"));
    address internal terminal = makeAddr("terminal");
    address internal trustedForwarder = makeAddr("trustedForwarder");

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));
    IJBController internal controller = IJBController(makeAddr("controller"));

    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    CodexNemesisProjectToken internal projectToken;

    JBBuybackHook internal hook;
    JBBuybackHookRegistry internal registry;

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new CodexNemesisProjectToken();

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");
        vm.mockCall(
            address(terminal), abi.encodeWithSignature("feeFreeSurplusOf(uint256,address)"), abi.encode(uint256(0))
        );

        hook = new JBBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: trustedForwarder
        });
        hook.setChainSpecificConstants({
            newPoolManager: IPoolManager(address(poolManager)), newOracleHook: IHooks(address(oracleHook))
        });

        registry = new JBBuybackHookRegistry({
            permissions: permissions, projects: projects, owner: owner, trustedForwarder: trustedForwarder
        });

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (PROJECT_ID)), abi.encode(owner));
        vm.mockCall(address(projects), abi.encodeWithSignature("count()"), abi.encode(uint256(0)));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (PROJECT_ID)), abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (PROJECT_ID)), abi.encode(controller));
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature("hasPermission(address,address,uint256,uint256,bool,bool)"),
            abi.encode(true)
        );
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature("hasPermission(address,address,uint256,uint256)"),
            abi.encode(true)
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(oracleHook))
        });
        poolManager.setSlot0(key.toId(), TickMath.getSqrtPriceAtTick(0), 0, 3000);

        vm.prank(owner);
        hook.setPoolFor({
            projectId: PROJECT_ID, poolKey: key, twapWindow: 5 minutes, terminalToken: JBConstants.NATIVE_TOKEN
        });

        vm.prank(owner);
        registry.setDefaultHook(hook);
    }

    function test_registryScopedCashOutMinimumIsRekeyed() public view {
        (uint256 hookTaxRate,,,, JBCashOutHookSpecification[] memory hookSpecs) =
            registry.beforeCashOutRecordedWith(_context(_metadataFor(address(hook), 2 ether)));

        (uint256 registryTaxRate,,,, JBCashOutHookSpecification[] memory registrySpecs) =
            registry.beforeCashOutRecordedWith(_context(_metadataFor(address(registry), 2 ether)));

        assertEq(hookTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE, "hook-scoped min activates sell hook");
        assertFalse(hookSpecs[0].noop, "hook-scoped min is enforced by the resolved hook");

        assertEq(
            registryTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE, "registry-scoped min is rekeyed and activates sell hook"
        );
        assertFalse(registrySpecs[0].noop, "registry-scoped min is rekeyed for cash-out");
    }

    /// @notice A registry-scoped `skip=true` (packed into the cashOutMinReclaimed entry) is rekeyed to the
    /// resolved hook and forces the terminal path — proving the packed bool survives the registry remap.
    function test_registryScopedSkipRoutesToTerminal() public view {
        (uint256 hookTaxRate,,,, JBCashOutHookSpecification[] memory hookSpecs) =
            registry.beforeCashOutRecordedWith(_context(_skipMetadataFor(address(hook))));

        (uint256 registryTaxRate,,,, JBCashOutHookSpecification[] memory registrySpecs) =
            registry.beforeCashOutRecordedWith(_context(_skipMetadataFor(address(registry))));

        assertEq(hookTaxRate, 0, "hook-scoped skip keeps the terminal tax rate");
        assertEq(hookSpecs.length, 0, "hook-scoped skip returns no hook spec (passthrough)");

        assertEq(registryTaxRate, 0, "registry-scoped skip is rekeyed and keeps the terminal tax rate");
        assertEq(registrySpecs.length, 0, "registry-scoped skip is rekeyed to a terminal-path passthrough");
    }

    function _context(bytes memory metadata) internal view returns (JBBeforeCashOutRecordedContext memory) {
        return JBBeforeCashOutRecordedContext({
            terminal: terminal,
            holder: holder,
            projectId: PROJECT_ID,
            rulesetId: 1,
            cashOutCount: 10 ether,
            totalSupply: 100 ether,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 5 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: metadata
        });
    }

    function _metadataFor(address target, uint256 minimumSwapAmountOut) internal pure returns (bytes memory) {
        return JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId("cashOutMinReclaimed", target),
            dataToAdd: abi.encode(minimumSwapAmountOut, false)
        });
    }

    function _skipMetadataFor(address target) internal pure returns (bytes memory) {
        return JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId("cashOutMinReclaimed", target),
            dataToAdd: abi.encode(uint256(0), true)
        });
    }
}
