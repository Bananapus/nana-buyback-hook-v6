// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdError} from "forge-std/StdError.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RegressionFOTMintAccountingRegression} from "test/regression/FOTMintAccounting.t.sol";

contract CodexNemesisFOTPreexistingUnderflowTest is RegressionFOTMintAccountingRegression {
    using PoolIdLibrary for *;

    function test_fotTerminalTokenPreexistingHookBalanceCanForceBuySideUnderflow() public {
        uint256 nominalPayment = 100 ether;
        uint256 preExistingBalance = 1 ether;
        uint256 swapOut = 100 ether;

        terminalToken.mint(address(hook), preExistingBalance);
        terminalToken.mint(address(terminal), nominalPayment);
        terminal.approveToken(address(terminalToken), address(hook), nominalPayment);
        projectToken.mint(address(poolManager), swapOut);

        bool projectTokenIs0 = address(projectToken) < address(terminalToken);
        if (projectTokenIs0) {
            poolManager.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(nominalPayment)));
        } else {
            poolManager.setMockDeltas(-int128(uint128(nominalPayment)), int128(uint128(swapOut)));
        }

        vm.mockCall(
            address(controller), abi.encodeCall(IJBController.burnTokensOf, (address(hook), projectId, swapOut, "")), ""
        );

        JBAfterPayRecordedContext memory context = JBAfterPayRecordedContext({
            payer: makeAddr("payer"),
            projectId: projectId,
            rulesetId: 1,
            amount: JBTokenAmount({
                token: address(terminalToken),
                decimals: 18,
                currency: uint32(uint160(address(terminalToken))),
                value: nominalPayment
            }),
            forwardedAmount: JBTokenAmount({
                token: address(terminalToken),
                decimals: 18,
                currency: uint32(uint160(address(terminalToken))),
                value: nominalPayment
            }),
            weight: 1e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(projectTokenIs0, uint256(0), uint256(0), false, controller, uint256(0), 1e18),
            payerMetadata: ""
        });

        vm.expectRevert(stdError.arithmeticError);
        terminal.runAfterPay(hook, context);
    }
}
