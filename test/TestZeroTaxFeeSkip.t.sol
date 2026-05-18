// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";

import {MockPoolManager} from "./mock/MockPoolManager.sol";
import {MockOracleHook} from "./mock/MockOracleHook.sol";

contract ZeroTaxProjectToken is ERC20 {
    constructor() ERC20("PT", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Test harness for fee skip behavior.
contract ForTest_ZeroTax is JBBuybackHook {
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
}

/// @title TestZeroTaxFeeSkip
/// @notice Verifies the asymmetric fee model the hook applies for sell-side route scoring:
///   - When `cashOutTaxRate != 0` and the beneficiary is non-feeless, the terminal always charges the standard
///     fee on the full reclaim, so `netDirectCashOutAmount = gross - fee`.
///   - When `cashOutTaxRate == 0` and the beneficiary is non-feeless, the terminal charges the standard fee only
///     up to `_feeFreeSurplusOf` (which the hook cannot read). For routing the hook uses the best-case net
///     (`= gross`) so it never directs to the AMM when the direct path could pay more.
///   - Feeless beneficiaries always settle at gross.
/// Explicit minima in the no-pool fallback are still enforced against the worst-case net (`gross - fee`) so the
/// user is never silently settled below their floor — that path is covered in TestCashOutMinFallbackWorstCase.
contract TestZeroTaxFeeSkip is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    ForTest_ZeroTax hook;
    MockPoolManager mockPm;
    MockOracleHook mockOracle;
    ZeroTaxProjectToken projectToken;

    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));
    IJBController controller = IJBController(makeAddr("controller"));
    address terminal = makeAddr("terminal");

    address owner = makeAddr("owner");
    address holder = makeAddr("holder");

    uint256 projectId = 77;

    PoolKey poolKey;

    function setUp() public {
        mockPm = new MockPoolManager();
        mockOracle = new MockOracleHook();
        projectToken = new ZeroTaxProjectToken();

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(terminal, "0x01");

        hook = new ForTest_ZeroTax({
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
            abi.encodeCall(directory.isTerminalOf, (projectId, IJBTerminal(terminal))),
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

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolKey.toId(), sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolKey.toId(), 1_000_000 ether);

        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: 600, terminalToken: JBConstants.NATIVE_TOKEN
        });
    }

    function _mockRuleset(uint256 cashOutTaxRate) internal {
        JBRulesetMetadata memory meta = JBRulesetMetadata({
            reservedPercent: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            cashOutTaxRate: uint16(cashOutTaxRate),
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
        uint256 cashOutTaxRate,
        bool beneficiaryIsFeeless,
        uint256 explicitMinimum
    )
        internal
        view
        returns (JBBeforeCashOutRecordedContext memory)
    {
        bytes4 metadataId = JBMetadataResolver.getId("cashOutMinReclaimed", address(hook));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(explicitMinimum));

        return JBBeforeCashOutRecordedContext({
            terminal: terminal,
            holder: holder,
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
            // forge-lint: disable-next-line(unsafe-typecast)
            cashOutTaxRate: uint16(cashOutTaxRate),
            beneficiaryIsFeeless: beneficiaryIsFeeless,
            metadata: metadata
        });
    }

    /// @notice Decode netDirectCashOutAmount from hook metadata (3rd field in 7-tuple).
    function _decodeNet(bytes memory metadata) internal pure returns (uint256 netDirectCashOutAmount) {
        (,, netDirectCashOutAmount,,,,) =
            abi.decode(metadata, (uint256, uint256, uint256, int24, uint128, PoolId, uint256));
    }

    /// @notice `cashOutTaxRate=0`, non-feeless beneficiary → routing uses GROSS (best case) so the
    /// hook never directs to the AMM when the direct path could pay more. The terminal's actual fee charge depends
    /// on `_feeFreeSurplusOf` (which the hook cannot read); the best-case bound protects the user from being routed
    /// to the AMM in cases where the direct path would settle at gross.
    function test_zeroTaxRate_nonFeelessUsesGrossForRouting() public {
        _mockRuleset(0);
        uint256 gross = 0.5 ether;

        // AMM quote just below gross → noop, because the direct path could pay gross under the active
        // fee/free-surplus semantics. Routing to the AMM would deny the user the better outcome.
        JBBeforeCashOutRecordedContext memory context = _buildContext(0, false, gross - 1);

        (,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        uint256 net = _decodeNet(specs[0].metadata);
        assertEq(net, gross, "zero tax rate non-feeless routing must use gross (best case)");
        assertTrue(specs[0].noop, "AMM below gross direct: hook must prefer direct path");
    }

    /// @notice With `cashOutTaxRate=0` and non-feeless beneficiary, the hook only routes to the AMM
    /// when the AMM minimum strictly beats the best-case direct (gross). That way the route swap is unambiguously
    /// better than any direct outcome under the active fee/free-surplus semantics.
    function test_zeroTaxRate_nonFeelessRoutesToAmmOnlyWhenAmmBeatsGross() public {
        _mockRuleset(0);
        uint256 gross = 0.5 ether;

        // AMM quote strictly above gross → AMM wins.
        JBBeforeCashOutRecordedContext memory context = _buildContext(0, false, gross + 1);

        (,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        assertEq(_decodeNet(specs[0].metadata), gross, "still uses gross as the routing reference");
        assertFalse(specs[0].noop, "AMM strictly beats gross direct: hook must route to AMM");
    }

    /// @notice cashOutTaxRate=0, feeless=true → no fee deduction (net == gross), because feeless beneficiary skips
    /// the
    /// terminal fee entirely.
    function test_zeroTaxRate_feelessBeneficiarySkipsFee() public {
        _mockRuleset(0);
        uint256 gross = 0.5 ether;

        // AMM minimum is just below gross → noop because feeless direct path returns gross.
        JBBeforeCashOutRecordedContext memory context = _buildContext(0, true, gross - 1);

        (,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        uint256 net = _decodeNet(specs[0].metadata);
        assertEq(net, gross, "feeless beneficiary should not deduct fee at zero tax rate");
        assertTrue(specs[0].noop, "AMM minimum below gross direct: feeless direct path wins");
    }

    /// @notice cashOutTaxRate=5000, feeless=false → fee IS deducted (net < gross).
    function test_nonZeroTaxRate_feeDeducted() public {
        _mockRuleset(5000);
        JBBeforeCashOutRecordedContext memory context = _buildContext(5000, false, 1 ether);

        (,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        uint256 net = _decodeNet(specs[0].metadata);

        // gross with 50% tax = 0.275 ether, fee = 0.006875 ether, net = 0.268125 ether
        uint256 expectedGross = 0.275 ether;
        uint256 expectedFee = JBFees.feeAmountFrom({amountBeforeFee: expectedGross, feePercent: 25});
        uint256 expectedNet = expectedGross - expectedFee;

        assertEq(net, expectedNet, "nonzero tax rate should deduct fee");
        assertLt(net, expectedGross, "net should be less than gross");
    }

    /// @notice cashOutTaxRate=5000, feeless=true → no fee deduction (net == gross).
    function test_feelessBeneficiary_alwaysGross() public {
        _mockRuleset(5000);
        JBBeforeCashOutRecordedContext memory context = _buildContext(5000, true, 1 ether);

        (,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        uint256 net = _decodeNet(specs[0].metadata);

        uint256 expectedGross = 0.275 ether;
        assertEq(net, expectedGross, "feeless beneficiary should not deduct fee");
    }

    /// @notice cashOutTaxRate=MAX → JBCashOuts returns 0 (no reclaim), so net is 0.
    function test_maxTaxRate_zeroReclaim() public {
        _mockRuleset(JBConstants.MAX_CASH_OUT_TAX_RATE);
        JBBeforeCashOutRecordedContext memory context = _buildContext(JBConstants.MAX_CASH_OUT_TAX_RATE, false, 1 ether);

        (,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        uint256 net = _decodeNet(specs[0].metadata);

        // MAX_CASH_OUT_TAX_RATE makes JBCashOuts.cashOutFrom return 0 — no direct reclaim at all.
        assertEq(net, 0, "max tax rate should yield zero reclaim");
    }
}
