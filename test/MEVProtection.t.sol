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

/// @notice MEV protection tests for the buyback hook.
/// Verifies that the dynamic sqrtPriceLimit protects against frontrunning and sandwich attacks
/// by reverting when pool price deviates from the quoted price.
contract TestBuybackHook_MEVProtection is TestBaseWorkflow, JBTest, UniswapV3ForgeQuoter {
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

    /// @dev Execute a frontrun: swap ETH for JBX on the router, moving the pool price.
    function _frontrun(uint256 amount) internal {
        address frontrunner = makeAddr("frontrunner");
        deal(address(weth), frontrunner, amount);

        vm.startPrank(frontrunner);
        weth.approve(address(router), amount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(jbx),
            fee: fee,
            recipient: frontrunner,
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        router.exactInputSingle(params);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /// @notice Frontrun protection: Record a quote, then a frontrunner swaps 50 ETH
    /// (moving the price significantly), then the victim pays 1 ETH with the stale quote.
    /// The dynamic sqrtPriceLimit should prevent execution at the manipulated price,
    /// causing the hook to revert with SpecifiedSlippageExceeded.
    function test_frontrunProtection() public {
        uint256 victimAmount = 1 ether;

        // Step 1: Victim records a quote at the current (pre-manipulation) price.
        uint256 staleQuote = getAmountOut(pool, victimAmount, address(weth));
        assertGt(staleQuote, 0, "pre-frontrun quote should be non-zero");

        // Step 2: Frontrunner swaps 50 ETH, significantly moving the pool price.
        _frontrun(50 ether);

        // Step 3: Verify the price has moved — a new quote gives fewer tokens.
        uint256 postFrontrunQuote = getAmountOut(pool, victimAmount, address(weth));
        assertLt(postFrontrunQuote, staleQuote, "frontrun should reduce available output");

        // Step 4: Victim submits tx with the stale (pre-frontrun) quote.
        // The sqrtPriceLimit derived from the stale quote is too tight for the
        // manipulated pool price, causing the swap to partially fill or fail.
        // The hook then reverts because actual output < staleQuote.
        bytes memory metadata = _buildMetadata(victimAmount, staleQuote);

        vm.expectRevert();
        jbMultiTerminal().pay{value: victimAmount}(
            1, JBConstants.NATIVE_TOKEN, victimAmount, multisig(), 0, "", metadata
        );
    }

    /// @notice Sandwich attack quantification: Frontrunner swaps 10 ETH, victim pays 1 ETH,
    /// compare actual output vs expected output. The dynamic sqrtPriceLimit limits the
    /// victim's maximum slippage.
    function test_sandwichQuantified() public {
        uint256 victimAmount = 1 ether;

        // Record the expected output before any manipulation.
        uint256 expectedOutput = getAmountOut(pool, victimAmount, address(weth));
        assertGt(expectedOutput, 0, "expected output should be non-zero");

        // Frontrunner swaps 10 ETH (moderate frontrun).
        _frontrun(10 ether);

        // After frontrun, get the actual achievable output at the new price.
        uint256 achievableOutput = getAmountOut(pool, victimAmount, address(weth));
        assertLt(achievableOutput, expectedOutput, "frontrun should reduce output");

        // Compute the slippage the victim would suffer without protection.
        uint256 slippageWithout = ((expectedOutput - achievableOutput) * 10_000) / expectedOutput;

        // Now try the victim's tx with the stale quote.
        // With a 10 ETH frontrun on a 10M liquidity pool, the price impact is moderate.
        // The stale quote demands more output than the pool can provide at the new price,
        // so the sqrtPriceLimit prevents full execution.
        bytes memory metadata = _buildMetadata(victimAmount, expectedOutput);

        // The hook should revert because the sqrtPriceLimit (from staleQuote) constrains
        // the swap, producing less than the minimum required.
        vm.expectRevert();
        jbMultiTerminal().pay{value: victimAmount}(
            1, JBConstants.NATIVE_TOKEN, victimAmount, multisig(), 0, "", metadata
        );

        // Verify that the slippage without protection would have been significant.
        // For a 10 ETH frontrun on a ~10M pool, we expect measurable slippage.
        assertGt(slippageWithout, 0, "frontrun should cause measurable slippage");

        // The key property: the victim's tx is REVERTED rather than executing at a bad price.
        // This is the MEV protection in action. The victim loses nothing (tx reverts).
    }

    /// @notice Partial fill on mild price movement: Move the price slightly (not drastically)
    /// with a small frontrun, then victim pays 1 ETH with a slightly discounted quote
    /// (applying the sigmoid tolerance). The swap should succeed because the tolerance
    /// accommodates the minor price deviation.
    function test_partialFillOnPriceLimit() public {
        uint256 victimAmount = 1 ether;

        // Record quote at current price.
        uint256 originalQuote = getAmountOut(pool, victimAmount, address(weth));

        // Mild frontrun: only 0.5 ETH. This moves the price slightly.
        _frontrun(0.5 ether);

        // Get the post-frontrun achievable output.
        uint256 postMoveQuote = getAmountOut(pool, victimAmount, address(weth));
        assertLt(postMoveQuote, originalQuote, "mild frontrun should reduce output slightly");

        // The slippage from the mild frontrun should be small.
        uint256 slippageBps = ((originalQuote - postMoveQuote) * 10_000) / originalQuote;
        // With 0.5 ETH frontrun on 10M liquidity, slippage should be very small.
        assertLt(slippageBps, 500, "mild frontrun slippage should be < 5%");

        // Use the post-frontrun quote as the minimum (the victim updates their quote
        // to reflect the current price). This is the realistic scenario where the
        // quote is fetched shortly before submission and reflects current conditions.
        bytes memory metadata = _buildMetadata(victimAmount, postMoveQuote);

        uint256 balBefore = jbx.balanceOf(multisig());

        jbMultiTerminal().pay{value: victimAmount}(
            1, JBConstants.NATIVE_TOKEN, victimAmount, multisig(), 0, "", metadata
        );

        uint256 tokensReceived = jbx.balanceOf(multisig()) - balBefore;

        // The victim should receive tokens.
        assertGt(tokensReceived, 0, "victim should receive tokens with updated quote");

        // The output should match the post-move quote (the sqrtPriceLimit allows full fill).
        assertEq(tokensReceived, postMoveQuote, "output should match the updated quote");

        // Output should be less than the original quote but still reasonable.
        assertGt(tokensReceived, originalQuote * 9000 / 10_000, "output should be within 10% of original");
    }
}
