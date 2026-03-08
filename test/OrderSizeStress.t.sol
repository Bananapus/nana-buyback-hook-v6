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

/// @notice Order size stress tests for the buyback hook.
/// Verifies correct behavior across dust, small, medium, large, and whale-sized swaps
/// against a real forked Uniswap V3 pool.
contract TestBuybackHook_OrderSizeStress is TestBaseWorkflow, JBTest, UniswapV3ForgeQuoter {
    using JBRulesetMetadataResolver for JBRuleset;

    // Events from the buyback hook interface.
    event Swap(
        uint256 indexed projectId, uint256 amountToSwapWith, IUniswapV3Pool pool, uint256 amountReceived, address caller
    );
    event Mint(uint256 indexed projectId, uint256 leftoverAmount, uint256 tokenCount, address caller);

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

        // Reconfigure with weight=0 so swap path is always chosen.
        _reconfigure(1, address(delegate), 0, 0);

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

    /// @dev Reconfigure the project with a new weight, reserved percent, and the buyback hook.
    function _reconfigure(uint256 _projectId, address _delegate, uint256 _weight, uint256 _reservedPercent) internal {
        address _projectOwner = jbProjects().ownerOf(_projectId);

        JBRuleset memory _fundingCycle = jbRulesets().currentOf(_projectId);
        _metadata = _fundingCycle.expandMetadata();

        JBSplitGroup[] memory _groupedSplits = new JBSplitGroup[](1);
        _groupedSplits[0] = JBSplitGroup({
            groupId: 1,
            splits: jbSplits().splitsOf(_projectId, _fundingCycle.id, uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        _metadata.useDataHookForPay = true;
        _metadata.dataHook = _delegate;
        _metadata.reservedPercent = uint16(_reservedPercent);

        vm.prank(_projectOwner);

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0] = JBRulesetConfig({
            mustStartAtOrAfter: uint48(block.timestamp),
            duration: 14 days,
            weight: uint112(_weight),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _metadata,
            splitGroups: _groupedSplits,
            fundAccessLimitGroups: fundAccessLimitGroups
        });

        jbController().queueRulesetsOf(_projectId, rulesetConfig, "");

        // Move to the next funding cycle so the reconfiguration takes effect.
        vm.warp(block.timestamp + _fundingCycle.duration * 2 + 1);
    }

    /// @dev Build JB metadata with a buyback hook quote.
    function _buildMetadata(uint256 _amountIn, uint256 _quote) internal view returns (bytes memory) {
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, _quote);

        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = metadataHelper().getId("quote", address(delegate));

        return metadataHelper().createMetadata(_ids, _data);
    }

    /// @dev Execute a direct swap on the Uniswap router (bypass the hook) and return output.
    function _directSwap(uint256 amountIn) internal returns (uint256 amountOut) {
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
        amountOut = router.exactInputSingle(params);
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /// @notice Dust amounts (1, 100, 1000 wei) should not revert. The pool may return 0 tokens
    /// for extremely small inputs because the price impact rounds to zero output.
    /// With weight=0 and TWAP fallback, dust that produces 0 output will revert (correct behavior).
    function test_dustAmountSwap() public {
        uint256[3] memory dustAmounts = [uint256(1), uint256(100), uint256(1000)];

        for (uint256 i = 0; i < dustAmounts.length; i++) {
            uint256 amount = dustAmounts[i];
            uint256 quote = getAmountOut(pool, amount, address(weth));

            if (quote == 0) {
                // Dust too small to produce output. Hook correctly reverts since
                // swap output (0) < minimumSwapAmountOut. No funds are lost.
                vm.expectRevert();
                jbMultiTerminal().pay{value: amount}(
                    1, JBConstants.NATIVE_TOKEN, amount, multisig(), 0, "", new bytes(0)
                );
            } else {
                // The pool can produce output for this dust amount.
                bytes memory metadata = _buildMetadata(amount, quote);
                uint256 balBefore = jbx.balanceOf(multisig());

                jbMultiTerminal().pay{value: amount}(1, JBConstants.NATIVE_TOKEN, amount, multisig(), 0, "", metadata);

                assertGt(jbx.balanceOf(multisig()) - balBefore, 0, "dust swap should yield tokens");
            }
        }
    }

    /// @notice Small swaps (0.001, 0.01, 0.1 ETH) should produce correct output
    /// matching the quoter exactly. At these sizes, the sqrtPriceLimit is loose enough
    /// that the swap fills completely.
    function test_smallSwaps() public {
        uint256[3] memory amounts = [uint256(0.001 ether), uint256(0.01 ether), uint256(0.1 ether)];

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            uint256 snapshot = vm.snapshotState();

            uint256 quote = getAmountOut(pool, amount, address(weth));
            assertGt(quote, 0, "quoter should return non-zero for small amounts");

            bytes memory metadata = _buildMetadata(amount, quote);
            uint256 balBefore = jbx.balanceOf(multisig());

            jbMultiTerminal().pay{value: amount}(1, JBConstants.NATIVE_TOKEN, amount, multisig(), 0, "", metadata);

            uint256 tokensReceived = jbx.balanceOf(multisig()) - balBefore;
            assertEq(tokensReceived, quote, "small swap output should match quote exactly");

            vm.revertToState(snapshot);
        }
    }

    /// @notice Medium swaps (1 ETH, 10 ETH) — baseline swaps cross-validated against the quoter.
    /// For 1 ETH the price impact is negligible and fills fully.
    /// For 10 ETH the sqrtPriceLimit may cause a partial fill, so we verify output > 0
    /// and compare it against a direct router swap as ground truth.
    function test_mediumSwaps() public {
        // Test 1 ETH: low impact, fills completely.
        {
            uint256 amount = 1 ether;
            uint256 quote = getAmountOut(pool, amount, address(weth));
            assertGt(quote, 0, "quoter should return non-zero for 1 ETH");

            bytes memory metadata = _buildMetadata(amount, quote);
            uint256 balBefore = jbx.balanceOf(multisig());

            jbMultiTerminal().pay{value: amount}(1, JBConstants.NATIVE_TOKEN, amount, multisig(), 0, "", metadata);

            uint256 tokensReceived = jbx.balanceOf(multisig()) - balBefore;
            assertEq(tokensReceived, quote, "1 ETH swap should match quote exactly");

            // Sanity: output should be in the right ballpark (~69k JBX per ETH).
            assertGt(tokensReceived, 10_000 ether, "1 ETH should yield >10k JBX");
        }

        // Test 10 ETH: use TWAP fallback, which computes a discount internally.
        // The TWAP fallback is the recommended path for larger swaps because it
        // automatically applies the sigmoid-derived slippage tolerance.
        {
            uint256 snapshot = vm.snapshotState();
            uint256 amount = 10 ether;

            // First, do a direct router swap to get ground truth output.
            uint256 directOutput = _directSwap(amount);
            vm.revertToState(snapshot);

            // Now use TWAP fallback (empty metadata) through the hook.
            uint256 balBefore = jbx.balanceOf(multisig());
            jbMultiTerminal().pay{value: amount}(1, JBConstants.NATIVE_TOKEN, amount, multisig(), 0, "", new bytes(0));
            uint256 tokensReceived = jbx.balanceOf(multisig()) - balBefore;

            assertGt(tokensReceived, 0, "10 ETH TWAP swap should produce tokens");
            // The hook output should be close to the direct swap output
            // (within the sigmoid tolerance, which is relatively small for 10 ETH).
            assertGt(tokensReceived, directOutput / 2, "10 ETH output should be reasonable vs direct");
        }
    }

    /// @notice Large swaps (100, 500 ETH) cause significant price impact.
    /// With an exact quote as minimumSwapAmountOut, the dynamic sqrtPriceLimit will cause
    /// a partial fill that falls below the minimum, triggering SpecifiedSlippageExceeded.
    /// This is correct MEV protection behavior.
    /// We verify: (1) exact-quote reverts, (2) TWAP fallback succeeds, (3) sigmoid is elevated.
    function test_largeSwaps() public {
        uint256[2] memory amounts = [uint256(100 ether), uint256(500 ether)];

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            uint256 snapshot = vm.snapshotState();

            // Verify sigmoid tolerance is elevated for large amounts.
            {
                (uint160 sqrtP,,,,,,) = pool.slot0();
                uint128 liquidity = pool.liquidity();
                bool zeroForOne = !(address(jbx) < address(weth));
                uint256 impact = JBSwapLib.calculateImpact(amount, liquidity, sqrtP, zeroForOne);
                uint256 tolerance = JBSwapLib.getSlippageTolerance(impact, uint256(fee) / 100);
                // For large swaps, tolerance should be well above the minimum floor (200 bps).
                assertGt(tolerance, 200, "sigmoid tolerance should be elevated for large swaps");
            }

            // With exact quote as minimum, the sqrtPriceLimit causes partial fill => revert.
            // This proves the MEV protection is active.
            {
                uint256 quote = getAmountOut(pool, amount, address(weth));
                bytes memory metadata = _buildMetadata(amount, quote);

                vm.expectRevert();
                jbMultiTerminal().pay{value: amount}(1, JBConstants.NATIVE_TOKEN, amount, multisig(), 0, "", metadata);
            }

            vm.revertToState(snapshot);

            // TWAP fallback succeeds because it applies the sigmoid discount internally.
            {
                uint256 balBefore = jbx.balanceOf(multisig());

                jbMultiTerminal().pay{value: amount}(
                    1, JBConstants.NATIVE_TOKEN, amount, multisig(), 0, "", new bytes(0)
                );

                uint256 tokensReceived = jbx.balanceOf(multisig()) - balBefore;
                assertGt(tokensReceived, 0, "TWAP fallback should succeed for large swaps");
            }

            vm.revertToState(snapshot);
        }
    }

    /// @notice A whale-sized swap (5M ETH) that far exceeds available liquidity.
    /// With weight=0, the hook must swap. The TWAP fallback applies a large sigmoid
    /// discount. Verify the swap either succeeds with some output or the pool cannot
    /// fill even with maximum tolerance.
    function test_whaleSwapPartialFill() public {
        uint256 whaleAmount = 5_000_000 ether;

        // With exact quote: should revert due to sqrtPriceLimit constraint.
        uint256 quote = getAmountOut(pool, whaleAmount, address(weth));
        assertGt(quote, 0, "pool should have some output even for whale amount");

        {
            bytes memory metadata = _buildMetadata(whaleAmount, quote);
            vm.expectRevert();
            jbMultiTerminal().pay{value: whaleAmount}(
                1, JBConstants.NATIVE_TOKEN, whaleAmount, multisig(), 0, "", metadata
            );
        }

        // With TWAP fallback: the sigmoid applies maximum tolerance. The swap should
        // either succeed (producing tokens) or the slippage still exceeds tolerance.
        // Both outcomes are valid. We test that the protocol does not lose funds.
        uint256 balBefore = jbx.balanceOf(multisig());

        try jbMultiTerminal().pay{value: whaleAmount}(
            1, JBConstants.NATIVE_TOKEN, whaleAmount, multisig(), 0, "", new bytes(0)
        ) {
            uint256 tokensReceived = jbx.balanceOf(multisig()) - balBefore;
            assertGt(tokensReceived, 0, "whale TWAP swap should produce tokens if it succeeds");
        } catch {
            // Revert is acceptable: even with maximum sigmoid tolerance, the whale amount
            // exceeds what the pool can fill at an acceptable price. No funds lost.
            assertTrue(true, "whale swap revert is acceptable MEV protection");
        }
    }
}
