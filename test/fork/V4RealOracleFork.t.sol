// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

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
import {JBSwapLib} from "src/libraries/JBSwapLib.sol";
// Mock oracle
import {MockOracleHook} from "../mock/MockOracleHook.sol";

//*********************************************************************//
// ----------------------------- Helpers ----------------------------- //
//*********************************************************************//

/// @notice Simple mintable ERC20 for test project tokens.
contract OracleProjectToken is ERC20 {
    constructor() ERC20("OracleProjectToken", "OPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Test harness that exposes JBSwapLib.getQuoteFromOracle as a public function.
/// @dev Since JBSwapLib functions are internal, we need a wrapper contract to call them from tests.
contract OracleQuoteHarness {
    using StateLibrary for IPoolManager;

    /// @notice Expose JBSwapLib.getQuoteFromOracle for direct testing.
    function getQuoteFromOracle(
        IPoolManager poolManager,
        PoolKey memory key,
        uint32 twapWindow,
        uint128 amountIn,
        address baseToken,
        address quoteToken
    )
        external
        view
        returns (uint256 amountOut, int24 arithmeticMeanTick, uint128 harmonicMeanLiquidity)
    {
        return JBSwapLib.getQuoteFromOracle(poolManager, key, twapWindow, amountIn, baseToken, quoteToken);
    }
}

/// @notice Helper that adds liquidity to a V4 pool via the unlock/callback pattern.
contract OracleLiquidityHelper is IUnlockCallback {
    IPoolManager public immutable POOL_MANAGER;

    struct AddLiqParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    constructor(IPoolManager _poolManager) {
        POOL_MANAGER = _poolManager;
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
        bytes memory data = abi.encode(
            AddLiqParams({key: key, tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta})
        );
        POOL_MANAGER.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "only PM");

        AddLiqParams memory params = abi.decode(data, (AddLiqParams));

        (BalanceDelta callerDelta,) = POOL_MANAGER.modifyLiquidity(
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
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(uint128(-delta));

        if (currency.isAddressZero()) {
            POOL_MANAGER.settle{value: amount}();
        } else {
            POOL_MANAGER.sync(currency);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        }
    }

    function _takeIfPositive(Currency currency, int128 delta) internal {
        if (delta <= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(uint128(delta));
        POOL_MANAGER.take(currency, address(this), amount);
    }

    receive() external payable {}
}

/// @notice Test harness exposing internal state for fork tests.
contract ForTest_OracleBuybackHook is JBBuybackHook {
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

/// @title V4RealOracleForkTest
/// @notice Fork tests that exercise the TWAP quote path with a properly-responding oracle.
///
///         The problem: all existing tests pass IHooks(address(0)) as ORACLE_HOOK. The `try` call
///         to IGeomeanOracle(address(0)).observe() always reverts into `catch`, returning (0,0,0)
///         and forcing the mint fallback. The TWAP quote path is never exercised with a real oracle.
///
///         These tests deploy a MockOracleHook at a valid non-zero address, returning realistic
///         tick cumulatives, and prove the TWAP branch works end-to-end.
///
///         Run with: FOUNDRY_PROFILE=fork forge test --match-contract V4RealOracleForkTest -vvv --skip "script/*"
///         Requires RPC_ETHEREUM_MAINNET in .env
contract V4RealOracleForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    //*********************************************************************//
    // ----------------------------- constants --------------------------- //
    //*********************************************************************//

    /// @notice Real V4 PoolManager on Ethereum mainnet (canonical address).
    address constant POOL_MANAGER_ADDR = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @notice The address where MockOracleHook is deployed via vm.etch.
    /// @dev Bit 12 (AFTER_INITIALIZE_FLAG = 1 << 12 = 0x1000) is set so V4's isValidHookAddress
    ///      accepts this as a valid hook. Only afterInitialize fires during pool init — we mock it.
    ///      No other hook callback flags are set, so addLiquidity/swap callbacks are skipped.
    address constant ORACLE_ADDR = address(uint160(0x1000));

    /// @notice Full-range tick bounds for tickSpacing = 60.
    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = 887_220;
    int24 constant TICK_SPACING = 60;
    uint24 constant POOL_FEE = 3000; // 0.3% in hundredths of a bip

    //*********************************************************************//
    // ----------------------------- state ------------------------------- //
    //*********************************************************************//

    IPoolManager poolManager;
    OracleLiquidityHelper liqHelper;
    OracleQuoteHarness quoteHarness;
    ForTest_OracleBuybackHook hook;

    // Mock JB core (we're testing oracle behavior, not JB core).
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
        liqHelper = new OracleLiquidityHelper(poolManager);
        quoteHarness = new OracleQuoteHarness();

        // Deploy MockOracleHook at the chosen hook-flag-compatible address via vm.etch.
        _deployOracleAtFlagAddress();

        // Etch code at mock JB addresses.
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        // Deploy the buyback hook with the mock oracle as ORACLE_HOOK.
        hook = new ForTest_OracleBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            poolManager: poolManager,
            oracleHook: IHooks(ORACLE_ADDR),
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

    //*********************************************************************//
    // ---- Test 1: Real Oracle Returns Non-Zero Quote (Library Level) --- //
    //*********************************************************************//

    /// @notice Deploy a mock oracle at a valid address that returns realistic tick cumulatives
    ///         (tick=0 for a 1:1 price, with valid secondsPerLiquidity). Call
    ///         JBSwapLib.getQuoteFromOracle() directly and assert amountOut > 0,
    ///         arithmeticMeanTick is reasonable, and harmonicMeanLiquidity > 0.
    function test_fork_RealOracleReturnsNonZeroQuote() public {
        console.log("");
        console.log("====== TEST 1: REAL ORACLE RETURNS NON-ZERO QUOTE ======");
        console.log("");

        OracleProjectToken projectToken = new OracleProjectToken();

        // Configure oracle: tick=0 (1:1 price), with realistic liquidity.
        // tickCumulative delta = 0 -> arithmeticMeanTick = 0.
        // secondsPerLiquidity delta computed for 1M liquidity over 5 min window.
        uint256 liquidity = 1_000_000 ether;
        uint32 twapWindow = 300; // 5 minutes
        int56 tickCumulativeDelta = 0; // tick=0 -> 1:1 price

        // secondsPerLiquidityDelta = twapWindow * 2^128 / liquidity
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 secPerLiqDelta = uint160((uint256(twapWindow) << 128) / liquidity);

        MockOracleHook(ORACLE_ADDR).setObserveData({
            _tickCumulative0: 0,
            _tickCumulative1: tickCumulativeDelta,
            _secPerLiq0: 0,
            _secPerLiq1: secPerLiqDelta
        });

        // Build a PoolKey pointing to the mock oracle. The pool does not need to exist in V4
        // for the TWAP path, because getQuoteFromOracle with twapWindow > 0 calls the oracle
        // directly without touching the PoolManager.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(ORACLE_ADDR)
        });

        // Call the library function through the harness.
        (uint256 amountOut, int24 arithmeticMeanTick, uint128 harmonicMeanLiquidity) = quoteHarness.getQuoteFromOracle({
            poolManager: poolManager,
            key: key,
            twapWindow: twapWindow,
            amountIn: 1 ether,
            baseToken: address(0),
            quoteToken: address(projectToken)
        });

        console.log("  amountOut: %s", _formatEther(amountOut));
        console.log("  arithmeticMeanTick: %s", _toStringSigned(arithmeticMeanTick));
        console.log("  harmonicMeanLiquidity: %s", _toString(uint256(harmonicMeanLiquidity)));

        // Assert the TWAP branch returned real data, not the (0,0,0) fallback.
        assertGt(amountOut, 0, "Oracle must return non-zero amountOut");
        assertEq(arithmeticMeanTick, 0, "Mean tick should be 0 for 1:1 price");
        assertGt(harmonicMeanLiquidity, 0, "Harmonic mean liquidity must be > 0");

        // At tick=0 (1:1 price), 1 ETH input should yield ~1 ETH worth of output.
        // Allow 1% tolerance for rounding.
        assertApproxEqRel(amountOut, 1 ether, 0.01e18, "1:1 oracle should return ~1:1 quote");
    }

    //*********************************************************************//
    // -------- Test 2: Oracle Swap vs Mint Decision (Hook Level) -------- //
    //*********************************************************************//

    /// @notice Deploy a JBBuybackHook with the mock oracle. Set up a real V4 pool with the
    ///         oracle hook. Call beforePayRecordedWith. When the TWAP says the pool price is
    ///         better than the mint rate, verify the hook chooses the swap path.
    function test_fork_OracleSwapVsMintDecision() public {
        console.log("");
        console.log("====== TEST 2: ORACLE SWAP VS MINT DECISION ======");
        console.log("");

        uint256 projectId = _nextProjectId();
        _setupProjectWithOraclePool(projectId, 10_000 ether);

        // Configure oracle to return tick=0 (1:1 price).
        // With weight=0.5e18, minting yields 0.5 tokens per ETH.
        // With tick=0 (1:1 pool price), the swap yields ~1 token per ETH.
        // So the hook should choose the swap path.
        uint256 poolLiquidity = 10_000 ether / 2;
        uint32 twapWindow = 300;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 secPerLiqDelta = uint160((uint256(twapWindow) << 128) / poolLiquidity);

        MockOracleHook(ORACLE_ADDR).setObserveData({
            _tickCumulative0: 0,
            _tickCumulative1: 0, // tick=0 -> 1:1 price
            _secPerLiq0: 0,
            _secPerLiq1: secPerLiqDelta
        });

        // Build the beforePay context.
        JBBeforePayRecordedContext memory ctx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: 1 ether
            }),
            projectId: projectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 0.5e18,
            reservedPercent: 0,
            metadata: ""
        });

        // Call beforePayRecordedWith - this is where _getQuote runs.
        vm.prank(address(terminal));
        (uint256 weight, JBPayHookSpecification[] memory hookSpecs) = hook.beforePayRecordedWith(ctx);

        console.log("  weight returned: %s", _toString(weight));
        console.log("  hookSpecs length: %s", _toString(hookSpecs.length));

        // The hook should choose the swap path: weight=0, hookSpecs.length=1.
        assertEq(weight, 0, "Weight must be 0 when swap is preferred over mint");
        assertEq(hookSpecs.length, 1, "Hook must return exactly 1 hook specification for the swap");
        console.log("  -> Hook correctly chose SWAP path over mint (oracle TWAP active).");
    }

    //*********************************************************************//
    // ----- Test 3: Oracle Harmonic Mean Liquidity Zero -> Mint --------- //
    //*********************************************************************//

    /// @notice Mock oracle returns valid tickCumulatives but
    ///         secondsPerLiquidityCumulativeX128s[0] == secondsPerLiquidityCumulativeX128s[1]
    ///         (delta = 0). This makes harmonicMeanLiquidity = 0, which causes _getQuote to
    ///         return 0, triggering the mint fallback.
    function test_fork_OracleHarmonicMeanLiquidityZero() public {
        console.log("");
        console.log("====== TEST 3: ORACLE HARMONIC MEAN LIQUIDITY = 0 -> MINT ======");
        console.log("");

        uint256 projectId = _nextProjectId();
        (PoolKey memory key, OracleProjectToken projectToken) = _setupProjectWithOraclePool(projectId, 10_000 ether);

        // Configure oracle with valid tick cumulatives but zero liquidity delta.
        // secondsPerLiq0 == secondsPerLiq1 => delta = 0 => harmonicMeanLiquidity = 0.
        MockOracleHook(ORACLE_ADDR).setObserveData({
            _tickCumulative0: 0,
            _tickCumulative1: 0,
            _secPerLiq0: 100, // same value
            _secPerLiq1: 100 // same value => delta = 0
        });

        // First verify at the library level that harmonicMeanLiquidity is 0.
        (uint256 libAmountOut,, uint128 libHarmonicMeanLiquidity) = quoteHarness.getQuoteFromOracle({
            poolManager: poolManager,
            key: key,
            twapWindow: 300,
            amountIn: 1 ether,
            baseToken: address(0),
            quoteToken: address(projectToken)
        });

        console.log("  Library-level amountOut: %s", _formatEther(libAmountOut));
        console.log("  Library-level harmonicMeanLiquidity: %s", _toString(uint256(libHarmonicMeanLiquidity)));

        // The library returns amountOut > 0 but harmonicMeanLiquidity = 0.
        // The library itself does not zero-out the quote — that logic is in _getQuote.
        assertGt(libAmountOut, 0, "Library should still compute a quote from tick cumulatives");
        assertEq(libHarmonicMeanLiquidity, 0, "Harmonic mean liquidity must be 0 when delta is 0");

        // Now test the hook-level behavior: _getQuote returns 0 when harmonicMeanLiquidity = 0.
        JBBeforePayRecordedContext memory ctx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: 1 ether
            }),
            projectId: projectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 0.5e18,
            reservedPercent: 0,
            metadata: ""
        });

        vm.prank(address(terminal));
        (uint256 weight, JBPayHookSpecification[] memory hookSpecs) = hook.beforePayRecordedWith(ctx);

        console.log("  weight returned: %s", _toString(weight));
        console.log("  hookSpecs length: %s", _toString(hookSpecs.length));

        // With no TWAP minimum (harmonicMeanLiquidity = 0 triggers _getQuote returning 0),
        // and no payer quote, the hook falls through to minting.
        assertGt(weight, 0, "Weight must be > 0 (mint path) when oracle liquidity is zero");
        assertEq(hookSpecs.length, 0, "No hook specs - mint fallback when liquidity is zero");
        console.log("  -> Hook correctly fell back to MINT path (zero liquidity oracle).");
    }

    //*********************************************************************//
    // -------- Test 4: Oracle Different TWAP Windows -------------------- //
    //*********************************************************************//

    /// @notice Compare quotes with 300s (5min) vs 7200s (2hr) TWAP windows.
    ///         Both should return valid nonzero quotes. The 5min window should be
    ///         more responsive to recent price changes.
    function test_fork_OracleDifferentTwapWindows() public {
        console.log("");
        console.log("====== TEST 4: ORACLE DIFFERENT TWAP WINDOWS ======");
        console.log("");

        OracleProjectToken projectToken = new OracleProjectToken();

        // Use a realistic scenario: the pool is at tick=100 (slight premium for project token).
        // Simulate different TWAP windows seeing the same average tick.
        uint256 liquidity = 500_000 ether;
        int24 targetTick = 100; // Slight premium

        // -- 5 minute window (300s) --
        uint32 window5min = 300;
        // forge-lint: disable-next-line(unsafe-typecast)
        int56 tickCumDelta5min = int56(targetTick) * int56(int32(window5min));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 secPerLiqDelta5min = uint160((uint256(window5min) << 128) / liquidity);

        MockOracleHook(ORACLE_ADDR).setObserveData({
            _tickCumulative0: 0,
            _tickCumulative1: tickCumDelta5min,
            _secPerLiq0: 0,
            _secPerLiq1: secPerLiqDelta5min
        });

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(ORACLE_ADDR)
        });

        (uint256 amountOut5min, int24 meanTick5min, uint128 meanLiq5min) = quoteHarness.getQuoteFromOracle({
            poolManager: poolManager,
            key: key,
            twapWindow: window5min,
            amountIn: 1 ether,
            baseToken: address(0),
            quoteToken: address(projectToken)
        });

        console.log("  5min TWAP:");
        console.log("    amountOut: %s", _formatEther(amountOut5min));
        console.log("    meanTick: %s", _toStringSigned(meanTick5min));
        console.log("    meanLiquidity: %s", _toString(uint256(meanLiq5min)));

        assertGt(amountOut5min, 0, "5min window must return non-zero quote");
        assertGt(meanLiq5min, 0, "5min window must return non-zero liquidity");
        assertEq(meanTick5min, targetTick, "5min mean tick should equal target tick");

        // -- 2 hour window (7200s) --
        uint32 window2hr = 7200;
        // forge-lint: disable-next-line(unsafe-typecast)
        int56 tickCumDelta2hr = int56(targetTick) * int56(int32(window2hr));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 secPerLiqDelta2hr = uint160((uint256(window2hr) << 128) / liquidity);

        MockOracleHook(ORACLE_ADDR).setObserveData({
            _tickCumulative0: 0,
            _tickCumulative1: tickCumDelta2hr,
            _secPerLiq0: 0,
            _secPerLiq1: secPerLiqDelta2hr
        });

        (uint256 amountOut2hr, int24 meanTick2hr, uint128 meanLiq2hr) = quoteHarness.getQuoteFromOracle({
            poolManager: poolManager,
            key: key,
            twapWindow: window2hr,
            amountIn: 1 ether,
            baseToken: address(0),
            quoteToken: address(projectToken)
        });

        console.log("  2hr TWAP:");
        console.log("    amountOut: %s", _formatEther(amountOut2hr));
        console.log("    meanTick: %s", _toStringSigned(meanTick2hr));
        console.log("    meanLiquidity: %s", _toString(uint256(meanLiq2hr)));

        assertGt(amountOut2hr, 0, "2hr window must return non-zero quote");
        assertGt(meanLiq2hr, 0, "2hr window must return non-zero liquidity");
        assertEq(meanTick2hr, targetTick, "2hr mean tick should equal target tick");

        // Both windows see the same average tick, so quotes should match.
        assertEq(amountOut5min, amountOut2hr, "Same average tick should produce same quote regardless of window");

        // Now simulate a price shift: the 5min window sees a recent price change, 2hr does not.
        // 5min window: tick moved from 0 to 200 recently -> average tick = 200.
        // 2hr window: tick was at 0 for most of the window, moved to 200 recently -> average tick ~ 8.
        int24 recentTick = 200;
        // forge-lint: disable-next-line(unsafe-typecast)
        int56 tickCumDelta5minShift = int56(recentTick) * int56(int32(window5min));
        // For 2hr, simulate that only the last 5min out of 7200s was at tick=200.
        // Average tick = (0 * 6900 + 200 * 300) / 7200 = 60000 / 7200 = 8.
        // forge-lint: disable-next-line(unsafe-typecast)
        int56 tickCumDelta2hrShift = int56(recentTick) * int56(int32(window5min)); // = 200 * 300 = 60000

        MockOracleHook(ORACLE_ADDR).setObserveData({
            _tickCumulative0: 0,
            _tickCumulative1: tickCumDelta5minShift,
            _secPerLiq0: 0,
            _secPerLiq1: secPerLiqDelta5min
        });

        (uint256 amountOut5minShift, int24 meanTick5minShift,) = quoteHarness.getQuoteFromOracle({
            poolManager: poolManager,
            key: key,
            twapWindow: window5min,
            amountIn: 1 ether,
            baseToken: address(0),
            quoteToken: address(projectToken)
        });

        MockOracleHook(ORACLE_ADDR).setObserveData({
            _tickCumulative0: 0,
            _tickCumulative1: tickCumDelta2hrShift,
            _secPerLiq0: 0,
            _secPerLiq1: secPerLiqDelta2hr
        });

        (uint256 amountOut2hrShift, int24 meanTick2hrShift,) = quoteHarness.getQuoteFromOracle({
            poolManager: poolManager,
            key: key,
            twapWindow: window2hr,
            amountIn: 1 ether,
            baseToken: address(0),
            quoteToken: address(projectToken)
        });

        console.log("");
        console.log("  After price shift (tick 0 -> 200):");
        console.log("    5min meanTick: %s, amountOut: %s", _toStringSigned(meanTick5minShift), _formatEther(amountOut5minShift));
        console.log("    2hr  meanTick: %s, amountOut: %s", _toStringSigned(meanTick2hrShift), _formatEther(amountOut2hrShift));

        assertGt(amountOut5minShift, 0, "5min shifted window must return non-zero quote");
        assertGt(amountOut2hrShift, 0, "2hr shifted window must return non-zero quote");

        // The 5min window sees the full shift (tick=200), the 2hr window sees a dampened version (tick~8).
        // Since tick > 0 means project token is more expensive per base token,
        // the 5min window should return MORE project tokens per ETH than the 2hr window.
        // (Higher tick -> higher price ratio -> more quote tokens per base token when baseToken < quoteToken.)
        assertGt(
            amountOut5minShift,
            amountOut2hrShift,
            "5min window should be more responsive to recent price changes than 2hr"
        );

        console.log("  -> 5min window is more responsive: %s vs %s tokens", _formatEther(amountOut5minShift), _formatEther(amountOut2hrShift));
    }

    //*********************************************************************//
    // ----------------------- Internal Setup ---------------------------- //
    //*********************************************************************//

    function _nextProjectId() internal returns (uint256) {
        return nextProjectId++;
    }

    /// @notice Deploy MockOracleHook bytecode at ORACLE_ADDR using vm.etch.
    function _deployOracleAtFlagAddress() internal {
        // Deploy MockOracleHook to get its runtime bytecode.
        MockOracleHook template = new MockOracleHook();
        bytes memory oracleCode = address(template).code;

        // Etch the bytecode at the hook-flag-compatible address.
        vm.etch(ORACLE_ADDR, oracleCode);

        // Mock the afterInitialize callback — V4 will call this during pool init because
        // AFTER_INITIALIZE_FLAG (bit 12) is set in ORACLE_ADDR. The mock oracle doesn't
        // implement IHooks, so we mock this to prevent reverts.
        vm.mockCall(
            ORACLE_ADDR,
            abi.encodeWithSelector(IHooks.afterInitialize.selector),
            abi.encode(IHooks.afterInitialize.selector)
        );
    }

    /// @notice Deploy a project token, initialize a V4 pool with the oracle hook, add liquidity, register in hook.
    function _setupProjectWithOraclePool(
        uint256 projectId,
        uint256 liquidityTokenAmount
    )
        internal
        returns (PoolKey memory key, OracleProjectToken projectToken)
    {
        projectToken = new OracleProjectToken();

        // Build the pool key with the oracle hook as hooks field.
        // Native ETH (address(0)) is always currency0 since it's the smallest address.
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(ORACLE_ADDR)
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
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 liquidityDelta = int256(liquidityTokenAmount / 2);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity{value: liquidityTokenAmount}(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        // Mock JB core for this project.
        _mockJbCore(projectId, projectToken);

        // Register pool in hook via setPoolFor (uses the explicit PoolKey overload).
        vm.prank(owner);
        hook.setPoolFor(projectId, key, 5 minutes, JBConstants.NATIVE_TOKEN);
    }

    function _mockJbCore(uint256 projectId, OracleProjectToken projectToken) internal {
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
            // forge-lint: disable-next-line(unsafe-typecast)
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }

    function _toStringSigned(int24 value) internal pure returns (string memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (value >= 0) return _toString(uint256(int256(value)));
        // forge-lint: disable-next-line(unsafe-typecast)
        return string(abi.encodePacked("-", _toString(uint256(int256(-value)))));
    }
}
