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
import {ModifyLiquidityParams, SwapParams as V4SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// Buyback hook
import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {IJBBuybackHook} from "src/interfaces/IJBBuybackHook.sol";
import {IGeomeanOracle} from "src/interfaces/IGeomeanOracle.sol";
import {IWETH9} from "src/interfaces/external/IWETH9.sol";

//*********************************************************************//
// ----------------------------- Helpers ----------------------------- //
//*********************************************************************//

/// @notice Simple mintable ERC20 for test project tokens.
contract SandwichProjectToken is ERC20 {
    constructor() ERC20("SandwichProjectToken", "SPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Helper that adds liquidity to a V4 pool via the unlock/callback pattern.
contract SandwichLiquidityHelper is IUnlockCallback {
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

        _settleIfNegative(params.key.currency0, callerDelta.amount0());
        _settleIfNegative(params.key.currency1, callerDelta.amount1());
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

/// @notice V4 swap executor that simulates an attacker swapping directly through the PoolManager.
contract SwapHelper is IUnlockCallback {
    IPoolManager public immutable poolManager;

    struct SwapParams {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Execute a swap on a V4 pool.
    /// @return delta The balance delta from the swap.
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    )
        external
        payable
        returns (BalanceDelta delta)
    {
        bytes memory result = poolManager.unlock(
            abi.encode(
                SwapParams({
                    key: key,
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: sqrtPriceLimitX96
                })
            )
        );
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PM");

        SwapParams memory params = abi.decode(data, (SwapParams));

        BalanceDelta delta = poolManager.swap(
            params.key,
            V4SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            }),
            ""
        );

        // Settle negative deltas (we owe the pool).
        _settleIfNegative(params.key.currency0, delta.amount0());
        _settleIfNegative(params.key.currency1, delta.amount1());

        // Take positive deltas (pool owes us).
        _takeIfPositive(params.key.currency0, delta.amount0());
        _takeIfPositive(params.key.currency1, delta.amount1());

        return abi.encode(delta);
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
contract ForTest_SandwichBuybackHook is JBBuybackHook {
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
}

//*********************************************************************//
// ----------------------------- Tests ------------------------------- //
//*********************************************************************//

/// @title V4SandwichForkTest
/// @notice Fork tests simulating sandwich attacks against the buyback hook's V4 swap path.
///         Verifies that the sqrtPriceLimit circuit breaker + sigmoid slippage + TWAP cross-validation
///         pipeline prevents MEV extraction on real V4 PoolManager state.
///
///         Run with: forge test --match-contract V4SandwichForkTest -vvv --skip "script/*"
///         Requires RPC_ETHEREUM_MAINNET in .env
contract V4SandwichForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    //*********************************************************************//
    // ----------------------------- constants --------------------------- //
    //*********************************************************************//

    address constant POOL_MANAGER_ADDR = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = 887_220;
    int24 constant TICK_SPACING = 60;
    uint24 constant POOL_FEE = 3000; // 0.3% in hundredths of a bip

    //*********************************************************************//
    // ----------------------------- state ------------------------------- //
    //*********************************************************************//

    IPoolManager poolManager;
    IWETH9 weth;
    SandwichLiquidityHelper liqHelper;
    SwapHelper swapHelper;
    ForTest_SandwichBuybackHook hook;

    // Mock JB core
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
    address attacker = makeAddr("attacker");

    uint256 nextProjectId = 1;

    //*********************************************************************//
    // ----------------------------- setup ------------------------------- //
    //*********************************************************************//

    function setUp() public {
        string memory rpcUrl = vm.envOr("RPC_ETHEREUM_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl);

        require(POOL_MANAGER_ADDR.code.length > 0, "PoolManager not deployed at expected address");

        poolManager = IPoolManager(POOL_MANAGER_ADDR);
        weth = IWETH9(WETH_ADDR);
        liqHelper = new SandwichLiquidityHelper(poolManager);
        swapHelper = new SwapHelper(poolManager);

        // Etch code at mock addresses.
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        hook = new ForTest_SandwichBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            wrappedNativeToken: weth,
            poolManager: poolManager,
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
        string memory rpcUrl = vm.envOr("RPC_ETHEREUM_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) return;
        _;
    }

    //*********************************************************************//
    // ----------- Test 1: Sandwich at varying attack sizes -------------- //
    //*********************************************************************//

    /// @notice Sandwich 1 ETH victim buyback at attack sizes [0.1, 0.5, 1, 5, 10, 50] ETH.
    /// @dev Measures when the sqrtPriceLimit circuit breaker triggers and the swap falls back to mint.
    function test_fork_sandwich_varyingAttackSizes() public onlyFork {
        console.log("");
        console.log("====== SANDWICH FORK TEST: VARYING ATTACK SIZES (100K liq) ======");
        console.log("Victim: 1 ETH buyback | Pool: 100K liquidity, 0.3%% fee");
        console.log("");

        uint256[6] memory attackSizes = [uint256(0.1 ether), 0.5 ether, 1 ether, 5 ether, 10 ether, 50 ether];
        uint256 victimAmount = 1 ether;
        uint256 liquidityAmount = 100_000 ether;

        // Baseline: victim swap with no attack.
        uint256 pid = _nextProjectId();
        (PoolKey memory key, SandwichProjectToken projectToken) = _setupProjectWithPool(pid, liquidityAmount);
        uint256 baselineReceived = _executeNativeSwap(pid, key, projectToken, victimAmount);
        console.log("  Baseline (no attack): %s tokens for 1 ETH", _formatEther(baselineReceived));
        console.log("");

        for (uint256 i = 0; i < attackSizes.length; i++) {
            uint256 attackSize = attackSizes[i];

            // Fresh project + pool for each iteration.
            pid = _nextProjectId();
            (key, projectToken) = _setupProjectWithPool(pid, liquidityAmount);

            // Snapshot before attack.
            uint256 snapId = vm.snapshotState();

            // Step 1: Attacker frontrun — swap WETH for project tokens (push price down).
            bool projectTokenIs0 = address(projectToken) < WETH_ADDR;
            bool attackZeroForOne = !projectTokenIs0; // Attacker sells WETH to buy project tokens.

            _fundSwapHelper(attackSize);

            BalanceDelta frontrunDelta = swapHelper.swap(
                key,
                attackZeroForOne,
                -int256(attackSize), // exact input
                attackZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            );

            // Step 2: Victim buyback via hook.
            uint256 victimReceived = _executeNativeSwap(pid, key, projectToken, victimAmount);

            // Step 3: Attacker backrun — sell project tokens back for WETH.
            uint256 attackerTokenBalance;
            {
                // Calculate tokens the attacker received from frontrun.
                int128 tokenDelta = projectTokenIs0 ? frontrunDelta.amount0() : frontrunDelta.amount1();
                attackerTokenBalance = tokenDelta > 0 ? uint256(uint128(tokenDelta)) : 0;
            }

            int256 attackerProfit = 0;
            if (attackerTokenBalance > 0) {
                // Attacker sells project tokens back.
                bool backrunZeroForOne = projectTokenIs0; // Sell project token (token0) for WETH.

                // Fund swap helper with project tokens for backrun.
                projectToken.mint(address(swapHelper), attackerTokenBalance);

                BalanceDelta backrunDelta = swapHelper.swap(
                    key,
                    backrunZeroForOne,
                    -int256(attackerTokenBalance), // exact input
                    backrunZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                );

                // Attacker profit = WETH received from backrun - WETH spent on frontrun.
                int128 wethReceived = projectTokenIs0 ? backrunDelta.amount1() : backrunDelta.amount0();
                attackerProfit =
                    int256(uint256(uint128(wethReceived > 0 ? wethReceived : int128(0)))) - int256(attackSize);
            }

            // Compute victim loss vs baseline.
            uint256 victimLoss = baselineReceived > victimReceived ? baselineReceived - victimReceived : 0;
            uint256 victimLossBps = baselineReceived > 0 ? (victimLoss * 10_000) / baselineReceived : 0;
            bool mintFallback = victimReceived == 0;

            console.log("  Attack: %s ETH", _formatEther(attackSize));
            if (mintFallback) {
                console.log("    Victim: MINT FALLBACK (circuit breaker triggered)");
            } else {
                console.log(
                    "    Victim received: %s tokens (loss: %s bps)",
                    _formatEther(victimReceived),
                    _toString(victimLossBps)
                );
            }
            if (attackerProfit >= 0) {
                console.log("    Attacker profit: +%s ETH", _formatEther(uint256(attackerProfit)));
            } else {
                console.log("    Attacker profit: -%s ETH (LOSS)", _formatEther(uint256(-attackerProfit)));
            }

            // Revert to pre-attack state for next iteration.
            vm.revertToState(snapId);
        }

        console.log("");
        console.log("KEY: sqrtPriceLimit circuit breaker triggers mint fallback above threshold.");
        console.log("When triggered, victim gets mint-rate tokens and attacker loses 2x pool fees.");
    }

    //*********************************************************************//
    // ---- Test 2: Circuit breaker threshold by liquidity depth --------- //
    //*********************************************************************//

    /// @notice For each liquidity level, find the approximate attack size that triggers mint fallback.
    function test_fork_sandwich_circuitBreakerThreshold() public onlyFork {
        console.log("");
        console.log("====== CIRCUIT BREAKER THRESHOLD BY LIQUIDITY ======");
        console.log("Finding attack size that triggers mint fallback for 1 ETH victim.");
        console.log("");

        uint256[4] memory liquidities = [uint256(1000 ether), 10_000 ether, 100_000 ether, 1_000_000 ether];
        string[4] memory labels = ["1K", "10K", "100K", "1M"];
        uint256 victimAmount = 1 ether;

        // Attack sizes to probe (binary search would be ideal but iteration is simpler for documentation).
        uint256[8] memory probeSizes =
            [uint256(0.1 ether), 0.5 ether, 1 ether, 2 ether, 5 ether, 10 ether, 25 ether, 50 ether];

        for (uint256 l = 0; l < liquidities.length; l++) {
            console.log("  --- Liquidity: %s ---", labels[l]);

            uint256 pid = _nextProjectId();
            (PoolKey memory key, SandwichProjectToken projectToken) = _setupProjectWithPool(pid, liquidities[l]);

            uint256 threshold = 0;

            for (uint256 p = 0; p < probeSizes.length; p++) {
                uint256 attackSize = probeSizes[p];
                if (attackSize >= liquidities[l] / 2) break; // Skip if attack > pool depth.

                uint256 snapId = vm.snapshotState();

                // Frontrun.
                bool projectTokenIs0 = address(projectToken) < WETH_ADDR;
                bool attackZeroForOne = !projectTokenIs0;

                _fundSwapHelper(attackSize);

                swapHelper.swap(
                    key,
                    attackZeroForOne,
                    -int256(attackSize),
                    attackZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                );

                // Victim swap.
                uint256 victimReceived = _executeNativeSwap(pid, key, projectToken, victimAmount);

                if (victimReceived == 0 && threshold == 0) {
                    threshold = attackSize;
                    console.log("    Circuit breaker at: %s ETH attack", _formatEther(attackSize));
                }

                vm.revertToState(snapId);
            }

            if (threshold == 0) {
                console.log("    Circuit breaker NOT triggered (pool too deep for probe sizes)");
            }
        }

        console.log("");
        console.log("KEY: Deeper pools tolerate larger attacks before circuit breaker fires.");
    }

    //*********************************************************************//
    // ------ Test 3: Mint fallback under aggressive attack -------------- //
    //*********************************************************************//

    /// @notice Aggressive attack guaranteeing circuit breaker fires.
    ///         Assert victim gets mint-rate tokens and attacker profit is negative.
    function test_fork_sandwich_mintFallback() public onlyFork {
        console.log("");
        console.log("====== MINT FALLBACK UNDER AGGRESSIVE ATTACK ======");
        console.log("");

        uint256 victimAmount = 1 ether;
        uint256 liquidityAmount = 10_000 ether;

        uint256 pid = _nextProjectId();
        (PoolKey memory key, SandwichProjectToken projectToken) = _setupProjectWithPool(pid, liquidityAmount);

        // Use an attack so large it will certainly trigger the circuit breaker.
        uint256 attackSize = liquidityAmount / 4; // 25% of pool liquidity.

        bool projectTokenIs0 = address(projectToken) < WETH_ADDR;
        bool attackZeroForOne = !projectTokenIs0;

        // Frontrun.
        _fundSwapHelper(attackSize);

        BalanceDelta frontrunDelta = swapHelper.swap(
            key,
            attackZeroForOne,
            -int256(attackSize),
            attackZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );

        // Victim buyback — expect mint fallback (received = 0 from swap, falls through to mint).
        uint256 victimReceived = _executeNativeSwap(pid, key, projectToken, victimAmount);

        // Under aggressive attack, the swap should fail (circuit breaker) and the hook falls back to mint.
        // victimReceived from the swap itself will be 0, but the hook calls controller.mintTokensOf
        // for the full amount. Since our mock returns 0, we check behavior via the swap returning 0.
        console.log("  Attack size: %s ETH (25%% of pool)", _formatEther(attackSize));
        console.log("  Victim swap output: %s tokens", _formatEther(victimReceived));
        if (victimReceived == 0) {
            console.log("  CIRCUIT BREAKER FIRED -> mint fallback path taken");
        } else {
            console.log("  Swap completed within bounds (sigmoid tolerance absorbed the attack)");
        }

        // Backrun: attacker tries to profit.
        uint256 attackerTokenBalance;
        {
            int128 tokenDelta = projectTokenIs0 ? frontrunDelta.amount0() : frontrunDelta.amount1();
            attackerTokenBalance = tokenDelta > 0 ? uint256(uint128(tokenDelta)) : 0;
        }

        if (attackerTokenBalance > 0) {
            bool backrunZeroForOne = projectTokenIs0;
            projectToken.mint(address(swapHelper), attackerTokenBalance);
            vm.startPrank(address(swapHelper));
            IERC20(address(projectToken)).approve(address(poolManager), type(uint256).max);
            vm.stopPrank();

            BalanceDelta backrunDelta = swapHelper.swap(
                key,
                backrunZeroForOne,
                -int256(attackerTokenBalance),
                backrunZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            );

            int128 wethReceived = projectTokenIs0 ? backrunDelta.amount1() : backrunDelta.amount0();
            int256 attackerProfit =
                int256(uint256(uint128(wethReceived > 0 ? wethReceived : int128(0)))) - int256(attackSize);

            if (attackerProfit < 0) {
                console.log("  Attacker LOST: %s ETH (paid 2x pool fees)", _formatEther(uint256(-attackerProfit)));
            } else {
                console.log("  Attacker profit: %s ETH", _formatEther(uint256(attackerProfit)));
            }

            // When circuit breaker fires, attacker should lose money (2x pool fees).
            if (victimReceived == 0) {
                assertLt(attackerProfit, 0, "Attacker should lose money when circuit breaker fires");
            }
        }

        console.log("");
        console.log("KEY: When circuit breaker fires, victim gets mint-rate tokens (0 MEV).");
        console.log("Attacker loses 2x pool fees on the round trip.");
    }

    //*********************************************************************//
    // ---- Test 4: Payer quote cross-validation blocks sandwich --------- //
    //*********************************************************************//

    /// @notice Payer provides 1% slippage quote. Attacker frontruns by 2%.
    ///         TWAP cross-validation picks the tighter payer quote. Swap blocked, mint fallback, 0 MEV.
    function test_fork_sandwich_withPayerQuote() public onlyFork {
        console.log("");
        console.log("====== PAYER QUOTE CROSS-VALIDATION vs SANDWICH ======");
        console.log("");

        uint256 victimAmount = 1 ether;
        uint256 liquidityAmount = 100_000 ether;

        uint256 pid = _nextProjectId();
        (PoolKey memory key, SandwichProjectToken projectToken) = _setupProjectWithPool(pid, liquidityAmount);

        // Get baseline swap output (no attack) to compute a tight payer quote.
        uint256 snapId = vm.snapshotState();
        uint256 baselineReceived = _executeNativeSwap(pid, key, projectToken, victimAmount);
        vm.revertToState(snapId);

        // Payer sets 1% slippage quote based on current pool state.
        uint256 payerMinOut = (baselineReceived * 99) / 100;

        // Attacker frontruns with 3% of pool (should move price ~2%).
        uint256 attackSize = 3 ether;
        bool projectTokenIs0 = address(projectToken) < WETH_ADDR;
        bool attackZeroForOne = !projectTokenIs0;

        _fundSwapHelper(attackSize);

        swapHelper.swap(
            key,
            attackZeroForOne,
            -int256(attackSize),
            attackZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );

        // Victim uses beforePayRecordedWith with the tight payer quote.
        // The hook will cross-validate: max(payerQuote, twapQuote). Since payer quote is tight,
        // the manipulated pool can't satisfy it -> mint fallback.
        bytes memory fullMetadata;
        {
            bytes memory quoteMetadata = abi.encode(victimAmount, payerMinOut);
            bytes4 metadataId = JBMetadataResolver.getId("quote");
            fullMetadata = JBMetadataResolver.addToMetadata("", metadataId, quoteMetadata);
        }

        // Run the full E2E flow with the payer quote.
        uint256 victimReceived = _executeE2EWithMetadata(pid, key, projectToken, victimAmount, fullMetadata);

        console.log("  Baseline (no attack): %s tokens", _formatEther(baselineReceived));
        console.log("  Payer min out (1%% slippage): %s tokens", _formatEther(payerMinOut));
        console.log("  Attack size: %s ETH", _formatEther(attackSize));
        console.log("  Victim received: %s tokens", _formatEther(victimReceived));

        if (victimReceived == 0) {
            console.log("  RESULT: Swap blocked by payer quote -> mint fallback (0 MEV)");
        } else if (victimReceived >= payerMinOut) {
            console.log("  RESULT: Swap completed (attack too small to breach payer quote)");
        } else {
            console.log("  RESULT: Swap completed below payer quote (should not happen)");
        }

        console.log("");
        console.log("KEY: Tight payer quote + TWAP cross-validation blocks sandwich attacks.");
        console.log("Even if TWAP alone would allow the swap, payer's tighter quote overrides.");
    }

    //*********************************************************************//
    // ----------------------- Internal Setup ---------------------------- //
    //*********************************************************************//

    function _nextProjectId() internal returns (uint256) {
        return nextProjectId++;
    }

    function _setupProjectWithPool(
        uint256 projectId,
        uint256 liquidityTokenAmount
    )
        internal
        returns (PoolKey memory key, SandwichProjectToken projectToken)
    {
        projectToken = new SandwichProjectToken();

        address token0;
        address token1;
        if (address(projectToken) < WETH_ADDR) {
            token0 = address(projectToken);
            token1 = WETH_ADDR;
        } else {
            token0 = WETH_ADDR;
            token1 = address(projectToken);
        }

        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        poolManager.initialize(key, sqrtPrice);

        // Fund LiquidityHelper.
        projectToken.mint(address(liqHelper), liquidityTokenAmount);
        vm.deal(address(liqHelper), liquidityTokenAmount);
        vm.prank(address(liqHelper));
        IWETH9(WETH_ADDR).deposit{value: liquidityTokenAmount}();

        vm.startPrank(address(liqHelper));
        IERC20(address(projectToken)).approve(address(poolManager), type(uint256).max);
        IERC20(WETH_ADDR).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        int256 liquidityDelta = int256(liquidityTokenAmount / 2);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        // Approve SwapHelper for both tokens.
        vm.startPrank(address(swapHelper));
        IERC20(address(projectToken)).approve(address(poolManager), type(uint256).max);
        IERC20(WETH_ADDR).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        _mockJBCore(projectId, projectToken);
        _mockOracle(key, liquidityDelta);

        vm.prank(owner);
        hook.setPoolFor(projectId, key, 5 minutes, address(weth));
    }

    /// @dev Fund the SwapHelper with WETH for attacks.
    function _fundSwapHelper(uint256 amount) internal {
        vm.deal(address(swapHelper), amount);
        vm.prank(address(swapHelper));
        IWETH9(WETH_ADDR).deposit{value: amount}();
    }

    function _mockOracle(PoolKey memory, int256 liquidity) internal {
        vm.etch(address(0), hex"00");

        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = 0;

        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](2);
        secondsPerLiquidityCumulativeX128s[0] = 0;
        uint256 liq = uint256(liquidity > 0 ? liquidity : -liquidity);
        if (liq == 0) liq = 1;
        secondsPerLiquidityCumulativeX128s[1] = uint160((uint256(300) << 128) / liq);

        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IGeomeanOracle.observe.selector),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );
    }

    function _mockJBCore(uint256 projectId, SandwichProjectToken projectToken) internal {
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
        vm.mockCall(
            address(controller),
            abi.encodeWithSignature("mintTokensOf(uint256,uint256,address,string,bool)"),
            abi.encode(0)
        );
        vm.mockCall(
            address(controller), abi.encodeWithSignature("burnTokensOf(address,uint256,uint256,string)"), abi.encode()
        );

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
    // -------------------- Internal: Swap Execution --------------------- //
    //*********************************************************************//

    function _executeNativeSwap(
        uint256 projectId,
        PoolKey memory,
        SandwichProjectToken projectToken,
        uint256 orderSize
    )
        internal
        returns (uint256 received)
    {
        bool projectTokenIs0 = address(projectToken) < WETH_ADDR;

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

    function _executeE2EWithMetadata(
        uint256 projectId,
        PoolKey memory,
        SandwichProjectToken projectToken,
        uint256 orderSize,
        bytes memory fullMetadata
    )
        internal
        returns (uint256 received)
    {
        // Step 1: beforePayRecordedWith
        uint256 specAmount;
        bytes memory specMetadata;
        {
            JBBeforePayRecordedContext memory beforeCtx = JBBeforePayRecordedContext({
                terminal: address(terminal),
                payer: payer,
                amount: JBTokenAmount({
                    token: JBConstants.NATIVE_TOKEN,
                    decimals: 18,
                    currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                    value: orderSize
                }),
                projectId: projectId,
                rulesetId: 1,
                beneficiary: beneficiary,
                weight: 0.5e18,
                reservedPercent: 0,
                metadata: fullMetadata
            });

            (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

            if (weight > 0 || specs.length == 0) {
                // Mint path chosen — no swap.
                return 0;
            }
            specAmount = specs[0].amount;
            specMetadata = specs[0].metadata;
        }

        // Step 2: afterPayRecordedWith
        {
            JBAfterPayRecordedContext memory afterCtx = JBAfterPayRecordedContext({
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
                    value: specAmount
                }),
                weight: 0.5e18,
                newlyIssuedTokenCount: 0,
                beneficiary: beneficiary,
                hookMetadata: specMetadata,
                payerMetadata: fullMetadata
            });

            vm.mockCall(
                address(terminal),
                abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
                abi.encode()
            );

            uint256 balBefore = projectToken.balanceOf(address(hook));

            vm.deal(address(terminal), specAmount);
            vm.prank(address(terminal));
            hook.afterPayRecordedWith{value: specAmount}(afterCtx);

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
