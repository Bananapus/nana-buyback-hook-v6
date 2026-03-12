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
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// Buyback hook
import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {JBSwapLib} from "src/libraries/JBSwapLib.sol";
import {IGeomeanOracle} from "src/interfaces/IGeomeanOracle.sol";

//*********************************************************************//
// ----------------------------- Helpers ----------------------------- //
//*********************************************************************//

/// @notice Simple mintable ERC20 for test project tokens.
contract SlippageProjectToken is ERC20 {
    constructor() ERC20("SlippageProjectToken", "SPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Helper that adds liquidity to a V4 pool via the unlock/callback pattern.
contract SlippageLiquidityHelper is IUnlockCallback {
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
        payable
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

        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _takeIfPositive(Currency currency, int128 delta) internal {
        if (delta <= 0) return;
        uint256 amount = uint256(uint128(delta));
        poolManager.take(currency, address(this), amount);
    }

    receive() external payable {}
}

/// @notice Test harness exposing internal state for fork tests.
contract ForTest_SlippageBuybackHook is JBBuybackHook {
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

/// @title V4GeomeanSlippageForkTest
/// @notice Fork tests that stress-test the geomean oracle's sigmoid slippage optimization
///         across varying order sizes, liquidity depths, and TWAP windows.
///
///         Run with: FOUNDRY_PROFILE=fork forge test --match-contract V4GeomeanSlippageForkTest -vvv --skip "script/*"
///         Requires RPC_ETHEREUM_MAINNET in .env
contract V4GeomeanSlippageForkTest is Test {
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
    SlippageLiquidityHelper liqHelper;
    ForTest_SlippageBuybackHook hook;

    // Mock JB core (we're testing slippage behavior, not JB core)
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
        liqHelper = new SlippageLiquidityHelper(poolManager);

        // Etch code at mock addresses.
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        // Deploy the buyback hook with real PoolManager.
        hook = new ForTest_SlippageBuybackHook({
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
    // ---------- Test 1: Slippage Monotonicity vs Order Size ----------- //
    //*********************************************************************//

    /// @notice For a fixed liquidity (10K ETH), test order sizes from 0.001 to 100 ETH.
    ///         Assert slippage tolerance is monotonically increasing with order size.
    function test_fork_slippageMonotonicity_orderSize() public onlyFork {
        console.log("");
        console.log("====== SLIPPAGE MONOTONICITY: ORDER SIZE (10K ETH liquidity) ======");
        console.log("");

        uint256[7] memory orderSizes =
            [uint256(0.001 ether), 0.01 ether, 0.1 ether, 1 ether, 10 ether, 50 ether, 100 ether];
        string[7] memory labels = ["0.001", "0.01", "0.1", "1", "10", "50", "100"];

        uint256 prevSlippage = 0;

        for (uint256 i = 0; i < orderSizes.length; i++) {
            uint256 pid = _nextProjectId();
            (PoolKey memory key,) = _setupProjectWithPool(pid, 10_000 ether);

            (uint256 slippage, uint256 impact) = _getSlippageForSwap(key, orderSizes[i]);

            console.log(
                "  Order: %s ETH -> impact=%s, slippage=%s bps", labels[i], _toString(impact), _toString(slippage)
            );

            assertGe(slippage, prevSlippage, "Slippage must be monotonically increasing with order size");
            prevSlippage = slippage;
        }
    }

    //*********************************************************************//
    // --------- Test 2: Slippage Monotonicity vs Liquidity ------------ //
    //*********************************************************************//

    /// @notice For a fixed order (1 ETH), test liquidity depths from 100 to 1M ETH.
    ///         Assert slippage tolerance is monotonically DECREASING with liquidity depth.
    function test_fork_slippageMonotonicity_liquidity() public onlyFork {
        console.log("");
        console.log("====== SLIPPAGE MONOTONICITY: LIQUIDITY (1 ETH order) ======");
        console.log("");

        uint256[5] memory liquidities = [uint256(100 ether), 1000 ether, 10_000 ether, 100_000 ether, 1_000_000 ether];
        string[5] memory labels = ["100", "1K", "10K", "100K", "1M"];

        uint256 prevSlippage = type(uint256).max;

        for (uint256 i = 0; i < liquidities.length; i++) {
            uint256 pid = _nextProjectId();
            (PoolKey memory key,) = _setupProjectWithPool(pid, liquidities[i]);

            (uint256 slippage, uint256 impact) = _getSlippageForSwap(key, 1 ether);

            console.log(
                "  Liquidity: %s ETH -> impact=%s, slippage=%s bps", labels[i], _toString(impact), _toString(slippage)
            );

            assertLe(slippage, prevSlippage, "Slippage must be monotonically decreasing with liquidity");
            prevSlippage = slippage;
        }
    }

    //*********************************************************************//
    // ------------- Test 3: Slippage Matrix (size x depth) ------------ //
    //*********************************************************************//

    /// @notice Cross-product: order sizes x liquidity depths. Log the full matrix and assert
    ///         monotonicity on both axes.
    function test_fork_slippageMatrix() public onlyFork {
        console.log("");
        console.log("====== SLIPPAGE MATRIX: ORDER SIZE x LIQUIDITY ======");
        console.log("");

        uint256[5] memory orders = [uint256(0.01 ether), 0.1 ether, 1 ether, 10 ether, 100 ether];
        uint256[4] memory liqs = [uint256(1000 ether), 10_000 ether, 100_000 ether, 1_000_000 ether];
        string[5] memory orderLabels = ["0.01", "0.1", "1", "10", "100"];
        string[4] memory liqLabels = ["1K", "10K", "100K", "1M"];

        // Store results for cross-axis monotonicity checks.
        uint256[5][4] memory slippageGrid;

        for (uint256 l = 0; l < liqs.length; l++) {
            console.log("  --- Liquidity: %s ETH ---", liqLabels[l]);

            uint256 prevSlippageInRow = 0;

            for (uint256 o = 0; o < orders.length; o++) {
                uint256 pid = _nextProjectId();
                (PoolKey memory key,) = _setupProjectWithPool(pid, liqs[l]);

                (uint256 slippage, uint256 impact) = _getSlippageForSwap(key, orders[o]);

                slippageGrid[l][o] = slippage;

                console.log(
                    "    Order %s ETH -> impact=%s, slippage=%s bps",
                    orderLabels[o],
                    _toString(impact),
                    _toString(slippage)
                );

                // Row monotonicity: slippage increases with order size at fixed liquidity.
                assertGe(slippage, prevSlippageInRow, "Slippage must increase with order size at fixed liquidity");
                prevSlippageInRow = slippage;
            }
        }

        // Column monotonicity: slippage decreases with liquidity at fixed order size.
        for (uint256 o = 0; o < orders.length; o++) {
            for (uint256 l = 1; l < liqs.length; l++) {
                assertLe(
                    slippageGrid[l][o],
                    slippageGrid[l - 1][o],
                    "Slippage must decrease with liquidity at fixed order size"
                );
            }
        }
    }

    //*********************************************************************//
    // ---------- Test 4: TWAP Window Effect on Oracle Quote ----------- //
    //*********************************************************************//

    /// @notice For fixed order (1 ETH) and liquidity (10K ETH), test TWAP windows from 5 min to 2 days.
    ///         Mock oracle with different tick deltas to simulate price movement. Assert valid TWAP
    ///         quotes returned for all windows.
    function test_fork_twapWindowEffect() public onlyFork {
        console.log("");
        console.log("====== TWAP WINDOW EFFECT (1 ETH order, 10K liquidity) ======");
        console.log("");

        uint32[4] memory twapWindows = [uint32(300), uint32(1800), uint32(7200), uint32(172_800)];
        string[4] memory labels = ["5min", "30min", "2hr", "2day"];
        // Simulate different tick deltas for different TWAP windows.
        // Larger windows accumulate more tick cumulatives.
        int56[4] memory tickDeltas = [int56(0), int56(1800), int56(14_400), int56(345_600)];

        for (uint256 i = 0; i < twapWindows.length; i++) {
            uint256 pid = _nextProjectId();
            (PoolKey memory key, SlippageProjectToken projectToken) = _setupProjectWithPool(pid, 10_000 ether);

            // Mock oracle with specific tick delta for this TWAP window.
            _mockOracleWithTickDelta(key, 10_000 ether / 2, twapWindows[i], tickDeltas[i]);

            // Update the TWAP window (pool is already registered in _setupProjectWithPool).
            vm.prank(owner);
            hook.setTwapWindowOf(pid, twapWindows[i]);

            // Query the oracle via JBSwapLib.
            (uint256 amountOut, int24 meanTick, uint128 meanLiquidity) = JBSwapLib.getQuoteFromOracle(
                poolManager,
                key,
                twapWindows[i],
                1 ether,
                address(0), // native ETH (base)
                address(projectToken) // project token (quote)
            );

            console.log(
                "  TWAP %s: amountOut=%s, meanTick=%s", labels[i], _formatEther(amountOut), _toStringSigned(meanTick)
            );
            console.log("    meanLiquidity=%s", _toString(uint256(meanLiquidity)));

            // Verify valid quotes returned for all windows.
            assertGt(amountOut, 0, "Oracle should return non-zero quote for all TWAP windows");
            assertGt(meanLiquidity, 0, "Oracle should return non-zero mean liquidity");
        }
    }

    //*********************************************************************//
    // ------- Test 5: Swap Output vs Slippage-Adjusted Minimum -------- //
    //*********************************************************************//

    /// @notice For each combination, execute actual swap and verify:
    ///         received >= twapMinimum * (SLIPPAGE_DENOMINATOR - slippageTolerance) / SLIPPAGE_DENOMINATOR
    function test_fork_swapOutputVsMinimum() public onlyFork {
        console.log("");
        console.log("====== SWAP OUTPUT vs SLIPPAGE-ADJUSTED MINIMUM ======");
        console.log("");

        uint256[3] memory orders = [uint256(0.1 ether), 1 ether, 10 ether];
        uint256[3] memory liqs = [uint256(1000 ether), 10_000 ether, 100_000 ether];
        string[3] memory orderLabels = ["0.1", "1", "10"];
        string[3] memory liqLabels = ["1K", "10K", "100K"];

        for (uint256 l = 0; l < liqs.length; l++) {
            console.log("  --- Liquidity: %s ETH ---", liqLabels[l]);

            for (uint256 o = 0; o < orders.length; o++) {
                uint256 pid = _nextProjectId();
                (PoolKey memory key, SlippageProjectToken projectToken) = _setupProjectWithPool(pid, liqs[l]);

                // Compute slippage and TWAP minimum before the swap.
                (uint256 slippage,) = _getSlippageForSwap(key, orders[o]);

                // Get the TWAP quote as the minimum baseline.
                (uint256 twapMinimum,,) = JBSwapLib.getQuoteFromOracle(
                    poolManager, key, 5 minutes, uint128(orders[o]), address(0), address(projectToken)
                );

                uint256 adjustedMinimum =
                    twapMinimum * (JBSwapLib.SLIPPAGE_DENOMINATOR - slippage) / JBSwapLib.SLIPPAGE_DENOMINATOR;

                // Execute the swap.
                uint256 received = _executeNativeSwap(pid, key, projectToken, orders[o]);

                console.log(
                    "    Order %s ETH: received=%s, adjustedMin=%s",
                    orderLabels[o],
                    _formatEther(received),
                    _formatEther(adjustedMinimum)
                );
                console.log("      slippage=%s bps", _toString(slippage));

                assertGe(received, adjustedMinimum, "Swap output must meet or exceed slippage-adjusted minimum");
            }
        }
    }

    //*********************************************************************//
    // --------- Test 6: Circuit Breaker — Extreme Impact -------------- //
    //*********************************************************************//

    /// @notice For a very small pool (10 ETH liquidity) hit with a large order (100 ETH),
    ///         verify the sigmoid saturates near MAX_SLIPPAGE (8800 bps = 88%).
    function test_fork_circuitBreaker_extremeImpact() public onlyFork {
        console.log("");
        console.log("====== CIRCUIT BREAKER: EXTREME IMPACT ======");
        console.log("");

        uint256 pid = _nextProjectId();
        (PoolKey memory key,) = _setupProjectWithPool(pid, 10 ether);

        (uint256 slippage, uint256 impact) = _getSlippageForSwap(key, 100 ether);

        console.log("  Pool: 10 ETH liquidity, Order: 100 ETH");
        console.log("  Impact: %s", _toString(impact));
        console.log("  Slippage: %s bps (MAX_SLIPPAGE = 8800)", _toString(slippage));

        assertGe(slippage, 8000, "Extreme impact slippage must be >= 8000 bps (80%)");
        assertLe(slippage, JBSwapLib.MAX_SLIPPAGE, "Slippage must not exceed MAX_SLIPPAGE ceiling");
    }

    //*********************************************************************//
    // ----------------------- Internal Setup ---------------------------- //
    //*********************************************************************//

    function _nextProjectId() internal returns (uint256) {
        return nextProjectId++;
    }

    /// @notice Deploy a project token, initialize a native ETH V4 pool, add liquidity, register in hook.
    function _setupProjectWithPool(
        uint256 projectId,
        uint256 liquidityTokenAmount
    )
        internal
        returns (PoolKey memory key, SlippageProjectToken projectToken)
    {
        projectToken = new SlippageProjectToken();

        // Native ETH (address(0)) is always currency0 since it's the smallest address.
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // Initialize pool at price = 1.0 (tick 0).
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        poolManager.initialize(key, sqrtPrice);

        // Fund LiquidityHelper with project tokens and native ETH.
        projectToken.mint(address(liqHelper), liquidityTokenAmount);
        vm.deal(address(liqHelper), liquidityTokenAmount);

        // Approve PoolManager to spend project tokens from LiquidityHelper.
        vm.prank(address(liqHelper));
        IERC20(address(projectToken)).approve(address(poolManager), type(uint256).max);

        // Add full-range liquidity.
        int256 liquidityDelta = int256(liquidityTokenAmount / 2);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity{value: liquidityTokenAmount}(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        // Mock JB core for this project.
        _mockJBCore(projectId, projectToken);

        // Mock the oracle at address(0) for hookless pools.
        _mockOracle(key, liquidityDelta);

        // Register pool in hook via setPoolFor (sets _poolIsSet = true).
        vm.prank(owner);
        hook.setPoolFor(projectId, key, 5 minutes, JBConstants.NATIVE_TOKEN);
    }

    /// @notice Mock the IGeomeanOracle at address(0) for hookless pools.
    /// @dev Returns tick cumulatives for tick=0 (1:1 price) and liquidity-based secondsPerLiquidity.
    function _mockOracle(PoolKey memory, int256 liquidity) internal {
        // Etch minimal bytecode at address(0) so it's treated as a contract.
        vm.etch(address(0), hex"00");

        // Build the return data: tick=0 cumulates, and secondsPerLiquidity based on pool liquidity.
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = 0; // tick=0 -> no delta

        uint136[] memory secondsPerLiquidityCumulativeX128s = new uint136[](2);
        secondsPerLiquidityCumulativeX128s[0] = 0;
        // delta = twapWindow * 2^128 / liquidity (so harmonicMeanLiquidity ~ actual liquidity)
        uint256 liq = uint256(liquidity > 0 ? liquidity : -liquidity);
        if (liq == 0) liq = 1;
        secondsPerLiquidityCumulativeX128s[1] = uint136((uint256(300) << 128) / liq);

        // Mock all calls to observe() on address(0).
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IGeomeanOracle.observe.selector),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );
    }

    /// @notice Mock oracle with a specific tick delta to simulate price movement over a TWAP window.
    function _mockOracleWithTickDelta(PoolKey memory, uint256 liquidity, uint32 twapWindow, int56 tickDelta) internal {
        vm.etch(address(0), hex"00");

        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = tickDelta;

        uint136[] memory secondsPerLiquidityCumulativeX128s = new uint136[](2);
        secondsPerLiquidityCumulativeX128s[0] = 0;
        uint256 liq = liquidity > 0 ? liquidity : 1;
        secondsPerLiquidityCumulativeX128s[1] = uint136((uint256(twapWindow) << 128) / liq);

        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IGeomeanOracle.observe.selector),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );
    }

    function _mockJBCore(uint256 projectId, SlippageProjectToken projectToken) internal {
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

        // Mock currentRulesetOf with weight = 0.5e18 (so swap path wins over mint at 1:1 pool).
        _mockRuleset(projectId, 0.5e18);
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
    // -------------------- Internal: Slippage Query --------------------- //
    //*********************************************************************//

    /// @notice Compute the sigmoid slippage tolerance for a given swap against a real on-chain pool.
    /// @param key The pool key (must already be initialized with liquidity).
    /// @param orderSize The amount of base tokens being swapped in.
    /// @return slippage The slippage tolerance in basis points of SLIPPAGE_DENOMINATOR.
    /// @return impact The estimated price impact scaled by IMPACT_PRECISION.
    function _getSlippageForSwap(
        PoolKey memory key,
        uint256 orderSize
    )
        internal
        view
        returns (uint256 slippage, uint256 impact)
    {
        // Read actual pool state from real PoolManager.
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        // Calculate impact using JBSwapLib.
        bool zeroForOne = true; // ETH is currency0.
        impact = JBSwapLib.calculateImpact(orderSize, liquidity, sqrtPriceX96, zeroForOne);

        // Get slippage tolerance using JBSwapLib.
        // POOL_FEE is in hundredths of a bip, convert to bps: 3000 / 100 = 30 bps.
        slippage = JBSwapLib.getSlippageTolerance(impact, POOL_FEE / 100);
    }

    //*********************************************************************//
    // -------------------- Internal: Swap Execution --------------------- //
    //*********************************************************************//

    /// @notice Execute a swap via afterPayRecordedWith with native ETH.
    /// @return received The amount of project tokens received.
    function _executeNativeSwap(
        uint256 projectId,
        PoolKey memory,
        SlippageProjectToken projectToken,
        uint256 orderSize
    )
        internal
        returns (uint256 received)
    {
        // With native ETH pools, address(0) is always currency0, so projectToken is never token0.
        bool projectTokenIs0 = false;

        JBAfterPayRecordedContext memory ctx = JBAfterPayRecordedContext({
            payer: payer,
            projectId: projectId,
            rulesetId: 1,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: orderSize
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
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

        uint256 balBefore = projectToken.balanceOf(address(hook));

        vm.deal(address(terminal), orderSize);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: orderSize}(ctx);

        received = projectToken.balanceOf(address(hook)) - balBefore;
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

    function _toStringSigned(int24 value) internal pure returns (string memory) {
        if (value >= 0) return _toString(uint256(int256(value)));
        return string(abi.encodePacked("-", _toString(uint256(int256(-value)))));
    }
}
