// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// JB core imports
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
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
import {SwapCallbackData} from "src/structs/SwapCallbackData.sol";

// Test mocks
import {MockPoolManager} from "test/mock/MockPoolManager.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";

/// @notice Simple project token for testing.
contract AuditFixProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Fee-on-transfer token that deducts 2% on every transfer.
contract AuditFixFOTToken is ERC20 {
    uint256 public constant FEE_BPS = 200; // 2%
    uint256 public constant BPS_DENOM = 10_000;

    constructor() ERC20("FOTToken", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * FEE_BPS) / BPS_DENOM;
        uint256 net = amount - fee;
        _transfer(msg.sender, to, net);
        _burn(msg.sender, fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = (amount * FEE_BPS) / BPS_DENOM;
        uint256 net = amount - fee;
        _transfer(from, to, net);
        _burn(from, fee);
        return true;
    }
}

/// @notice Test harness exposing JBBuybackHook internals for pool configuration.
contract AuditFixHook is JBBuybackHook {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBPrices prices,
        IJBProjects projects,
        IJBTokens tokens,
        IPoolManager poolManager,
        IHooks oracleHook,
        address trustedForwarder
    )
        JBBuybackHook(directory, permissions, prices, projects, tokens, poolManager, oracleHook, trustedForwarder)
    {}

    /// @notice Directly initialize pool state for testing without going through setPoolFor permission checks.
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

