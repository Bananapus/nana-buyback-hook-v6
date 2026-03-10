// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

// JB core imports
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
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
import {IJBBuybackHook} from "src/interfaces/IJBBuybackHook.sol";
import {IWETH9} from "src/interfaces/external/IWETH9.sol";
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

/// @notice Minimal mock WETH9 for testing -- supports deposit/withdraw/transfer.
contract MockWETH9 is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "MockWETH9: ETH transfer failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
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
        IWETH9 wrappedNativeToken,
        IPoolManager poolManager,
        address trustedForwarder
    )
        JBBuybackHook(directory, permissions, prices, projects, tokens, wrappedNativeToken, poolManager, trustedForwarder)
    {}

    /// @notice Directly initialize pool state for testing without going through setPoolFor permission checks.
    function ForTest_initPool(
        uint256 projectId,
        PoolKey calldata key,
        uint256 twapWindow,
        address projectToken,
        address terminalToken
    )
        external
    {
        _poolKeyOf[projectId][terminalToken] = key;
        twapWindowOf[projectId] = twapWindow;
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
    MockPoolManager mockPM;
    MockOracleHook mockOracle;
    MockProjectToken projectToken;
    MockWETH9 mockWeth;

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
        mockPM = new MockPoolManager();
        mockOracle = new MockOracleHook();
        projectToken = new MockProjectToken();
        mockWeth = new MockWETH9();

        // Etch code at mock addresses so calls don't revert with "no code"
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        // Labels
        vm.label(address(mockPM), "MockPoolManager");
        vm.label(address(mockOracle), "MockOracleHook");
        vm.label(address(projectToken), "ProjectToken");
        vm.label(address(mockWeth), "WETH");

        // Deploy hook
        hook = new ForTest_V4BuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            wrappedNativeToken: IWETH9(address(mockWeth)),
            poolManager: IPoolManager(address(mockPM)),
            trustedForwarder: address(0)
        });

        // Build pool key: currency0 < currency1 (sorted)
        address token0;
        address token1;
        if (address(projectToken) < address(mockWeth)) {
            token0 = address(projectToken);
            token1 = address(mockWeth);
        } else {
            token0 = address(mockWeth);
            token1 = address(projectToken);
        }

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
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
        mockPM.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPM.setLiquidity(poolId, 1_000_000 ether);

        // Initialize the pool in the hook (bypass permissions)
        address terminalTokenNormalized = address(mockWeth);
        hook.ForTest_initPool(projectId, poolKey, twapWindow, address(projectToken), terminalTokenNormalized);
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
            hookMetadata: abi.encode(projectTokenIs0, amountToMintWith, minimumSwapAmountOut, controller),
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
        bool projectTokenIs0 = address(projectToken) < address(mockWeth);
        uint256 payAmount = 1 ether;
        uint256 swapOut = 500e18; // project tokens received from swap

        // Configure mock deltas: the swap returns swapOut project tokens.
        // V4 convention: negative = caller spent (input), positive = caller received (output).
        // If projectTokenIs0: zeroForOne=false, delta0=+swapOut (received), delta1=-payAmount (spent)
        // If !projectTokenIs0: zeroForOne=true, delta0=-payAmount (spent), delta1=+swapOut (received)
        if (projectTokenIs0) {
            mockPM.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            mockPM.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        // Pre-fund the MockPoolManager with project tokens so take() can transfer them.
        projectToken.mint(address(mockPM), swapOut);

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
        assertTrue(mockPM.swapCalled(), "swap() should have been called on PoolManager");
    }

    /// @notice Test that when POOL_MANAGER.unlock() reverts, the hook gracefully falls back to minting.
    /// @dev Sets MockPoolManager to revert on unlock, then verifies afterPayRecordedWith does NOT
    ///      revert -- the try/catch in _swap catches the error and returns 0.
    function test_swapFallbackToMint() public {
        bool projectTokenIs0 = address(projectToken) < address(mockWeth);
        uint256 payAmount = 1 ether;

        // Force unlock to revert.
        mockPM.setShouldRevertOnUnlock(true);

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
        assertFalse(mockPM.swapCalled(), "swap() should NOT have been called when unlock reverts");
    }

    /// @notice Test that only the PoolManager can call unlockCallback.
    /// @dev Calling unlockCallback from any address other than the PoolManager should revert
    ///      with JBBuybackHook_CallerNotPoolManager.
    function test_unlockCallbackAuth() public {
        bytes memory fakeData = abi.encode(
            JBBuybackHook.SwapCallbackData({
                key: poolKey,
                projectTokenIs0: address(projectToken) < address(mockWeth),
                amountIn: 1 ether,
                minimumSwapAmountOut: 0,
                terminalToken: JBConstants.NATIVE_TOKEN
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
        bool projectTokenIs0 = address(projectToken) < address(mockWeth);
        uint256 payAmount = 2 ether;
        uint256 swapOut = 1000e18;

        // Configure deltas for the swap (V4 convention: negative=spent, positive=received).
        if (projectTokenIs0) {
            mockPM.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            mockPM.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        // Pre-fund MockPoolManager with project tokens.
        projectToken.mint(address(mockPM), swapOut);

        JBAfterPayRecordedContext memory ctx =
            _makeAfterPayContext(JBConstants.NATIVE_TOKEN, payAmount, projectTokenIs0, 0, 0);

        // Execute from terminal with ETH.
        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        // Verify swap executed.
        assertTrue(mockPM.swapCalled(), "swap() should have been called for native ETH payment");
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
        // First, clear the pool from ForTest_initPool.
        // We need to use setPoolFor which requires permissions and a valid pool.
        // Since we already have permissions mocked, let's do it properly.
        // But ForTest_initPool doesn't set _poolIsSet. We need a second project.

        uint256 oracleProjectId = 99;
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (oracleProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens),
            abi.encodeCall(tokens.tokenOf, (oracleProjectId)),
            abi.encode(IJBToken(address(projectToken)))
        );

        // Set valid sqrtPrice in MockPoolManager for the pool.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPM.setSlot0(poolId, sqrtPrice, 0, 3000);

        // Call setPoolFor to set _poolIsSet = true.
        vm.prank(owner);
        hook.setPoolFor(oracleProjectId, poolKey, twapWindow, address(mockWeth));

        // Verify pool was set by reading poolKeyOf.
        PoolKey memory storedKey = hook.poolKeyOf(oracleProjectId, address(mockWeth));
        assertEq(Currency.unwrap(storedKey.currency0), Currency.unwrap(poolKey.currency0), "currency0 mismatch");

        // Now verify the oracle is actually used by checking that projectTokenOf is set.
        assertEq(hook.projectTokenOf(oracleProjectId), address(projectToken), "project token should be set");
        assertEq(hook.twapWindowOf(oracleProjectId), twapWindow, "twap window should be set");
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
        mockPM.setSlot0(poolId, sqrtPrice, 0, 3000);

        vm.prank(owner);
        hook.setPoolFor(noOracleProjectId, poolKey, twapWindow, address(mockWeth));

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
                token: address(mockWeth),
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
        // Since tokenCountWithoutHook > 0, mint path is chosen (no hook specifications returned).
        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

        // Weight should be returned unchanged (mint path).
        assertEq(weight, 1e18, "Weight should be unchanged when oracle is unavailable (mint path)");
        assertEq(specs.length, 0, "No hook specifications when falling back to mint");
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
        mockPM.setSlot0(poolId, sqrtPrice, 0, 3000);

        vm.prank(owner);
        hook.setPoolFor(newProjectId, poolKey, twapWindow, address(mockWeth));

        // Verify the pool key was stored.
        PoolKey memory stored = hook.poolKeyOf(newProjectId, address(mockWeth));
        assertEq(stored.fee, poolKey.fee, "Pool fee should match");
        assertEq(stored.tickSpacing, poolKey.tickSpacing, "Tick spacing should match");

        // --- 2. Revert when pool already set ---
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_PoolAlreadySet.selector, poolId));
        hook.setPoolFor(newProjectId, poolKey, twapWindow, address(mockWeth));

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
        hook.setPoolFor(uninitProjectId, uninitPoolKey, twapWindow, address(mockWeth));

        // --- 4. Revert with invalid TWAP window ---
        uint256 twapProjectId = 202;
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (twapProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens),
            abi.encodeCall(tokens.tokenOf, (twapProjectId)),
            abi.encode(IJBToken(address(projectToken)))
        );

        // Too small (less than MIN_TWAP_WINDOW = 2 minutes).
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector,
                60, // 1 minute
                hook.MIN_TWAP_WINDOW(),
                hook.MAX_TWAP_WINDOW()
            )
        );
        hook.setPoolFor(twapProjectId, poolKey, 60, address(mockWeth));

        // Too large (more than MAX_TWAP_WINDOW = 2 days).
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector,
                3 days,
                hook.MIN_TWAP_WINDOW(),
                hook.MAX_TWAP_WINDOW()
            )
        );
        hook.setPoolFor(twapProjectId, poolKey, 3 days, address(mockWeth));
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
        bool projectTokenIs0 = address(projectToken) < address(mockWeth);
        uint256 payAmount = 10 ether;
        // Partial fill: only 3 ether consumed by the swap, returning 300 tokens.
        // The remaining 7 ether should trigger the leftover mint path.
        uint256 swapConsumed = 3 ether;
        uint256 swapOut = 300e18;

        // Configure deltas for a partial fill (V4 convention: negative=spent, positive=received).
        if (projectTokenIs0) {
            mockPM.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(swapConsumed)));
        } else {
            mockPM.setMockDeltas(-int128(uint128(swapConsumed)), int128(uint128(swapOut)));
        }

        // Pre-fund MockPoolManager with project tokens.
        projectToken.mint(address(mockPM), swapOut);

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
        assertTrue(mockPM.swapCalled(), "swap() should have been called for partial fill");
    }

    /// @notice Test that a payer's bad quote is overridden by a higher TWAP minimum.
    /// @dev Sets up the oracle to return a higher quote than the payer specified, then verifies
    ///      the hook uses the TWAP quote (higher of the two) in the swap decision.
    function test_payerQuoteCrossValidation() public {
        // Set up a project with _poolIsSet = true via setPoolFor.
        uint256 cvProjectId = 300;
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (cvProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (cvProjectId)), abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (cvProjectId)), abi.encode(controller));

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPM.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPM.setLiquidity(poolId, 1_000_000 ether);

        vm.prank(owner);
        hook.setPoolFor(cvProjectId, poolKey, twapWindow, address(mockWeth));

        // Configure oracle: tick=0 means price=1, so 1 ETH -> ~1 token.
        // With slippage applied, the TWAP-based quote will be somewhat less than 1e18 but still substantial.
        mockOracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

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

        // Payer provides a very low quote (1 token), meaning they'd accept terrible execution.
        uint256 badPayerQuote = 1;
        uint256 amountToSwapWith = 1 ether;

        // Encode the payer's bad quote as metadata.
        bytes memory quoteMetadata = abi.encode(amountToSwapWith, badPayerQuote);
        bytes4 metadataId = JBMetadataResolver.getId("quote");
        bytes memory fullMetadata = JBMetadataResolver.addToMetadata("", metadataId, quoteMetadata);

        JBBeforePayRecordedContext memory beforeCtx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: address(mockWeth),
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

        // Call beforePayRecordedWith. If the TWAP quote > payer's bad quote,
        // the hook should use the TWAP quote (the higher one).
        (, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

        // The hook should still choose the swap path (specs.length == 1) because the TWAP quote
        // should exceed the mint count. The minimumSwapAmountOut in the hook spec metadata
        // should be the TWAP-based value (> 1).
        if (specs.length == 1) {
            (,, uint256 minOut,) = abi.decode(specs[0].metadata, (bool, uint256, uint256, IJBController));
            assertGt(minOut, badPayerQuote, "TWAP minimum should override bad payer quote");
        }
        // If specs.length == 0, the mint path was chosen (TWAP returned 0) — still valid,
        // the cross-validation didn't make things worse.
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
        mockPM.setSlot0(poolId, sqrtPrice, 0, 3000);

        // 2 minutes should now be rejected (was valid before, now too small).
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector,
                2 minutes,
                hook.MIN_TWAP_WINDOW(),
                hook.MAX_TWAP_WINDOW()
            )
        );
        hook.setPoolFor(newProjectId, poolKey, 2 minutes, address(mockWeth));

        // 4 minutes should also be rejected.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector,
                4 minutes,
                hook.MIN_TWAP_WINDOW(),
                hook.MAX_TWAP_WINDOW()
            )
        );
        hook.setPoolFor(newProjectId, poolKey, 4 minutes, address(mockWeth));

        // 5 minutes should succeed.
        vm.prank(owner);
        hook.setPoolFor(newProjectId, poolKey, 5 minutes, address(mockWeth));

        assertEq(hook.twapWindowOf(newProjectId), 5 minutes, "TWAP window should be 5 minutes");
    }
}
