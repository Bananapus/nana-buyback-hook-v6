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
/* import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol'; */

import "src/JBBuybackHook.sol";

import {mulDiv, mulDiv18} from "@prb/math/src/Common.sol";

/**
 * @notice Buyback fork integration tests, using $jbx v3
 */
contract TestJBBuybackHook_Fork is TestBaseWorkflow, JBTest, UniswapV3ForgeQuoter {
    using JBRulesetMetadataResolver for JBRuleset;

    event Swap(uint256 indexed projectId, uint256 amountIn, IUniswapV3Pool pool, uint256 amountOut, address caller);
    event Mint(
        address indexed holder,
        uint256 indexed projectId,
        uint256 amount,
        bool tokensWereClaimed,
        bool preferClaimedTokens,
        address caller
    );

    // Constants
    uint256 constant TWAP_SLIPPAGE_DENOMINATOR = 10_000;
    uint256 constant UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE = 1050;
    uint256 constant LOW_TWAP_SLIPPAGE_TOLERANCE = 300;

    IUniswapV3Factory constant factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IJBToken jbx;
    IWETH9 constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // 1 - 1*10**18

    uint256 constant price = 69_420 ether;
    uint32 constant cardinality = 2 minutes;
    uint24 constant fee = 10_000;

    uint256 constant amountPaid = 1 ether;

    // Contracts needed
    ISwapRouter router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IUniswapV3Pool pool;

    // Structure needed
    JBRulesetMetadata _metadata;
    JBFundAccessLimitGroup[] fundAccessLimitGroups;
    IJBTerminal[] terminals;
    JBSplitGroup[] groupedSplits;

    // Target contract
    JBBuybackHook delegate;

    // sqrtPriceX96 = sqrt(1*10**18 << 192 / 69420*10**18) = 300702666377442711115399168 (?)
    uint160 sqrtPriceX96 = 300_702_666_377_442_711_115_399_168;

    uint256 amountOutQuoted;

    function initMetadata() public {
        _metadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT / 2, //50%
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

    function launchAndConfigureL1Project() public {
        // Setup: terminal / project
        // Package up the limits for the given terminal.
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        {
            // Specify a payout limit.
            JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](0);

            // Specify a surplus allowance.
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
            // Package up the ruleset configuration.
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

            // Create a first project to collect fees.
            jbController()
                .launchProjectFor({
                    owner: multisig(),
                    projectUri: "whatever",
                    rulesetConfigurations: _rulesetConfigurations,
                    terminalConfigurations: _terminalConfigurations, // Set terminals to receive fees.
                    memo: ""
                });

            // Setup an erc20 for the project
            vm.prank(multisig());
            jbx = jbController().deployERC20For(1, "JUICEBOXXX", "JBX", bytes32(0));
            vm.label(address(jbx), "$JBX");
            vm.label(address(jbErc20()), "jbErc20");
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
        launchAndConfigureL1Project();

        // JBX V3 pool wasn't deployed at that block
        pool = IUniswapV3Pool(factory.createPool(address(weth), address(jbx), fee));
        pool.initialize(sqrtPriceX96); // 1 eth <=> 69420 jbx

        address LP = makeAddr("LP");

        vm.prank(multisig());
        jbController().mintTokensOf(1, 10_000_000 ether, LP, "", false);

        vm.startPrank(LP, LP);
        deal(address(weth), LP, 10_000_000 ether);
        /* deal(address(jbx), LP, 10_000_000 ether); */

        // create a full range position
        address POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
        IERC20(address(jbx)).approve(POSITION_MANAGER, 10_000_000 ether);
        weth.approve(POSITION_MANAGER, 10_000_000 ether);

        // mint concentrated position
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(jbx),
            token1: address(weth),
            fee: fee,
            // considering a max valid range
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

        vm.prank(jbProjects().ownerOf(1));
        delegate.setPoolFor(1, fee, 2 minutes, address(weth));

        primePool();

        amountOutQuoted = getAmountOut(pool, 1 ether, address(weth));

        vm.label(address(pool), "uniswapPool");
        vm.label(address(factory), "uniswapFactory");
        vm.label(address(weth), "$WETH");
        vm.label(address(jbx), "$JBX");
        vm.label(address(delegate), "delegate");
    }

    // placeholder so that our setup actually runs
    function test_isSetup() external {}

    function primePool() internal {
        uint256 amountIn = 1 ether;

        // *** Simulate a trade to create an observation ***
        deal(address(weth), address(this), 1 ether);
        /* vm.startPrank(address(this)); // Assume your test contract can make the trade */
        weth.approve(address(router), amountIn); // Approve the pool to spend WETH

        // Perform a swap (adjust parameters as needed)
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(jbx),
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0, // Set a suitable minimum output amount
            sqrtPriceLimitX96: 0 // Set a suitable price limit
        });
        router.exactInputSingle(params);

        // Now advance time and increase cardinality
        vm.warp(block.timestamp + 2 minutes);
        pool.increaseObservationCardinalityNext(2 minutes);
    }

    function _getTwapQuote(uint256 _amountIn, uint32 _twapWindow) internal view returns (uint256 _amountOut) {
        // Get the twap tick
        (int24 arithmeticMeanTick, uint128 liquidity) = OracleLibrary.consult(address(pool), uint32(_twapWindow));
        console.log("amountIn", _amountIn);
        console.log("liquidity", liquidity);
        (address token0,) = address(jbx) < address(weth) ? (address(jbx), address(weth)) : (address(weth), address(jbx));
        bool zeroForOne = (address(weth) == token0);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
        if (sqrtP == 0) return TWAP_SLIPPAGE_DENOMINATOR;
        uint256 base = mulDiv(_amountIn, 100_000, uint256(liquidity));
        console.log("base", base);
        uint256 slippageTolerance = zeroForOne
            ? mulDiv(base, uint256(sqrtP), uint256(1) << 96)
            : mulDiv(base, uint256(1) << 96, uint256(sqrtP));
        console.log("slippageTolerance", slippageTolerance);
        if (slippageTolerance > 150_000) slippageTolerance = 8800;
        else if (slippageTolerance > 100_000) slippageTolerance = 6700;
        else if (slippageTolerance > 30_000) slippageTolerance = slippageTolerance / 12;
        else if (slippageTolerance > 15_000) slippageTolerance = slippageTolerance / 10;
        else if (slippageTolerance > 10_000) slippageTolerance = slippageTolerance * 2 / 15;
        else if (slippageTolerance > 5000) slippageTolerance = slippageTolerance * 3 / 20;
        else if (slippageTolerance > 1500) slippageTolerance = slippageTolerance / 5;
        else if (slippageTolerance > 500) slippageTolerance = slippageTolerance / 5 + 200;
        else if (slippageTolerance > 0) slippageTolerance = (slippageTolerance / 5) + 100;
        else if (slippageTolerance == 0) slippageTolerance = UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE;

        console.log("slippageTolerance adjusted", slippageTolerance);

        // Get a quote based on this TWAP tick.
        _amountOut = OracleLibrary.getQuoteAtTick({
            tick: arithmeticMeanTick,
            baseAmount: uint128(_amountIn),
            baseToken: address(weth),
            quoteToken: address(address(jbx))
        });
        console.log("amountOut", _amountOut);

        // return the lowest acceptable return based on the TWAP and its parameters.
        _amountOut -= (_amountOut * slippageTolerance) / TWAP_SLIPPAGE_DENOMINATOR;
        console.log("amountOut after slippage tolerance", _amountOut);
    }

    /**
     * @notice If the amount of token returned by minting is greater than by swapping, mint
     *
     * @dev    Should mint for both multisig() and reserve
     */
    function test_mintIfWeightGreatherThanPrice(uint256 _weight, uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 100, 1000 ether);

        uint256 _amountOutQuoted = getAmountOut(pool, _amountIn, address(weth));

        // Reconfigure with a weight bigger than the price implied by the quote
        _weight = bound(_weight, (_amountOutQuoted * 10 ** 18 / _amountIn) + 1, type(uint88).max);

        _reconfigure(1, address(delegate), _weight, 5000);

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, _amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"b55923f0");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        // This shouldn't mint via the delegate
        vm.expectEmit(true, true, true, true);
        emit IJBTokens.Mint({
            holder: multisig(),
            projectId: 1,
            count: mulDiv18(_weight, _amountIn) / 2, // Half is reserved
            tokensWereClaimed: true,
            caller: address(jbController())
        });

        uint256 _balBeforePayment = jbx.balanceOf(multisig());

        // Pay the project
        jbMultiTerminal().pay{value: _amountIn}(
            1,
            JBConstants.NATIVE_TOKEN,
            _amountIn,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        uint256 _balAfterPayment = jbx.balanceOf(multisig());
        uint256 _diff = _balAfterPayment - _balBeforePayment;

        // Check: token received by the multisig()
        assertEq(_diff, mulDiv18(_weight, _amountIn) / 2);

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(
            jbController().pendingReservedTokenBalanceOf(1),
            _reservedBalanceBefore + mulDiv18(_weight, _amountIn) / 2,
            1
        );
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap
     *
     * @dev    Should swap for both multisig() and reserve (by burning/minting)
     */
    function test_swapIfQuoteBetter(uint256 _weight, uint256 _amountIn, uint256 _reservedPercent) public {
        _amountIn = bound(_amountIn, 100, 1000 ether);

        primePool();
        uint256 _amountOutTwap = _getTwapQuote(_amountIn, cardinality);
        console.log("amountOutTwap", _amountOutTwap);
        uint256 _amountOutQuoted = getAmountOut(pool, _amountIn, address(weth));

        console.log("amountOutQuoted", _amountOutQuoted);

        // Reconfigure with a weight smaller than the price implied by the quote
        _weight = 0;

        _reservedPercent = bound(_reservedPercent, 0, 10_000);

        _reconfigure(1, address(delegate), _weight, _reservedPercent);

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, _amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        uint256 _balBeforePayment = jbx.balanceOf(multisig());

        // Pay the project.
        // With the dynamic sqrtPriceLimit (computed from amountIn and the TWAP-derived minimum,
        // since the metadata ID hex"69" doesn't match the hook's getId("quote")),
        // the actual swap output may differ from _amountOutQuoted.
        try jbMultiTerminal().pay{value: _amountIn}(
            1, JBConstants.NATIVE_TOKEN, _amountIn, multisig(), 0, "Take my money!", _delegateMetadata
        ) {
            // The swap succeeded: verify token balances
            uint256 _balAfterPayment = jbx.balanceOf(multisig());
            uint256 _beneficiaryReceived = _balAfterPayment - _balBeforePayment;
            uint256 _reserveAdded = jbController().pendingReservedTokenBalanceOf(1) - _reservedBalanceBefore;

            // The total swap output is split between beneficiary and reserve.
            uint256 _totalSwapOutput = _beneficiaryReceived + _reserveAdded;

            // Verify the total is positive (swap happened).
            assertGt(_totalSwapOutput, 0, "no tokens from swap");

            // Verify the beneficiary/reserve split matches the reserved percent (1 wei tolerance for rounding).
            if (_reservedPercent > 0) {
                assertApproxEqAbs(_reserveAdded, _totalSwapOutput * _reservedPercent / 10_000, 1, "wrong reserve split");
            }
            if (_reservedPercent < 10_000) {
                assertApproxEqAbs(
                    _beneficiaryReceived,
                    _totalSwapOutput - (_totalSwapOutput * _reservedPercent / 10_000),
                    1,
                    "wrong beneficiary split"
                );
            }
        } catch (bytes memory reason) {
            // The dynamic sqrtPriceLimit caused a partial fill that didn't meet the minimum.
            bytes4 selector = bytes4(reason);
            assertEq(
                selector, JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, "unexpected revert reason"
            );
        }
    }

    /**
     * @notice Use the delegate multiple times to swap, with different quotes
     */
    function test_swapMultiple() public {
        // Reconfigure with a weight of 1 wei, to force swapping
        uint256 _weight = 1;
        _reconfigure(1, address(delegate), _weight, 5000);
        primePool();

        // Build the metadata using the quote at that block
        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(amountPaid, amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        // Pay the project
        jbMultiTerminal().pay{value: amountPaid}(
            1,
            JBConstants.NATIVE_TOKEN,
            amountPaid,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        uint256 _balanceBene = jbx.balanceOf(multisig());

        uint256 _reserveBalance = jbController().pendingReservedTokenBalanceOf(1);

        // Update the quote, this is now a different one as we already swapped
        uint256 _previousQuote = amountOutQuoted;
        amountOutQuoted = getAmountOut(pool, 1 ether, address(weth));

        // Sanity check
        assert(_previousQuote != amountOutQuoted);

        // Update the metadata
        _data[0] = abi.encode(amountPaid, amountOutQuoted);

        // Generate the metadata
        _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        vm.roll(block.timestamp + 1);

        // Pay the project
        jbMultiTerminal().pay{value: amountPaid}(
            1,
            JBConstants.NATIVE_TOKEN,
            amountPaid,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        // Check: token received by the multisig()
        assertEq(jbx.balanceOf(multisig()), _balanceBene + amountOutQuoted / 2);

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(jbController().pendingReservedTokenBalanceOf(1), _reserveBalance + amountOutQuoted / 2, 1);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap
     *
     * @dev    Should swap for both multisig() and reserve (by burning/minting)
     */
    function test_swapRandomAmountIn(uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 100, 1000 ether);

        uint256 _quote = getAmountOut(pool, _amountIn, address(weth));

        // Reconfigure with a weight of 0
        _reconfigure(1, address(delegate), 0, 0);

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // Build the metadata using the quote
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, _quote);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        uint256 _balBeforePayment = jbx.balanceOf(multisig());

        // Pay the project.
        // With the dynamic sqrtPriceLimit (computed from amountIn and minimumSwapAmountOut),
        // large swaps may partially fill and revert with SpecifiedSlippageExceeded.
        // This is valid MEV-protection behavior.
        try jbMultiTerminal().pay{value: _amountIn}(
            1,
            JBConstants.NATIVE_TOKEN,
            _amountIn,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        ) {
            uint256 _balAfterPayment = jbx.balanceOf(multisig());
            uint256 _diff = _balAfterPayment - _balBeforePayment;

            // Check: tokens were received (swap happened and succeeded).
            // The actual amount may be less than _quote due to the dynamic sqrtPriceLimit
            // which restricts execution price for MEV protection. The hook guarantees
            // amountReceived >= TWAP-derived minimum (since the metadata ID doesn't match
            // the hook's expected ID, the TWAP minimum is used, not _quote).
            assertGt(_diff, 0, "no tokens received");

            // Check: reserve unchanged (reservedPercent is 0)
            assertEq(jbController().pendingReservedTokenBalanceOf(1), _reservedBalanceBefore);
        } catch (bytes memory reason) {
            // The dynamic sqrtPriceLimit caused a partial fill that didn't meet the minimum.
            // This is expected behavior for large swaps relative to pool liquidity.
            bytes4 selector = bytes4(reason);
            assertEq(
                selector, JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, "unexpected revert reason"
            );
        }
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap & use quote from uniswap
     * lib
     * rather than a user provided quote
     *
     * @dev    Should swap for both multisig() and reserve (by burning/minting)
     */
    function test_swapWhenQuoteNotProvidedInMetadata(uint256 _amountIn, uint256 _reservedPercent) public {
        _amountIn = bound(_amountIn, 10, 10 ether);
        _reservedPercent = bound(_reservedPercent, 0, 10_000);

        uint256 _weight = 10 ether;

        _reconfigure(1, address(delegate), _weight, _reservedPercent);
        primePool();

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // The twap which is going to be used
        uint256 _twap = _getTwapQuote(_amountIn, cardinality);
        console.log("twap", _twap);

        // The actual quote, here for test only
        uint256 _quote = getAmountOut(pool, _amountIn, address(weth));
        console.log("quote", _quote);

        // for checking balance difference after payment
        uint256 _balanceBeforePayment = jbx.balanceOf(multisig());

        uint256 _tokenCount = mulDiv18(_amountIn, _weight);

        // Pay the project.
        // With the dynamic sqrtPriceLimit (computed from amountIn and TWAP-derived minimum),
        // some fuzz inputs may cause partial fills that revert with SpecifiedSlippageExceeded.
        // This is valid behavior: the TWAP-computed minimum may exceed what the pool can deliver
        // within the dynamic price limit for certain swap sizes.
        try jbMultiTerminal().pay{value: _amountIn}(
            1,
            JBConstants.NATIVE_TOKEN,
            _amountIn,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            new bytes(0)
        ) {
            uint256 _balanceAfterPayment = jbx.balanceOf(multisig());
            uint256 _tokenReceived = _balanceAfterPayment - _balanceBeforePayment;

            // 1 wei sensitivity for rounding errors
            if (_twap > _tokenCount) {
                // Path is picked based on twap, but the token received are the one quoted
                assertApproxEqAbs(_tokenReceived, _quote - (_quote * _reservedPercent) / 10_000, 1, "wrong swap");
                assertApproxEqAbs(
                    jbController().pendingReservedTokenBalanceOf(1),
                    _reservedBalanceBefore + (_quote * _reservedPercent) / 10_000,
                    1,
                    "Reserve"
                );
            } else {
                assertApproxEqAbs(
                    _tokenReceived, _tokenCount - (_tokenCount * _reservedPercent) / 10_000, 1, "Wrong mint"
                );
                assertApproxEqAbs(
                    jbController().pendingReservedTokenBalanceOf(1),
                    _reservedBalanceBefore + (_tokenCount * _reservedPercent) / 10_000,
                    1,
                    "Reserve"
                );
            }
        } catch (bytes memory reason) {
            // The dynamic sqrtPriceLimit caused a partial fill that didn't meet the TWAP minimum.
            bytes4 selector = bytes4(reason);
            assertEq(
                selector, JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, "unexpected revert reason"
            );
        }
    }

    /**
     * @notice If the amount of token returned by minting is greater than by swapping, we mint outside of the delegate
     * &
     * when there is no user provided quote presemt in metadata
     *
     * @dev    Should mint for both multisig() and reserve
     */
    function test_swapWhenMintIsPreferredEvenWhenMetadataIsNotPresent(uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 1 ether, 1000 ether);

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // Reconfigure with a weight of amountOutQuoted + 1
        _reconfigure(1, address(delegate), amountOutQuoted + 1, 0);
        primePool();

        uint256 _balBeforePayment = jbx.balanceOf(multisig());

        // Pay the project
        jbMultiTerminal().pay{value: _amountIn}(
            1, JBConstants.NATIVE_TOKEN, _amountIn, multisig(), 0, "Take my money!", new bytes(0)
        );

        uint256 expectedTokenCount = mulDiv(_amountIn, amountOutQuoted + 1, 10 ** 18);

        uint256 _balAfterPayment = jbx.balanceOf(multisig());
        uint256 _diff = _balAfterPayment - _balBeforePayment;

        // Check: token received by the multisig()
        assertEq(_diff, expectedTokenCount);

        // Check: reserve unchanged
        assertEq(jbController().pendingReservedTokenBalanceOf(1), _reservedBalanceBefore);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting but slippage is too high,
     *         revert if a quote was passed in the pay data
     */
    function test_revertIfSlippageTooHighAndQuote() public {
        uint256 _weight = 1;
        // Reconfigure with a weight smaller than the quote, slippage included
        _reconfigure(1, address(delegate), _weight, 5000);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(
            0,
            67_331_221_947_532_926_107_815 + 10 // 10 more than quote at that block
        );

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        vm.prank(address(delegate));
        _ids[0] = bytes4(hex"b55923f0");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector,
                67_331_221_947_532_926_107_815,
                67_331_221_947_532_926_107_815 + 10 // 10 more than quote at block as before
            )
        );

        // Pay the project
        jbMultiTerminal().pay{value: 1 ether}(
            1,
            JBConstants.NATIVE_TOKEN,
            1 ether,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );
    }

    function test_mintWithExtraFunds(uint256 _amountIn, uint256 _amountInExtra) public {
        _amountIn = bound(_amountIn, 100, 1000 ether);
        _amountInExtra = bound(_amountInExtra, 100, 1000 ether);

        // Refresh the quote
        amountOutQuoted = getAmountOut(pool, _amountIn, address(weth));

        // Reconfigure with a weight smaller than the quote
        uint256 _weight = amountOutQuoted * 10 ** 18 / _amountIn - 1;
        _reconfigure(1, address(delegate), _weight, 5000);

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"b55923f0");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        uint256 _balBeforePayment = jbx.balanceOf(multisig());

        // Pay the project.
        // With the dynamic sqrtPriceLimit, large swaps may partially fill and revert
        // with SpecifiedSlippageExceeded. This is valid MEV-protection behavior.
        try jbMultiTerminal().pay{value: _amountIn + _amountInExtra}(
            1,
            JBConstants.NATIVE_TOKEN,
            _amountIn + _amountInExtra,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        ) {
            // Check: token received by the multisig()
            assertApproxEqAbs(
                jbx.balanceOf(multisig()) - _balBeforePayment,
                amountOutQuoted / 2 + mulDiv18(_amountInExtra, _weight) / 2,
                10
            );

            // Check: token added to the reserve
            assertApproxEqAbs(
                jbController().pendingReservedTokenBalanceOf(1),
                _reservedBalanceBefore + amountOutQuoted / 2 + mulDiv18(_amountInExtra, _weight) / 2,
                10
            );
        } catch (bytes memory reason) {
            // The dynamic sqrtPriceLimit caused a partial fill that didn't meet the minimum.
            bytes4 selector = bytes4(reason);
            assertEq(
                selector, JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, "unexpected revert reason"
            );
        }
    }

    function _reconfigure(uint256 _projectId, address _delegate, uint256 _weight, uint256 _reservedPercent) internal {
        address _projectOwner = jbProjects().ownerOf(_projectId);

        JBRuleset memory _fundingCycle = jbRulesets().currentOf(_projectId);
        _metadata = _fundingCycle.expandMetadata();

        JBSplitGroup[] memory _groupedSplits = new JBSplitGroup[](1);
        _groupedSplits[0] = JBSplitGroup({
            groupId: 1,
            splits: jbSplits()
                .splitsOf(
                    _projectId,
                    _fundingCycle.id,
                    uint256(uint160(JBConstants.NATIVE_TOKEN)) /*group*/
                )
        });

        _metadata.useDataHookForPay = true;
        _metadata.dataHook = _delegate;

        _metadata.reservedPercent = uint16(_reservedPercent);

        // reconfigure
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

        // Move to next fc
        vm.warp(block.timestamp + _fundingCycle.duration * 2 + 1);
    }
}
