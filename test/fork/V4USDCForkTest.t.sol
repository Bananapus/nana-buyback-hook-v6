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
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// Buyback hook
import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {IGeomeanOracle} from "src/interfaces/IGeomeanOracle.sol";

// Shared fork test helpers
import {ForkProjectToken, ForkController, ForkLiquidityHelper, ForTest_BuybackHook} from "../helpers/ForkHelpers.sol";

//*********************************************************************//
// ----------------------------- Helpers ----------------------------- //
//*********************************************************************//

/// @notice Mock USDC with 6 decimals.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

//*********************************************************************//
// ----------------------------- Tests ------------------------------- //
//*********************************************************************//

/// @title V4USDCForkTest
/// @notice Fork tests against the real Uniswap V4 PoolManager on Ethereum mainnet
///         using a 6-decimal USDC-like ERC-20 as the terminal token.
///         Mirrors V4ForkTest.t.sol but validates non-18-decimal terminal token handling.
///
///         Run with: FOUNDRY_PROFILE=fork forge test --match-contract V4USDCFork -vvv --skip "script/*"
///         Requires RPC_ETHEREUM_MAINNET in .env
abstract contract V4USDCForkTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    //*********************************************************************//
    // ----------------------------- constants --------------------------- //
    //*********************************************************************//

    /// @notice Real V4 PoolManager on Ethereum mainnet (canonical address).
    address constant POOL_MANAGER_ADDR = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @notice Full-range tick bounds for tickSpacing = 60.
    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = 887_220;
    int24 constant TICK_SPACING = 60;
    uint24 constant POOL_FEE = 3000; // 0.3% in hundredths of a bip

    //*********************************************************************//
    // ----------------------------- state ------------------------------- //
    //*********************************************************************//

    IPoolManager poolManager;
    ForkLiquidityHelper liqHelper;
    ForTest_BuybackHook hook;

    // Mock JB core (we're testing V4 integration, not JB core)
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

    uint256 nextProjectId = 1;

    //*********************************************************************//
    // ----------------------------- setup ------------------------------- //
    //*********************************************************************//

    function setUp() public {
        // Fork Ethereum mainnet.
        vm.createSelectFork("ethereum", 21_700_000);

        // Verify V4 PoolManager is deployed.
        require(POOL_MANAGER_ADDR.code.length > 0, "PoolManager not deployed at expected address");

        poolManager = IPoolManager(POOL_MANAGER_ADDR);
        liqHelper = new ForkLiquidityHelper(poolManager);

        // Etch code at mock addresses.
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

        // Deploy the buyback hook with real PoolManager.
        hook = new ForTest_BuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants({newPoolManager: poolManager, newOracleHook: IHooks(address(0))});

        // Default JB mocks.
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
    }

    modifier onlyFork() {
        _;
    }

    //*********************************************************************//
    // --------------- Fork: USDC Varying Order Sizes -------------------- //
    //*********************************************************************//

    /// @notice Test swaps at 5 different USDC order sizes against a medium-depth pool.
    function _test_fork_usdc_varyingOrderSizes() internal {
        for (uint256 i; i < 5; i++) {
            uint256 orderSize = _usdcOrderSizeAt(i);
            uint256 pid = _nextProjectId();
            MockUSDC usdc = new MockUSDC();
            (PoolKey memory key, ForkProjectToken projectToken) = _setupProjectWithUsdcPool(pid, usdc, 100_000e6);

            uint256 received = _executeUsdcSwap(pid, key, projectToken, usdc, orderSize);

            assertGt(received, 0, "Should receive tokens from USDC swap");
        }
    }

    //*********************************************************************//
    // --------------- Fork: USDC Varying Liquidity ---------------------- //
    //*********************************************************************//

    /// @notice Test the same USDC order size across 4 different liquidity depths.
    function _test_fork_usdc_varyingLiquidity() internal {
        for (uint256 i; i < 4; i++) {
            uint256 liquidity = _usdcLiquidityAt(i);
            uint256 pid = _nextProjectId();
            MockUSDC usdc = new MockUSDC();
            (PoolKey memory key, ForkProjectToken projectToken) = _setupProjectWithUsdcPool(pid, usdc, liquidity);

            uint256 received = _executeUsdcSwap(pid, key, projectToken, usdc, 1000e6);

            assertGt(received, 0, "Should receive tokens from USDC swap");
        }
    }

    //*********************************************************************//
    // -------------- Fork: USDC Order Size x Liquidity Matrix ----------- //
    //*********************************************************************//

    /// @notice Cross-product: 3 USDC order sizes x 3 liquidity depths.
    function _test_fork_usdc_orderSizeByLiquidity() internal {
        for (uint256 l; l < 3; l++) {
            uint256 liquidity = _matrixLiquidityAt(l);

            for (uint256 o; o < 3; o++) {
                uint256 orderSize = _matrixOrderSizeAt(o);
                uint256 pid = _nextProjectId();
                MockUSDC usdc = new MockUSDC();
                (PoolKey memory key, ForkProjectToken projectToken) = _setupProjectWithUsdcPool(pid, usdc, liquidity);

                uint256 received = _executeUsdcSwap(pid, key, projectToken, usdc, orderSize);

                assertGt(received, 0, "Should receive tokens");
            }
        }
    }

    //*********************************************************************//
    // -------------- E2E: Full beforePay -> afterPay (USDC) ------------- //
    //*********************************************************************//

    /// @notice End-to-end: beforePayRecordedWith -> afterPayRecordedWith with USDC terminal token.
    function _test_fork_usdc_e2e_fullFlow() internal {
        uint256[3] memory orderSizes = [uint256(100e6), 1000e6, 10_000e6];

        for (uint256 i = 0; i < orderSizes.length; i++) {
            uint256 pid = _nextProjectId();
            MockUSDC usdc = new MockUSDC();
            (PoolKey memory key, ForkProjectToken projectToken) = _setupProjectWithUsdcPool(pid, usdc, 100_000e6);

            uint256 received = _executeE2eUsdc(pid, key, projectToken, usdc, orderSizes[i]);

            assertGt(received, 0, "E2E USDC should complete swap");
        }
    }

    //*********************************************************************//
    // ------------ E2E: No Payer Quote (USDC terminal) ------------------ //
    //*********************************************************************//

    /// @notice Verify buybacks work for callers that provide NO quote metadata with USDC terminal.
    /// @dev Uses the TWAP oracle route when the oracle is warm; no unsafe spot fallback is used.
    function _test_fork_usdc_e2e_noPayerQuote() internal {
        uint256[3] memory orderSizes = [uint256(100e6), 1000e6, 10_000e6];

        for (uint256 i = 0; i < orderSizes.length; i++) {
            uint256 pid = _nextProjectId();
            MockUSDC usdc = new MockUSDC();
            (PoolKey memory key, ForkProjectToken projectToken) = _setupProjectWithUsdcPool(pid, usdc, 100_000e6);

            uint256 received = _executeE2eNoQuoteUsdc(pid, key, projectToken, usdc, orderSizes[i]);

            assertGt(received, 0, "No-quote USDC E2E should still trigger buyback via TWAP");
        }
    }

    function _test_fork_usdc_sellSide_e2e() internal {
        uint256 pid = _nextProjectId();
        MockUSDC usdc = new MockUSDC();
        (PoolKey memory key, ForkProjectToken projectToken) = _setupProjectWithUsdcPool(pid, usdc, 100_000e6);

        uint256 proceeds = _executeSellE2eUsdc(pid, key, projectToken, usdc, 1e6);

        assertGt(proceeds, 0, "Sell-side USDC E2E should complete swap");
    }

    function _test_fork_usdc_sellSide_noopWhenProtocolBetter() internal {
        uint256 pid = _nextProjectId();
        MockUSDC usdc = new MockUSDC();
        _setupProjectWithUsdcPool(pid, usdc, 100_000e6);

        bytes4 metadataId = JBMetadataResolver.getId("cashOut", address(hook));
        bytes memory fullMetadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(uint256(1), false));

        JBBeforeCashOutRecordedContext memory beforeCtx = JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: payer,
            projectId: pid,
            rulesetId: 1,
            cashOutCount: 1e6,
            totalSupply: 2e6,
            surplus: JBTokenAmount({
                token: address(usdc), value: 100e6, decimals: 6, currency: uint32(uint160(address(usdc)))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: fullMetadata
        });

        (uint256 cashOutTaxRate,,,, JBCashOutHookSpecification[] memory specs) =
            hook.beforeCashOutRecordedWith(beforeCtx);

        assertEq(cashOutTaxRate, 0, "protocol path should be preserved when USDC reclaim is better");
        assertEq(specs.length, 1, "sell-side noop path should still return metadata");
        assertTrue(specs[0].noop, "protocol-winning USDC sell path should be noop");
    }

    //*********************************************************************//
    // ----------------------- Internal Setup ---------------------------- //
    //*********************************************************************//

    function _nextProjectId() internal returns (uint256) {
        return nextProjectId++;
    }

    /// @notice Deploy a project token, initialize a USDC V4 pool, add liquidity, register in hook.
    function _setupProjectWithUsdcPool(
        uint256 projectId,
        MockUSDC usdc,
        uint256 liquidityUsdcAmount
    )
        internal
        returns (PoolKey memory key, ForkProjectToken projectToken)
    {
        projectToken = new ForkProjectToken();

        // Build sorted pool key (both tokens are ERC-20).
        address token0;
        address token1;
        if (address(projectToken) < address(usdc)) {
            token0 = address(projectToken);
            token1 = address(usdc);
        } else {
            token0 = address(usdc);
            token1 = address(projectToken);
        }

        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // Initialize pool at price = 1.0 (tick 0) in raw token terms.
        // For a 6-decimal/18-decimal pair, tick 0 means 1 raw USDC = 1 raw projectToken.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        poolManager.initialize(key, sqrtPrice);

        // Fund LiquidityHelper with both tokens.
        // At tick 0 (1:1 price ratio in raw terms), we need matching raw amounts.
        usdc.mint(address(liqHelper), liquidityUsdcAmount);
        projectToken.mint(address(liqHelper), liquidityUsdcAmount);

        // Approve PoolManager to spend both tokens from LiquidityHelper.
        vm.startPrank(address(liqHelper));
        IERC20(address(projectToken)).approve(address(poolManager), type(uint256).max);
        IERC20(address(usdc)).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        // Add full-range liquidity.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 liquidityDelta = int256(liquidityUsdcAmount / 2);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        // Mock JB core for this project.
        _mockJbCore(projectId, projectToken);
        _mockTerminalLocalSurplus({
            projectId: projectId,
            token: address(usdc),
            decimals: usdc.decimals(),
            currency: uint32(uint160(address(usdc))),
            surplus: type(uint256).max
        });

        // Mock the oracle at address(0) for hookless pools.
        _mockOracle(key, liquidityDelta);

        // Register pool in hook via setPoolFor.
        vm.prank(owner);
        hook.setPoolFor(projectId, key, 5 minutes, address(usdc));
    }

    function _mockTerminalLocalSurplus(
        uint256 projectId,
        address token,
        uint256 decimals,
        uint256 currency,
        uint256 surplus
    )
        internal
    {
        address[] memory tokensToCheck = new address[](1);
        tokensToCheck[0] = token;

        vm.mockCall(
            address(terminal),
            abi.encodeCall(IJBTerminal.currentSurplusOf, (projectId, tokensToCheck, decimals, currency)),
            abi.encode(surplus)
        );
    }

    /// @notice Mock the IGeomeanOracle at address(0) for hookless pools.
    /// @dev Returns tick cumulatives for tick=0 (1:1 raw price) and liquidity-based secondsPerLiquidity.
    function _mockOracle(PoolKey memory, int256 liquidity) internal {
        // Etch minimal bytecode at address(0) so it's treated as a contract.
        vm.etch(address(0), hex"00");

        // Build the return data: tick=0 cumulates, and secondsPerLiquidity based on pool liquidity.
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = 0; // tick=0 → no delta

        uint136[] memory secondsPerLiquidityCumulativeX128s = new uint136[](2);
        secondsPerLiquidityCumulativeX128s[0] = 0;
        // delta = twapWindow * 2^128 / liquidity (so harmonicMeanLiquidity ≈ actual liquidity).
        uint256 liq = uint256(liquidity > 0 ? liquidity : -liquidity);
        if (liq == 0) liq = 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        secondsPerLiquidityCumulativeX128s[1] = uint136((uint256(300) << 128) / liq);

        // Mock all calls to observe() on address(0).
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IGeomeanOracle.observe.selector),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );
    }

    function _mockJbCore(uint256 projectId, ForkProjectToken projectToken) internal {
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (projectId)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (projectId, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );

        // Mock controller mint/burn.
        vm.mockCall(
            address(controller),
            abi.encodeWithSignature("mintTokensOf(uint256,uint256,address,string,bool)"),
            abi.encode(0)
        );
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.previewMintOf.selector), abi.encode(0, 0));
        vm.mockCall(
            address(controller), abi.encodeWithSignature("burnTokensOf(address,uint256,uint256,string)"), abi.encode()
        );

        // Mock currentRulesetOf with very low weight so swap path wins over mint.
        // For USDC (6 decimals), weightRatio = 1e6, so mint gives: orderSize * weight / 1e6.
        // With weight = 1e6 (0.000000000001e18), mint gives ~orderSize raw tokens (negligible).
        // The pool at tick-0 will always give more, so the hook should choose swap.
        _mockRuleset(projectId, 1e6);
    }

    function _mockRuleset(uint256 projectId, uint256 weight) internal {
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
            // forge-lint: disable-next-line(unsafe-typecast)
            weight: uint112(weight),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller), abi.encodeCall(IJBController.currentRulesetOf, (projectId)), abi.encode(ruleset, meta)
        );
    }

    //*********************************************************************//
    // -------------------- Internal: Swap Execution --------------------- //
    //*********************************************************************//

    /// @notice Execute a swap via afterPayRecordedWith with USDC (ERC-20, 6 decimals).
    /// @return received The amount of project tokens received.
    function _executeUsdcSwap(
        uint256 projectId,
        PoolKey memory,
        ForkProjectToken projectToken,
        MockUSDC usdc,
        uint256 orderSize
    )
        internal
        returns (uint256 received)
    {
        bool projectTokenIs0 = address(projectToken) < address(usdc);

        JBAfterPayRecordedContext memory ctx = JBAfterPayRecordedContext({
            payer: payer,
            projectId: projectId,
            rulesetId: 1,
            amount: JBTokenAmount({
                token: address(usdc), decimals: 6, currency: uint32(uint160(JBConstants.NATIVE_TOKEN)), value: orderSize
            }),
            forwardedAmount: JBTokenAmount({
                token: address(usdc), decimals: 6, currency: uint32(uint160(JBConstants.NATIVE_TOKEN)), value: orderSize
            }),
            weight: 0.5e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(
                projectTokenIs0,
                uint256(0),
                uint256(0),
                false,
                controller,
                uint256(0),
                1e18,
                int24(0),
                uint128(0),
                bytes32(0),
                uint256(0),
                uint256(0),
                uint256(0),
                orderSize
            ),
            payerMetadata: ""
        });

        // Mock addToBalanceOf for any leftover.
        vm.mockCall(
            address(terminal),
            abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
            abi.encode()
        );

        // Fund the terminal with USDC, approve the hook.
        usdc.mint(address(terminal), orderSize);
        vm.prank(address(terminal));
        IERC20(address(usdc)).approve(address(hook), orderSize);

        uint256 balBefore = projectToken.balanceOf(address(hook));

        vm.prank(address(terminal));
        hook.afterPayRecordedWith(ctx);

        received = projectToken.balanceOf(address(hook)) - balBefore;
    }

    /// @notice Full E2E: beforePayRecordedWith -> afterPayRecordedWith with USDC terminal.
    function _executeE2eUsdc(
        uint256 projectId,
        PoolKey memory,
        ForkProjectToken projectToken,
        MockUSDC usdc,
        uint256 orderSize
    )
        internal
        returns (uint256 received)
    {
        // Build metadata in scoped block.
        bytes memory fullMetadata;
        {
            uint256 payerMinOut = (orderSize * 9) / 10;
            bytes memory quoteMetadata = abi.encode(orderSize, payerMinOut);
            bytes4 metadataId = JBMetadataResolver.getId("pay");
            fullMetadata = JBMetadataResolver.addToMetadata("", metadataId, quoteMetadata);
        }

        // Step 1: beforePayRecordedWith -- scoped to free beforeCtx.
        uint256 specAmount;
        bytes memory specMetadata;
        {
            // Weight is set to 1 (near-zero) so the TWAP swap quote at tick 0
            // (~orderSize raw tokens after slippage) easily beats the mint amount
            // (orderSize * 1 / 1e6 ≈ 0), forcing the hook to choose the swap path.
            JBBeforePayRecordedContext memory beforeCtx = JBBeforePayRecordedContext({
                terminal: address(terminal),
                payer: payer,
                amount: JBTokenAmount({
                    token: address(usdc),
                    decimals: 6,
                    currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                    value: orderSize
                }),
                projectId: projectId,
                rulesetId: 1,
                beneficiary: beneficiary,
                weight: 1,
                reservedPercent: 0,
                metadata: fullMetadata
            });

            (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

            assertEq(weight, 0, "E2E USDC: weight should be 0 (swap path)");
            assertEq(specs.length, 1, "E2E USDC: should have 1 hook specification");
            assertGt(specs[0].amount, 0, "E2E USDC: swap amount should be > 0");
            specAmount = specs[0].amount;
            specMetadata = specs[0].metadata;
        }

        // Step 2: afterPayRecordedWith -- scoped to free afterCtx.
        {
            JBAfterPayRecordedContext memory afterCtx = JBAfterPayRecordedContext({
                payer: payer,
                projectId: projectId,
                rulesetId: 1,
                amount: JBTokenAmount({
                    token: address(usdc),
                    decimals: 6,
                    currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                    value: orderSize
                }),
                forwardedAmount: JBTokenAmount({
                    token: address(usdc),
                    decimals: 6,
                    currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                    value: specAmount
                }),
                weight: 1,
                newlyIssuedTokenCount: 0,
                beneficiary: beneficiary,
                hookMetadata: specMetadata,
                payerMetadata: fullMetadata
            });

            // Mock addToBalanceOf for leftover.
            vm.mockCall(
                address(terminal),
                abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
                abi.encode()
            );

            // Fund the terminal with USDC.
            usdc.mint(address(terminal), specAmount);
            vm.prank(address(terminal));
            IERC20(address(usdc)).approve(address(hook), specAmount);

            uint256 balBefore = projectToken.balanceOf(address(hook));

            vm.prank(address(terminal));
            hook.afterPayRecordedWith(afterCtx);

            received = projectToken.balanceOf(address(hook)) - balBefore;
        }
    }

    /// @notice Full E2E with NO payer quote -- simulates a programmatic caller with USDC terminal.
    /// @dev The hook must use the TWAP oracle to decide swap-vs-mint.
    function _executeE2eNoQuoteUsdc(
        uint256 projectId,
        PoolKey memory,
        ForkProjectToken projectToken,
        MockUSDC usdc,
        uint256 orderSize
    )
        internal
        returns (uint256 received)
    {
        // Step 1: beforePayRecordedWith with EMPTY metadata (no quote).
        uint256 specAmount;
        bytes memory specMetadata;
        {
            // Weight is set to 1 (near-zero) so the TWAP swap quote beats mint.
            JBBeforePayRecordedContext memory beforeCtx = JBBeforePayRecordedContext({
                terminal: address(terminal),
                payer: payer,
                amount: JBTokenAmount({
                    token: address(usdc),
                    decimals: 6,
                    currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                    value: orderSize
                }),
                projectId: projectId,
                rulesetId: 1,
                beneficiary: beneficiary,
                weight: 1,
                reservedPercent: 0,
                metadata: "" // No quote metadata -- this is the point of the test.
            });

            (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

            assertEq(weight, 0, "No-quote USDC: weight should be 0 (swap path chosen via TWAP)");
            assertEq(specs.length, 1, "No-quote USDC: should have 1 hook specification");
            specAmount = specs[0].amount;
            specMetadata = specs[0].metadata;
        }

        // Step 2: afterPayRecordedWith -- execute the swap.
        {
            JBAfterPayRecordedContext memory afterCtx = JBAfterPayRecordedContext({
                payer: payer,
                projectId: projectId,
                rulesetId: 1,
                amount: JBTokenAmount({
                    token: address(usdc),
                    decimals: 6,
                    currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                    value: orderSize
                }),
                forwardedAmount: JBTokenAmount({
                    token: address(usdc),
                    decimals: 6,
                    currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                    value: specAmount
                }),
                weight: 1,
                newlyIssuedTokenCount: 0,
                beneficiary: beneficiary,
                hookMetadata: specMetadata,
                payerMetadata: ""
            });

            vm.mockCall(
                address(terminal),
                abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
                abi.encode()
            );

            // Fund the terminal with USDC.
            usdc.mint(address(terminal), specAmount);
            vm.prank(address(terminal));
            IERC20(address(usdc)).approve(address(hook), specAmount);

            uint256 balBefore = projectToken.balanceOf(address(hook));

            vm.prank(address(terminal));
            hook.afterPayRecordedWith(afterCtx);

            received = projectToken.balanceOf(address(hook)) - balBefore;
        }
    }

    function _executeSellE2eUsdc(
        uint256 projectId,
        PoolKey memory,
        ForkProjectToken projectToken,
        MockUSDC usdc,
        uint256 cashOutCount
    )
        internal
        returns (uint256 received)
    {
        bytes4 metadataId = JBMetadataResolver.getId("cashOut", address(hook));
        bytes memory fullMetadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(uint256(1), false));

        bytes memory specMetadata;
        {
            JBBeforeCashOutRecordedContext memory beforeCtx = JBBeforeCashOutRecordedContext({
                terminal: address(terminal),
                holder: payer,
                projectId: projectId,
                rulesetId: 1,
                cashOutCount: cashOutCount,
                totalSupply: 100e6,
                surplus: JBTokenAmount({
                    token: address(usdc), value: 1, decimals: 6, currency: uint32(uint160(address(usdc)))
                }),
                scopeCashOutsToLocalBalances: true,
                cashOutTaxRate: 0,
                beneficiaryIsFeeless: false,
                metadata: fullMetadata
            });

            (uint256 cashOutTaxRate,,,, JBCashOutHookSpecification[] memory specs) =
                hook.beforeCashOutRecordedWith(beforeCtx);

            assertEq(
                cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE, "USDC sell-side E2E should choose the pool route"
            );
            assertEq(specs.length, 1, "USDC sell-side E2E should return one hook specification");
            assertFalse(specs[0].noop, "USDC sell-side E2E should return an active hook spec");
            specMetadata = specs[0].metadata;
        }

        // Use a real controller so that mintTokensOf actually mints tokens to the hook.
        // The FOT fix uses a balance-delta pattern that requires real token movements.
        ForkController sellController = new ForkController(projectToken);
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (projectId)), abi.encode(sellController));

        JBAfterCashOutRecordedContext memory afterCtx = JBAfterCashOutRecordedContext({
            holder: payer,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            reclaimedAmount: JBTokenAmount({
                token: address(usdc), value: 0, decimals: 6, currency: uint32(uint160(address(usdc)))
            }),
            forwardedAmount: JBTokenAmount({
                token: address(usdc), value: 0, decimals: 6, currency: uint32(uint160(address(usdc)))
            }),
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: payable(beneficiary),
            hookMetadata: specMetadata,
            cashOutMetadata: fullMetadata
        });

        uint256 balanceBefore = usdc.balanceOf(beneficiary);
        vm.prank(address(terminal));
        hook.afterCashOutRecordedWith(afterCtx);
        received = usdc.balanceOf(beneficiary) - balanceBefore;
    }

    //*********************************************************************//
    // ----------------------------- Helpers ----------------------------- //
    //*********************************************************************//

    function _matrixLiquidityAt(uint256 index) internal pure returns (uint256) {
        if (index == 0) return 10_000e6;
        if (index == 1) return 100_000e6;
        return 1_000_000e6;
    }

    function _matrixOrderSizeAt(uint256 index) internal pure returns (uint256) {
        if (index == 0) return 100e6;
        if (index == 1) return 1000e6;
        return 10_000e6;
    }

    function _usdcLiquidityAt(uint256 index) internal pure returns (uint256) {
        if (index == 0) return 1000e6;
        if (index == 1) return 10_000e6;
        if (index == 2) return 100_000e6;
        return 1_000_000e6;
    }

    function _usdcOrderSizeAt(uint256 index) internal pure returns (uint256) {
        if (index == 0) return 10e6;
        if (index == 1) return 100e6;
        if (index == 2) return 1000e6;
        if (index == 3) return 10_000e6;
        return 100_000e6;
    }
}

contract V4USDCForkQuoteTest is V4USDCForkTestBase {
    function test_fork_usdc_varyingOrderSizes() public onlyFork {
        _test_fork_usdc_varyingOrderSizes();
    }

    function test_fork_usdc_varyingLiquidity() public onlyFork {
        _test_fork_usdc_varyingLiquidity();
    }

    function test_fork_usdc_orderSizeByLiquidity() public onlyFork {
        _test_fork_usdc_orderSizeByLiquidity();
    }
}

contract V4USDCForkE2ETest is V4USDCForkTestBase {
    function test_fork_usdc_e2e_fullFlow() public onlyFork {
        _test_fork_usdc_e2e_fullFlow();
    }

    function test_fork_usdc_e2e_noPayerQuote() public onlyFork {
        _test_fork_usdc_e2e_noPayerQuote();
    }
}

contract V4USDCForkSellSideTest is V4USDCForkTestBase {
    function test_fork_usdc_sellSide_e2e() public onlyFork {
        _test_fork_usdc_sellSide_e2e();
    }

    function test_fork_usdc_sellSide_noopWhenProtocolBetter() public onlyFork {
        _test_fork_usdc_sellSide_noopWhenProtocolBetter();
    }
}
