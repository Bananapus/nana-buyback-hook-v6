// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

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
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// Buyback hook
import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {IGeomeanOracle} from "src/interfaces/IGeomeanOracle.sol";

//*********************************************************************//
// ----------------------------- Helpers ----------------------------- //
//*********************************************************************//

/// @notice Simple mintable ERC20 for USDC project tokens (always 18 decimals).
contract USDCProjectToken is ERC20 {
    constructor() ERC20("USDCProjectToken", "UPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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

/// @notice Helper that adds liquidity to a V4 pool via the unlock/callback pattern (ERC-20 only).
contract USDCLiquidityHelper is IUnlockCallback {
    IPoolManager public immutable poolManager;

    struct AddLiqParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function addLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    )
        external
    {
        bytes memory data = abi.encode(AddLiqParams(key, tickLower, tickUpper, liquidityDelta));
        poolManager.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PM");

        AddLiqParams memory params = abi.decode(data, (AddLiqParams));

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            params.key,
            ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        // Settle negative deltas (caller owes pool).
        _settleIfNegative(params.key.currency0, callerDelta.amount0());
        _settleIfNegative(params.key.currency1, callerDelta.amount1());

        // Take positive deltas (pool owes caller). Unlikely when adding liquidity, but handle it.
        _takeIfPositive(params.key.currency0, callerDelta.amount0());
        _takeIfPositive(params.key.currency1, callerDelta.amount1());

        return abi.encode(callerDelta);
    }

    function _settleIfNegative(Currency currency, int128 delta) internal {
        if (delta >= 0) return;
        uint256 amount = uint256(uint128(-delta));

        // Both tokens are ERC-20 (no native ETH in USDC pools).
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _takeIfPositive(Currency currency, int128 delta) internal {
        if (delta <= 0) return;
        uint256 amount = uint256(uint128(delta));
        poolManager.take(currency, address(this), amount);
    }
}

/// @notice Test harness exposing internal state for USDC fork tests.
contract ForTest_USDCBuybackHook is JBBuybackHook {
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
}

//*********************************************************************//
// ----------------------------- Tests ------------------------------- //
//*********************************************************************//

/// @title V4USDCForkTest
/// @notice Fork tests against the real Uniswap V4 PoolManager on Ethereum mainnet
///         using a 6-decimal USDC-like ERC-20 as the terminal token.
///         Mirrors V4ForkTest.t.sol but validates non-18-decimal terminal token handling.
///
///         Run with: FOUNDRY_PROFILE=fork forge test --match-contract V4USDCForkTest -vvv --skip "script/*"
///         Requires RPC_ETHEREUM_MAINNET in .env
contract V4USDCForkTest is Test {
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
    USDCLiquidityHelper liqHelper;
    ForTest_USDCBuybackHook hook;

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
        liqHelper = new USDCLiquidityHelper(poolManager);

        // Etch code at mock addresses.
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        // Deploy the buyback hook with real PoolManager.
        hook = new ForTest_USDCBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            poolManager: poolManager,
            oracleHook: IHooks(address(0)),
            trustedForwarder: address(0)
        });

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
    function test_fork_usdc_varyingOrderSizes() public onlyFork {
        console.log("");
        console.log("====== FORK TEST: USDC VARYING ORDER SIZES (100K USDC liq) ======");
        console.log("");

        uint256[5] memory orderSizes = [uint256(10e6), 100e6, 1_000e6, 10_000e6, 100_000e6];
        string[5] memory labels = ["10 USDC", "100 USDC", "1K USDC", "10K USDC", "100K USDC"];

        for (uint256 i = 0; i < orderSizes.length; i++) {
            uint256 pid = _nextProjectId();
            MockUSDC usdc = new MockUSDC();
            (PoolKey memory key, USDCProjectToken projectToken) =
                _setupProjectWithUSDCPool(pid, usdc, 100_000e6);

            uint256 received = _executeUSDCSwap(pid, key, projectToken, usdc, orderSizes[i]);

            console.log(
                "  Order: %s -> %s tokens received",
                labels[i],
                _formatEther(received)
            );

            assertGt(received, 0, "Should receive tokens from USDC swap");
        }
    }

    //*********************************************************************//
    // --------------- Fork: USDC Varying Liquidity ---------------------- //
    //*********************************************************************//

    /// @notice Test the same USDC order size across 4 different liquidity depths.
    function test_fork_usdc_varyingLiquidity() public onlyFork {
        console.log("");
        console.log("====== FORK TEST: USDC VARYING LIQUIDITY (1K USDC order) ======");
        console.log("");

        uint256[4] memory liquidities = [uint256(1_000e6), 10_000e6, 100_000e6, 1_000_000e6];
        string[4] memory labels = ["1K", "10K", "100K", "1M"];

        for (uint256 i = 0; i < liquidities.length; i++) {
            uint256 pid = _nextProjectId();
            MockUSDC usdc = new MockUSDC();
            (PoolKey memory key, USDCProjectToken projectToken) =
                _setupProjectWithUSDCPool(pid, usdc, liquidities[i]);

            uint256 received = _executeUSDCSwap(pid, key, projectToken, usdc, 1_000e6);

            console.log(
                "  Liquidity: %s USDC -> %s tokens for 1K USDC",
                labels[i],
                _formatEther(received)
            );

            assertGt(received, 0, "Should receive tokens from USDC swap");
        }
    }

    //*********************************************************************//
    // -------------- Fork: USDC Order Size x Liquidity Matrix ----------- //
    //*********************************************************************//

    /// @notice Cross-product: 3 USDC order sizes x 3 liquidity depths.
    function test_fork_usdc_orderSizeByLiquidity() public onlyFork {
        console.log("");
        console.log("====== FORK TEST: USDC ORDER SIZE x LIQUIDITY MATRIX ======");
        console.log("");

        uint256[3] memory orders = [uint256(100e6), 1_000e6, 10_000e6];
        uint256[3] memory liqs = [uint256(10_000e6), 100_000e6, 1_000_000e6];
        string[3] memory orderLabels = ["100 USDC", "1K USDC", "10K USDC"];
        string[3] memory liqLabels = ["10K", "100K", "1M"];

        for (uint256 l = 0; l < liqs.length; l++) {
            console.log("  --- Liquidity: %s USDC ---", liqLabels[l]);

            for (uint256 o = 0; o < orders.length; o++) {
                uint256 pid = _nextProjectId();
                MockUSDC usdc = new MockUSDC();
                (PoolKey memory key, USDCProjectToken projectToken) =
                    _setupProjectWithUSDCPool(pid, usdc, liqs[l]);

                uint256 received = _executeUSDCSwap(pid, key, projectToken, usdc, orders[o]);

                // Compute effective rate (scale USDC to 18 decimals for comparison).
                uint256 orderIn18 = orders[o] * 1e12;
                uint256 rateBps = received > 0 ? (received * 10_000) / orderIn18 : 0;

                console.log(
                    "    %s -> %s tokens (rate: %s bps of par)",
                    orderLabels[o],
                    _formatEther(received),
                    _toString(rateBps)
                );

                assertGt(received, 0, "Should receive tokens");
            }
        }
    }

    //*********************************************************************//
    // -------------- E2E: Full beforePay -> afterPay (USDC) ------------- //
    //*********************************************************************//

    /// @notice End-to-end: beforePayRecordedWith -> afterPayRecordedWith with USDC terminal token.
    function test_fork_usdc_e2e_fullFlow() public onlyFork {
        console.log("");
        console.log("====== FORK E2E: USDC FULL FLOW (beforePay -> afterPay) ======");
        console.log("");

        uint256[3] memory orderSizes = [uint256(100e6), 1_000e6, 10_000e6];
        string[3] memory labels = ["100 USDC", "1K USDC", "10K USDC"];

        for (uint256 i = 0; i < orderSizes.length; i++) {
            uint256 pid = _nextProjectId();
            MockUSDC usdc = new MockUSDC();
            (PoolKey memory key, USDCProjectToken projectToken) =
                _setupProjectWithUSDCPool(pid, usdc, 100_000e6);

            uint256 received = _executeE2E_USDC(pid, key, projectToken, usdc, orderSizes[i]);

            console.log(
                "  E2E %s -> %s tokens received",
                labels[i],
                _formatEther(received)
            );

            assertGt(received, 0, "E2E USDC should complete swap");
        }
    }

    //*********************************************************************//
    // ------------ E2E: No Payer Quote (USDC terminal) ------------------ //
    //*********************************************************************//

    /// @notice Verify buybacks work for callers that provide NO quote metadata with USDC terminal.
    /// @dev Without the spot-price fallback, this would always mint (twapMinimum = 0).
    function test_fork_usdc_e2e_noPayerQuote() public onlyFork {
        console.log("");
        console.log("====== FORK E2E: USDC NO PAYER QUOTE (programmatic caller) ======");
        console.log("");

        uint256[3] memory orderSizes = [uint256(100e6), 1_000e6, 10_000e6];
        string[3] memory labels = ["100 USDC", "1K USDC", "10K USDC"];

        for (uint256 i = 0; i < orderSizes.length; i++) {
            uint256 pid = _nextProjectId();
            MockUSDC usdc = new MockUSDC();
            (PoolKey memory key, USDCProjectToken projectToken) =
                _setupProjectWithUSDCPool(pid, usdc, 100_000e6);

            uint256 received = _executeE2E_noQuote_USDC(pid, key, projectToken, usdc, orderSizes[i]);

            console.log(
                "  No-quote %s -> %s tokens received",
                labels[i],
                _formatEther(received)
            );

            assertGt(received, 0, "No-quote USDC E2E should still trigger buyback via spot fallback");
        }
    }

    //*********************************************************************//
    // ----------------------- Internal Setup ---------------------------- //
    //*********************************************************************//

    function _nextProjectId() internal returns (uint256) {
        return nextProjectId++;
    }

    /// @notice Deploy a project token, initialize a USDC V4 pool, add liquidity, register in hook.
    function _setupProjectWithUSDCPool(
        uint256 projectId,
        MockUSDC usdc,
        uint256 liquidityUSDCAmount
    )
        internal
        returns (PoolKey memory key, USDCProjectToken projectToken)
    {
        projectToken = new USDCProjectToken();

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
        usdc.mint(address(liqHelper), liquidityUSDCAmount);
        projectToken.mint(address(liqHelper), liquidityUSDCAmount);

        // Approve PoolManager to spend both tokens from LiquidityHelper.
        vm.startPrank(address(liqHelper));
        IERC20(address(projectToken)).approve(address(poolManager), type(uint256).max);
        IERC20(address(usdc)).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        // Add full-range liquidity.
        int256 liquidityDelta = int256(liquidityUSDCAmount / 2);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        // Mock JB core for this project.
        _mockJBCore(projectId, projectToken);

        // Mock the oracle at address(0) for hookless pools.
        _mockOracle(key, liquidityDelta);

        // Register pool in hook via setPoolFor.
        vm.prank(owner);
        hook.setPoolFor(projectId, key, 5 minutes, address(usdc));
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

        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](2);
        secondsPerLiquidityCumulativeX128s[0] = 0;
        // delta = twapWindow * 2^128 / liquidity (so harmonicMeanLiquidity ≈ actual liquidity).
        uint256 liq = uint256(liquidity > 0 ? liquidity : -liquidity);
        if (liq == 0) liq = 1;
        secondsPerLiquidityCumulativeX128s[1] = uint160((uint256(300) << 128) / liq);

        // Mock all calls to observe() on address(0).
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IGeomeanOracle.observe.selector),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );
    }

    function _mockJBCore(uint256 projectId, USDCProjectToken projectToken) internal {
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
    function _executeUSDCSwap(
        uint256 projectId,
        PoolKey memory,
        USDCProjectToken projectToken,
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
                token: address(usdc),
                decimals: 6,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: orderSize
            }),
            forwardedAmount: JBTokenAmount({
                token: address(usdc),
                decimals: 6,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: orderSize
            }),
            weight: 0.5e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(projectTokenIs0, uint256(0), uint256(0), controller),
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
    function _executeE2E_USDC(
        uint256 projectId,
        PoolKey memory,
        USDCProjectToken projectToken,
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
            bytes4 metadataId = JBMetadataResolver.getId("quote");
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
    /// @dev The hook must use the spot-price fallback to decide swap-vs-mint.
    function _executeE2E_noQuote_USDC(
        uint256 projectId,
        PoolKey memory,
        USDCProjectToken projectToken,
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

            assertEq(weight, 0, "No-quote USDC: weight should be 0 (swap path chosen via spot fallback)");
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

    //*********************************************************************//
    // ----------------------------- Helpers ----------------------------- //
    //*********************************************************************//

    function _formatEther(uint256 weiAmount) internal pure returns (string memory) {
        uint256 whole = weiAmount / 1e18;
        uint256 frac = (weiAmount % 1e18) / 1e16;
        if (frac < 10) return string(abi.encodePacked(_toString(whole), ".0", _toString(frac)));
        return string(abi.encodePacked(_toString(whole), ".", _toString(frac)));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}
