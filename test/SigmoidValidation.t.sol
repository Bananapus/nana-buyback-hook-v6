// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "src/interfaces/external/IWETH9.sol";
import /* {*} from */ "@bananapus/core-v5/test/helpers/TestBaseWorkflow.sol";
import {MetadataResolverHelper} from "@bananapus/core-v5/test/helpers/MetadataResolverHelper.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@exhausted-pigeon/uniswap-v3-forge-quoter/src/UniswapV3ForgeQuoter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "src/JBBuybackHook.sol";
import {JBSwapLib} from "src/libraries/JBSwapLib.sol";
import {mulDiv, mulDiv18} from "@prb/math/src/Common.sol";

/// @notice Sigmoid validation tests for the buyback hook.
/// Verifies that the sigmoid slippage tolerance computed by JBSwapLib matches real swap
/// behavior on a forked Uniswap V3 pool, scales monotonically, respects pool fees,
/// and maintains precision at the smallest possible inputs.
contract TestBuybackHook_SigmoidValidation is TestBaseWorkflow, JBTest, UniswapV3ForgeQuoter {
    using JBRulesetMetadataResolver for JBRuleset;

    // Constants
    IUniswapV3Factory constant factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IJBToken jbx;
    IWETH9 constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    uint24 constant fee = 10_000;

    ISwapRouter router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IUniswapV3Pool pool;

    JBRulesetMetadata _metadata;
    JBFundAccessLimitGroup[] fundAccessLimitGroups;

    JBBuybackHook delegate;

    // sqrtPriceX96 for 1 ETH = 69,420 JBX
    uint160 _sqrtPriceX96 = 300_702_666_377_442_711_115_399_168;

    function initMetadata() internal {
        _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(JBConstants.NATIVE_TOKEN))),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: true,
            useDataHookForCashOut: false,
            dataHook: address(delegate),
            metadata: 0
        });
    }

    function launchProject() internal {
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        {
            JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](0);
            JBCurrencyAmount[] memory _surplusAllowances = new JBCurrencyAmount[](1);
            _surplusAllowances[0] =
                JBCurrencyAmount({amount: 5 * 10 ** 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

            _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
                terminal: address(jbMultiTerminal()),
                token: JBConstants.NATIVE_TOKEN,
                payoutLimits: _payoutLimits,
                surplusAllowances: _surplusAllowances
            });
        }

        {
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].duration = 0;
            _rulesetConfigurations[0].weight = 1000 * 10 ** 18;
            _rulesetConfigurations[0].weightCutPercent = 0;
            _rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
            JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);

            _tokensToAccept[0] = JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });

            _terminalConfigurations[0] =
                JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokensToAccept});

            jbController()
                .launchProjectFor({
                    owner: multisig(),
                    projectUri: "whatever",
                    rulesetConfigurations: _rulesetConfigurations,
                    terminalConfigurations: _terminalConfigurations,
                    memo: ""
                });

            vm.prank(multisig());
            jbx = jbController().deployERC20For(1, "JUICEBOXXX", "JBX", bytes32(0));
        }
    }

    function setUp() public override {
        vm.createSelectFork(
            "https://rpc.ankr.com/eth/4bdda9badb97f42aa5cc09055318c1ae2e4d3c0a449ebdf8bf4fe6969b20772a", 17_962_427
        );

        super.setUp();

        delegate = new JBBuybackHook({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            projects: jbProjects(),
            prices: jbPrices(),
            weth: weth,
            factory: address(factory),
            trustedForwarder: address(0)
        });

        initMetadata();
        launchProject();

        // Create Uniswap V3 pool (JBX/WETH) at ~69,420 JBX per ETH.
        pool = IUniswapV3Pool(factory.createPool(address(weth), address(jbx), fee));
        pool.initialize(_sqrtPriceX96);

        // Provide full-range liquidity.
        address LP = makeAddr("LP");
        vm.prank(multisig());
        jbController().mintTokensOf(1, 10_000_000 ether, LP, "", false);

        vm.startPrank(LP, LP);
        deal(address(weth), LP, 10_000_000 ether);

        address POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
        IERC20(address(jbx)).approve(POSITION_MANAGER, 10_000_000 ether);
        weth.approve(POSITION_MANAGER, 10_000_000 ether);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(jbx),
            token1: address(weth),
            fee: fee,
            tickLower: -840_000,
            tickUpper: 840_000,
            amount0Desired: 10_000_000 ether,
            amount1Desired: 10_000_000 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: LP,
            deadline: block.timestamp
        });

        INonfungiblePositionManager(POSITION_MANAGER).mint(params);
        vm.stopPrank();

        // Set pool for the buyback hook.
        vm.prank(jbProjects().ownerOf(1));
        delegate.setPoolFor(1, fee, 2 minutes, address(weth));

        // Prime pool with a swap to create oracle observations.
        _primePool();

        vm.label(address(pool), "uniswapPool");
        vm.label(address(factory), "uniswapFactory");
        vm.label(address(weth), "$WETH");
        vm.label(address(jbx), "$JBX");
        vm.label(address(delegate), "delegate");
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _primePool() internal {
        uint256 amountIn = 1 ether;
        deal(address(weth), address(this), 1 ether);
        weth.approve(address(router), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(jbx),
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        router.exactInputSingle(params);

        vm.warp(block.timestamp + 2 minutes);
        pool.increaseObservationCardinalityNext(2 minutes);
    }

    /// @dev Get pool state for sigmoid calculations.
    function _getPoolState() internal view returns (uint160 sqrtP, uint128 liquidity, bool zeroForOne) {
        (sqrtP,,,,,,) = pool.slot0();
        liquidity = pool.liquidity();
        // Swap direction: selling WETH for JBX.
        // If jbx < weth, jbx is token0, weth is token1. Selling token1 = !zeroForOne = false.
        // The hook uses zeroForOne = !projectTokenIs0.
        zeroForOne = !(address(jbx) < address(weth));
    }

    /// @dev Execute a direct swap on the router and measure actual slippage.
    function _measureSlippage(uint256 amountIn) internal returns (uint256 slippageBps) {
        // Ideal output: output at the current spot price (no impact).
        // We approximate this by getting the quote for a tiny amount and scaling.
        uint256 tinyQuote = getAmountOut(pool, 0.0001 ether, address(weth));
        uint256 idealOutput = (tinyQuote * amountIn) / 0.0001 ether;

        // Actual output from a real swap.
        deal(address(weth), address(this), amountIn);
        weth.approve(address(router), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(jbx),
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 actualOutput = router.exactInputSingle(params);

        // Slippage = (ideal - actual) / ideal, in basis points.
        if (idealOutput > actualOutput) {
            slippageBps = ((idealOutput - actualOutput) * 10_000) / idealOutput;
        }
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /// @notice For 5 different amounts (0.01, 0.1, 1, 10, 100 ETH):
    /// compute the sigmoid tolerance via JBSwapLib, execute a real swap,
    /// and verify that the actual slippage is within the predicted tolerance.
    function test_sigmoidMatchesRealSlippage() public {
        uint256[5] memory amounts =
            [uint256(0.01 ether), uint256(0.1 ether), uint256(1 ether), uint256(10 ether), uint256(100 ether)];

        uint256 poolFeeBps = uint256(fee) / 100; // 100 bps

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            uint256 snapshot = vm.snapshotState();

            // Get pool state and compute sigmoid tolerance.
            (uint160 sqrtP, uint128 liquidity, bool zeroForOne) = _getPoolState();
            uint256 impact = JBSwapLib.calculateImpact(amount, liquidity, sqrtP, zeroForOne);
            uint256 tolerance = JBSwapLib.getSlippageTolerance(impact, poolFeeBps);

            // Execute a real swap and measure actual slippage.
            uint256 actualSlippage = _measureSlippage(amount);

            // The sigmoid tolerance should be >= actual slippage.
            // This proves the tolerance is sufficient to protect against expected price impact.
            assertGe(
                tolerance,
                actualSlippage,
                string(
                    abi.encodePacked("sigmoid tolerance should cover actual slippage for amount index ", vm.toString(i))
                )
            );

            vm.revertToState(snapshot);
        }
    }

    /// @notice Verify that the sigmoid tolerance increases monotonically as swap size grows.
    /// This ensures larger swaps get proportionally wider slippage protection.
    function test_sigmoidScalesWithImpact() public view {
        uint256[7] memory amounts = [
            uint256(0.001 ether),
            uint256(0.01 ether),
            uint256(0.1 ether),
            uint256(1 ether),
            uint256(10 ether),
            uint256(100 ether),
            uint256(1000 ether)
        ];

        uint256 poolFeeBps = uint256(fee) / 100;
        (uint160 sqrtP, uint128 liquidity, bool zeroForOne) = _getPoolState();

        uint256 prevTolerance = 0;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 impact = JBSwapLib.calculateImpact(amounts[i], liquidity, sqrtP, zeroForOne);
            uint256 tolerance = JBSwapLib.getSlippageTolerance(impact, poolFeeBps);

            // Tolerance should be monotonically non-decreasing with amount.
            assertGe(tolerance, prevTolerance, "tolerance should not decrease as amount increases");
            prevTolerance = tolerance;
        }

        // The smallest amount should have a low tolerance (near minimum).
        uint256 smallImpact = JBSwapLib.calculateImpact(amounts[0], liquidity, sqrtP, zeroForOne);
        uint256 smallTolerance = JBSwapLib.getSlippageTolerance(smallImpact, poolFeeBps);

        // The largest amount should have a significantly higher tolerance.
        uint256 largeImpact = JBSwapLib.calculateImpact(amounts[6], liquidity, sqrtP, zeroForOne);
        uint256 largeTolerance = JBSwapLib.getSlippageTolerance(largeImpact, poolFeeBps);

        assertGt(largeTolerance, smallTolerance, "large swap should have higher tolerance than small");
    }

    /// @notice Verify that higher pool fees lead to higher minimum tolerance.
    /// The sigmoid formula uses poolFeeBps to set the floor: minSlippage = poolFee + 100 bps.
    function test_sigmoidRespectsPoolFee() public view {
        // Use a fixed impact value for comparison.
        (uint160 sqrtP, uint128 liquidity, bool zeroForOne) = _getPoolState();
        uint256 impact = JBSwapLib.calculateImpact(1 ether, liquidity, sqrtP, zeroForOne);

        // Test different fee tiers and verify tolerance increases.
        uint256[4] memory feeBpsValues = [uint256(5), uint256(30), uint256(100), uint256(500)];
        // Corresponding to 0.05%, 0.3%, 1%, 5% pool fees.

        uint256 prevTolerance = 0;

        for (uint256 i = 0; i < feeBpsValues.length; i++) {
            uint256 tolerance = JBSwapLib.getSlippageTolerance(impact, feeBpsValues[i]);

            // Higher fee should yield higher or equal tolerance.
            assertGe(tolerance, prevTolerance, "higher pool fee should yield higher tolerance");
            prevTolerance = tolerance;
        }

        // Verify the floor behavior: with zero impact, tolerance = minSlippage = max(poolFee + 100, 200).
        uint256 zeroImpactLowFee = JBSwapLib.getSlippageTolerance(0, 5);
        assertEq(zeroImpactLowFee, 200, "zero impact + low fee should hit 200 bps floor");

        uint256 zeroImpactHighFee = JBSwapLib.getSlippageTolerance(0, 500);
        assertEq(zeroImpactHighFee, 600, "zero impact + 500 bps fee should yield 600 bps");

        // High fee tolerance should exceed low fee tolerance.
        assertGt(zeroImpactHighFee, zeroImpactLowFee, "higher fee should produce higher minimum tolerance");
    }

    /// @notice Verify that the 1e18 IMPACT_PRECISION prevents rounding to zero for small
    /// but realistic swaps. Without 1e18, a 0.001 ETH swap in a deep pool would have
    /// impact = 0 (using the old 1e5 precision). With 1e18, even small swaps register
    /// non-zero impact.
    ///
    /// Also verify that the absolute minimum (1 wei) correctly returns 0 impact and
    /// the sigmoid gracefully handles it by returning the floor tolerance.
    function test_impactPrecisionNoRounding() public view {
        (uint160 sqrtP, uint128 liquidity, bool zeroForOne) = _getPoolState();

        // Part 1: Verify 1e18 precision captures small swap impact.
        // 0.001 ETH (1e15 wei) in a pool with ~3.8e22 liquidity.
        // With old 1e5 precision: base = mulDiv(1e15, 1e5, 3.8e22) ≈ 0 (rounds to 0).
        // With 1e18 precision: base = mulDiv(1e15, 1e18, 3.8e22) ≈ 2.6e10 (non-zero!).
        uint256 smallAmount = 0.001 ether;
        uint256 smallImpact = JBSwapLib.calculateImpact(smallAmount, liquidity, sqrtP, zeroForOne);
        assertGt(smallImpact, 0, "0.001 ETH impact should be non-zero with 1e18 precision");

        // Verify the old precision (1e5) would have rounded this to zero.
        // base_old = mulDiv(1e15, 1e5, 3.8e22) = 1e20 / 3.8e22 ≈ 0.0026 → rounds to 0.
        uint256 baseOldPrecision = mulDiv(smallAmount, 1e5, uint256(liquidity));
        assertEq(baseOldPrecision, 0, "old 1e5 precision should round small swap base to 0");

        // Part 2: 1 wei truly is too small even for 1e18 precision in a deep pool.
        // base = mulDiv(1, 1e18, 3.8e22) ≈ 0.000026 → rounds to 0.
        // This is acceptable: 1 wei has essentially zero market impact.
        uint256 weiImpact = JBSwapLib.calculateImpact(1, liquidity, sqrtP, zeroForOne);
        assertEq(weiImpact, 0, "1 wei impact should be 0 in a deep pool (too small)");

        // Part 3: The sigmoid gracefully handles zero impact by returning the floor.
        uint256 tolerance = JBSwapLib.getSlippageTolerance(0, uint256(fee) / 100);
        // Floor = max(poolFee + 100, 200) = max(100 + 100, 200) = 200.
        assertEq(tolerance, 200, "zero impact should yield minimum floor tolerance");

        // Part 4: Verify 0.001 ETH tolerance is very close to the floor.
        // The impact (~6.9e12) relative to SIGMOID_K (5e16) adds ~1 bps via the sigmoid.
        // tolerance = 200 + (8600 * 6.9e12) / (6.9e12 + 5e16) ≈ 200 + 1 = 201.
        uint256 smallTolerance = JBSwapLib.getSlippageTolerance(smallImpact, uint256(fee) / 100);
        assertLe(smallTolerance, 210, "tiny impact tolerance should be near floor (within 10 bps)");
        assertGe(smallTolerance, 200, "tiny impact tolerance should be at least the floor");
    }
}
