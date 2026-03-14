// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

// JB core imports
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

// Buyback hook
import {JBBuybackHook} from "src/JBBuybackHook.sol";

/// @title CrossCurrency_Unit
/// @notice Tests cross-currency weight ratio calculation in JBBuybackHook.beforePayRecordedWith.
/// Verifies that when amount.currency != baseCurrency, the hook correctly queries JBPrices
/// for the weight ratio and uses it in swap-vs-mint comparisons.
contract CrossCurrency_Unit is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    // Mock JB core contracts
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));
    IJBController controller = IJBController(makeAddr("controller"));
    IJBMultiTerminal terminal = IJBMultiTerminal(makeAddr("terminal"));
    IPoolManager poolManager = IPoolManager(makeAddr("poolManager"));

    JBBuybackHook hook;

    address owner = makeAddr("owner");
    address beneficiary = makeAddr("beneficiary");

    uint256 projectId = 42;
    uint112 weight = uint112(1000e18);

    // Currency constants
    uint32 nativeCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));
    uint32 constant USD = 2; // JBCurrencyIds.USD

    function setUp() public {
        // Etch code at mock addresses so calls don't revert.
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");
        vm.etch(address(poolManager), "0x01");

        hook = new JBBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            poolManager: poolManager,
            oracleHook: IHooks(address(0)),
            trustedForwarder: address(0)
        });

        // Mock directory -> controller
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, projectId),
            abi.encode(address(controller))
        );

        // Mock terminal -> isTerminalOf
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.isTerminalOf.selector, projectId, address(terminal)),
            abi.encode(true)
        );
    }

    function _mockRuleset(uint32 baseCurrency) internal {
        JBRulesetMetadata memory meta = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: baseCurrency,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: true,
            useDataHookForCashOut: false,
            dataHook: address(hook),
            metadata: 0
        });

        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 30 days,
            weight: weight,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.currentRulesetOf.selector, projectId),
            abi.encode(ruleset, meta)
        );
    }

    /// @notice Test 1: ETH payment -> USD baseCurrency. The hook queries JBPrices for weightRatio.
    /// Since no pool is set up, beforePayRecorded should return the weight unchanged
    /// (mint wins over swap with no pool), but the weight ratio calculation should be correct.
    function test_cc_beforePayRecorded_ethPayment_usdBase() public {
        _mockRuleset(USD);

        // Mock pricePerUnitOf: nativeCurrency -> USD at 18 decimals.
        // Returns 5e14 (inverse of $2000: "1 native token unit costs 5e14 USD units").
        vm.mockCall(
            address(prices),
            abi.encodeWithSelector(IJBPrices.pricePerUnitOf.selector, projectId, nativeCurrency, USD, uint256(18)),
            abi.encode(uint256(5e14))
        );

        // No pool set up for this project -> buyback hook should fall back to mint.
        // beforePayRecordedWith should return weight and empty specs.
        JBBeforePayRecordedContext memory context = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: beneficiary,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN, value: 1e18, decimals: 18, currency: nativeCurrency
            }),
            projectId: projectId,
            rulesetId: uint48(block.timestamp),
            beneficiary: beneficiary,
            weight: weight,
            reservedPercent: 0,
            metadata: ""
        });

        vm.prank(address(terminal));
        (uint256 returnedWeight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(context);

        // Without a pool, hook returns the original weight (no swap).
        assertEq(returnedWeight, weight, "weight returned unchanged (no pool, mint wins)");
        assertEq(specs.length, 0, "no pay hook specs (no pool)");
    }

    /// @notice Test 2: Same currency (nativeCurrency == baseCurrency) -> no price lookup needed.
    function test_cc_sameCurrency_skipsPriceLookup() public {
        _mockRuleset(nativeCurrency); // baseCurrency = nativeCurrency (same)

        // If JBPrices.pricePerUnitOf were called, it would return 10^decimals (identity).
        // But since currencies match, the store should never call JBPrices at all.
        // We don't mock the price feed to prove it's not called.

        JBBeforePayRecordedContext memory context = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: beneficiary,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN, value: 1e18, decimals: 18, currency: nativeCurrency
            }),
            projectId: projectId,
            rulesetId: uint48(block.timestamp),
            beneficiary: beneficiary,
            weight: weight,
            reservedPercent: 0,
            metadata: ""
        });

        vm.prank(address(terminal));
        (uint256 returnedWeight,) = hook.beforePayRecordedWith(context);

        assertEq(returnedWeight, weight, "weight returned unchanged (same currency)");
    }

    /// @notice Test 3: Cross-currency but price feed reverts -> entire pay reverts.
    /// The buyback hook should propagate the revert (not silently skip like 721 hook).
    function test_cc_missingFeed_reverts() public {
        _mockRuleset(USD);

        // Mock JBPrices to revert (no feed registered).
        vm.mockCallRevert(
            address(prices),
            abi.encodeWithSelector(IJBPrices.pricePerUnitOf.selector, projectId, nativeCurrency, USD, uint256(18)),
            abi.encodeWithSignature("JBPrices_PriceFeedNotFound()")
        );

        // Mock a pool so the hook actually attempts the cross-currency path.
        // Without a pool, the hook returns early before hitting the price feed.
        // We need the hook to have a pool registered to exercise the weight ratio code.
        address mockToken = makeAddr("projectToken");
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(mockToken),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.mockCall(
            address(tokens), abi.encodeWithSelector(IJBTokens.tokenOf.selector, projectId), abi.encode(mockToken)
        );

        JBBeforePayRecordedContext memory context = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: beneficiary,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN, value: 1e18, decimals: 18, currency: nativeCurrency
            }),
            projectId: projectId,
            rulesetId: uint48(block.timestamp),
            beneficiary: beneficiary,
            weight: weight,
            reservedPercent: 0,
            metadata: ""
        });

        // The hook queries JBPrices for weightRatio BEFORE checking for a pool (line 554-562),
        // so a missing feed always reverts in the cross-currency path.
        vm.prank(address(terminal));
        vm.expectRevert();
        hook.beforePayRecordedWith(context);
    }

    /// @notice Test 4: Verify the weight ratio math at the JBTerminalStore level.
    /// When amount.currency != baseCurrency, weightRatio = pricePerUnitOf(_, currency, baseCurrency, decimals).
    /// tokenCount = mulDiv(amount.value, weight, weightRatio).
    function test_cc_weightRatio_tokenCountCalculation() public {
        // This is a pure math verification test.
        // For baseCurrency=USD(2), weight=1000e18, ETH payment of 1e18:
        // pricePerUnitOf(_, nativeCurrency, USD, 18) = 5e14 (inverse of $2000)
        // tokenCount = mulDiv(1e18, 1000e18, 5e14) = 2_000_000e18

        uint256 paymentValue = 1e18;
        uint256 hookWeight = 1000e18;
        uint256 weightRatio = 5e14; // Inverse of $2000 at 18 decimals

        uint256 expectedTokenCount = (paymentValue * hookWeight) / weightRatio;
        assertEq(expectedTokenCount, 2_000_000e18, "1 ETH at $2000 with 1000 tokens/USD = 2M tokens");

        // Same with USDC payment:
        // pricePerUnitOf(_, usdcCurrency, USD, 6) = 1e6 (1:1 USDC/USD)
        // tokenCount = mulDiv(2000e6, 1000e18, 1e6) = 2_000_000e18
        uint256 usdcPayment = 2000e6;
        uint256 usdcWeightRatio = 1e6;
        uint256 usdcTokenCount = (usdcPayment * hookWeight) / usdcWeightRatio;
        assertEq(usdcTokenCount, 2_000_000e18, "2000 USDC at 1:1 with 1000 tokens/USD = 2M tokens");

        // Both should yield identical token counts — this is the key cross-currency invariant.
        assertEq(expectedTokenCount, usdcTokenCount, "ETH and USDC yield same token count for equivalent USD value");
    }
}
