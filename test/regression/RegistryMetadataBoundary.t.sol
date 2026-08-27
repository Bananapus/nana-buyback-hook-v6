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
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract RegressionProjectToken {}

contract RegressionRegistryMetadataBoundaryTest is Test {
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    uint256 internal constant PROJECT_ID = 919;

    address internal owner = makeAddr("owner");
    address internal beneficiary = makeAddr("beneficiary");
    address internal payer = makeAddr("payer");
    address internal terminal = makeAddr("terminal");
    address internal trustedForwarder = makeAddr("trustedForwarder");

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));

    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    RegressionProjectToken internal projectToken;
    IJBController internal controller = IJBController(makeAddr("controller"));

    JBBuybackHook internal hook;
    JBBuybackHookRegistry internal registry;

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new RegressionProjectToken();

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");

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

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: true,
            useDataHookForCashOut: false,
            dataHook: address(registry),
            metadata: 0
        });

        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 30 days,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata.packRulesetMetadata()
        });
        vm.mockCall(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (PROJECT_ID)),
            abi.encode(ruleset, metadata)
        );
        vm.mockCall(
            address(controller),
            abi.encodeCall(IJBController.previewMintOf, (PROJECT_ID, 2 ether, true)),
            abi.encode(2 ether, 0)
        );

        (Currency currency0, Currency currency1) = address(0) < address(projectToken)
            ? (Currency.wrap(address(0)), Currency.wrap(address(projectToken)))
            : (Currency.wrap(address(projectToken)), Currency.wrap(address(0)));
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(oracleHook))
        });

        poolManager.setSlot0(key.toId(), TickMath.getSqrtPriceAtTick(0), 0, 3000);
        poolManager.setLiquidity(key.toId(), 1_000_000 ether);

        vm.prank(owner);
        hook.setPoolFor({
            projectId: PROJECT_ID, poolKey: key, twapWindow: 5 minutes, terminalToken: JBConstants.NATIVE_TOKEN
        });

        vm.prank(owner);
        registry.setDefaultHook(hook);
    }

    function test_registryKeyedQuoteIsReroutedToResolvedHook() public view {
        bytes memory registryKeyedMetadata = _metadataFor(address(registry), 1 ether, 2 ether);
        (uint256 registryWeight, JBPayHookSpecification[] memory registrySpecs) =
            registry.beforePayRecordedWith(_context(registryKeyedMetadata));

        bytes memory hookKeyedMetadata = _metadataFor(address(hook), 1 ether, 2 ether);
        (uint256 hookWeight, JBPayHookSpecification[] memory hookSpecs) =
            registry.beforePayRecordedWith(_context(hookKeyedMetadata));

        // Registry-keyed metadata is now rerouted to the underlying hook, so both paths produce the same result.
        assertEq(registryWeight, hookWeight, "registry-keyed and hook-keyed quotes produce the same weight");
        assertEq(registrySpecs.length, hookSpecs.length, "same number of hook specs");
        assertEq(registrySpecs[0].noop, hookSpecs[0].noop, "same noop status");
        assertEq(registrySpecs[0].amount, hookSpecs[0].amount, "same swap amount");

        assertEq(hookWeight, 0, "hook-keyed explicit quote selects the swap path");
        assertFalse(hookSpecs[0].noop, "hook-keyed quote activates the swap path");
        assertEq(hookSpecs[0].amount, 1 ether, "hook-keyed quote forwards the requested swap amount");
    }

    function _context(bytes memory metadata) internal view returns (JBBeforePayRecordedContext memory) {
        return JBBeforePayRecordedContext({
            terminal: terminal,
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 1 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            projectId: PROJECT_ID,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 1e18,
            reservedPercent: 0,
            metadata: metadata
        });
    }

    function _metadataFor(
        address target,
        uint256 amountToSwapWith,
        uint256 minimumSwapAmountOut
    )
        internal
        pure
        returns (bytes memory)
    {
        return JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId("pay", target),
            dataToAdd: abi.encode(amountToSwapWith, minimumSwapAmountOut, false)
        });
    }
}