/// @title AuditFixC3M12Test
/// @notice Tests for audit findings C-3 and M-12:
///   C-3: beforeCashOutRecordedWith noop path returns context.surplus.value as effectiveSurplusValue.
///   M-12: unlockCallback uses balance-delta accounting for swap output (handles fee-on-transfer).
contract AuditFixC3M12Test is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    AuditFixHook hook;
    MockPoolManager mockPm;
    MockOracleHook mockOracle;
    AuditFixProjectToken projectToken;

    // Mock JB core contracts
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));
    IJBController controller = IJBController(makeAddr("controller"));
    IJBMultiTerminal terminal = IJBMultiTerminal(makeAddr("terminal"));

    address owner = makeAddr("owner");
    address payer = makeAddr("payer");

    uint256 projectId = 55;
    uint32 twapWindow = 600;

    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        mockPm = new MockPoolManager();
        mockOracle = new MockOracleHook();
        projectToken = new AuditFixProjectToken();

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        hook = new AuditFixHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            poolManager: IPoolManager(address(mockPm)),
            oracleHook: IHooks(address(mockOracle)),
            trustedForwarder: address(0)
        });

        // Build pool key: native ETH (address(0)) is always currency0.
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        poolId = poolKey.toId();

        // Mock JB core responses.
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

        // Mock controller.
        _mockCurrentRuleset();

        // Configure pool in MockPoolManager.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);

        // Use setPoolFor to set _poolIsSet = true (required for beforeCashOutRecordedWith).
        vm.prank(owner);
        hook.setPoolFor(projectId, poolKey, twapWindow, JBConstants.NATIVE_TOKEN);
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
            useTotalSurplusForCashOuts: false,
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
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (projectId)),
            abi.encode(ruleset, meta)
        );
    }

    //*********************************************************************//
    // ---------- C-3: Noop path returns surplus as effectiveSurplusValue -- //
    //*********************************************************************//

    /// @notice When the swap is not worthwhile (noop=true), beforeCashOutRecordedWith must return
    /// context.surplus.value as effectiveSurplusValue so the terminal computes a proper bonding
    /// curve reclaim. Before the fix, it returned 0, causing zero reclaim.
    function test_C3_noopPathReturnsSurplusValue() public {
        // Oracle returns a weak TWAP quote (tick=0 means 1:1 price, giving cashOutCount worth of output).
        // With cashOutCount=1 ether, totalSupply=100 ether, surplus=10 ether, cashOutTaxRate=0:
        // directCashOut = 10 * 1 / 100 = 0.1 ether
        // TWAP at tick=0 with cashOutCount=1 ether of project token input gives ~1 ether of terminal token output
        // So the swap would actually win here. Let's make the oracle return a quote worse than direct reclaim.
        // Set the oracle to revert so _getQuote returns 0, forcing the noop path.
        mockOracle.setShouldRevert(true);

        uint256 surplusValue = 10 ether;
        uint256 cashOutCount = 1 ether;
        uint256 totalSupplyValue = 100 ether;
        uint256 cashOutTaxRate = 0;

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            totalSupply: totalSupplyValue,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: surplusValue,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            useTotalSurplus: false,
            cashOutTaxRate: cashOutTaxRate,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        (
            uint256 returnedCashOutTaxRate,
            uint256 returnedCashOutCount,
            uint256 returnedTotalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory specs
        ) = hook.beforeCashOutRecordedWith(context);

        // The spec should be noop since oracle reverted => minimumSwapAmountOut = 0 <= directCashOutAmount.
        assertEq(specs.length, 1, "should return one hook spec");
        assertTrue(specs[0].noop, "should be noop when oracle reverts (swap not worthwhile)");

        // C-3 FIX: effectiveSurplusValue must equal context.surplus.value, NOT zero.
        assertEq(
            effectiveSurplusValue,
            surplusValue,
            "C-3: noop path must return surplus value so terminal computes proper reclaim"
        );

        // Other values pass through unchanged.
        assertEq(returnedCashOutTaxRate, cashOutTaxRate, "tax rate should pass through");
        assertEq(returnedCashOutCount, cashOutCount, "cash out count should pass through");
        assertEq(returnedTotalSupply, totalSupplyValue, "total supply should pass through");
    }

    /// @notice Verify the user gets a proper bonding curve reclaim when the noop path is used.
    /// The terminal uses effectiveSurplusValue in JBCashOuts.cashOutFrom to compute reclaim.
    /// With the C-3 fix, effectiveSurplusValue = surplus.value, yielding correct reclaim.
    function test_C3_noopPathYieldsCorrectBondingCurveReclaim() public {
        // Make oracle revert to force noop path.
        mockOracle.setShouldRevert(true);

        uint256 surplusValue = 50 ether;
        uint256 cashOutCount = 10 ether;
        uint256 totalSupplyValue = 100 ether;
        uint256 cashOutTaxRate = 5000; // 50% tax

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            totalSupply: totalSupplyValue,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: surplusValue,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            useTotalSurplus: false,
            cashOutTaxRate: cashOutTaxRate,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        (,,, uint256 effectiveSurplusValue,) = hook.beforeCashOutRecordedWith(context);

        // Compute expected reclaim using the returned effectiveSurplusValue.
        uint256 expectedReclaim = JBCashOuts.cashOutFrom({
            surplus: effectiveSurplusValue,
            cashOutCount: cashOutCount,
            totalSupply: totalSupplyValue,
            cashOutTaxRate: cashOutTaxRate
        });

        // Without the C-3 fix, effectiveSurplusValue would be 0, giving reclaim = 0.
        // With the fix, effectiveSurplusValue = 50 ether, giving a non-zero bonding curve reclaim.
        assertGt(expectedReclaim, 0, "C-3: reclaim must be non-zero when surplus is non-zero");

        // Verify the exact value: base = 50 * 10 / 100 = 5 ether
        // With 50% tax: reclaim = 5 * [(10000 - 5000) + 5000 * (10/100)] / 10000
        //             = 5 * [5000 + 500] / 10000 = 5 * 5500 / 10000 = 2.75 ether
        assertEq(expectedReclaim, 2.75 ether, "C-3: reclaim should match bonding curve formula");
    }

    /// @notice When an explicit minimumSwapAmountOut is provided via metadata but is less than
    /// the direct reclaim, the noop path should still return the correct surplus value.
    function test_C3_noopPathWithExplicitMinimumStillReturnsSurplus() public {
        uint256 surplusValue = 20 ether;
        uint256 cashOutCount = 5 ether;
        uint256 totalSupplyValue = 50 ether;
        // Direct reclaim (0% tax) = 20 * 5 / 50 = 2 ether

        // Set explicit minimum below direct reclaim to trigger noop.
        uint256 explicitMinimum = 1 ether; // less than 2 ether direct reclaim
        bytes4 metadataId = JBMetadataResolver.getId("cashOutMinReclaimed", address(hook));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(explicitMinimum));

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            totalSupply: totalSupplyValue,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: surplusValue,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            useTotalSurplus: false,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: metadata
        });

        (,,, uint256 effectiveSurplusValue, JBCashOutHookSpecification[] memory specs) =
            hook.beforeCashOutRecordedWith(context);

        assertTrue(specs[0].noop, "should be noop when explicit minimum is below direct reclaim");
        assertEq(
            effectiveSurplusValue,
            surplusValue,
            "C-3: noop path with explicit minimum must still return surplus value"
        );
    }

    //*********************************************************************//
    // ---------- M-12: Balance-delta accounting in unlockCallback --------- //
    //*********************************************************************//

    /// @notice For a normal (non-FOT) token, the balance-delta accounting in unlockCallback returns
    /// the same amount as reported by the pool since there is no transfer fee.
    function test_M12_balanceDeltaReturnsCorrectAmountForNormalToken() public {
        // Project token is the output of the swap (zeroForOne = true: ETH in, project token out).
        uint256 amountIn = 1 ether;
        uint256 expectedOut = 500e18;

        // Mock deltas: delta0 = negative (input spent), delta1 = positive (output received).
        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(-int128(uint128(amountIn)), int128(uint128(expectedOut)));

        // Fund the mock pool manager with project tokens so take() can transfer them.
        projectToken.mint(address(mockPm), expectedOut);

        // Build callback data for a zeroForOne swap (ETH -> project token).
        SwapCallbackData memory callbackData = SwapCallbackData({
            key: poolKey,
            zeroForOne: true,
            amountIn: amountIn,
            minimumSwapAmountOut: 0
        });

        // Fund the hook with ETH for settlement.
        vm.deal(address(hook), amountIn);

        // Call unlockCallback directly from the pool manager.
        vm.prank(address(mockPm));
        bytes memory result = hook.unlockCallback(abi.encode(callbackData));

        (uint256 returnedInput, uint256 returnedOutput) = abi.decode(result, (uint256, uint256));

        assertEq(returnedInput, amountIn, "M-12: input amount should match delta");
        assertEq(
            returnedOutput, expectedOut, "M-12: output amount should equal pool-reported amount for normal tokens"
        );
    }

    /// @notice For a fee-on-transfer token, the balance-delta accounting in unlockCallback returns
    /// the actual received amount (less than pool-reported) based on balance before/after the take.
    function test_M12_balanceDeltaAccountsForFeeOnTransfer() public {
        AuditFixFOTToken fotToken = new AuditFixFOTToken();

        // Set up a new pool with FOT token as currency1 (output currency for zeroForOne swap).
        // We need fotToken address > address(0) for currency1.
        PoolKey memory fotPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(fotToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });

        uint256 amountIn = 1 ether;
        uint256 poolReportedOut = 100 ether;
        // FOT token has 2% fee, so actual received = 100 * 98% = 98 ether.
        uint256 expectedActualOut = (poolReportedOut * (10_000 - 200)) / 10_000;

        // Mock deltas: ETH in (negative delta0), FOT out (positive delta1).
        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(-int128(uint128(amountIn)), int128(uint128(poolReportedOut)));

        // Fund the mock pool manager with FOT tokens so take() triggers the fee-on-transfer.
        fotToken.mint(address(mockPm), poolReportedOut);

        // Build callback data.
        SwapCallbackData memory callbackData = SwapCallbackData({
            key: fotPoolKey,
            zeroForOne: true,
            amountIn: amountIn,
            minimumSwapAmountOut: 0
        });

        // Fund the hook with ETH for settlement.
        vm.deal(address(hook), amountIn);

        // Call unlockCallback directly from the pool manager.
        vm.prank(address(mockPm));
        bytes memory result = hook.unlockCallback(abi.encode(callbackData));

        (uint256 returnedInput, uint256 returnedOutput) = abi.decode(result, (uint256, uint256));

        assertEq(returnedInput, amountIn, "M-12: input amount should match delta");
        assertEq(
            returnedOutput,
            expectedActualOut,
            "M-12: output must reflect actual received after FOT deduction, not pool-reported amount"
        );
        // The key assertion: the returned output is LESS than what the pool reported.
        assertLt(returnedOutput, poolReportedOut, "M-12: FOT token output must be less than pool-reported amount");
    }

    /// @notice Verify balance-delta accounting works for the oneForZero direction (project token in, ETH out).
    function test_M12_balanceDeltaWorksForOneForZeroDirection() public {
        // oneForZero: project token (currency1) is input, ETH (currency0) is output.
        uint256 amountIn = 500e18;
        uint256 expectedOut = 2 ether;

        // Mock deltas: delta0 = positive (output received ETH), delta1 = negative (input spent project token).
        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(int128(uint128(expectedOut)), -int128(uint128(amountIn)));

        // Fund the mock pool manager with ETH so take() can send it.
        vm.deal(address(mockPm), expectedOut);

        // Fund the hook with project tokens for settlement.
        projectToken.mint(address(hook), amountIn);

        // Approve pool manager to pull project tokens during settle.
        vm.prank(address(hook));
        projectToken.approve(address(mockPm), amountIn);

        // Build callback data for oneForZero.
        SwapCallbackData memory callbackData = SwapCallbackData({
            key: poolKey,
            zeroForOne: false, // oneForZero
            amountIn: amountIn,
            minimumSwapAmountOut: 0
        });

        // Call unlockCallback from pool manager.
        vm.prank(address(mockPm));
        bytes memory result = hook.unlockCallback(abi.encode(callbackData));

        (uint256 returnedInput, uint256 returnedOutput) = abi.decode(result, (uint256, uint256));

        assertEq(returnedInput, amountIn, "M-12: input should be project token amount");
        assertEq(returnedOutput, expectedOut, "M-12: output should be ETH amount from balance delta");
    }
}
