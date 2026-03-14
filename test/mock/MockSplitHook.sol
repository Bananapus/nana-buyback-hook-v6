// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract MockSplitHook is ERC165, IJBSplitHook {
    IJBPayHook public immutable PAY_HOOK;

    constructor(IJBPayHook payHook) {
        PAY_HOOK = payHook;
    }

    function processSplitWith(JBSplitHookContext calldata) external payable override {
        JBAfterPayRecordedContext memory context = JBAfterPayRecordedContext({
            payer: address(this),
            projectId: 1,
            rulesetId: 2,
            amount: JBTokenAmount({token: address(this), value: 1 ether, decimals: 18, currency: 0}),
            forwardedAmount: JBTokenAmount({token: address(this), value: 1 ether, decimals: 18, currency: 0}),
            weight: 1,
            newlyIssuedTokenCount: 1,
            beneficiary: address(this),
            hookMetadata: "",
            payerMetadata: new bytes(0)
        });

        // Make a malicious delegate call to the buyback hook.
        (bool success,) = address(PAY_HOOK)
            .delegatecall(abi.encodeWithSignature("afterPayRecordedWith(JBAfterPayRecordedContext)", context));
        assert(success);
    }

    function supportsInterface(bytes4 interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return interfaceId == type(IJBSplitHook).interfaceId || super.supportsInterface(interfaceId);
    }
}
