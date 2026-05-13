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

contract RegressionNoPoolCashOutRegression is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant CASH_OUT_COUNT = 10 ether;
    uint256 internal constant TOTAL_SUPPLY = 100 ether;
    uint256 internal constant SURPLUS = 50 ether;

    function test_hookNoPoolFallbackReturnsZeroSurplus() public {
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

        (,,, uint256 effectiveSurplusValue,) = hook.beforeCashOutRecordedWith(_context());

        uint256 reclaimFromReturnedSurplus = JBCashOuts.cashOutFrom({
            surplus: effectiveSurplusValue, cashOutCount: CASH_OUT_COUNT, totalSupply: TOTAL_SUPPLY, cashOutTaxRate: 0
        });
        uint256 reclaimFromContextSurplus = JBCashOuts.cashOutFrom({
            surplus: SURPLUS, cashOutCount: CASH_OUT_COUNT, totalSupply: TOTAL_SUPPLY, cashOutTaxRate: 0
        });

        assertEq(effectiveSurplusValue, SURPLUS, "fix: no-pool hook fallback now returns context surplus");
        assertEq(reclaimFromReturnedSurplus, reclaimFromContextSurplus, "returned surplus matches context surplus");
        assertGt(reclaimFromContextSurplus, 0, "native passthrough should have non-zero reclaim");
    }

    function test_registryNoHookFallbackReturnsContextSurplus() public {
        JBBuybackHookRegistry registry = new JBBuybackHookRegistry({
            permissions: IJBPermissions(makeAddr("permissions")),
            projects: IJBProjects(makeAddr("projects")),
            owner: makeAddr("owner"),
            trustedForwarder: address(0)
        });

        (,,, uint256 effectiveSurplusValue,) = registry.beforeCashOutRecordedWith(_context());

        uint256 reclaimFromReturnedSurplus = JBCashOuts.cashOutFrom({
            surplus: effectiveSurplusValue, cashOutCount: CASH_OUT_COUNT, totalSupply: TOTAL_SUPPLY, cashOutTaxRate: 0
        });
        uint256 reclaimFromContextSurplus = JBCashOuts.cashOutFrom({
            surplus: SURPLUS, cashOutCount: CASH_OUT_COUNT, totalSupply: TOTAL_SUPPLY, cashOutTaxRate: 0
        });

        assertEq(effectiveSurplusValue, SURPLUS, "fix: no-hook registry fallback now returns context surplus");
        assertEq(reclaimFromReturnedSurplus, reclaimFromContextSurplus, "returned surplus matches context surplus");
        assertGt(reclaimFromContextSurplus, 0, "native passthrough should have non-zero reclaim");
    }

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
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: ""
        });
    }
}
