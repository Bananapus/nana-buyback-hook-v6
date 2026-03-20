// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

// JB core imports
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";

import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
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

/// @notice ERC20 token with configurable decimals for testing non-18-decimal tokens.
contract MockProjectTokenDecimals is ERC20 {
    uint8 private _dec;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Standard 18-decimal mock token.
contract MockProjectToken18 is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Test harness that exposes JBBuybackHook internals for direct pool configuration.
contract ForTest_AuditGaps_BuybackHook is JBBuybackHook {
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

    /// @notice Directly initialize pool state for testing without permission checks.
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

/// @title TestAuditGaps
/// @notice Tests for audit gaps: non-18-decimal tokens, multi-pool projects, and concurrent payments.
contract TestAuditGaps is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    //*********************************************************************//
    // ----------------------------- state ------------------------------ //
    //*********************************************************************//

    ForTest_AuditGaps_BuybackHook hook;
    MockPoolManager mockPm;
    MockOracleHook mockOracle;

    // Mock JB core contracts (address-only, mocked via vm.mockCall)
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));
    IJBController controller = IJBController(makeAddr("controller"));
    IJBMultiTerminal terminal = IJBMultiTerminal(makeAddr("terminal"));

    address owner = makeAddr("owner");
    address payer = makeAddr("payer");
    address beneficiary = makeAddr("beneficiary");

    uint256 projectId = 42;
    uint32 twapWindow = 600; // 10 minutes

    //*********************************************************************//
    // ----------------------------- setup ------------------------------ //
    //*********************************************************************//

    function setUp() public {
        // Deploy real contracts.
        mockPm = new MockPoolManager();
        mockOracle = new MockOracleHook();

        // Etch code at mock addresses so calls don't revert with "no code".
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        // Labels.
        vm.label(address(mockPm), "MockPoolManager");
        vm.label(address(mockOracle), "MockOracleHook");

        // Deploy hook.
        hook = new ForTest_AuditGaps_BuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            poolManager: IPoolManager(address(mockPm)),
            oracleHook: IHooks(address(mockOracle)),
            trustedForwarder: address(0)
        });

        // Set up default mock responses for JB core.
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(owner));
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (projectId)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (projectId, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );

        // Mock permissions to always allow.
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

        // Mock controller responses.
        _mockControllerMint();
        _mockControllerBurn();
    }

    //*********************************************************************//
    // ----------------------------- helpers ---------------------------- //
    //*********************************************************************//

    /// @notice Build a JBRuleset and mock controller.currentRulesetOf for a given project/weight/baseCurrency.
    function _mockCurrentRuleset(uint256 pid, uint256 weight, uint32 baseCurrency) internal {
        JBRulesetMetadata memory meta = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: baseCurrency,
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
            useDataHookForCashOut: false,
            dataHook: address(hook),
            metadata: 0
        });

        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 30 days,
            // forge-lint: disable-next-line(unsafe-typecast)
            weight: uint112(weight),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller), abi.encodeCall(IJBController.currentRulesetOf, (pid)), abi.encode(ruleset, meta)
        );
    }

    /// @notice Mock controller.mintTokensOf to succeed.
    function _mockControllerMint() internal {
        vm.mockCall(
            address(controller),
            abi.encodeWithSignature("mintTokensOf(uint256,uint256,address,string,bool)"),
            abi.encode(0)
        );
    }

    /// @notice Mock controller.burnTokensOf to succeed.
    function _mockControllerBurn() internal {
        vm.mockCall(
            address(controller), abi.encodeWithSignature("burnTokensOf(address,uint256,uint256,string)"), abi.encode()
        );
    }

    /// @notice Mock addToBalanceOf on the terminal (for leftover funds returned by the hook).
    function _mockAddToBalance() internal {
        vm.mockCall(
            address(terminal),
            abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
            abi.encode()
        );
    }

    /// @notice Build a JBAfterPayRecordedContext for the given parameters.
    function _makeAfterPayContext(
        uint256 pid,
        address payToken,
        uint256 payValue,
        uint8 payDecimals,
        bool projectTokenIs0,
        uint256 amountToMintWith,
        uint256 minimumSwapAmountOut
    )
        internal
        view
        returns (JBAfterPayRecordedContext memory)
    {
        return JBAfterPayRecordedContext({
            payer: payer,
            projectId: pid,
            rulesetId: 1,
            amount: JBTokenAmount({
                token: payToken,
                decimals: payDecimals,
                currency: uint32(uint160(payToken == JBConstants.NATIVE_TOKEN ? JBConstants.NATIVE_TOKEN : payToken)),
                value: payValue
            }),
            forwardedAmount: JBTokenAmount({
                token: payToken,
                decimals: payDecimals,
                currency: uint32(uint160(payToken == JBConstants.NATIVE_TOKEN ? JBConstants.NATIVE_TOKEN : payToken)),
                value: payValue
            }),
            weight: 1e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(projectTokenIs0, amountToMintWith, minimumSwapAmountOut, controller),
            payerMetadata: ""
        });
    }

    //*********************************************************************//
    // ----------- GAP 1: Non-18-decimal tokens (e.g., USDC 6) ---------- //
    //*********************************************************************//

    /// @notice Test that a full swap works with a 6-decimal ERC-20 terminal token (like USDC).
    /// The hook should correctly handle the token transfer and swap through V4.
    function test_non18Decimal_swapWithUSDC6() public {
        // Deploy a 6-decimal "USDC" token and an 18-decimal project token.
        MockProjectTokenDecimals usdc = new MockProjectTokenDecimals("USDC", "USDC", 6);
        MockProjectToken18 projToken = new MockProjectToken18();

        vm.label(address(usdc), "USDC6");
        vm.label(address(projToken), "ProjectToken18");

        // Mock tokens.tokenOf to return this project token.
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projToken)))
        );

        // Build pool key: sort addresses for currency0 < currency1.
        (Currency c0, Currency c1) = address(usdc) < address(projToken)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(projToken)))
            : (Currency.wrap(address(projToken)), Currency.wrap(address(usdc)));

        PoolKey memory poolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(mockOracle))});
        PoolId poolId = poolKey.toId();

        bool projectTokenIs0 = address(projToken) < address(usdc);

        // Set up the pool in MockPoolManager.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);

        // Configure the pool in the hook (bypass permissions).
        // normalizedTerminalToken is the USDC address (not native, so no normalization to address(0)).
        hook.forTestInitPool(projectId, poolKey, twapWindow, address(projToken), address(usdc));

        // Set up mock ruleset.
        _mockCurrentRuleset(projectId, 1e18, uint32(uint160(address(usdc))));

        // Configure mock deltas: the swap consumes 1000 USDC (1000e6) and returns 500 project tokens.
        uint256 payAmount = 1000e6; // 1000 USDC
        uint256 swapOut = 500e18; // 500 project tokens

        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        // Pre-fund the MockPoolManager with project tokens so take() can transfer them.
        projToken.mint(address(mockPm), swapOut);

        // Mint USDC to the terminal so it can transfer them to the hook.
        usdc.mint(address(terminal), payAmount);

        // The hook calls safeTransferFrom(terminal, hook, payAmount) for ERC-20 payments.
        // Approve the hook to pull from the terminal.
        vm.prank(address(terminal));
        usdc.approve(address(hook), payAmount);

        // Build the afterPay context for a 6-decimal ERC-20 payment.
        JBAfterPayRecordedContext memory ctx =
            _makeAfterPayContext(projectId, address(usdc), payAmount, 6, projectTokenIs0, 0, 0);

        // Call afterPayRecordedWith from the terminal.
        vm.prank(address(terminal));
        hook.afterPayRecordedWith(ctx);

        // Verify the swap was executed.
        assertTrue(mockPm.swapCalled(), "swap() should have been called for 6-decimal USDC payment");
    }

    /// @notice Test that a swap with a 6-decimal token falls back to mint when pool reverts.
    function test_non18Decimal_fallbackToMint_USDC6() public {
        MockProjectTokenDecimals usdc = new MockProjectTokenDecimals("USDC", "USDC", 6);
        MockProjectToken18 projToken = new MockProjectToken18();

        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projToken)))
        );

        (Currency c0, Currency c1) = address(usdc) < address(projToken)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(projToken)))
            : (Currency.wrap(address(projToken)), Currency.wrap(address(usdc)));

        PoolKey memory poolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(mockOracle))});
        PoolId poolId = poolKey.toId();

        bool projectTokenIs0 = address(projToken) < address(usdc);

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        hook.forTestInitPool(projectId, poolKey, twapWindow, address(projToken), address(usdc));

        _mockCurrentRuleset(projectId, 1e18, uint32(uint160(address(usdc))));

        // Force unlock to revert, triggering mint fallback.
        mockPm.setShouldRevertOnUnlock(true);

        uint256 payAmount = 500e6; // 500 USDC
        usdc.mint(address(terminal), payAmount);
        vm.prank(address(terminal));
        usdc.approve(address(hook), payAmount);

        // Mock addToBalanceOf (hook returns leftover funds to terminal). Also need ERC-20 approval mock.
        _mockAddToBalance();

        JBAfterPayRecordedContext memory ctx =
            _makeAfterPayContext(projectId, address(usdc), payAmount, 6, projectTokenIs0, 0, 0);

        // Should NOT revert -- falls back to minting.
        vm.prank(address(terminal));
        hook.afterPayRecordedWith(ctx);

        // swap() should NOT have been called.
        assertFalse(mockPm.swapCalled(), "swap() should NOT have been called when unlock reverts for USDC");
    }

    /// @notice Test that a 8-decimal token (like WBTC) also works correctly through the swap flow.
    function test_non18Decimal_swapWithWBTC8() public {
        MockProjectTokenDecimals wbtc = new MockProjectTokenDecimals("WBTC", "WBTC", 8);
        MockProjectToken18 projToken = new MockProjectToken18();

        vm.label(address(wbtc), "WBTC8");
        vm.label(address(projToken), "ProjectToken18");

        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projToken)))
        );

        (Currency c0, Currency c1) = address(wbtc) < address(projToken)
            ? (Currency.wrap(address(wbtc)), Currency.wrap(address(projToken)))
            : (Currency.wrap(address(projToken)), Currency.wrap(address(wbtc)));

        PoolKey memory poolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(mockOracle))});
        PoolId poolId = poolKey.toId();

        bool projectTokenIs0 = address(projToken) < address(wbtc);

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);

        hook.forTestInitPool(projectId, poolKey, twapWindow, address(projToken), address(wbtc));
        _mockCurrentRuleset(projectId, 1e18, uint32(uint160(address(wbtc))));

        uint256 payAmount = 1e8; // 1 WBTC
        uint256 swapOut = 10_000e18; // 10,000 project tokens

        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        projToken.mint(address(mockPm), swapOut);
        wbtc.mint(address(terminal), payAmount);
        vm.prank(address(terminal));
        wbtc.approve(address(hook), payAmount);

        JBAfterPayRecordedContext memory ctx =
            _makeAfterPayContext(projectId, address(wbtc), payAmount, 8, projectTokenIs0, 0, 0);

        vm.prank(address(terminal));
        hook.afterPayRecordedWith(ctx);

        assertTrue(mockPm.swapCalled(), "swap() should have been called for 8-decimal WBTC payment");
    }

    /// @notice Test that sell-side routing also works with a 6-decimal ERC-20 terminal token.
    function test_non18Decimal_sellSideRoutesWithUSDC6() public {
        MockProjectTokenDecimals usdc = new MockProjectTokenDecimals("USDC", "USDC", 6);
        MockProjectTokenDecimals projToken = new MockProjectTokenDecimals("ProjectToken", "PT", 6);

        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projToken)))
        );

        (Currency c0, Currency c1) = address(usdc) < address(projToken)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(projToken)))
            : (Currency.wrap(address(projToken)), Currency.wrap(address(usdc)));

        PoolKey memory poolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(mockOracle))});
        PoolId poolId = poolKey.toId();

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);
        mockOracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId,
            poolKey: poolKey,
            twapWindow: twapWindow,
            terminalToken: address(usdc)
        });

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: 10e6,
            totalSupply: 100e6,
            surplus: JBTokenAmount({
                token: address(usdc),
                value: 5e6,
                decimals: 6,
                currency: uint32(uint160(address(usdc)))
            }),
            useTotalSurplus: false,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        (uint256 cashOutTaxRate,,,
            JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE, "USDC sell-side should reroute through swap");
        assertEq(specs.length, 1, "USDC sell-side should return a hook spec");
    }

    /// @notice Test that sell-side settlement correctly transfers 6-decimal ERC-20 proceeds to the beneficiary.
    function test_non18Decimal_sellSideSettlementWithUSDC6() public {
        MockProjectTokenDecimals usdc = new MockProjectTokenDecimals("USDC", "USDC", 6);
        MockProjectTokenDecimals projToken = new MockProjectTokenDecimals("ProjectToken", "PT", 6);

        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projToken)))
        );

        (Currency c0, Currency c1) = address(usdc) < address(projToken)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(projToken)))
            : (Currency.wrap(address(projToken)), Currency.wrap(address(usdc)));

        PoolKey memory poolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(mockOracle))});
        PoolId poolId = poolKey.toId();
        bool projectTokenIs0 = address(projToken) < address(usdc);

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);

        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId,
            poolKey: poolKey,
            twapWindow: twapWindow,
            terminalToken: address(usdc)
        });

        uint256 cashOutCount = 10e6;
        uint256 amountOut = 15e6;

        projToken.mint(address(hook), cashOutCount);
        usdc.mint(address(mockPm), amountOut);

        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(cashOutCount)), int128(uint128(amountOut)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(amountOut)), -int128(uint128(cashOutCount)));
        }

        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            reclaimedAmount: JBTokenAmount({
                token: address(usdc),
                value: 0,
                decimals: 6,
                currency: uint32(uint160(address(usdc)))
            }),
            forwardedAmount: JBTokenAmount({
                token: address(usdc),
                value: 0,
                decimals: 6,
                currency: uint32(uint160(address(usdc)))
            }),
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: payable(beneficiary),
            hookMetadata: abi.encode(amountOut),
            cashOutMetadata: ""
        });

        uint256 balanceBefore = usdc.balanceOf(beneficiary);

        vm.prank(address(terminal));
        hook.afterCashOutRecordedWith(context);

        assertTrue(mockPm.swapCalled(), "USDC sell-side settlement should swap through V4");
        assertEq(usdc.balanceOf(beneficiary) - balanceBefore, amountOut, "beneficiary should receive USDC proceeds");
    }

    //*********************************************************************//
    // ----------- GAP 2: Multi-pool projects ----------------------------- //
    //*********************************************************************//

    /// @notice Test that a project can have pools registered for multiple terminal tokens
    /// (e.g., one for native ETH and another for an ERC-20), and both are independently accessible.
    function test_multiPool_separateETHAndERC20Pools() public {
        MockProjectToken18 projToken = new MockProjectToken18();
        MockProjectTokenDecimals usdc = new MockProjectTokenDecimals("USDC", "USDC", 6);

        vm.label(address(projToken), "ProjectToken");
        vm.label(address(usdc), "USDC");

        uint256 multiPid = 500;

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (multiPid)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (multiPid)), abi.encode(IJBToken(address(projToken)))
        );
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (multiPid)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (multiPid, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );

        // --- Pool 1: Native ETH / ProjectToken ---
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH (always smallest)
            currency1: Currency.wrap(address(projToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        PoolId ethPoolId = ethPoolKey.toId();

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(ethPoolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(ethPoolId, 1_000_000 ether);

        // setPoolFor for native ETH.
        vm.prank(owner);
        hook.setPoolFor(multiPid, ethPoolKey, twapWindow, JBConstants.NATIVE_TOKEN);

        // --- Pool 2: USDC / ProjectToken ---
        (Currency c0, Currency c1) = address(usdc) < address(projToken)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(projToken)))
            : (Currency.wrap(address(projToken)), Currency.wrap(address(usdc)));

        PoolKey memory usdcPoolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 500, // different fee tier for USDC pool
            tickSpacing: 10,
            hooks: IHooks(address(mockOracle))
        });
        PoolId usdcPoolId = usdcPoolKey.toId();

        mockPm.setSlot0(usdcPoolId, sqrtPrice, 0, 500);
        mockPm.setLiquidity(usdcPoolId, 1_000_000 ether);

        // setPoolFor for USDC.
        vm.prank(owner);
        hook.setPoolFor(multiPid, usdcPoolKey, twapWindow, address(usdc));

        // --- Verify both pools stored independently ---
        PoolKey memory storedEthKey = hook.poolKeyOf(multiPid, address(0));
        assertEq(storedEthKey.fee, 3000, "ETH pool fee should be 3000");
        assertEq(storedEthKey.tickSpacing, int24(60), "ETH pool tickSpacing should be 60");

        PoolKey memory storedUsdcKey = hook.poolKeyOf(multiPid, address(usdc));
        assertEq(storedUsdcKey.fee, 500, "USDC pool fee should be 500");
        assertEq(storedUsdcKey.tickSpacing, int24(10), "USDC pool tickSpacing should be 10");

        // Verify TWAP windows are independent.
        assertEq(hook.twapWindowOf(multiPid, address(0)), twapWindow, "ETH TWAP window should match");
        assertEq(hook.twapWindowOf(multiPid, address(usdc)), twapWindow, "USDC TWAP window should match");
    }

    /// @notice Test that executing a swap via the ETH pool does not affect the USDC pool configuration.
    function test_multiPool_swapOnETHPoolDoesNotAffectUSDCPool() public {
        MockProjectToken18 projToken = new MockProjectToken18();
        MockProjectTokenDecimals usdc = new MockProjectTokenDecimals("USDC", "USDC", 6);

        uint256 multiPid = 501;

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (multiPid)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (multiPid)), abi.encode(IJBToken(address(projToken)))
        );
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (multiPid)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (multiPid, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );

        // Set up both pools via forTestInitPool.
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        PoolId ethPoolId = ethPoolKey.toId();
        mockPm.setSlot0(ethPoolId, TickMath.getSqrtPriceAtTick(0), 0, 3000);
        mockPm.setLiquidity(ethPoolId, 1_000_000 ether);
        hook.forTestInitPool(multiPid, ethPoolKey, twapWindow, address(projToken), address(0));

        (Currency c0, Currency c1) = address(usdc) < address(projToken)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(projToken)))
            : (Currency.wrap(address(projToken)), Currency.wrap(address(usdc)));

        PoolKey memory usdcPoolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(mockOracle))});
        PoolId usdcPoolId = usdcPoolKey.toId();
        mockPm.setSlot0(usdcPoolId, TickMath.getSqrtPriceAtTick(0), 0, 500);
        mockPm.setLiquidity(usdcPoolId, 1_000_000 ether);
        hook.forTestInitPool(multiPid, usdcPoolKey, twapWindow, address(projToken), address(usdc));

        _mockCurrentRuleset(multiPid, 1e18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Execute a swap on the ETH pool.
        uint256 payAmount = 1 ether;
        uint256 swapOut = 500e18;
        bool ethProjectTokenIs0 = address(projToken) < address(0);

        if (ethProjectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }
        projToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx =
            _makeAfterPayContext(multiPid, JBConstants.NATIVE_TOKEN, payAmount, 18, ethProjectTokenIs0, 0, 0);

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        assertTrue(mockPm.swapCalled(), "swap() should have been called on ETH pool");

        // Verify the USDC pool configuration is completely untouched.
        PoolKey memory storedUsdcKey = hook.poolKeyOf(multiPid, address(usdc));
        assertEq(storedUsdcKey.fee, 500, "USDC pool fee should still be 500 after ETH swap");
        assertEq(storedUsdcKey.tickSpacing, int24(10), "USDC pool tickSpacing should still be 10 after ETH swap");
        assertEq(hook.twapWindowOf(multiPid, address(usdc)), twapWindow, "USDC TWAP window unchanged after ETH swap");
    }

    /// @notice Test that independent TWAP windows can be set for different terminal tokens on the same project.
    function test_multiPool_independentTWAPWindows() public {
        MockProjectToken18 projToken = new MockProjectToken18();
        MockProjectTokenDecimals usdc = new MockProjectTokenDecimals("USDC", "USDC", 6);

        uint256 multiPid = 502;

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (multiPid)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (multiPid)), abi.encode(IJBToken(address(projToken)))
        );

        // Set ETH pool with 10 minute window.
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        PoolId ethPoolId = ethPoolKey.toId();
        mockPm.setSlot0(ethPoolId, TickMath.getSqrtPriceAtTick(0), 0, 3000);

        vm.prank(owner);
        hook.setPoolFor(multiPid, ethPoolKey, 10 minutes, JBConstants.NATIVE_TOKEN);

        // Set USDC pool with 30 minute window.
        (Currency c0, Currency c1) = address(usdc) < address(projToken)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(projToken)))
            : (Currency.wrap(address(projToken)), Currency.wrap(address(usdc)));

        PoolKey memory usdcPoolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(mockOracle))});
        PoolId usdcPoolId = usdcPoolKey.toId();
        mockPm.setSlot0(usdcPoolId, TickMath.getSqrtPriceAtTick(0), 0, 500);

        vm.prank(owner);
        hook.setPoolFor(multiPid, usdcPoolKey, 30 minutes, address(usdc));

        // Verify independent windows.
        assertEq(hook.twapWindowOf(multiPid, address(0)), 10 minutes, "ETH pool should have 10 min TWAP window");
        assertEq(hook.twapWindowOf(multiPid, address(usdc)), 30 minutes, "USDC pool should have 30 min TWAP window");

        // Update ETH TWAP window only.
        vm.prank(owner);
        hook.setTwapWindowOf(multiPid, JBConstants.NATIVE_TOKEN, 15 minutes);

        assertEq(hook.twapWindowOf(multiPid, address(0)), 15 minutes, "ETH pool TWAP window should now be 15 min");
        assertEq(
            hook.twapWindowOf(multiPid, address(usdc)),
            30 minutes,
            "USDC pool TWAP window should still be 30 min after ETH update"
        );
    }

    /// @notice Test that setPoolFor reverts for the second pool with the same terminal token (PoolAlreadySet).
    function test_multiPool_cannotSetSameTerminalTokenTwice() public {
        MockProjectToken18 projToken = new MockProjectToken18();

        uint256 multiPid = 503;

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (multiPid)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (multiPid)), abi.encode(IJBToken(address(projToken)))
        );

        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        PoolId ethPoolId = ethPoolKey.toId();
        mockPm.setSlot0(ethPoolId, TickMath.getSqrtPriceAtTick(0), 0, 3000);

        // First set succeeds.
        vm.prank(owner);
        hook.setPoolFor(multiPid, ethPoolKey, twapWindow, JBConstants.NATIVE_TOKEN);

        // Second set should revert with PoolAlreadySet.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_PoolAlreadySet.selector, ethPoolId));
        hook.setPoolFor(multiPid, ethPoolKey, twapWindow, JBConstants.NATIVE_TOKEN);
    }

    //*********************************************************************//
    // ----------- GAP 3: Concurrent payments ----------------------------- //
    //*********************************************************************//

    /// @notice Test that two sequential payments (simulating concurrent payments) through the buyback hook
    /// both succeed independently.
    function test_concurrent_twoSequentialSwapPayments() public {
        MockProjectToken18 projToken = new MockProjectToken18();

        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projToken)))
        );

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        PoolId poolId = poolKey.toId();

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);
        hook.forTestInitPool(projectId, poolKey, twapWindow, address(projToken), address(0));
        _mockCurrentRuleset(projectId, 1e18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        bool projectTokenIs0 = address(projToken) < address(0);

        // --- Payment 1 ---
        uint256 payAmount1 = 1 ether;
        uint256 swapOut1 = 500e18;

        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut1)), -int128(uint128(payAmount1)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount1)), int128(uint128(swapOut1)));
        }
        projToken.mint(address(mockPm), swapOut1);

        JBAfterPayRecordedContext memory ctx1 =
            _makeAfterPayContext(projectId, JBConstants.NATIVE_TOKEN, payAmount1, 18, projectTokenIs0, 0, 0);

        vm.deal(address(terminal), payAmount1);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount1}(ctx1);

        assertTrue(mockPm.swapCalled(), "swap() should have been called for payment 1");

        // --- Payment 2 ---
        uint256 payAmount2 = 2 ether;
        uint256 swapOut2 = 1000e18;

        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut2)), -int128(uint128(payAmount2)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount2)), int128(uint128(swapOut2)));
        }
        projToken.mint(address(mockPm), swapOut2);

        JBAfterPayRecordedContext memory ctx2 =
            _makeAfterPayContext(projectId, JBConstants.NATIVE_TOKEN, payAmount2, 18, projectTokenIs0, 0, 0);

        vm.deal(address(terminal), payAmount2);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount2}(ctx2);

        assertTrue(mockPm.swapCalled(), "swap() should have been called for payment 2");
    }

    /// @notice Test that payment 1 succeeds via swap and payment 2 falls back to mint,
    /// simulating divergent concurrent outcomes.
    function test_concurrent_swapThenMintFallback() public {
        MockProjectToken18 projToken = new MockProjectToken18();

        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projToken)))
        );

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        PoolId poolId = poolKey.toId();

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);
        hook.forTestInitPool(projectId, poolKey, twapWindow, address(projToken), address(0));
        _mockCurrentRuleset(projectId, 1e18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        bool projectTokenIs0 = address(projToken) < address(0);

        // --- Payment 1: Successful swap ---
        uint256 payAmount1 = 1 ether;
        uint256 swapOut1 = 500e18;

        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut1)), -int128(uint128(payAmount1)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount1)), int128(uint128(swapOut1)));
        }
        projToken.mint(address(mockPm), swapOut1);

        JBAfterPayRecordedContext memory ctx1 =
            _makeAfterPayContext(projectId, JBConstants.NATIVE_TOKEN, payAmount1, 18, projectTokenIs0, 0, 0);

        vm.deal(address(terminal), payAmount1);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount1}(ctx1);

        assertTrue(mockPm.swapCalled(), "swap() should have been called for payment 1");

        // --- Payment 2: Pool reverts, falls back to mint ---
        mockPm.setShouldRevertOnUnlock(true);
        _mockAddToBalance();

        uint256 payAmount2 = 3 ether;
        JBAfterPayRecordedContext memory ctx2 =
            _makeAfterPayContext(projectId, JBConstants.NATIVE_TOKEN, payAmount2, 18, projectTokenIs0, 0, 0);

        vm.deal(address(terminal), payAmount2);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount2}(ctx2);

        // The hook should not revert -- it falls back to minting.
        // swapCalled is still true from payment 1 because MockPoolManager doesn't reset it,
        // but the important thing is that the second call didn't revert.
    }

    /// @notice Test that two payments with different beneficiaries both succeed.
    function test_concurrent_differentBeneficiaries() public {
        MockProjectToken18 projToken = new MockProjectToken18();

        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projToken)))
        );

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        PoolId poolId = poolKey.toId();

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);
        hook.forTestInitPool(projectId, poolKey, twapWindow, address(projToken), address(0));
        _mockCurrentRuleset(projectId, 1e18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        bool projectTokenIs0 = address(projToken) < address(0);

        address beneficiary1 = makeAddr("beneficiary1");
        address beneficiary2 = makeAddr("beneficiary2");

        uint256 payAmount = 1 ether;
        uint256 swapOut = 500e18;

        // --- Payment for beneficiary 1 ---
        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }
        projToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx1 = JBAfterPayRecordedContext({
            payer: payer,
            projectId: projectId,
            rulesetId: 1,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: payAmount
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: payAmount
            }),
            weight: 1e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary1,
            hookMetadata: abi.encode(projectTokenIs0, uint256(0), uint256(0), controller),
            payerMetadata: ""
        });

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx1);

        assertTrue(mockPm.swapCalled(), "swap() should have been called for beneficiary 1");

        // --- Payment for beneficiary 2 ---
        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }
        projToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx2 = JBAfterPayRecordedContext({
            payer: payer,
            projectId: projectId,
            rulesetId: 1,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: payAmount
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: payAmount
            }),
            weight: 1e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary2,
            hookMetadata: abi.encode(projectTokenIs0, uint256(0), uint256(0), controller),
            payerMetadata: ""
        });

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx2);

        assertTrue(mockPm.swapCalled(), "swap() should have been called for beneficiary 2");
    }

    /// @notice Test that multiple payments with varying amounts through the same pool all succeed,
    /// simulating a burst of concurrent activity.
    function test_concurrent_burstOfPayments() public {
        MockProjectToken18 projToken = new MockProjectToken18();

        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projToken)))
        );

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        PoolId poolId = poolKey.toId();

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);
        hook.forTestInitPool(projectId, poolKey, twapWindow, address(projToken), address(0));
        _mockCurrentRuleset(projectId, 1e18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        bool projectTokenIs0 = address(projToken) < address(0);

        // Simulate 5 consecutive payments with varying amounts.
        uint256[5] memory amounts = [uint256(0.1 ether), 0.5 ether, 1 ether, 2 ether, 5 ether];

        for (uint256 i = 0; i < 5; i++) {
            uint256 payAmount = amounts[i];
            uint256 swapOut = payAmount * 500; // Arbitrary exchange rate

            if (projectTokenIs0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
            } else {
                // forge-lint: disable-next-line(unsafe-typecast)
                mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
            }
            projToken.mint(address(mockPm), swapOut);

            JBAfterPayRecordedContext memory ctx =
                _makeAfterPayContext(projectId, JBConstants.NATIVE_TOKEN, payAmount, 18, projectTokenIs0, 0, 0);

            vm.deal(address(terminal), payAmount);
            vm.prank(address(terminal));
            hook.afterPayRecordedWith{value: payAmount}(ctx);
        }

        assertTrue(mockPm.swapCalled(), "swap() should have been called during burst");
    }

    /// @notice Test concurrent payments across two different terminal tokens (ETH and ERC-20)
    /// for the same project with separate pools.
    function test_concurrent_crossTokenPayments() public {
        MockProjectToken18 projToken = new MockProjectToken18();
        MockProjectTokenDecimals usdc = new MockProjectTokenDecimals("USDC", "USDC", 6);

        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projToken)))
        );

        // --- Set up ETH pool ---
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        PoolId ethPoolId = ethPoolKey.toId();
        mockPm.setSlot0(ethPoolId, TickMath.getSqrtPriceAtTick(0), 0, 3000);
        mockPm.setLiquidity(ethPoolId, 1_000_000 ether);
        hook.forTestInitPool(projectId, ethPoolKey, twapWindow, address(projToken), address(0));

        // --- Set up USDC pool ---
        (Currency c0, Currency c1) = address(usdc) < address(projToken)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(projToken)))
            : (Currency.wrap(address(projToken)), Currency.wrap(address(usdc)));

        PoolKey memory usdcPoolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(mockOracle))});
        PoolId usdcPoolId = usdcPoolKey.toId();
        mockPm.setSlot0(usdcPoolId, TickMath.getSqrtPriceAtTick(0), 0, 500);
        mockPm.setLiquidity(usdcPoolId, 1_000_000 ether);
        hook.forTestInitPool(projectId, usdcPoolKey, twapWindow, address(projToken), address(usdc));

        // Mock rulesets.
        _mockCurrentRuleset(projectId, 1e18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        bool ethProjectTokenIs0 = address(projToken) < address(0);
        bool usdcProjectTokenIs0 = address(projToken) < address(usdc);

        // --- ETH payment ---
        uint256 ethPayAmount = 1 ether;
        uint256 ethSwapOut = 500e18;

        if (ethProjectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(ethSwapOut)), -int128(uint128(ethPayAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(ethPayAmount)), int128(uint128(ethSwapOut)));
        }
        projToken.mint(address(mockPm), ethSwapOut);

        JBAfterPayRecordedContext memory ethCtx =
            _makeAfterPayContext(projectId, JBConstants.NATIVE_TOKEN, ethPayAmount, 18, ethProjectTokenIs0, 0, 0);

        vm.deal(address(terminal), ethPayAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: ethPayAmount}(ethCtx);

        assertTrue(mockPm.swapCalled(), "swap() should have been called for ETH payment");

        // --- USDC payment ---
        // Need to re-mock ruleset for USDC currency.
        _mockCurrentRuleset(projectId, 1e18, uint32(uint160(address(usdc))));

        uint256 usdcPayAmount = 1000e6;
        uint256 usdcSwapOut = 500e18;

        if (usdcProjectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(usdcSwapOut)), -int128(uint128(usdcPayAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(usdcPayAmount)), int128(uint128(usdcSwapOut)));
        }
        projToken.mint(address(mockPm), usdcSwapOut);

        usdc.mint(address(terminal), usdcPayAmount);
        vm.prank(address(terminal));
        usdc.approve(address(hook), usdcPayAmount);

        JBAfterPayRecordedContext memory usdcCtx =
            _makeAfterPayContext(projectId, address(usdc), usdcPayAmount, 6, usdcProjectTokenIs0, 0, 0);

        vm.prank(address(terminal));
        hook.afterPayRecordedWith(usdcCtx);

        // Both payments completed successfully.
        assertTrue(mockPm.swapCalled(), "swap() should have been called for USDC payment");
    }
}
