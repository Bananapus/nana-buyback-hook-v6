// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestBuybackFOT} from "../TestBuybackFOT.t.sol";

import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {stdError} from "forge-std/StdError.sol";

contract CodexNemesisFOTDonationDoS is TestBuybackFOT {
    function test_codexNemesis_donatedFotBalanceMakesSwapSuccessThenUnderflowsLeftover() public {
        bool projectTokenIs0 = address(projectToken) < address(fotToken);
        uint256 payAmount = 10 ether;
        uint256 fotFee = (payAmount * 100) / 10_000;
        uint256 swapOut = 500 ether;

        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        projectToken.mint(address(mockPm), swapOut);

        address attacker = makeAddr("attacker");
        uint256 donationGross = (fotFee * 10_000 + 9900 - 1) / 9900;
        fotToken.mint(attacker, donationGross);
        vm.prank(attacker);
        fotToken.transfer(address(hook), donationGross);
        assertGe(fotToken.balanceOf(address(hook)), fotFee);

        JBAfterPayRecordedContext memory ctx = _makeAfterPayContext(payAmount, projectTokenIs0, 0, 0);

        fotToken.mint(address(terminal), payAmount);
        vm.prank(address(terminal));
        fotToken.approve(address(hook), payAmount);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith(ctx);

        assertGe(fotToken.balanceOf(address(hook)), fotFee);
    }
}
