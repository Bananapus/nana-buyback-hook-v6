// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";

import {MockOracleHook} from "../mock/MockOracleHook.sol";
import {MockPoolManager} from "../mock/MockPoolManager.sol";

contract CurrentLiquidityProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}
}

contract CurrentLiquidityRouteSelectionTest is Test {
    using JBRulesetMetadataResolver for JBRulesetMetadata;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    JBBuybackHook hook;
    MockPoolManager poolManager;
    MockOracleHook oracle;
    CurrentLiquidityProjectToken projectToken;

    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));
    IJBController controller = IJBController(makeAddr("controller"));
    IJBMultiTerminal terminal = IJBMultiTerminal(makeAddr("terminal"));

    address owner = makeAddr("owner");
    address payer = makeAddr("payer");
    address beneficiary = makeAddr("beneficiary");

    uint256 projectId = 42;
    uint32 twapWindow = 600;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        poolManager = new MockPoolManager();
        oracle = new MockOracleHook();
        projectToken = new CurrentLiquidityProjectToken();

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        hook = new JBBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants({
            newPoolManager: IPoolManager(address(poolManager)), newOracleHook: IHooks(address(oracle))
        });

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(oracle))
        });
        poolId = poolKey.toId();

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(owner));
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (projectId)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (projectId, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projectToken)))
        );
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
        vm.mockCall(
            address(terminal), abi.encodeWithSignature("feeFreeSurplusOf(uint256,address)"), abi.encode(uint256(0))
        );
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.previewMintOf.selector), abi.encode(0, 0));

        _mockCurrentRuleset();

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        poolManager.setSlot0(poolId, sqrtPrice, 0, 3000);
        poolManager.setLiquidity(poolId, 1_000_000 ether);
    }

    function test_beforePayRecordedWith_zeroCurrentLiquidityFallsBackToMint() public {
        _setPoolThenRemoveLiquidity();
        oracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext());

        assertEq(weight, 1, "empty live pool should leave mint weight unchanged");
        assertEq(specs.length, 1, "noop diagnostics should still be surfaced for configured pools");
        assertTrue(specs[0].noop, "empty live pool should not activate the AMM route");
        assertEq(specs[0].amount, 0, "noop spec should not forward funds to afterPay");

        (
            bool projectTokenIs0,
            uint256 amountToMintWith,
            uint256 minimumSwapAmountOut,
            bool hasExplicitQuote,
            IJBController decodedController,
            uint256 tokenCountWithoutHook,
            uint256 weightRatio,
            int24 twapTick,
            uint128 twapLiquidity,
            PoolId decodedPoolId,
            uint256 minimumBeneficiaryTokenCount,
            uint256 minimumReservedTokenCount,
            uint256 rawSwapQuote
        ) = abi.decode(
            specs[0].metadata,
            (
                bool,
                uint256,
                uint256,
                bool,
                IJBController,
                uint256,
                uint256,
                int24,
                uint128,
                PoolId,
                uint256,
                uint256,
                uint256
            )
        );
        projectTokenIs0;
        amountToMintWith;
        hasExplicitQuote;
        decodedController;
        tokenCountWithoutHook;
        weightRatio;
        minimumBeneficiaryTokenCount;
        minimumReservedTokenCount;
        rawSwapQuote;
        assertEq(minimumSwapAmountOut, 0, "empty live pool should not surface an executable AMM floor");
        assertEq(twapTick, 0, "TWAP lookup should be skipped when live liquidity is zero");
        assertEq(twapLiquidity, 0, "TWAP liquidity should be zeroed when live liquidity is zero");
        assertEq(PoolId.unwrap(decodedPoolId), PoolId.unwrap(poolId), "poolId should identify the configured pool");
    }

    function test_beforePayRecordedWith_dustCurrentLiquidityFallsBackToMint() public {
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });
        poolManager.setLiquidity(poolId, 1);
        oracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext());

        assertEq(weight, 1, "max-impact dust pool should leave mint weight unchanged");
        assertEq(specs.length, 1, "noop diagnostics should still be surfaced for configured pools");
        assertTrue(specs[0].noop, "max-impact dust pool should not activate the AMM route");

        (
            bool projectTokenIs0,
            uint256 amountToMintWith,
            uint256 minimumSwapAmountOut,
            bool hasExplicitQuote,
            IJBController decodedController,
            uint256 tokenCountWithoutHook,
            uint256 weightRatio,
            int24 twapTick,
            uint128 twapLiquidity,
            PoolId decodedPoolId,
            uint256 minimumBeneficiaryTokenCount,
            uint256 minimumReservedTokenCount,
            uint256 rawSwapQuote
        ) = abi.decode(
            specs[0].metadata,
            (
                bool,
                uint256,
                uint256,
                bool,
                IJBController,
                uint256,
                uint256,
                int24,
                uint128,
                PoolId,
                uint256,
                uint256,
                uint256
            )
        );
        projectTokenIs0;
        amountToMintWith;
        hasExplicitQuote;
        decodedController;
        tokenCountWithoutHook;
        weightRatio;
        decodedPoolId;
        minimumBeneficiaryTokenCount;
        minimumReservedTokenCount;
        rawSwapQuote;
        assertEq(minimumSwapAmountOut, 0, "max-impact dust pool should not surface an executable AMM floor");
        assertEq(twapTick, 0, "TWAP diagnostics should still identify the observed price");
        assertGt(twapLiquidity, 0, "TWAP diagnostics should still identify historical oracle liquidity");
    }

    function test_beforeCashOutRecordedWith_zeroCurrentLiquidityDoesNotRouteSellSide() public {
        _setPoolThenRemoveLiquidity();
        oracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        (uint256 cashOutTaxRate,,,, JBCashOutHookSpecification[] memory specs) =
            hook.beforeCashOutRecordedWith(_cashOutContext(""));

        assertEq(cashOutTaxRate, 0, "empty live pool should use the direct cash-out path");
        assertEq(specs.length, 1, "noop diagnostics should still be surfaced for configured pools");
        assertTrue(specs[0].noop, "empty live pool should not activate the sell-side AMM route");

        (
            uint256 minimumSwapAmountOut,
            uint256 cashOutCount,
            uint256 minimumProtocolAmountOut,
            int24 twapTick,
            uint128 twapLiquidity,
            PoolId decodedPoolId,
            uint256 rawSwapQuote,
            bool hasExplicitMinimum
        ) = abi.decode(specs[0].metadata, (uint256, uint256, uint256, int24, uint128, PoolId, uint256, bool));
        cashOutCount;
        minimumProtocolAmountOut;
        twapTick;
        rawSwapQuote;
        hasExplicitMinimum;
        assertEq(minimumSwapAmountOut, 0, "empty live pool should not surface an executable AMM floor");
        assertEq(twapLiquidity, 0, "TWAP liquidity should be zeroed when live liquidity is zero");
        assertEq(PoolId.unwrap(decodedPoolId), PoolId.unwrap(poolId), "poolId should identify the configured pool");
    }

    function test_beforeCashOutRecordedWith_zeroCurrentLiquidityRevertsUnmetExplicitMinimum() public {
        _setPoolThenRemoveLiquidity();

        uint256 explicitMinimumReclaimed = 0.5 ether + 1;
        bytes memory metadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId("cashOut", address(hook)),
            dataToAdd: abi.encode(explicitMinimumReclaimed, false)
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, 0.5 ether, explicitMinimumReclaimed
            )
        );
        hook.beforeCashOutRecordedWith(_cashOutContext(metadata));
    }

    function _setPoolThenRemoveLiquidity() internal {
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });
        poolManager.setLiquidity(poolId, 0);
    }

    function _mockCurrentRuleset() internal {
        JBRulesetMetadata memory meta = JBRulesetMetadata({
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
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller), abi.encodeCall(IJBController.currentRulesetOf, (projectId)), abi.encode(ruleset, meta)
        );
    }

    function _payContext() internal view returns (JBBeforePayRecordedContext memory) {
        return JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: 1 ether
            }),
            projectId: projectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 1,
            reservedPercent: 0,
            metadata: ""
        });
    }

    function _cashOutContext(bytes memory metadata) internal view returns (JBBeforeCashOutRecordedContext memory) {
        return JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: payer,
            projectId: projectId,
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
}
