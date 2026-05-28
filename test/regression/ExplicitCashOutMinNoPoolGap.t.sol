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
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

import {JBBuybackHook} from "../../src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "../../src/JBBuybackHookRegistry.sol";

contract ExplicitCashOutMinNoPoolGapTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant CASH_OUT_COUNT = 10 ether;
    uint256 internal constant TOTAL_SUPPLY = 100 ether;
    uint256 internal constant SURPLUS = 10 ether;
    uint256 internal constant CASH_OUT_TAX_RATE = 0;
    uint256 internal constant DIRECT_RECLAIM = 1 ether;
    uint256 internal constant EXPLICIT_MINIMUM = 2 ether;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));

    JBBuybackHook internal hook;
    JBBuybackHookRegistry internal registry;

    function setUp() public {
        hook = new JBBuybackHook({
            directory: IJBDirectory(makeAddr("directory")),
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
        // Mock the terminal used in the context so the hook's `feeFreeSurplusOf` read returns zero.
        vm.etch(address(0x1234), "0x01");
        vm.mockCall(
            address(0x1234), abi.encodeWithSignature("feeFreeSurplusOf(uint256,address)"), abi.encode(uint256(0))
        );
    }

    function test_explicitCashOutMinimumRevertsWhenNoPoolIsSet() public {
        bytes memory metadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId({purpose: "cashOutMinReclaimed", target: address(hook)}),
            dataToAdd: abi.encode(EXPLICIT_MINIMUM, false)
        });

        _assertFallbackRevertsBelowMinimum();
        // The no-pool fallback enforces the user's explicit minimum against the exact net the
        // terminal would settle. With `feeFreeSurplusOf == 0` and `cashOutTaxRate == 0`, the
        // terminal charges no fee, so the exact net equals the gross direct reclaim.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, DIRECT_RECLAIM, EXPLICIT_MINIMUM
            )
        );
        hook.beforeCashOutRecordedWith(_context(metadata));
    }

    function test_registryScopedExplicitCashOutMinimumRevertsWhenNoPoolIsSet() public {
        vm.mockCall(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(0));
        registry.setDefaultHook(hook);

        bytes memory metadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId({purpose: "cashOutMinReclaimed", target: address(registry)}),
            dataToAdd: abi.encode(EXPLICIT_MINIMUM, false)
        });

        _assertFallbackRevertsBelowMinimum();
        // The no-pool fallback enforces the user's explicit minimum against the exact net the
        // terminal would settle. With `feeFreeSurplusOf == 0` and `cashOutTaxRate == 0`, the
        // terminal charges no fee, so the exact net equals the gross direct reclaim.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, DIRECT_RECLAIM, EXPLICIT_MINIMUM
            )
        );
        registry.beforeCashOutRecordedWith(_context(metadata));
    }

    function _assertFallbackRevertsBelowMinimum() internal pure {
        assertEq(
            JBCashOuts.cashOutFrom({
                surplus: SURPLUS,
                cashOutCount: CASH_OUT_COUNT,
                totalSupply: TOTAL_SUPPLY,
                cashOutTaxRate: CASH_OUT_TAX_RATE
            }),
            DIRECT_RECLAIM,
            "test direct reclaim assumption"
        );
        assertLt(DIRECT_RECLAIM, EXPLICIT_MINIMUM, "test must set minimum above direct reclaim");
    }

    function _context(bytes memory metadata) internal pure returns (JBBeforeCashOutRecordedContext memory context) {
        context = JBBeforeCashOutRecordedContext({
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
            metadata: metadata
        });
    }
}
