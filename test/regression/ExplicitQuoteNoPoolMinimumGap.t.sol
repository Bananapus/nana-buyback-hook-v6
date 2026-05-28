// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

import {JBBuybackHook} from "../../src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "../../src/JBBuybackHookRegistry.sol";

contract ExplicitQuoteNoPoolMinimumGapTest is Test {
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant PAYMENT_AMOUNT = 1 ether;
    uint256 internal constant WEIGHT = 1 ether;
    uint256 internal constant DIRECT_MINT_COUNT = 1 ether;
    uint256 internal constant EXPLICIT_MINIMUM = 2 ether;

    address internal beneficiary = makeAddr("beneficiary");
    address internal payer = makeAddr("payer");
    address internal terminal = makeAddr("terminal");

    IJBController internal controller = IJBController(makeAddr("controller"));
    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));

    JBBuybackHook internal hook;
    JBBuybackHookRegistry internal registry;

    function setUp() public {
        hook = new JBBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: IJBPrices(makeAddr("prices")),
            projects: projects,
            tokens: IJBTokens(makeAddr("tokens")),
            deployer: address(this),
            trustedForwarder: address(0)
        });
        registry = new JBBuybackHookRegistry({
            permissions: permissions, projects: projects, owner: address(this), trustedForwarder: address(0)
        });

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
            dataHook: address(hook),
            metadata: 0
        });

        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 30 days,
            // forge-lint: disable-next-line(unsafe-typecast)
            weight: uint112(WEIGHT),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata.packRulesetMetadata()
        });

        vm.mockCall(address(directory), abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(controller));
        vm.mockCall(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (PROJECT_ID)),
            abi.encode(ruleset, metadata)
        );
        vm.mockCall(
            address(controller),
            abi.encodeCall(IJBController.previewMintOf, (PROJECT_ID, EXPLICIT_MINIMUM, true)),
            abi.encode(EXPLICIT_MINIMUM, 0)
        );
    }

    function test_explicitQuoteMinimumRevertsWhenNoPoolIsSet() public {
        bytes memory quoteMetadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId({purpose: "pay", target: address(hook)}),
            dataToAdd: abi.encode(PAYMENT_AMOUNT, EXPLICIT_MINIMUM)
        });

        _expectExplicitMinimumDecoded();

        assertLt(DIRECT_MINT_COUNT, EXPLICIT_MINIMUM, "test must set minimum above direct mint");
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, DIRECT_MINT_COUNT, EXPLICIT_MINIMUM
            )
        );
        hook.beforePayRecordedWith(_context(quoteMetadata));
    }

    function test_registryScopedExplicitQuoteMinimumRevertsWhenNoPoolIsSet() public {
        vm.mockCall(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(0));
        registry.setDefaultHook(hook);

        bytes memory quoteMetadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId({purpose: "pay", target: address(registry)}),
            dataToAdd: abi.encode(PAYMENT_AMOUNT, EXPLICIT_MINIMUM)
        });

        _expectExplicitMinimumDecoded();

        assertLt(DIRECT_MINT_COUNT, EXPLICIT_MINIMUM, "test must set minimum above direct mint");
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, DIRECT_MINT_COUNT, EXPLICIT_MINIMUM
            )
        );
        registry.beforePayRecordedWith(_context(quoteMetadata));
    }

    function _expectExplicitMinimumDecoded() internal {
        vm.expectCall(
            address(controller), abi.encodeCall(IJBController.previewMintOf, (PROJECT_ID, EXPLICIT_MINIMUM, true))
        );
    }

    function _context(bytes memory metadata) internal view returns (JBBeforePayRecordedContext memory context) {
        context = JBBeforePayRecordedContext({
            terminal: terminal,
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: PAYMENT_AMOUNT,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            projectId: PROJECT_ID,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: WEIGHT,
            reservedPercent: 0,
            metadata: metadata
        });
    }
}
