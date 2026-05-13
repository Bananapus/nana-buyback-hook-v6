// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";

/// @title NoPoolCashOutSurplusTest
/// @notice Tests for regression Zero surplus on no-pool cashout.
///   When `beforeCashOutRecordedWith` falls back because no pool is configured (JBBuybackHook)
///   or no hook is configured (JBBuybackHookRegistry), it must return `context.surplus.value`
///   instead of `0` for the effective surplus. Returning `0` causes the terminal store to
///   compute cashouts against zero surplus, meaning users get nothing back.
contract NoPoolCashOutSurplusTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant CASH_OUT_COUNT = 10 ether;
    uint256 internal constant TOTAL_SUPPLY = 100 ether;
    uint256 internal constant SURPLUS = 50 ether;
    uint256 internal constant CASH_OUT_TAX_RATE = 0;

    /// @notice Verify JBBuybackHook returns context.surplus.value (not 0) when no pool is set.
    function test_noPoolSurplus_noPool_returns_actual_surplus() public {
        JBBuybackHook hook = new JBBuybackHook({
            directory: IJBDirectory(makeAddr("directory")),
            permissions: IJBPermissions(makeAddr("permissions")),
            prices: IJBPrices(makeAddr("prices")),
            projects: IJBProjects(makeAddr("projects")),
            tokens: IJBTokens(makeAddr("tokens")),
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants({
            poolManager: IPoolManager(makeAddr("poolManager")), oracleHook: IHooks(makeAddr("oracleHook"))
        });

        JBBeforeCashOutRecordedContext memory context = _context();

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply, uint256 effectiveSurplusValue,) =
            hook.beforeCashOutRecordedWith(context);

        // FIX: effectiveSurplusValue must equal context.surplus.value, NOT zero.
        assertEq(effectiveSurplusValue, SURPLUS, "hook no-pool fallback must return context.surplus.value");

        // Other return values must pass through unchanged.
        assertEq(cashOutTaxRate, CASH_OUT_TAX_RATE, "cashOutTaxRate should pass through");
        assertEq(cashOutCount, CASH_OUT_COUNT, "cashOutCount should pass through");
        assertEq(totalSupply, TOTAL_SUPPLY, "totalSupply should pass through");

        // Verify the terminal would compute a non-zero reclaim with the returned surplus.
        uint256 reclaim = JBCashOuts.cashOutFrom({
            surplus: effectiveSurplusValue,
            cashOutCount: CASH_OUT_COUNT,
            totalSupply: TOTAL_SUPPLY,
            cashOutTaxRate: CASH_OUT_TAX_RATE
        });
        assertGt(reclaim, 0, "reclaim must be non-zero when surplus is non-zero");
    }

    /// @notice Verify JBBuybackHookRegistry returns context.surplus.value (not 0) when no hook is configured.
    function test_noPoolSurplus_registry_returns_actual_surplus() public {
        JBBuybackHookRegistry registry = new JBBuybackHookRegistry({
            permissions: IJBPermissions(makeAddr("permissions")),
            projects: IJBProjects(makeAddr("projects")),
            owner: makeAddr("owner"),
            trustedForwarder: address(0)
        });

        JBBeforeCashOutRecordedContext memory context = _context();

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply, uint256 effectiveSurplusValue,) =
            registry.beforeCashOutRecordedWith(context);

        // FIX: effectiveSurplusValue must equal context.surplus.value, NOT zero.
        assertEq(effectiveSurplusValue, SURPLUS, "registry no-hook fallback must return context.surplus.value");

        // Other return values must pass through unchanged.
        assertEq(cashOutTaxRate, CASH_OUT_TAX_RATE, "cashOutTaxRate should pass through");
        assertEq(cashOutCount, CASH_OUT_COUNT, "cashOutCount should pass through");
        assertEq(totalSupply, TOTAL_SUPPLY, "totalSupply should pass through");

        // Verify the terminal would compute a non-zero reclaim with the returned surplus.
        uint256 reclaim = JBCashOuts.cashOutFrom({
            surplus: effectiveSurplusValue,
            cashOutCount: CASH_OUT_COUNT,
            totalSupply: TOTAL_SUPPLY,
            cashOutTaxRate: CASH_OUT_TAX_RATE
        });
        assertGt(reclaim, 0, "reclaim must be non-zero when surplus is non-zero");
    }

    /// @notice Build a standard cash-out context with non-zero surplus for testing.
    function _context() internal pure returns (JBBeforeCashOutRecordedContext memory) {
        return JBBeforeCashOutRecordedContext({
            terminal: address(0x1234),
            holder: address(0x5678),
            projectId: PROJECT_ID,
            rulesetId: 1,
            cashOutCount: CASH_OUT_COUNT,
            totalSupply: TOTAL_SUPPLY,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: SURPLUS,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: CASH_OUT_TAX_RATE,
            beneficiaryIsFeeless: false,
            metadata: ""
        });
    }
}
