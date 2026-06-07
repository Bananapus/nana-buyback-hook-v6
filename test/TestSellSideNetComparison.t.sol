// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// JB core imports
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Buyback hook
import {JBBuybackHook} from "src/JBBuybackHook.sol";

// Test mocks
import {MockPoolManager} from "./mock/MockPoolManager.sol";
import {MockOracleHook} from "./mock/MockOracleHook.sol";

/// @notice Simple ERC20 token for testing.
contract TestProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Test harness that exposes JBBuybackHook internals.
contract ForTest_NetComparison is JBBuybackHook {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBPrices prices,
        IJBProjects projects,
        IJBTokens tokens,
        address deployer,
        address trustedForwarder
    )
        JBBuybackHook(directory, permissions, prices, projects, tokens, deployer, trustedForwarder)
    {}

    function forTestInitPool(
        uint256 projectId,
        PoolKey calldata key,
        uint256 twapWindow,
        address projectToken,
        address terminalToken
    )
        external
    {
        _poolKeyOf[projectId][terminalToken] = key;
        twapWindowOf[projectId][terminalToken] = twapWindow;
        projectTokenOf[projectId] = projectToken;
    }
}

/// @title TestSellSideNetComparison
/// @notice Tests that sell-side routing compares AMM quotes against the net (post-fee) terminal reclaim.
contract TestSellSideNetComparison is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    ForTest_NetComparison hook;
    MockPoolManager mockPm;
    MockOracleHook mockOracle;
    TestProjectToken projectToken;

    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));
    IJBController controller = IJBController(makeAddr("controller"));
    IJBMultiTerminal terminal = IJBMultiTerminal(makeAddr("terminal"));

    address owner = makeAddr("owner");
    address payer = makeAddr("payer");

    uint256 projectId = 42;
    uint32 twapWindow = 600;

    PoolKey poolKey;

    // Scenario: cashOutCount=10, totalSupply=100, surplus=5, taxRate=5000 (50%)
    // gross = cashOuts.cashOutFrom(surplus=5, cashOutCount=10, totalSupply=100, taxRate=5000)
    //       = 10/100 * 5 * [(MAX - 5000) + 5000 * (10/100)] / MAX = 0.5 * 0.55 = 0.275 ether
    // fee = 0.275 * 25/1000 = 0.006875 ether
    // net = 0.275 - 0.006875 = 0.268125 ether
    uint256 constant GROSS = 0.275 ether;
    uint256 constant NET = 0.268_125 ether;

    function setUp() public {
        mockPm = new MockPoolManager();
        mockOracle = new MockOracleHook();
        projectToken = new TestProjectToken();

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");
        vm.mockCall(
            address(terminal), abi.encodeWithSignature("feeFreeSurplusOf(uint256,address)"), abi.encode(uint256(0))
        );
        _mockTerminalLocalSurplus(type(uint256).max);

        hook = new ForTest_NetComparison({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants({
            newPoolManager: IPoolManager(address(mockPm)), newOracleHook: IHooks(address(mockOracle))
        });

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });

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

        _mockCurrentRuleset();

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolKey.toId(), sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolKey.toId(), 1_000_000 ether);

        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });
    }

    function _mockCurrentRuleset() internal {
        JBRulesetMetadata memory meta = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 5000,
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
            useDataHookForCashOut: true,
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

    function _buildContext(
        uint256 explicitMinimum,
        bool beneficiaryIsFeeless
    )
        internal
        view
        returns (JBBeforeCashOutRecordedContext memory)
    {
        bytes4 metadataId = JBMetadataResolver.getId("cashOut", address(hook));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(explicitMinimum, false));

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
            cashOutTaxRate: 5000,
            beneficiaryIsFeeless: beneficiaryIsFeeless,
            metadata: metadata
        });
    }

    /// @notice AMM quote between net and gross → routes to AMM (noop=false).
    function test_ammQuoteBetweenNetAndGross_routesToAmm() public view {
        // 0.27 ether is between net (0.268125) and gross (0.275)
        uint256 ammQuote = 0.27 ether;
        JBBeforeCashOutRecordedContext memory context = _buildContext(ammQuote, false);

        (uint256 cashOutTaxRate,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE, "should route to AMM");
        assertFalse(specs[0].noop, "should not be noop when AMM beats net reclaim");
    }

    /// @notice AMM quote below net reclaim → routes to terminal (noop=true).
    function test_ammQuoteBelowNet_routesToTerminal() public view {
        // 0.26 ether is below net (0.268125)
        uint256 ammQuote = 0.26 ether;
        JBBeforeCashOutRecordedContext memory context = _buildContext(ammQuote, false);

        (uint256 cashOutTaxRate,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, 5000, "should keep original tax rate for terminal path");
        assertTrue(specs[0].noop, "should noop when AMM loses to net reclaim");
    }

    /// @notice Feeless beneficiary → compares against gross (no fee deduction), so AMM between net and gross noops.
    function test_feelessBeneficiary_comparesAgainstGross() public view {
        // 0.27 ether is between net (0.268125) and gross (0.275).
        // With feeless, comparison is against gross 0.275 → noop because 0.27 <= 0.275.
        uint256 ammQuote = 0.27 ether;
        JBBeforeCashOutRecordedContext memory context = _buildContext(ammQuote, true);

        (uint256 cashOutTaxRate,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, 5000, "feeless beneficiary should keep original tax rate");
        assertTrue(specs[0].noop, "feeless beneficiary should compare against gross, so noop");

        // Metadata should encode gross (no fee deduction for feeless).
        (,, uint256 minimumProtocolAmountOut,,,) =
            abi.decode(specs[0].metadata, (uint256, uint256, uint256, int24, uint128, PoolId));
        assertEq(minimumProtocolAmountOut, GROSS, "feeless metadata should encode gross reclaim");
    }

    /// @notice skip=true forces the terminal path even when the pool quote genuinely beats the net direct
    /// reclaim and the holder set no floor — the headline guarantee. A control with skip=false proves the
    /// pool would otherwise win for the exact same inputs.
    function test_skip_forcesTerminalEvenWhenAmmWouldWin() public {
        // Calibrate the oracle so a min=0 cash-out quote beats the net direct reclaim (tick 0 == 1:1 price,
        // full-window liquidity). This is the same calibration the routing tests in V4BuybackHook.t.sol use.
        mockOracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        // Control: without skip, the pool wins — tax is maxed and an active (non-noop) sell spec is returned.
        JBBeforeCashOutRecordedContext memory routed = _buildSkipContext({explicitMinimum: 0, skip: false});
        (uint256 routedTax,,,, JBCashOutHookSpecification[] memory routedSpecs) = hook.beforeCashOutRecordedWith(routed);
        assertEq(routedTax, JBConstants.MAX_CASH_OUT_TAX_RATE, "control: pool wins when skip is off");
        assertFalse(routedSpecs[0].noop, "control: sell-side route is active when skip is off");

        // With skip, the same winning pool quote is ignored and the cash-out settles at the terminal.
        JBBeforeCashOutRecordedContext memory skipped = _buildSkipContext({explicitMinimum: 0, skip: true});
        (uint256 skipTax,,,, JBCashOutHookSpecification[] memory skipSpecs) = hook.beforeCashOutRecordedWith(skipped);
        assertEq(skipTax, 5000, "skip: terminal tax rate despite a winning pool quote");
        assertEq(skipSpecs.length, 0, "skip: no hook spec - pure passthrough to the terminal");
    }

    /// @notice skip=true with no explicit minimum is a clean passthrough to the bonding-curve cash-out.
    function test_skip_noMinimum_passesThrough() public view {
        JBBeforeCashOutRecordedContext memory context = _buildSkipContext({explicitMinimum: 0, skip: true});

        (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 surplus,
            JBCashOutHookSpecification[] memory specs
        ) = hook.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, 5000, "tax rate unchanged");
        assertEq(cashOutCount, 10 ether, "cash-out count unchanged");
        assertEq(totalSupply, 100 ether, "total supply unchanged");
        assertEq(surplus, 5 ether, "surplus unchanged");
        assertEq(specs.length, 0, "no hook spec on skip passthrough");
    }

    /// @notice skip does NOT waive the slippage floor: an explicit minimum the direct reclaim cannot meet
    /// reverts rather than silently settling the holder for less.
    function test_skip_stillEnforcesUnmeetableMinimum() public {
        // 0.30 ether is above the net direct reclaim (0.268125), so the terminal path cannot satisfy it.
        JBBeforeCashOutRecordedContext memory context = _buildSkipContext({explicitMinimum: 0.3 ether, skip: true});

        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, NET, 0.3 ether)
        );
        hook.beforeCashOutRecordedWith(context);
    }

    function _buildSkipContext(
        uint256 explicitMinimum,
        bool skip
    )
        internal
        view
        returns (JBBeforeCashOutRecordedContext memory)
    {
        bytes4 metadataId = JBMetadataResolver.getId("cashOut", address(hook));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(explicitMinimum, skip));

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
            cashOutTaxRate: 5000,
            beneficiaryIsFeeless: false,
            metadata: metadata
        });
    }

    function _mockTerminalLocalSurplus(uint256 surplus) internal {
        address[] memory tokensToCheck = new address[](1);
        tokensToCheck[0] = JBConstants.NATIVE_TOKEN;

        vm.mockCall(
            address(terminal),
            abi.encodeCall(
                IJBTerminal.currentSurplusOf,
                (projectId, tokensToCheck, uint256(18), uint256(uint32(uint160(JBConstants.NATIVE_TOKEN))))
            ),
            abi.encode(surplus)
        );
    }
}
