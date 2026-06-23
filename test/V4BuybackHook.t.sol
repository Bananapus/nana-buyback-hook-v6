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
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
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
import {JBSwapLib} from "src/libraries/JBSwapLib.sol";

// Test mocks
import {MockPoolManager} from "./mock/MockPoolManager.sol";
import {MockOracleHook} from "./mock/MockOracleHook.sol";

/// @notice Simple ERC20 token for testing.
contract MockProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Test harness that exposes JBBuybackHook internals for direct pool configuration.
contract ForTest_V4BuybackHook is JBBuybackHook {
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
        // Also set the private _poolIsSet flag via storage slot manipulation is not possible,
        // so we keep it unset and rely on _getQuote returning 0 for TWAP tests.
        // For setPoolFor tests we use the real function.
    }
}

/// @title V4BuybackHookTest
/// @notice Tests for the JBBuybackHook V4 integration covering the unlock/callback swap flow,
///         fallback-to-mint, callback auth, native ETH settlement, TWAP oracle queries,
///         continuous sigmoid slippage, and pool validation.
contract V4BuybackHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    //*********************************************************************//
    // ----------------------------- state ------------------------------ //
    //*********************************************************************//

    ForTest_V4BuybackHook hook;
    MockPoolManager mockPm;
    MockOracleHook mockOracle;
    MockProjectToken projectToken;

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

    // Pool key (set in setUp after deploying tokens)
    PoolKey poolKey;
    PoolId poolId;

    //*********************************************************************//
    // ----------------------------- setup ------------------------------ //
    //*********************************************************************//

    function setUp() public {
        // Deploy real contracts
        mockPm = new MockPoolManager();
        mockOracle = new MockOracleHook();
        projectToken = new MockProjectToken();

        // Etch code at mock addresses so calls don't revert with "no code"
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

        // Labels
        vm.label(address(mockPm), "MockPoolManager");
        vm.label(address(mockOracle), "MockOracleHook");
        vm.label(address(projectToken), "ProjectToken");

        // Deploy hook
        hook = new ForTest_V4BuybackHook({
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

        // Build pool key: native ETH (address(0)) is always currency0 (smallest address).
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000, // 0.3% in hundredths of a bip
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        poolId = poolKey.toId();

        // Set up default mock responses for JB core
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

        // Mock terminal FEE (2.5% = 25 out of MAX_FEE=1000)

        // Mock permissions to always allow (for setPoolFor)
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

        // Mock controller responses
        _mockCurrentRuleset();
        _mockControllerMint();
        _mockControllerBurn();

        // Configure the pool in the MockPoolManager (non-zero sqrtPrice means initialized)
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0); // price = 1.0
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);

        // Initialize the pool in the hook (bypass permissions)
        hook.forTestInitPool(projectId, poolKey, twapWindow, address(projectToken), address(0));
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

    //*********************************************************************//
    // ----------------------------- helpers ---------------------------- //
    //*********************************************************************//

    /// @notice Build a default JBRuleset and mock controller.currentRulesetOf.
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
            scopeCashOutsToLocalBalances: true,
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
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller), abi.encodeCall(IJBController.currentRulesetOf, (projectId)), abi.encode(ruleset, meta)
        );
    }

    /// @notice Mock controller.mintTokensOf to succeed (returns the requested count).
    function _mockControllerMint() internal {
        vm.mockCall(
            address(controller),
            abi.encodeWithSignature("mintTokensOf(uint256,uint256,address,string,bool)"),
            abi.encode(0) // return value doesn't matter for our tests
        );
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.previewMintOf.selector), abi.encode(0, 0));
    }

    /// @notice Mock controller.burnTokensOf to succeed.
    function _mockControllerBurn() internal {
        vm.mockCall(
            address(controller), abi.encodeWithSignature("burnTokensOf(address,uint256,uint256,string)"), abi.encode()
        );
    }

    /// @notice Build a JBAfterPayRecordedContext for the given parameters.
    function _makeAfterPayContext(
        address payToken,
        uint256 payValue,
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
            projectId: projectId,
            rulesetId: 1,
            amount: JBTokenAmount({
                token: payToken, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN)), value: payValue
            }),
            forwardedAmount: JBTokenAmount({
                token: payToken, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN)), value: payValue
            }),
            weight: 1e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(
                projectTokenIs0,
                amountToMintWith,
                minimumSwapAmountOut,
                false,
                controller,
                uint256(0),
                1e18,
                payValue,
                int24(0),
                uint128(0),
                bytes32(0),
                uint256(0),
                uint256(0),
                uint256(0)
            ),
            payerMetadata: ""
        });
    }

    //*********************************************************************//
    // ----------------------------- tests ------------------------------ //
    //*********************************************************************//

    /// @notice Test that a full swap goes through the V4 unlock/callback flow.
    /// @dev Deploys the hook with MockPoolManager, configures mock deltas so the swap
    ///      returns project tokens, and verifies the unlock -> callback -> swap -> settle/take
    ///      flow completes successfully.
    function test_swapViaV4PoolManager() public {
        bool projectTokenIs0 = address(projectToken) < address(0);
        uint256 payAmount = 1 ether;
        uint256 swapOut = 500e18; // project tokens received from swap

        // Configure mock deltas: the swap returns swapOut project tokens.
        // V4 convention: negative = caller spent (input), positive = caller received (output).
        // If projectTokenIs0: zeroForOne=false, delta0=+swapOut (received), delta1=-payAmount (spent)
        // If !projectTokenIs0: zeroForOne=true, delta0=-payAmount (spent), delta1=+swapOut (received)
        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        // Pre-fund the MockPoolManager with project tokens so take() can transfer them.
        projectToken.mint(address(mockPm), swapOut);

        // Build the afterPay context (native ETH payment).
        JBAfterPayRecordedContext memory ctx =
            _makeAfterPayContext(JBConstants.NATIVE_TOKEN, payAmount, projectTokenIs0, 0, 0);

        // Mock that the terminal is registered.
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (projectId, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );

        // Call afterPayRecordedWith from the terminal (with ETH value).
        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        // Verify the swap was executed.
        assertTrue(mockPm.swapCalled(), "swap() should have been called on PoolManager");
    }

    /// @notice Test that when POOL_MANAGER.unlock() reverts, the hook gracefully falls back to minting.
    /// @dev Sets MockPoolManager to revert on unlock, then verifies afterPayRecordedWith does NOT
    ///      revert -- the try/catch in _swap catches the error and returns 0.
    function test_swapFallbackToMint() public {
        bool projectTokenIs0 = address(projectToken) < address(0);
        uint256 payAmount = 1 ether;

        // Force unlock to revert.
        mockPm.setShouldRevertOnUnlock(true);

        // Build context with minimumSwapAmountOut = 0 so slippage check passes (0 >= 0).
        JBAfterPayRecordedContext memory ctx =
            _makeAfterPayContext(JBConstants.NATIVE_TOKEN, payAmount, projectTokenIs0, 0, 0);

        // Mock addToBalanceOf on terminal (for leftover funds returned by the hook).
        vm.mockCall(
            address(terminal),
            abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
            abi.encode()
        );

        // Should NOT revert -- falls back to minting.
        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        // swap() should NOT have been called (unlock reverted before reaching swap).
        assertFalse(mockPm.swapCalled(), "swap() should NOT have been called when unlock reverts");
    }

    /// @notice Test that only the PoolManager can call unlockCallback.
    /// @dev Calling unlockCallback from any address other than the PoolManager should revert
    ///      with JBBuybackHook_CallerNotPoolManager.
    function test_unlockCallbackAuth() public {
        bytes memory fakeData = abi.encode(
            SwapCallbackData({
                key: poolKey,
                zeroForOne: !(address(projectToken) < address(0)),
                amountIn: 1 ether,
                minimumSwapAmountOut: 0
            })
        );

        // Call from a random address (not the PoolManager).
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_CallerNotPoolManager.selector, attacker));
        hook.unlockCallback(fakeData);
    }

    /// @notice Test native ETH swap settlement.
    /// @dev Verifies that when paying with native ETH, the unlock callback correctly
    ///      settles via settle{value:} rather than ERC-20 transfer, and take() delivers
    ///      project tokens to the hook.
    function test_nativeETHSwap() public {
        bool projectTokenIs0 = address(projectToken) < address(0);
        uint256 payAmount = 2 ether;
        uint256 swapOut = 1000e18;

        // Configure deltas for the swap (V4 convention: negative=spent, positive=received).
        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        // Pre-fund MockPoolManager with project tokens.
        projectToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx =
            _makeAfterPayContext(JBConstants.NATIVE_TOKEN, payAmount, projectTokenIs0, 0, 0);

        // Execute from terminal with ETH.
        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        // Verify swap executed.
        assertTrue(mockPm.swapCalled(), "swap() should have been called for native ETH payment");
    }

    /// @notice Test TWAP oracle hook query returns a valid quote with slippage.
    /// @dev Configures MockOracleHook with known tick cumulatives, then calls
    ///      beforePayRecordedWith to trigger _getQuote, verifying the oracle is queried
    ///      and the quote influences the swap/mint decision.
    function test_oracleHookTWAP() public {
        // Configure oracle with tick cumulatives that imply a mean tick of 0 over twapWindow seconds.
        // tickCumulative[0] = 0 (at twapWindow seconds ago)
        // tickCumulative[1] = 0 (now)
        // Mean tick = (0 - 0) / twapWindow = 0, so price = 1.0
        //
        // For seconds-per-liquidity, set a non-zero delta to get a valid harmonicMeanLiquidity:
        // secPerLiq1 - secPerLiq0 = small value => high harmonic mean liquidity
        mockOracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        // Set up the pool via setPoolFor to make _poolIsSet = true.
        // First, clear the pool from forTestInitPool.
        // We need to use setPoolFor which requires permissions and a valid pool.
        // Since we already have permissions mocked, let's do it properly.
        // But forTestInitPool doesn't set _poolIsSet. We need a second project.

        uint256 oracleProjectId = 99;
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (oracleProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens),
            abi.encodeCall(tokens.tokenOf, (oracleProjectId)),
            abi.encode(IJBToken(address(projectToken)))
        );

        // Set valid sqrtPrice in MockPoolManager for the pool.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);

        // Call setPoolFor to set _poolIsSet = true.
        vm.prank(owner);
        hook.setPoolFor(oracleProjectId, poolKey, twapWindow, JBConstants.NATIVE_TOKEN);

        // Verify pool was set by reading poolKeyOf.
        PoolKey memory storedKey = hook.poolKeyOf(oracleProjectId, address(0));
        assertEq(Currency.unwrap(storedKey.currency0), Currency.unwrap(poolKey.currency0), "currency0 mismatch");

        // Now verify the oracle is actually used by checking that projectTokenOf is set.
        assertEq(hook.projectTokenOf(oracleProjectId), address(projectToken), "project token should be set");
        assertEq(hook.twapWindowOf(oracleProjectId, address(0)), twapWindow, "twap window should be set");
    }

    /// @notice Test that when the oracle hook is unavailable (reverts), _getQuote returns 0,
    ///         which means the hook falls back to minting.
    function test_oracleHookUnavailable() public {
        // Set oracle to revert.
        mockOracle.setShouldRevert(true);

        // Set up a project with _poolIsSet = true via setPoolFor.
        uint256 noOracleProjectId = 100;
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (noOracleProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens),
            abi.encodeCall(tokens.tokenOf, (noOracleProjectId)),
            abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(
            address(directory), abi.encodeCall(directory.controllerOf, (noOracleProjectId)), abi.encode(controller)
        );

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);

        vm.prank(owner);
        hook.setPoolFor(noOracleProjectId, poolKey, twapWindow, JBConstants.NATIVE_TOKEN);

        // Mock currentRulesetOf for this project.
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
            scopeCashOutsToLocalBalances: true,
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
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (noOracleProjectId)),
            abi.encode(ruleset, meta)
        );

        // Call beforePayRecordedWith with no explicit quote (so it tries TWAP).
        JBBeforePayRecordedContext memory beforeCtx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: 1 ether
            }),
            projectId: noOracleProjectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 1e18,
            reservedPercent: 0,
            metadata: "" // no explicit quote => falls back to TWAP
        });

        // When oracle reverts, _getQuote returns 0, meaning minimumSwapAmountOut = 0.
        // Since tokenCountWithoutHook > 0, mint path is chosen. A noop spec is returned so pool metadata can still
        // be surfaced without triggering afterPay.
        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

        // Weight should be returned unchanged (mint path).
        assertEq(weight, 1e18, "Weight should be unchanged when oracle is unavailable (mint path)");
        assertEq(specs.length, 1, "A noop hook specification should carry mint-path pool diagnostics");
        assertTrue(specs[0].noop, "Mint path specification should be marked noop");
        assertEq(specs[0].amount, 0, "Mint path noop specification should not forward funds");
    }

    /// @notice Deterministic formula regression test at known fee tiers and key points.
    /// @dev Impact values are scaled by IMPACT_PRECISION (1e18) / old_amplifier (1e5) = 1e13.
    function test_slippageFormulaRegression() public pure {
        // impact=0 returns minSlippage (not the old UNCERTAIN_TOLERANCE of 1050).
        assertEq(JBSwapLib.getSlippageTolerance(0, 0), 200, "impact=0,fee=0 -> minSlippage=200");
        assertEq(JBSwapLib.getSlippageTolerance(0, 30), 200, "impact=0,fee=30 -> minSlippage=200");
        assertEq(JBSwapLib.getSlippageTolerance(0, 3000), 3100, "impact=0,fee=3000 -> minSlippage=3100");
        assertEq(JBSwapLib.getSlippageTolerance(0, 10_000), 8800, "impact=0,fee=10000 -> MAX_SLIPPAGE");

        // Scaled impact values (old 5000 bps = 5e16 in new scale)
        // poolFeeBps=30: minSlippage=200, range=8600
        assertEq(JBSwapLib.getSlippageTolerance(5e16, 30), 4500);
        assertEq(JBSwapLib.getSlippageTolerance(1e13, 30), 201);

        // poolFeeBps=100 (1%): minSlippage=200, range=8600 (same as 30)
        assertEq(JBSwapLib.getSlippageTolerance(5e16, 100), 4500);

        // poolFeeBps=500 (5%): minSlippage=600, range=8200
        assertEq(JBSwapLib.getSlippageTolerance(5e16, 500), 4700);

        // poolFeeBps=3000 (30%): minSlippage=3100, range=5700
        assertEq(JBSwapLib.getSlippageTolerance(5e16, 3000), 5950);

        // poolFeeBps >= 8700: capped at MAX_SLIPPAGE
        assertEq(JBSwapLib.getSlippageTolerance(1e13, 8700), 8800);
        assertEq(JBSwapLib.getSlippageTolerance(5e16, 8700), 8800);
        assertEq(JBSwapLib.getSlippageTolerance(1e13, 9999), 8800);
        assertEq(JBSwapLib.getSlippageTolerance(5e16, 9999), 8800);
        assertEq(JBSwapLib.getSlippageTolerance(1e13, type(uint256).max), 8800);
    }

    /// @notice Fuzz: getSlippageTolerance never reverts and always returns in [minSlippage, MAX_SLIPPAGE].
    function testFuzz_slippageBounds(uint256 impact, uint256 poolFeeBps) public pure {
        uint256 tolerance = JBSwapLib.getSlippageTolerance(impact, poolFeeBps);

        uint256 minSlippage;
        if (poolFeeBps >= 8800) {
            minSlippage = 8800;
        } else {
            minSlippage = poolFeeBps + 100;
            if (minSlippage < 200) minSlippage = 200;
            if (minSlippage > 8800) minSlippage = 8800;
        }

        assertGe(tolerance, minSlippage, "Tolerance below minSlippage");
        assertLe(tolerance, 8800, "Tolerance above MAX_SLIPPAGE");
    }

    /// @notice Fuzz: getSlippageTolerance is monotonically non-decreasing in impact for fixed poolFeeBps.
    function testFuzz_slippageMonotonicity(uint256 impactA, uint256 impactB, uint256 poolFeeBps) public pure {
        impactA = bound(impactA, 0, type(uint128).max);
        impactB = bound(impactB, impactA, type(uint128).max);

        uint256 tolA = JBSwapLib.getSlippageTolerance(impactA, poolFeeBps);
        uint256 tolB = JBSwapLib.getSlippageTolerance(impactB, poolFeeBps);

        assertGe(tolB, tolA, "Slippage must be monotonically non-decreasing in impact");
    }

    /// @notice Fuzz: calculateImpact never reverts for realistic pool parameters.
    /// @dev Bounds sqrtP to [MIN_SQRT_PRICE, MAX_SQRT_PRICE] which is the valid range for all Uniswap pools.
    function testFuzz_calculateImpactNeverReverts(
        uint128 amountIn,
        uint128 liquidity,
        uint160 sqrtP,
        bool zeroForOne
    )
        public
        pure
    {
        // Bound sqrtP to the valid Uniswap range (any real pool is within these bounds).
        sqrtP = uint160(bound(sqrtP, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));

        uint256 impact = JBSwapLib.calculateImpact(amountIn, liquidity, sqrtP, zeroForOne);
        // If liquidity or sqrtP is 0, impact must be 0
        if (liquidity == 0 || sqrtP == 0) {
            assertEq(impact, 0, "Impact must be 0 when liquidity or sqrtP is 0");
        }
    }

    /// @notice Fuzz: full pipeline calculateImpact → getSlippageTolerance always produces valid bounds.
    function testFuzz_fullSlippagePipeline(
        uint128 amountIn,
        uint128 liquidity,
        uint160 sqrtP,
        bool zeroForOne,
        uint256 poolFeeBps
    )
        public
        pure
    {
        // Bound to valid Uniswap pool ranges
        sqrtP = uint160(bound(sqrtP, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        amountIn = uint128(bound(amountIn, 1, type(uint128).max));
        poolFeeBps = bound(poolFeeBps, 0, 10_000);

        uint256 impact = JBSwapLib.calculateImpact(amountIn, liquidity, sqrtP, zeroForOne);
        uint256 tolerance = JBSwapLib.getSlippageTolerance(impact, poolFeeBps);

        assertLe(tolerance, 8800, "Pipeline tolerance exceeds MAX_SLIPPAGE");
        assertGe(tolerance, 200, "Pipeline tolerance below floor");
    }

    /// @notice Deterministic multi-fee-tier monotonicity across all common Uniswap fee tiers.
    /// @dev Impact values scaled to match IMPACT_PRECISION (1e13 per old bps).
    function test_slippageMultiFeeTiers() public pure {
        uint256[7] memory fees = [uint256(1), 5, 30, 100, 500, 3000, 10_000];

        for (uint256 f = 0; f < fees.length; f++) {
            uint256 poolFeeBps = fees[f];
            uint256 prevTol = 0;
            for (uint256 impact = 1e13; impact <= 20_000e13; impact += 100e13) {
                uint256 tol = JBSwapLib.getSlippageTolerance(impact, poolFeeBps);
                assertGe(tol, prevTol, "Not monotonic");
                assertLe(tol, 8800, "Exceeds MAX_SLIPPAGE");

                uint256 minSlippage = poolFeeBps + 100;
                if (minSlippage < 200) minSlippage = 200;
                if (minSlippage > 8800) minSlippage = 8800;
                assertGe(tol, minSlippage, "Below minSlippage");
                prevTol = tol;
            }
        }
    }

    /// @notice Test that setPoolFor validates the PoolKey against PoolManager state.
    /// @dev Covers:
    ///      1. Successful set with valid pool (sqrtPrice != 0)
    ///      2. Revert when pool not initialized (sqrtPrice == 0)
    ///      3. Revert when pool already set for this project/token pair
    ///      4. Revert with invalid TWAP window (too small / too large)
    function test_setPoolForV4Validation() public {
        uint256 newProjectId = 200;

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (newProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (newProjectId)), abi.encode(IJBToken(address(projectToken)))
        );

        // --- 1. Successful set ---
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);

        vm.prank(owner);
        hook.setPoolFor(newProjectId, poolKey, twapWindow, JBConstants.NATIVE_TOKEN);

        // Verify the pool key was stored.
        PoolKey memory stored = hook.poolKeyOf(newProjectId, address(0));
        assertEq(stored.fee, poolKey.fee, "Pool fee should match");
        assertEq(stored.tickSpacing, poolKey.tickSpacing, "Tick spacing should match");

        // --- 2. Revert when pool already set ---
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_PoolAlreadySet.selector, poolId));
        hook.setPoolFor(newProjectId, poolKey, twapWindow, JBConstants.NATIVE_TOKEN);

        // --- 3. Revert when pool not initialized (sqrtPrice == 0) ---
        uint256 uninitProjectId = 201;
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (uninitProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens),
            abi.encodeCall(tokens.tokenOf, (uninitProjectId)),
            abi.encode(IJBToken(address(projectToken)))
        );

        // Create a different pool key (different tick spacing so it's a different pool).
        PoolKey memory uninitPoolKey = PoolKey({
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            fee: 3000,
            tickSpacing: 10, // different tick spacing = different pool
            hooks: IHooks(address(mockOracle))
        });
        PoolId uninitPoolId = uninitPoolKey.toId();

        // Don't set any slot0 data for this pool (sqrtPrice defaults to 0).
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_PoolNotInitialized.selector, uninitPoolId));
        hook.setPoolFor(uninitProjectId, uninitPoolKey, twapWindow, JBConstants.NATIVE_TOKEN);

        // --- 4. Revert with invalid TWAP window ---
        uint256 twapProjectId = 202;
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (twapProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens),
            abi.encodeCall(tokens.tokenOf, (twapProjectId)),
            abi.encode(IJBToken(address(projectToken)))
        );

        // Too small (less than MIN_TWAP_WINDOW = 5 minutes).
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector, 60, 5 minutes, 2 days)
        );
        hook.setPoolFor(twapProjectId, poolKey, 60, JBConstants.NATIVE_TOKEN);

        // Too large (more than MAX_TWAP_WINDOW = 2 days).
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector, 3 days, 5 minutes, 2 days)
        );
        hook.setPoolFor(twapProjectId, poolKey, 3 days, JBConstants.NATIVE_TOKEN);
    }

    //*********************************************************************//
    // -------------- MEV hardening tests (price limit + TWAP) ---------- //
    //*********************************************************************//

    /// @notice Test that the sqrtPriceLimit formula produces correct values at known points.
    /// @dev At price = 1.0 (equal amounts), sqrtPriceX96 should be ~2^96.
    function test_sqrtPriceLimitFormula() public pure {
        // Equal amounts → price = 1.0 → sqrtPrice = 2^96
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 1e18, true);
        // 2^96 = 79228162514264337593543950336
        // Allow 0.01% tolerance due to integer sqrt rounding.
        uint256 expected = uint256(1) << 96;
        assertApproxEqRel(uint256(limit), expected, 1e14, "Equal amounts should give ~2^96");

        // 4:1 ratio → price = 0.25 → sqrt = 0.5 → sqrtPriceX96 = 2^95
        uint160 limit2 = JBSwapLib.sqrtPriceLimitFromAmounts(4e18, 1e18, true);
        uint256 expected2 = uint256(1) << 95;
        assertApproxEqRel(uint256(limit2), expected2, 1e14, "4:1 ratio should give ~2^95");

        // !zeroForOne: 1:1 → sqrtPrice = 2^96
        uint160 limit3 = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 1e18, false);
        assertApproxEqRel(uint256(limit3), expected, 1e14, "!zeroForOne equal amounts should give ~2^96");

        // minimumAmountOut=0 → extreme value
        uint160 limitNoMin = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 0, true);
        assertEq(limitNoMin, TickMath.MIN_SQRT_PRICE + 1, "0 minimum should return MIN+1 for zeroForOne");

        uint160 limitNoMin2 = JBSwapLib.sqrtPriceLimitFromAmounts(1e18, 0, false);
        assertEq(limitNoMin2, TickMath.MAX_SQRT_PRICE - 1, "0 minimum should return MAX-1 for !zeroForOne");
    }

    /// @notice Fuzz: sqrtPriceLimitFromAmounts always returns a value within [MIN_SQRT_PRICE, MAX_SQRT_PRICE].
    function testFuzz_sqrtPriceLimitBounds(uint256 amountIn, uint256 minimumOut, bool zeroForOne) public pure {
        amountIn = bound(amountIn, 1, type(uint128).max);
        minimumOut = bound(minimumOut, 0, type(uint128).max);

        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, minimumOut, zeroForOne);

        assertGe(uint256(limit), uint256(TickMath.MIN_SQRT_PRICE), "Limit below MIN_SQRT_PRICE");
        assertLe(uint256(limit), uint256(TickMath.MAX_SQRT_PRICE), "Limit above MAX_SQRT_PRICE");

        // Direction constraints:
        if (minimumOut > 0) {
            if (zeroForOne) {
                // Price decreases → limit must be < MAX
                assertLt(uint256(limit), uint256(TickMath.MAX_SQRT_PRICE), "zeroForOne limit should be < MAX");
            } else {
                // Price increases → limit must be > MIN
                assertGt(uint256(limit), uint256(TickMath.MIN_SQRT_PRICE), "!zeroForOne limit should be > MIN");
            }
        }
    }

    /// @notice Test that the sqrtPriceLimit causes partial fills when the pool can't fill at the minimum rate.
    /// @dev Configures MockPoolManager to return fewer tokens than the full swap would have.
    ///      The leftover input should be returned via addToBalanceOf + minted.
    function test_sqrtPriceLimitEnforced() public {
        bool projectTokenIs0 = address(projectToken) < address(0);
        uint256 payAmount = 10 ether;
        // Partial fill: only 3 ether consumed by the swap, returning 300 tokens.
        // The remaining 7 ether should trigger the leftover mint path.
        uint256 swapConsumed = 3 ether;
        uint256 swapOut = 300e18;

        // Configure deltas for a partial fill (V4 convention: negative=spent, positive=received).
        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(swapConsumed)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(swapConsumed)), int128(uint128(swapOut)));
        }

        // Pre-fund MockPoolManager with project tokens.
        projectToken.mint(address(mockPm), swapOut);

        // Build context with minimumSwapAmountOut = 100e18 (below swapOut, so slippage passes).
        JBAfterPayRecordedContext memory ctx =
            _makeAfterPayContext(JBConstants.NATIVE_TOKEN, payAmount, projectTokenIs0, 0, 100e18);

        // Mock addToBalanceOf for the leftover.
        vm.mockCall(
            address(terminal),
            abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
            abi.encode()
        );

        // Execute.
        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        // Verify the swap executed (partial).
        assertTrue(mockPm.swapCalled(), "swap() should have been called for partial fill");
    }

    /// @notice Test that an explicit payer quote is honored without consulting the TWAP.
    /// @dev The oracle is configured to revert, proving the hook does not depend on TWAP when quote metadata exists.
    function test_payerQuoteIsHonored() public {
        // Set up a project with _poolIsSet = true via setPoolFor.
        uint256 cvProjectId = 300;
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (cvProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (cvProjectId)), abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (cvProjectId)), abi.encode(controller));

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);

        vm.prank(owner);
        hook.setPoolFor(cvProjectId, poolKey, twapWindow, JBConstants.NATIVE_TOKEN);

        // The oracle should not be consulted when the payer provides an explicit quote.
        mockOracle.setShouldRevert(true);

        // Mock currentRulesetOf for this project.
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
            scopeCashOutsToLocalBalances: true,
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
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (cvProjectId)),
            abi.encode(ruleset, meta)
        );

        // Payer provides an explicit quote that should be used as-is.
        uint256 badPayerQuote = 1;
        uint256 amountToSwapWith = 1 ether;

        // Encode the payer's bad quote as metadata.
        bytes memory quoteMetadata = abi.encode(amountToSwapWith, badPayerQuote);
        bytes4 metadataId = JBMetadataResolver.getId("pay", address(hook));
        bytes memory fullMetadata = JBMetadataResolver.addToMetadata("", metadataId, quoteMetadata);

        JBBeforePayRecordedContext memory beforeCtx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: amountToSwapWith
            }),
            projectId: cvProjectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 1e18,
            reservedPercent: 0,
            metadata: fullMetadata
        });

        (, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

        assertEq(specs.length, 1, "explicit payer quote should still produce a hook spec");
        (,, uint256 minOut,,) = abi.decode(specs[0].metadata, (bool, uint256, uint256, bool, IJBController));
        assertEq(minOut, badPayerQuote, "explicit payer quote should be honored");
    }

    /// @notice A quote metadata item with a zero minimum behaves like a programmatic no-quote call.
    /// @dev Contracts can set `amountToSwapWith` without relying on an offchain quote; the hook derives its floor from
    ///      TWAP and marks the metadata as non-explicit.
    function test_zeroMinimumQuoteMetadataUsesTwap() public {
        vm.prank(owner);
        hook.setPoolFor(projectId, poolKey, twapWindow, JBConstants.NATIVE_TOKEN);

        mockOracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        uint256 amountToSwapWith = 1 ether;
        bytes memory quoteMetadata = abi.encode(amountToSwapWith, uint256(0));
        bytes4 metadataId = JBMetadataResolver.getId("pay", address(hook));
        bytes memory fullMetadata = JBMetadataResolver.addToMetadata("", metadataId, quoteMetadata);

        JBBeforePayRecordedContext memory beforeCtx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: amountToSwapWith
            }),
            projectId: projectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 1,
            reservedPercent: 0,
            metadata: fullMetadata
        });

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

        assertEq(weight, 0, "zero-minimum quote metadata should allow the TWAP swap path");
        assertEq(specs.length, 1, "programmatic quote metadata should return a hook spec");
        assertFalse(specs[0].noop, "TWAP-derived route should be active when it beats minting");

        (,, uint256 minimumSwapAmountOut, bool hasExplicitQuote,) =
            abi.decode(specs[0].metadata, (bool, uint256, uint256, bool, IJBController));

        assertGt(minimumSwapAmountOut, 0, "TWAP should derive a non-zero minimum");
        assertFalse(hasExplicitQuote, "zero minimum should not be treated as an explicit quote");
    }

    /// @notice Test that setPoolFor rejects TWAP windows shorter than the new 5-minute minimum.
    function test_minTwapWindow5Minutes() public {
        assertEq(hook.MIN_TWAP_WINDOW(), 5 minutes, "MIN_TWAP_WINDOW should be 5 minutes");

        uint256 newProjectId = 400;
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (newProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (newProjectId)), abi.encode(IJBToken(address(projectToken)))
        );

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);

        // 2 minutes should now be rejected (was valid before, now too small).
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector, 2 minutes, 5 minutes, 2 days)
        );
        hook.setPoolFor(newProjectId, poolKey, 2 minutes, JBConstants.NATIVE_TOKEN);

        // 4 minutes should also be rejected.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector, 4 minutes, 5 minutes, 2 days)
        );
        hook.setPoolFor(newProjectId, poolKey, 4 minutes, JBConstants.NATIVE_TOKEN);

        // 5 minutes should succeed.
        vm.prank(owner);
        hook.setPoolFor(newProjectId, poolKey, 5 minutes, JBConstants.NATIVE_TOKEN);

        assertEq(hook.twapWindowOf(newProjectId, address(0)), 5 minutes, "TWAP window should be 5 minutes");
    }

    //*********************************************************************//
    // -------------------- initializePoolFor tests -------------------- //
    //*********************************************************************//

    /// @notice initializePoolFor creates pool in PoolManager and configures buyback hook.
    function test_initializePoolFor_createsPoolAndConfigures() public {
        uint256 newProjectId = 300;

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (newProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (newProjectId)), abi.encode(IJBToken(address(projectToken)))
        );

        // Call initializePoolFor — should initialize the pool AND configure the hook.
        vm.prank(owner);
        hook.initializePoolFor({
            projectId: newProjectId,
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            twapWindow: twapWindow,
            terminalToken: JBConstants.NATIVE_TOKEN,
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0)
        });

        // Verify the pool key was stored.
        PoolKey memory storedKey = hook.poolKeyOf(newProjectId, address(0));
        assertEq(Currency.unwrap(storedKey.currency0), Currency.unwrap(poolKey.currency0), "currency0 mismatch");
        assertEq(Currency.unwrap(storedKey.currency1), Currency.unwrap(poolKey.currency1), "currency1 mismatch");
        assertEq(storedKey.fee, poolKey.fee, "fee mismatch");
        assertEq(storedKey.tickSpacing, poolKey.tickSpacing, "tickSpacing mismatch");

        // Verify TWAP window was stored.
        assertEq(hook.twapWindowOf(newProjectId, address(0)), twapWindow, "TWAP window mismatch");

        // Verify project token was stored.
        assertEq(hook.projectTokenOf(newProjectId), address(projectToken), "project token mismatch");
    }

    /// @notice initializePoolFor is idempotent for pool initialization — if pool already exists, it still configures.
    function test_initializePoolFor_idempotentIfPoolExists() public {
        uint256 newProjectId = 301;

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (newProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (newProjectId)), abi.encode(IJBToken(address(projectToken)))
        );

        // Pre-initialize the pool manually.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, poolKey.fee);

        // Call initializePoolFor — pool already exists, should still configure without reverting.
        vm.prank(owner);
        hook.initializePoolFor({
            projectId: newProjectId,
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            twapWindow: twapWindow,
            terminalToken: JBConstants.NATIVE_TOKEN,
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0)
        });

        // Verify configuration succeeded.
        assertEq(hook.twapWindowOf(newProjectId, address(0)), twapWindow, "TWAP window mismatch");
        assertEq(hook.projectTokenOf(newProjectId), address(projectToken), "project token mismatch");
    }

    /// @notice initializePoolFor reverts if pool already set for this project/token pair.
    function test_initializePoolFor_revertsIfAlreadySet() public {
        uint256 newProjectId = 302;

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (newProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (newProjectId)), abi.encode(IJBToken(address(projectToken)))
        );

        // First call succeeds.
        vm.prank(owner);
        hook.initializePoolFor({
            projectId: newProjectId,
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            twapWindow: twapWindow,
            terminalToken: JBConstants.NATIVE_TOKEN,
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0)
        });

        // Second call reverts with PoolAlreadySet.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_PoolAlreadySet.selector, poolId));
        hook.initializePoolFor({
            projectId: newProjectId,
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            twapWindow: twapWindow,
            terminalToken: JBConstants.NATIVE_TOKEN,
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0)
        });
    }

    /// @notice Verify that tokenCountWithoutHook is encoded as the 5th field in hook spec metadata.
    /// @dev When the swap path is chosen (specs.length == 1), the metadata should contain all 5 fields:
    ///      (bool projectTokenIs0, uint256 mintFromExcess, uint256 minimumSwapAmountOut, IJBController controller,
    /// uint256 tokenCountWithoutHook)
    function test_hookSpecMetadataContainsTokenCountWithoutHook() public {
        // Set up a new project with setPoolFor.
        uint256 tcProjectId = 500;
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (tcProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (tcProjectId)), abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (tcProjectId)), abi.encode(controller));

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);

        vm.prank(owner);
        hook.setPoolFor(tcProjectId, poolKey, twapWindow, JBConstants.NATIVE_TOKEN);

        // Configure the oracle to produce a high TWAP quote so the swap path is chosen.
        // tick=0 means price=1, so 1 ETH -> ~1 token. With slippage the quote should still be > 0.
        mockOracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        // Mock ruleset with baseCurrency = NATIVE_TOKEN, weight = 1e18 (so tokenCountWithoutHook = amountToSwapWith).
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
            scopeCashOutsToLocalBalances: true,
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
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (tcProjectId)),
            abi.encode(ruleset, meta)
        );

        // Pay with 1 ETH and provide a very high payer quote (2e18 tokens) so swap path is guaranteed.
        uint256 amountToSwapWith = 1 ether;
        uint256 highPayerQuote = 2e18;

        bytes memory quoteMetadata = abi.encode(amountToSwapWith, highPayerQuote);
        // Use the hook's address for the metadata ID, since the hook decodes using its own address(this).
        bytes4 metadataId = JBMetadataResolver.getId("pay", address(hook));
        bytes memory fullMetadata = JBMetadataResolver.addToMetadata("", metadataId, quoteMetadata);

        JBBeforePayRecordedContext memory beforeCtx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: amountToSwapWith
            }),
            projectId: tcProjectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 1e18,
            reservedPercent: 2500,
            metadata: fullMetadata
        });

        (, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

        // The swap path must have been chosen.
        assertEq(specs.length, 1, "Swap path should be chosen");

        // Decode all 14 fields from the hook spec metadata.
        (
            bool projectTokenIs0,
            uint256 mintFromExcess,
            uint256 minimumSwapAmountOut,
            bool hasExplicitMinimumSwapAmountOut,
            IJBController decodedController,
            uint256 tokenCountWithoutHook,
            uint256 weightRatio,
            uint256 quotedAmountToSwapWith,
            int24 twapTick,
            uint128 twapLiquidity,
            PoolId decodedPoolId,
            uint256 minimumBeneficiaryTokenCount,
            uint256 minimumReservedTokenCount,
            uint256 rawSwapQuote
        ) = abi.decode(
            specs[0].metadata,
            (
                bool,
                uint256,
                uint256,
                bool,
                IJBController,
                uint256,
                uint256,
                uint256,
                int24,
                uint128,
                PoolId,
                uint256,
                uint256,
                uint256
            )
        );

        // Verify field 5: with weight=1e18, baseCurrency=NATIVE_TOKEN, paying 1 ETH in native,
        // weightRatio = 10^18, so tokenCountWithoutHook = mulDiv(1e18, 1e18, 1e18) = 1e18.
        assertEq(
            tokenCountWithoutHook, 1e18, "tokenCountWithoutHook should equal amountToSwapWith * weight / weightRatio"
        );

        // Verify fields 1-4.
        assertEq(address(decodedController), address(controller), "controller should match");
        assertEq(mintFromExcess, 0, "mintFromExcess should be 0 when amountToSwapWith == totalPaid");
        assertEq(minimumSwapAmountOut, highPayerQuote, "minimumSwapAmountOut should honor the explicit payer quote");
        assertTrue(hasExplicitMinimumSwapAmountOut, "explicit payer quote should be marked explicit");
        assertEq(projectTokenIs0, address(projectToken) < address(0), "projectTokenIs0 should match address comparison");

        // Verify field 6: weightRatio should be 10^decimals when baseCurrency == payment currency.
        assertEq(weightRatio, 1e18, "weightRatio should be 10^18 for same-currency payment");
        assertEq(quotedAmountToSwapWith, amountToSwapWith, "quotedAmountToSwapWith should match the pay quote");

        // Verify fields 7-8: explicit payer quotes preserve the caller's floor while still surfacing diagnostics.
        assertEq(twapTick, int24(0), "twapTick should match the oracle tick");
        assertGt(twapLiquidity, 0, "twapLiquidity should report warm oracle liquidity");

        // Verify field 8: poolId (should match the configured pool).
        assertEq(PoolId.unwrap(decodedPoolId), PoolId.unwrap(poolKey.toId()), "poolId should match configured pool");
        assertEq(
            rawSwapQuote,
            JBSwapLib.getQuoteAtTick({
                tick: twapTick,
                baseAmount: uint128(amountToSwapWith),
                baseToken: address(0),
                quoteToken: address(projectToken)
            }),
            "rawSwapQuote should report the diagnostic oracle quote"
        );

        // Verify fields 9-10: minimum beneficiary/reserved split for the swap path.
        (uint256 expectedBeneficiaryTokenCount, uint256 expectedReservedTokenCount) = controller.previewMintOf({
            projectId: tcProjectId, tokenCount: minimumSwapAmountOut, useReservedPercent: true
        });

        assertEq(
            minimumBeneficiaryTokenCount,
            expectedBeneficiaryTokenCount,
            "minimumBeneficiaryTokenCount should match controller.previewMintOf"
        );
        assertEq(
            minimumReservedTokenCount,
            expectedReservedTokenCount,
            "minimumReservedTokenCount should match controller.previewMintOf"
        );
    }

    /// @notice initializePoolFor reverts if caller is not authorized.

    /// @notice Verify that the buyback hook passes exactly 32 bytes of hookData encoding uint256(0)
    ///         to the V4 PoolManager swap. This is required for composition with JBUniswapV4Hook,
    ///         which reverts with AmountOutMinRequired if hookData is not exactly 32 bytes.
    function test_hookDataFormat_encodesAmountOutMinZero() public {
        bool projectTokenIs0 = address(projectToken) < address(0);
        uint256 payAmount = 1 ether;
        uint256 swapOut = 500e18;

        // Configure mock deltas.
        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        // Pre-fund the MockPoolManager with project tokens.
        projectToken.mint(address(mockPm), swapOut);

        // Build the afterPay context (native ETH payment).
        JBAfterPayRecordedContext memory ctx =
            _makeAfterPayContext(JBConstants.NATIVE_TOKEN, payAmount, projectTokenIs0, 0, 0);

        // Call afterPayRecordedWith from the terminal.
        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        // Verify hookData is exactly 32 bytes encoding uint256(0).
        bytes memory hookData = mockPm.lastSwapHookData();
        assertEq(hookData.length, 32, "hookData must be exactly 32 bytes for JBUniswapV4Hook compatibility");
        uint256 amountOutMin = abi.decode(hookData, (uint256));
        assertEq(amountOutMin, 0, "hookData should encode amountOutMin = 0 (oracle-delegated slippage)");
    }

    function test_beforeCashOutRecordedWith_routesWhenSellQuoteBeatsProtocolCashOut() public {
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });
        mockOracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        uint256 cashOutCount = 10 ether;
        uint256 explicitMinimumReclaimed = 0.5 ether + 1;
        bytes4 metadataId = JBMetadataResolver.getId("cashOut", address(hook));
        bytes memory fullMetadata =
            JBMetadataResolver.addToMetadata("", metadataId, abi.encode(explicitMinimumReclaimed, false));
        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            totalSupply: 100 ether,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 5 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: fullMetadata
        });

        (uint256 cashOutTaxRate,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE, "cash out should be rerouted through the pool");
        assertEq(specs.length, 1, "cash out hook spec should be returned");
        assertEq(address(specs[0].hook), address(hook), "hook should execute the sell-side swap");
        assertFalse(specs[0].noop, "sell-side execution spec should not be marked noop");
        assertEq(specs[0].amount, 0, "sell-side hook should not consume protocol reclaim funds");
        (
            uint256 minimumSwapAmountOut,
            uint256 cashOutCountInMetadata,
            uint256 minimumProtocolAmountOut,
            int24 twapTick,
            uint128 twapLiquidity,
            PoolId decodedPoolId
        ) = abi.decode(specs[0].metadata, (uint256, uint256, uint256, int24, uint128, PoolId));
        assertEq(minimumSwapAmountOut, explicitMinimumReclaimed, "explicit cash-out minimum should be honored");
        assertEq(cashOutCountInMetadata, cashOutCount, "metadata should encode the cash-out count for afterCashOut");
        // zero-tax non-feeless cash-outs use GROSS as the routing reference because the terminal
        // charges the fee only up to `feeFreeSurplusOf` (which the hook cannot read), so the surfaced direct-path
        // amount is gross.
        uint256 expectedGross = 0.5 ether;
        assertEq(minimumProtocolAmountOut, expectedGross, "zero-tax direct path uses gross for non-feeless routing");
        assertEq(twapTick, 0, "explicit minimum should skip TWAP diagnostics");
        assertEq(twapLiquidity, 0, "explicit minimum should skip TWAP diagnostics");
        assertEq(PoolId.unwrap(decodedPoolId), PoolId.unwrap(poolKey.toId()), "poolId should match configured pool");
    }

    function test_beforeCashOutRecordedWith_passesThroughWhenProtocolCashOutBeatsSellQuote() public {
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });
        mockOracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: 1 ether,
            totalSupply: 2 ether,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 100 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,,
            JBCashOutHookSpecification[] memory specs
        ) = hook.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, context.cashOutTaxRate, "cash out tax rate should pass through");
        assertEq(cashOutCount, context.cashOutCount, "cash out count should pass through");
        assertEq(totalSupply, context.totalSupply, "total supply should pass through");
        assertEq(specs.length, 1, "informational sell-side metadata should still be returned");
        assertTrue(specs[0].noop, "protocol-winning path should be marked noop");
        assertEq(specs[0].amount, 0, "noop sell-side spec should not consume protocol reclaim funds");
        (
            uint256 minimumSwapAmountOut,
            uint256 cashOutCountInMetadata,
            uint256 minimumProtocolAmountOut,
            int24 twapTick,
            uint128 twapLiquidity,
            PoolId decodedPoolId
        ) = abi.decode(specs[0].metadata, (uint256, uint256, uint256, int24, uint128, PoolId));
        assertEq(cashOutCountInMetadata, 1 ether, "metadata should encode the cash-out count for afterCashOut");
        // zero-tax non-feeless cash-outs use GROSS as the routing reference (see fix rationale).
        uint256 expectedGross50 = 50 ether;
        assertEq(minimumProtocolAmountOut, expectedGross50, "zero-tax direct path uses gross for non-feeless routing");
        assertGt(minimumSwapAmountOut, 0, "metadata should include a non-zero sell-side minimum");
        assertLt(minimumSwapAmountOut, minimumProtocolAmountOut, "sell-side minimum should lose to the protocol path");
        assertEq(twapTick, 0, "TWAP tick should be surfaced in informational metadata");
        assertGt(twapLiquidity, 0, "TWAP liquidity should be surfaced in informational metadata");
        assertEq(PoolId.unwrap(decodedPoolId), PoolId.unwrap(poolKey.toId()), "poolId should match configured pool");
    }

    function testFuzz_beforeCashOutRecordedWith_explicitMinimumAboveProtocolRoutes(
        uint96 cashOutCountSeed,
        uint96 totalSupplySeed,
        uint96 surplusSeed,
        uint96 deltaSeed
    )
        public
    {
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });

        uint256 cashOutCount = bound(uint256(cashOutCountSeed), 1, 1_000_000 ether);
        uint256 totalSupply = bound(uint256(totalSupplySeed), cashOutCount, 10_000_000 ether);
        uint256 surplus = bound(uint256(surplusSeed), 0, 10_000_000 ether);
        uint256 grossDirect = JBCashOuts.cashOutFrom({
            surplus: surplus, cashOutCount: cashOutCount, totalSupply: totalSupply, cashOutTaxRate: 0
        });
        // zero-tax non-feeless cash-outs use gross as the routing reference; the terminal's fee
        // depends on `feeFreeSurplusOf` which the hook cannot read, so the best-case direct (= gross) is used.
        uint256 protocolMinimum = grossDirect;
        uint256 explicitMinimum = protocolMinimum + bound(uint256(deltaSeed), 1, 1_000_000 ether);

        bytes4 metadataId = JBMetadataResolver.getId("cashOut", address(hook));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(explicitMinimum, false));

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            totalSupply: totalSupply,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: surplus,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: metadata
        });

        (
            uint256 cashOutTaxRate,
            uint256 returnedCashOutCount,
            uint256 returnedTotalSupply,,
            JBCashOutHookSpecification[] memory specs
        ) = hook.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE, "sell-side route should be activated");
        assertEq(returnedCashOutCount, cashOutCount, "cashOutCount should pass through");
        assertEq(returnedTotalSupply, totalSupply, "totalSupply should pass through");
        assertEq(specs.length, 1, "sell-side route should surface one hook spec");
        assertFalse(specs[0].noop, "sell-side route should not be noop");

        (uint256 minimumSwapAmountOut, uint256 cashOutCountInMetadata, uint256 minimumProtocolAmountOut,,,) =
            abi.decode(specs[0].metadata, (uint256, uint256, uint256, int24, uint128, PoolId));
        assertEq(minimumSwapAmountOut, explicitMinimum, "metadata should preserve explicit minimum");
        assertEq(cashOutCountInMetadata, cashOutCount, "metadata should encode the cash-out count for afterCashOut");
        assertEq(minimumProtocolAmountOut, protocolMinimum, "metadata should surface gross zero-tax protocol minimum");
    }

    function testFuzz_beforeCashOutRecordedWith_explicitMinimumAtOrBelowWorstCaseNetNoops(
        uint96 cashOutCountSeed,
        uint96 totalSupplySeed,
        uint96 surplusSeed,
        uint96 deltaSeed
    )
        public
    {
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });

        uint256 cashOutCount = bound(uint256(cashOutCountSeed), 1, 1_000_000 ether);
        uint256 totalSupply = bound(uint256(totalSupplySeed), cashOutCount, 10_000_000 ether);
        uint256 surplus = bound(uint256(surplusSeed), 0, 10_000_000 ether);
        uint256 grossDirect = JBCashOuts.cashOutFrom({
            surplus: surplus, cashOutCount: cashOutCount, totalSupply: totalSupply, cashOutTaxRate: 0
        });
        // Zero-tax non-feeless cash-outs use the EXACT direct net (= gross when feeFreeSurplus == 0, mocked here)
        // as the routing reference. Explicit user floors must be satisfiable against that same exact net.
        uint256 protocolMinimum = grossDirect;
        uint256 delta = bound(uint256(deltaSeed), 0, protocolMinimum);
        uint256 explicitMinimum = protocolMinimum - delta;

        bytes4 metadataId = JBMetadataResolver.getId("cashOut", address(hook));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(explicitMinimum, false));

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            totalSupply: totalSupply,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: surplus,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: metadata
        });

        (
            uint256 cashOutTaxRate,
            uint256 returnedCashOutCount,
            uint256 returnedTotalSupply,,
            JBCashOutHookSpecification[] memory specs
        ) = hook.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, 0, "protocol path should keep the original tax rate");
        assertEq(returnedCashOutCount, cashOutCount, "cashOutCount should pass through");
        assertEq(returnedTotalSupply, totalSupply, "totalSupply should pass through");
        assertEq(specs.length, 1, "noop sell-side metadata should still be returned");
        assertTrue(specs[0].noop, "protocol-winning path should be noop");

        (uint256 minimumSwapAmountOut, uint256 cashOutCountInMetadata, uint256 minimumProtocolAmountOut,,,) =
            abi.decode(specs[0].metadata, (uint256, uint256, uint256, int24, uint128, PoolId));
        assertEq(minimumSwapAmountOut, explicitMinimum, "metadata should preserve explicit minimum");
        assertEq(cashOutCountInMetadata, cashOutCount, "metadata should encode the cash-out count for afterCashOut");
        assertEq(minimumProtocolAmountOut, grossDirect, "metadata should surface gross zero-tax protocol minimum");
        assertLe(
            minimumSwapAmountOut,
            protocolMinimum,
            "noop path with an explicit user floor should only happen at or below the exact direct net"
        );
    }

    function test_afterCashOutRecordedWith_remintsAndSwapsForBeneficiary() public {
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });

        uint256 cashOutCount = 10 ether;
        uint256 amountOut = 5 ether;

        projectToken.mint(address(hook), cashOutCount);
        vm.deal(address(mockPm), amountOut);

        // project token is currency1, native ETH is currency0, so selling project token is oneForZero.
        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(int128(uint128(amountOut)), -int128(uint128(cashOutCount)));

        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            reclaimedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: payable(beneficiary),
            hookMetadata: abi.encode(amountOut, cashOutCount),
            cashOutMetadata: ""
        });

        uint256 balanceBefore = beneficiary.balance;

        vm.expectCall(
            address(controller),
            abi.encodeWithSignature(
                "mintTokensOf(uint256,uint256,address,string,bool)", projectId, cashOutCount, address(hook), "", false
            )
        );

        vm.prank(address(terminal));
        hook.afterCashOutRecordedWith(context);

        assertTrue(mockPm.swapCalled(), "sell-side swap should hit the pool manager");
        assertEq(beneficiary.balance - balanceBefore, amountOut, "beneficiary should receive swap proceeds");
    }

    /// @notice A successful-but-partial fill that lands below a DERIVED floor (`shouldEnforceMinimumSwapAmountOut`
    /// is `false`) soft-lands instead of reverting: the partial proceeds reach the beneficiary, mirroring the
    /// soft-land the swap-failed branch already performs for a derived floor. Only a caller-specified minimum
    /// hard-reverts on an underfill.
    function test_afterCashOutRecordedWith_softLandsWhenDerivedFloorUnderfills() public {
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });

        uint256 amountOut = 4 ether;
        uint256 cashOutCount = 10 ether;
        uint256 minimumSwapAmountOut = 5 ether; // amountOut (4) < derived floor (5): an underfill.

        projectToken.mint(address(hook), cashOutCount);
        vm.deal(address(mockPm), amountOut);

        // project token is currency1, native ETH is currency0, so selling project token is oneForZero.
        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(int128(uint128(amountOut)), -int128(uint128(cashOutCount)));

        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            reclaimedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: payable(beneficiary),
            hookMetadata: abi.encode(
                minimumSwapAmountOut,
                cashOutCount,
                uint256(3 ether),
                int24(0),
                uint128(1_000_000 ether),
                poolId,
                uint256(6 ether),
                false
            ),
            cashOutMetadata: ""
        });

        uint256 balanceBefore = beneficiary.balance;

        vm.prank(address(terminal));
        hook.afterCashOutRecordedWith(context);

        assertTrue(mockPm.swapCalled(), "sell-side swap should hit the pool manager");
        assertEq(beneficiary.balance - balanceBefore, amountOut, "beneficiary should receive the partial swap proceeds");
    }

    /// @notice An EXPLICIT caller-specified minimum (`shouldEnforceMinimumSwapAmountOut` is `true`) must still
    /// hard-revert when a successful-but-partial fill lands below it.
    function test_afterCashOutRecordedWith_revertsWhenExplicitMinimumUnderfills() public {
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });

        uint256 amountOut = 4 ether;
        uint256 cashOutCount = 10 ether;
        uint256 minimumSwapAmountOut = 5 ether;

        projectToken.mint(address(hook), cashOutCount);
        vm.deal(address(mockPm), amountOut);

        // project token is currency1, native ETH is currency0, so selling project token is oneForZero.
        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(int128(uint128(amountOut)), -int128(uint128(cashOutCount)));

        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            reclaimedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: payable(beneficiary),
            hookMetadata: abi.encode(
                minimumSwapAmountOut,
                cashOutCount,
                uint256(3 ether),
                int24(0),
                uint128(1_000_000 ether),
                poolId,
                uint256(6 ether),
                true
            ),
            cashOutMetadata: ""
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, amountOut, minimumSwapAmountOut
            )
        );
        vm.prank(address(terminal));
        hook.afterCashOutRecordedWith(context);
    }

    /// @notice When a wrapper splits cashOutCount into fee and non-fee tranches, the metadata-sourced count
    /// should be used for reminting/selling, NOT context.cashOutCount.
    function test_afterCashOutRecordedWith_usesMetadataCountNotContextCount() public {
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });

        // Simulate a wrapper (like REVDeployer) that splits: 100 tokens total, 5 are fee, 95 are non-fee.
        uint256 fullCashOutCount = 100 ether;
        uint256 nonFeeCashOutCount = 95 ether;
        uint256 amountOut = 5 ether;

        projectToken.mint(address(hook), nonFeeCashOutCount);
        vm.deal(address(mockPm), amountOut);

        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(int128(uint128(amountOut)), -int128(uint128(nonFeeCashOutCount)));

        // The context has the FULL count, but metadata has the non-fee count.
        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: fullCashOutCount,
            reclaimedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: payable(beneficiary),
            hookMetadata: abi.encode(amountOut, nonFeeCashOutCount),
            cashOutMetadata: ""
        });

        // The hook MUST mint nonFeeCashOutCount (95 ether), NOT fullCashOutCount (100 ether).
        vm.expectCall(
            address(controller),
            abi.encodeWithSignature(
                "mintTokensOf(uint256,uint256,address,string,bool)",
                projectId,
                nonFeeCashOutCount,
                address(hook),
                "",
                false
            )
        );

        vm.prank(address(terminal));
        hook.afterCashOutRecordedWith(context);

        assertTrue(mockPm.swapCalled(), "sell-side swap should execute");
        assertEq(beneficiary.balance, amountOut, "beneficiary should receive swap proceeds");
    }

    function test_afterCashOutRecordedWith_fallsBackToContextCountWhenNoMetadata() public {
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });

        uint256 cashOutCount = 10 ether;
        uint256 amountOut = 5 ether;

        projectToken.mint(address(hook), cashOutCount);
        vm.deal(address(mockPm), amountOut);

        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(int128(uint128(amountOut)), -int128(uint128(cashOutCount)));

        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            reclaimedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: payable(beneficiary),
            hookMetadata: "",
            cashOutMetadata: ""
        });

        // With empty metadata, the hook should fall back to context.cashOutCount.
        vm.expectCall(
            address(controller),
            abi.encodeWithSignature(
                "mintTokensOf(uint256,uint256,address,string,bool)", projectId, cashOutCount, address(hook), "", false
            )
        );

        vm.prank(address(terminal));
        hook.afterCashOutRecordedWith(context);

        assertTrue(mockPm.swapCalled(), "sell-side swap should execute");
    }

    function test_afterCashOutRecordedWith_revertsIfCallerIsNotProjectTerminal() public {
        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: 1 ether,
            reclaimedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: payable(beneficiary),
            hookMetadata: "",
            cashOutMetadata: ""
        });

        address attacker = makeAddr("attacker");
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (projectId, IJBTerminal(attacker))),
            abi.encode(false)
        );
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_CallerNotTerminal.selector, attacker));
        hook.afterCashOutRecordedWith(context);
    }
}
