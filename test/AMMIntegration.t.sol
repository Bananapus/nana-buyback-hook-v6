// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "src/interfaces/external/IWETH9.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {MetadataResolverHelper} from "@bananapus/core-v6/test/helpers/MetadataResolverHelper.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@exhausted-pigeon/uniswap-v3-forge-quoter/src/UniswapV3ForgeQuoter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "src/JBBuybackHook.sol";
import {JBSwapLib} from "src/libraries/JBSwapLib.sol";
import {mulDiv, mulDiv18} from "@prb/math/src/Common.sol";

/// @notice End-to-end AMM integration tests for the buyback hook.
/// Verifies full swap flow, mint fallback, partial swap with leftover,
/// TWAP fallback, and slippage revert behavior against a real forked Uniswap V3 pool.
contract TestBuybackHook_AMMIntegration is TestBaseWorkflow, JBTest, UniswapV3ForgeQuoter {
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

    uint256 constant price = 69_420 ether;
    uint32 constant cardinality = 2 minutes;
    uint24 constant fee = 10_000;
    uint256 constant amountPaid = 1 ether;

    ISwapRouter router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IUniswapV3Pool pool;

    JBRulesetMetadata _metadata;
    JBFundAccessLimitGroup[] fundAccessLimitGroups;

    JBBuybackHook delegate;

    // sqrtPriceX96 for 1 ETH = 69,420 JBX
    uint160 sqrtPriceX96 = 300_702_666_377_442_711_115_399_168;

    uint256 amountOutQuoted;

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
        pool.initialize(sqrtPriceX96);

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

        amountOutQuoted = getAmountOut(pool, 1 ether, address(weth));

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

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /// @notice When weight=0, swapping is always better than minting. The full payment should be
    ///         routed through the Uniswap V3 pool and the beneficiary should receive the quoted
    ///         amount of project tokens.
    function test_fullPaySwapFlow() public {
        // Weight = 0 so minting yields 0 tokens; swap is always better.
        _reconfigure(1, address(delegate), 0, 0);

        // Get a fresh quote for 1 ETH.
        uint256 quote = getAmountOut(pool, 1 ether, address(weth));

        // Build metadata with the quote.
        bytes memory metadata = _buildMetadata(1 ether, quote);

        uint256 balBefore = jbx.balanceOf(multisig());

        // Expect the Swap event with the correct amounts.
        vm.expectEmit(true, true, true, true);
        emit Swap(1, 1 ether, pool, quote, address(jbMultiTerminal()));

        // Pay 1 ETH to the project.
        jbMultiTerminal().pay{value: 1 ether}(
            1, JBConstants.NATIVE_TOKEN, 1 ether, multisig(), 0, "test_fullPaySwapFlow", metadata
        );

        uint256 balAfter = jbx.balanceOf(multisig());

        // Beneficiary receives exactly the quoted amount (reserved percent is 0).
        assertEq(balAfter - balBefore, quote, "beneficiary should receive quoted token amount");
    }

    /// @notice When the project weight is very high, minting yields more tokens than swapping.
    ///         The hook should return the original weight and skip the swap entirely, resulting in
    ///         a standard JB mint.
    function test_fullPayMintFlow() public {
        // Set an extremely high weight so minting far exceeds any possible swap output.
        uint256 highWeight = 1_000_000 ether;
        _reconfigure(1, address(delegate), highWeight, 0);

        // Get a real swap quote; it will be far less than what minting yields.
        uint256 quote = getAmountOut(pool, 1 ether, address(weth));
        uint256 mintAmount = mulDiv18(highWeight, 1 ether);
        assertTrue(mintAmount > quote, "mint amount should exceed swap quote for this test");

        // Build metadata with the swap quote (which is less than mint amount).
        bytes memory metadata = _buildMetadata(1 ether, quote);

        uint256 balBefore = jbx.balanceOf(multisig());

        // Expect the IJBTokens.Mint event (standard mint, not a swap).
        vm.expectEmit(true, true, true, true);
        emit IJBTokens.Mint({
            holder: multisig(),
            projectId: 1,
            count: mintAmount,
            tokensWereClaimed: true,
            caller: address(jbController())
        });

        // Pay 1 ETH.
        jbMultiTerminal().pay{value: 1 ether}(
            1, JBConstants.NATIVE_TOKEN, 1 ether, multisig(), 0, "test_fullPayMintFlow", metadata
        );

        uint256 balAfter = jbx.balanceOf(multisig());

        // Beneficiary receives the weight-derived mint amount.
        assertEq(balAfter - balBefore, mintAmount, "beneficiary should receive weight-derived mint amount");
    }

    /// @notice When metadata specifies a swap amount smaller than the total payment, the hook
    ///         swaps a portion and mints with the remainder. Both outputs should be credited to
    ///         the beneficiary.
    function test_partialSwapWithLeftover() public {
        // Use the initial project configuration (weight = 1000e18, reservedPercent = 0).
        // The hook's beforePayRecordedWith compares swap output vs mint output for the swap portion.
        // With weight = 1000e18 and 0.5 ETH, mint yields 500e18 tokens. Swap yields ~34,000e18.
        // Since swap > mint, the swap path is chosen.
        // The leftover 0.5 ETH is minted via the hook's afterPayRecordedWith at the ruleset weight.

        // Get the current ruleset weight (from setUp's launchProject, 1000e18).
        JBRuleset memory currentRuleset = jbRulesets().currentOf(1);
        uint256 rulesetWeight = currentRuleset.weight;

        // Swap only 0.5 ETH of a 1 ETH payment.
        uint256 swapAmount = 0.5 ether;
        uint256 leftoverAmount = 0.5 ether;
        uint256 swapQuote = getAmountOut(pool, swapAmount, address(weth));

        // Sanity: swap output exceeds mint output for the swap portion so the swap path is chosen.
        uint256 mintForSwapPortion = mulDiv(swapAmount, rulesetWeight, 1e18);
        assertTrue(swapQuote > mintForSwapPortion, "swap should be better than mint for test to be valid");

        // Build metadata specifying only 0.5 ETH for the swap.
        bytes memory metadata = _buildMetadata(swapAmount, swapQuote);

        uint256 balBefore = jbx.balanceOf(multisig());

        // Expect the Swap event for the partial amount.
        vm.expectEmit(true, true, true, true);
        emit Swap(1, swapAmount, pool, swapQuote, address(jbMultiTerminal()));

        // Pay 1 ETH total.
        jbMultiTerminal().pay{value: 1 ether}(
            1, JBConstants.NATIVE_TOKEN, 1 ether, multisig(), 0, "test_partialSwapWithLeftover", metadata
        );

        uint256 balAfter = jbx.balanceOf(multisig());
        uint256 tokensReceived = balAfter - balBefore;

        // The hook mints: swapQuote + mulDiv(amountToMintWith, context.weight, weightRatio)
        // where amountToMintWith = totalPaid - amountToSwapWith = 0.5 ETH
        // and context.weight = rulesetWeight, weightRatio = 1e18 (same currency).
        uint256 expectedMintFromLeftover = mulDiv(leftoverAmount, rulesetWeight, 1e18);

        // Beneficiary receives tokens from swap + tokens minted from the leftover.
        assertGe(tokensReceived, swapQuote, "should receive at least swap output");
        assertApproxEqAbs(
            tokensReceived, swapQuote + expectedMintFromLeftover, 1, "should receive swap + leftover mint"
        );
        // Verify both components are non-zero, confirming the partial swap actually happened.
        assertGt(swapQuote, 0, "swap output should be non-zero");
        assertGt(expectedMintFromLeftover, 0, "leftover mint should be non-zero");
    }

    /// @notice When no quote is provided in metadata, the hook falls back to the TWAP oracle to
    ///         determine a minimum swap output. The swap should still execute successfully.
    function test_twapFallbackSwap() public {
        // Weight = 0 so swap is always preferred.
        _reconfigure(1, address(delegate), 0, 0);

        // Re-prime the pool so TWAP has fresh observations.
        _primePool();

        uint256 balBefore = jbx.balanceOf(multisig());

        // Pay without any metadata (empty bytes triggers TWAP fallback).
        jbMultiTerminal().pay{value: 1 ether}(
            1, JBConstants.NATIVE_TOKEN, 1 ether, multisig(), 0, "test_twapFallbackSwap", new bytes(0)
        );

        uint256 balAfter = jbx.balanceOf(multisig());
        uint256 tokensReceived = balAfter - balBefore;

        // The beneficiary should receive a non-trivial amount of tokens from the TWAP-guided swap.
        assertGt(tokensReceived, 0, "should receive tokens from TWAP fallback swap");

        // Sanity check: the amount should be in the ballpark of the quoted amount.
        // We don't assert exact equality because the TWAP-derived minimum may differ from a
        // spot quote, but it should be within the same order of magnitude.
        uint256 spotQuote = getAmountOut(pool, 1 ether, address(weth));
        assertGt(tokensReceived, spotQuote / 2, "tokens received should be within reasonable range of spot");
    }

    /// @notice When the pool price moves significantly before a payment, a stale quote leads to
    ///         the swap hitting the sqrtPriceLimit or returning fewer tokens than the minimum.
    ///         The hook should revert with JBBuybackHook_SpecifiedSlippageExceeded.
    function test_swapRevertsOnExcessiveSlippage() public {
        // Weight = 0 so swap path is chosen.
        _reconfigure(1, address(delegate), 0, 0);

        // Get a quote at the current (pre-move) price.
        uint256 staleQuote = getAmountOut(pool, 1 ether, address(weth));

        // Move the pool price significantly by doing a large swap (500 ETH -> JBX).
        deal(address(weth), address(this), 500 ether);
        weth.approve(address(router), 500 ether);
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(jbx),
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: 500 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        router.exactInputSingle(swapParams);

        // Build metadata with the now-stale (too optimistic) quote.
        bytes memory metadata = _buildMetadata(1 ether, staleQuote);

        // The swap should either:
        // 1. Hit the sqrtPriceLimit (derived from staleQuote) and return less than staleQuote, OR
        // 2. The pool.swap itself reverts and _swap returns 0.
        // In either case, afterPayRecordedWith reverts with SpecifiedSlippageExceeded
        // because exactSwapAmountOut < minimumSwapAmountOut (= staleQuote).
        vm.expectRevert();

        // Pay 1 ETH with the stale quote.
        jbMultiTerminal().pay{value: 1 ether}(
            1, JBConstants.NATIVE_TOKEN, 1 ether, multisig(), 0, "test_swapRevertsOnExcessiveSlippage", metadata
        );
    }
}
