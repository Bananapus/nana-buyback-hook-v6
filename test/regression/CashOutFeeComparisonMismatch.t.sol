// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract _CashOutFeeComparisonProjectToken is ERC20 {
    constructor() ERC20("Project Token", "PT") {}
}

/// @notice Regression: the hook compares AMM output against the EXECUTABLE NET direct reclaim
/// under the active fee/free-surplus semantics, and the no-pool fallback enforces explicit minima against the
/// worst-case net so the user is never silently settled below their floor.
contract CashOutFeeComparisonMismatchTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant CASH_OUT_COUNT = 10 ether;
    uint256 internal constant TOTAL_SUPPLY = 100 ether;
    uint256 internal constant ZERO_TAX_SURPLUS = 10 ether;
    uint256 internal constant HALF_TAX_SURPLUS = 5 ether;
    // AMM minimum between gross (1 ether) and the worst-case net (0.975 ether) on the zero-tax route.
    uint256 internal constant AMM_BETWEEN_GROSS_AND_FULL_FEE_NET = 0.99 ether;
    // Explicit minimum between gross (0.275 ether) and the executable net after fee (0.268125 ether).
    uint256 internal constant EXPLICIT_MIN_BETWEEN_GROSS_AND_NET = 0.27 ether;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));
    IJBController internal controller = IJBController(makeAddr("controller"));
    IJBTerminal internal terminal = IJBTerminal(makeAddr("terminal"));

    address internal owner = makeAddr("owner");
    address internal holder = makeAddr("holder");

    JBBuybackHook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    _CashOutFeeComparisonProjectToken internal projectToken;

    function setUp() public {
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new _CashOutFeeComparisonProjectToken();

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
            newPoolManager: IPoolManager(address(poolManager)), newOracleHook: IHooks(address(oracleHook))
        });

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (PROJECT_ID)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (PROJECT_ID)), abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (PROJECT_ID)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (PROJECT_ID, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature("hasPermission(address,address,uint256,uint256,bool,bool)"),
            abi.encode(true)
        );

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(oracleHook))
        });
        poolManager.setSlot0(poolKey.toId(), TickMath.getSqrtPriceAtTick(0), 0, 3000);

        vm.prank(owner);
        hook.setPoolFor(PROJECT_ID, poolKey, 5 minutes, JBConstants.NATIVE_TOKEN);
    }

    /// @notice With `cashOutTaxRate == 0` and non-feeless beneficiary, routing can compare against gross direct, but
    /// explicit user floors must still be satisfiable if the terminal charges the standard fee.
    function test_zeroTaxNonFeeless_revertsWhenExplicitMinimumExceedsWorstCaseNet() public {
        uint256 grossDirect = JBCashOuts.cashOutFrom({
            surplus: ZERO_TAX_SURPLUS, cashOutCount: CASH_OUT_COUNT, totalSupply: TOTAL_SUPPLY, cashOutTaxRate: 0
        });
        uint256 fullFeeNet = grossDirect - JBFees.standardFeeAmountFrom(grossDirect);

        assertEq(grossDirect, 1 ether, "zero-tax gross direct reclaim");
        assertEq(fullFeeNet, 0.975 ether, "worst-case net direct reclaim");
        assertGt(grossDirect, AMM_BETWEEN_GROSS_AND_FULL_FEE_NET, "AMM minimum is below the gross direct");
        assertGt(AMM_BETWEEN_GROSS_AND_FULL_FEE_NET, fullFeeNet, "AMM minimum is above the full-fee net");

        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector,
                fullFeeNet,
                AMM_BETWEEN_GROSS_AND_FULL_FEE_NET
            )
        );
        hook.beforeCashOutRecordedWith(_context(0, ZERO_TAX_SURPLUS, AMM_BETWEEN_GROSS_AND_FULL_FEE_NET));
    }

    /// @notice with `cashOutTaxRate == 0` and non-feeless beneficiary, the AMM route is only chosen
    /// when the AMM minimum strictly beats the best-case direct (gross). At that point the AMM is unambiguously
    /// better than any direct outcome under the active fee/free-surplus semantics.
    function test_zeroTaxNonFeeless_routesToAmmWhenAmmStrictlyBeatsGross() public view {
        uint256 grossDirect = JBCashOuts.cashOutFrom({
            surplus: ZERO_TAX_SURPLUS, cashOutCount: CASH_OUT_COUNT, totalSupply: TOTAL_SUPPLY, cashOutTaxRate: 0
        });
        uint256 ammAboveGross = grossDirect + 1;

        (uint256 cashOutTaxRate,,,, JBCashOutHookSpecification[] memory specs) =
            hook.beforeCashOutRecordedWith(_context(0, ZERO_TAX_SURPLUS, ammAboveGross));

        assertEq(cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE, "hook maxes the tax rate to suppress direct");
        assertFalse(specs[0].noop, "AMM strictly beats gross: hook must route to AMM");
    }

    /// @notice the no-pool fallback enforces the user's explicit minimum against the WORST-CASE
    /// net (gross - standardFee) for non-feeless beneficiaries. Before the fix this comparison ran against the
    /// gross reclaim and the terminal could settle the user below their floor once the standard fee applied.
    function test_noPoolFallback_enforcesExplicitMinAgainstWorstCaseNet() public {
        uint256 grossDirect = JBCashOuts.cashOutFrom({
            surplus: HALF_TAX_SURPLUS, cashOutCount: CASH_OUT_COUNT, totalSupply: TOTAL_SUPPLY, cashOutTaxRate: 5000
        });
        uint256 executableNetDirect = grossDirect - JBFees.standardFeeAmountFrom(grossDirect);

        assertEq(grossDirect, 0.275 ether, "non-zero-tax gross direct reclaim");
        assertEq(executableNetDirect, 0.268_125 ether, "terminal return after standard fee");
        assertGt(grossDirect, EXPLICIT_MIN_BETWEEN_GROSS_AND_NET, "min is below gross");
        assertLt(executableNetDirect, EXPLICIT_MIN_BETWEEN_GROSS_AND_NET, "min is above executable net");

        // Deploy a hook with no pool configured so the fallback path is exercised.
        JBBuybackHook noPoolHook = new JBBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: address(0)
        });

        // Build a context that targets the no-pool hook so the explicit minimum check fires.
        bytes memory metadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId("cashOutMinReclaimed", address(noPoolHook)),
            dataToAdd: abi.encode(EXPLICIT_MIN_BETWEEN_GROSS_AND_NET)
        });
        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: holder,
            projectId: PROJECT_ID,
            rulesetId: 1,
            cashOutCount: CASH_OUT_COUNT,
            totalSupply: TOTAL_SUPPLY,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: HALF_TAX_SURPLUS,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 5000,
            beneficiaryIsFeeless: false,
            metadata: metadata
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector,
                executableNetDirect,
                EXPLICIT_MIN_BETWEEN_GROSS_AND_NET
            )
        );
        noPoolHook.beforeCashOutRecordedWith(context);
    }

    /// @notice Sanity: when the explicit minimum is below the worst-case net, the no-pool fallback proceeds
    /// without reverting and returns the terminal-direct config.
    function test_noPoolFallback_permitsMinimumBelowWorstCaseNet() public {
        JBBuybackHook noPoolHook = new JBBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: address(0)
        });

        // Floor below worst-case net (0.268125 ether) — fallback succeeds.
        uint256 safeMinimum = 0.26 ether;
        bytes memory metadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId("cashOutMinReclaimed", address(noPoolHook)),
            dataToAdd: abi.encode(safeMinimum)
        });
        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: holder,
            projectId: PROJECT_ID,
            rulesetId: 1,
            cashOutCount: CASH_OUT_COUNT,
            totalSupply: TOTAL_SUPPLY,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: HALF_TAX_SURPLUS,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 5000,
            beneficiaryIsFeeless: false,
            metadata: metadata
        });

        (uint256 cashOutTaxRate,,,, JBCashOutHookSpecification[] memory specs) =
            noPoolHook.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, 5000, "no-pool fallback returns the original tax rate");
        assertEq(specs.length, 0, "no hook spec when falling back to the terminal direct path");
    }

    function _context(
        uint256 cashOutTaxRate,
        uint256 surplus,
        uint256 minimum
    )
        internal
        view
        returns (JBBeforeCashOutRecordedContext memory context)
    {
        bytes memory metadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId("cashOutMinReclaimed", address(hook)),
            dataToAdd: abi.encode(minimum)
        });

        context = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: holder,
            projectId: PROJECT_ID,
            rulesetId: 1,
            cashOutCount: CASH_OUT_COUNT,
            totalSupply: TOTAL_SUPPLY,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: surplus,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: cashOutTaxRate,
            beneficiaryIsFeeless: false,
            metadata: metadata
        });
    }
}
