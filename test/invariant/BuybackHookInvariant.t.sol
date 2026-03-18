// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

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
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Buyback hook
import {JBBuybackHook} from "src/JBBuybackHook.sol";

// Test mocks
import {MockPoolManager} from "../mock/MockPoolManager.sol";
import {MockOracleHook} from "../mock/MockOracleHook.sol";

/// @notice Simple ERC20 project token for invariant testing.
contract InvProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Test harness exposing JBBuybackHook internals for pool configuration.
contract InvBuybackHook is JBBuybackHook {
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

    /// @notice Directly initialize pool state for testing without permission checks.
    function forTestInitPool(
        uint256 projectId,
        PoolKey calldata key,
        uint256 twapWindow,
        address projectToken,
        address terminalToken
    )
        external
    {
        _poolKeyOf[projectId][terminalToken] = key;
        twapWindowOf[projectId][terminalToken] = twapWindow;
        projectTokenOf[projectId] = projectToken;
    }
}

/// @notice Handler for the invariant fuzzer. Exercises `beforePayRecordedWith` with varying
/// payment amounts, oracle states, and weights. Tracks whether the core invariant holds:
///   - Swap path: minimumSwapAmountOut >= tokenCountFromMint
///   - Mint path: weight returned unchanged (at least as many tokens as a pure mint)
///
/// Either path guarantees the payer gets >= what a no-hook mint would produce.
contract BuybackHookHandler is Test {
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    InvBuybackHook public hook;
    MockPoolManager public mockPm;
    MockOracleHook public mockOracle;
    InvProjectToken public projectToken;

    IJBDirectory public directory;
    IJBPrices public prices;
    IJBProjects public projects;
    IJBTokens public tokens;
    IJBController public controller;
    IJBMultiTerminal public terminal;

    PoolKey public poolKey;
    PoolId public poolId;

    uint256 public constant PROJECT_ID = 42;

    // Ghost variables for invariant assertions.
    uint256 public callCount;
    uint256 public swapChosenCount;
    uint256 public mintChosenCount;
    bool public invariantViolated;
    string public violationReason;

    constructor(
        InvBuybackHook _hook,
        MockPoolManager _mockPm,
        MockOracleHook _mockOracle,
        InvProjectToken _projectToken,
        IJBDirectory _directory,
        IJBPrices _prices,
        IJBProjects _projects,
        IJBTokens _tokens,
        IJBController _controller,
        IJBMultiTerminal _terminal,
        PoolKey memory _poolKey
    ) {
        hook = _hook;
        mockPm = _mockPm;
        mockOracle = _mockOracle;
        projectToken = _projectToken;
        directory = _directory;
        prices = _prices;
        projects = _projects;
        tokens = _tokens;
        controller = _controller;
        terminal = _terminal;
        poolKey = _poolKey;
        poolId = PoolIdLibrary.toId(_poolKey);
    }

    /// @notice Fuzzed entry point: exercise beforePayRecordedWith with varying parameters.
    /// @param payAmount The amount being paid (bounded to realistic range).
    /// @param weightRaw The ruleset weight (bounded to avoid zero and overflow).
    /// @param oracleTick The TWAP tick to configure (bounded to valid tick range).
    /// @param oracleLiquidityRaw Raw value to derive oracle liquidity.
    function exerciseBeforePay(
        uint256 payAmount,
        uint112 weightRaw,
        int24 oracleTick,
        uint128 oracleLiquidityRaw
    )
        external
    {
        // Bound inputs to realistic ranges.
        payAmount = bound(payAmount, 1e6, 100_000 ether);
        // Weight is uint112 in JBRuleset; use uint256 for beforePay context but keep bounded.
        uint256 weight = bound(uint256(weightRaw), 1, uint256(type(uint112).max));
        // Valid tick range for Uniswap V4.
        oracleTick = int24(bound(int256(oracleTick), -500_000, 500_000));
        // Liquidity must be non-zero for meaningful oracle output.
        uint128 oracleLiquidity = uint128(bound(uint256(oracleLiquidityRaw), 1, type(uint128).max));

        // Configure the oracle to return the fuzzed tick.
        // tickCumulatives: [twapWindow * tick, 0] so that mean tick = (0 - twapWindow*tick) / twapWindow = -tick.
        // Actually: delta = tickCumulatives[1] - tickCumulatives[0], meanTick = delta / twapWindow.
        // We want meanTick = oracleTick, so delta = oracleTick * 600 (twapWindow).
        int56 tickCum0 = 0;
        int56 tickCum1 = int56(oracleTick) * 600;

        // secondsPerLiquidity: compute from liquidity.
        // harmonicMeanLiquidity = (twapWindow << 128) / secPerLiqDelta
        // We want harmonicMeanLiquidity = oracleLiquidity,
        // so secPerLiqDelta = (twapWindow << 128) / oracleLiquidity.
        // But this may overflow uint160 for small liquidity values. Use a safe calculation.
        uint256 secPerLiqDeltaRaw = (uint256(600) << 128) / uint256(oracleLiquidity);
        // Clamp to uint160 range.
        uint160 secPerLiqDelta;
        if (secPerLiqDeltaRaw > type(uint160).max) {
            secPerLiqDelta = type(uint160).max;
        } else {
            secPerLiqDelta = uint160(secPerLiqDeltaRaw);
        }

        mockOracle.setObserveData(tickCum0, tickCum1, 0, secPerLiqDelta);

        // Mock the ruleset with the fuzzed weight.
        _mockRulesetWithWeight(weight);

        // Build the beforePay context (no explicit payer quote => relies on TWAP).
        JBBeforePayRecordedContext memory ctx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: address(0xBEEF),
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: payAmount
            }),
            projectId: PROJECT_ID,
            rulesetId: 1,
            beneficiary: address(0xCAFE),
            weight: weight,
            reservedPercent: 0,
            metadata: ""
        });

        // Calculate what a no-hook mint would produce.
        // weightRatio = 10 ** decimals = 1e18 (same currency as baseCurrency).
        uint256 tokenCountWithoutHook = mulDiv({x: payAmount, y: weight, denominator: 1e18});

        // Call beforePayRecordedWith.
        (uint256 returnedWeight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(ctx);

        callCount++;

        // Check the invariant based on which path was chosen.
        if (specs.length == 0) {
            // Mint path: weight should be returned unchanged.
            mintChosenCount++;
            if (returnedWeight != weight) {
                invariantViolated = true;
                violationReason = "Mint path: returned weight differs from input weight";
            }
            // Mint path tokens = mulDiv(payAmount, weight, 1e18) = tokenCountWithoutHook.
            // This is exactly what a no-hook mint produces, so the invariant trivially holds.
        } else if (specs.length == 1) {
            // Swap path: weight should be 0 (hook takes over all minting).
            swapChosenCount++;
            if (returnedWeight != 0) {
                invariantViolated = true;
                violationReason = "Swap path: weight should be 0";
                return;
            }

            // Decode the hook metadata to extract minimumSwapAmountOut.
            // Format: abi.encode(projectTokenIs0, amountToMintWith, minimumSwapAmountOut, controller)
            (, uint256 amountToMintWith, uint256 minimumSwapAmountOut,) =
                abi.decode(specs[0].metadata, (bool, uint256, uint256, IJBController));

            // The amount forwarded to the hook for swapping.
            uint256 amountToSwapWith = specs[0].amount;

            // Tokens from the swap path: minimumSwapAmountOut (from swap) + mint from leftover.
            // Leftover = payAmount - amountToSwapWith (if partial swap).
            uint256 leftoverMintTokens = 0;
            if (payAmount > amountToSwapWith) {
                leftoverMintTokens = mulDiv({x: payAmount - amountToSwapWith, y: weight, denominator: 1e18});
            }

            // The hook also mints amountToMintWith worth of tokens.
            uint256 amountToMintWithTokens = mulDiv({x: amountToMintWith, y: weight, denominator: 1e18});

            // Total guaranteed minimum tokens from swap path.
            uint256 swapPathMinTokens = minimumSwapAmountOut + amountToMintWithTokens + leftoverMintTokens;

            // Core invariant: swap path should produce >= mint-only tokens.
            if (swapPathMinTokens < tokenCountWithoutHook) {
                invariantViolated = true;
                violationReason = string(
                    abi.encodePacked(
                        "Swap path minimum tokens (",
                        vm.toString(swapPathMinTokens),
                        ") < mint-only tokens (",
                        vm.toString(tokenCountWithoutHook),
                        ")"
                    )
                );
            }
        } else {
            // Unexpected: specs should be 0 or 1.
            invariantViolated = true;
            violationReason = "Unexpected: specs.length > 1";
        }
    }

    /// @notice Fuzzed entry point with an explicit payer quote in metadata.
    /// @param payAmount The payment amount.
    /// @param weightRaw The ruleset weight.
    /// @param payerQuote The payer-specified minimum swap output.
    /// @param amountToSwapWith The amount the payer wants to use for swapping (out of payAmount).
    function exerciseBeforePayWithQuote(
        uint256 payAmount,
        uint112 weightRaw,
        uint256 payerQuote,
        uint256 amountToSwapWith
    )
        external
    {
        // Bound inputs.
        payAmount = bound(payAmount, 1e6, 100_000 ether);
        uint256 weight = bound(uint256(weightRaw), 1, uint256(type(uint112).max));
        payerQuote = bound(payerQuote, 0, type(uint128).max);
        amountToSwapWith = bound(amountToSwapWith, 0, payAmount);

        // Use a broken oracle (returns 0) so the payer quote is the only source of swap minimum.
        mockOracle.setShouldRevert(true);

        // Mock the ruleset with the fuzzed weight.
        _mockRulesetWithWeight(weight);

        // Build metadata with the payer quote.
        bytes memory metadata;
        if (payerQuote > 0 && amountToSwapWith > 0) {
            // Encode the quote using JBMetadataResolver format.
            bytes4 quoteId = JBMetadataResolver.getId("quote", address(hook));
            bytes4[] memory ids = new bytes4[](1);
            ids[0] = quoteId;
            bytes[] memory datas = new bytes[](1);
            datas[0] = abi.encode(amountToSwapWith, payerQuote);
            metadata = JBMetadataResolver.createMetadata(ids, datas);
        }

        JBBeforePayRecordedContext memory ctx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: address(0xBEEF),
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: payAmount
            }),
            projectId: PROJECT_ID,
            rulesetId: 1,
            beneficiary: address(0xCAFE),
            weight: weight,
            reservedPercent: 0,
            metadata: metadata
        });

        uint256 tokenCountWithoutHook = mulDiv({x: payAmount, y: weight, denominator: 1e18});

        // Call beforePayRecordedWith. May revert if amountToSwapWith > payAmount, but we bounded it.
        try hook.beforePayRecordedWith(ctx) returns (
            uint256 returnedWeight, JBPayHookSpecification[] memory specs
        ) {
            callCount++;

            if (specs.length == 0) {
                mintChosenCount++;
                if (returnedWeight != weight) {
                    invariantViolated = true;
                    violationReason = "Quote path mint: returned weight differs from input weight";
                }
            } else if (specs.length == 1) {
                swapChosenCount++;
                if (returnedWeight != 0) {
                    invariantViolated = true;
                    violationReason = "Quote path swap: weight should be 0";
                    return;
                }

                (, uint256 decodedMintWith, uint256 decodedMinSwapOut,) =
                    abi.decode(specs[0].metadata, (bool, uint256, uint256, IJBController));

                uint256 swapAmount = specs[0].amount;
                uint256 leftoverMintTokens = 0;
                if (payAmount > swapAmount) {
                    leftoverMintTokens = mulDiv({x: payAmount - swapAmount, y: weight, denominator: 1e18});
                }
                uint256 mintWithTokens = mulDiv({x: decodedMintWith, y: weight, denominator: 1e18});

                uint256 swapPathMinTokens = decodedMinSwapOut + mintWithTokens + leftoverMintTokens;

                if (swapPathMinTokens < tokenCountWithoutHook) {
                    invariantViolated = true;
                    violationReason = string(
                        abi.encodePacked(
                            "Quote swap path minimum (",
                            vm.toString(swapPathMinTokens),
                            ") < mint-only (",
                            vm.toString(tokenCountWithoutHook),
                            ")"
                        )
                    );
                }
            }
        } catch {
            // Revert is acceptable (e.g., oracle issues, edge cases). Not a violation.
        }

        // Reset oracle for next call.
        mockOracle.setShouldRevert(false);
    }

    /// @notice Helper to mock the ruleset with a specific weight.
    function _mockRulesetWithWeight(uint256 weight) internal {
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
            // Safe: weight is bounded to type(uint112).max in the calling functions.
            // forge-lint: disable-next-line(unsafe-typecast)
            weight: uint112(weight),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (PROJECT_ID)),
            abi.encode(ruleset, meta)
        );
    }
}

/// @title BuybackHookInvariantTest
/// @notice Invariant test suite verifying the core property of the buyback hook:
///   The hook's decision in `beforePayRecordedWith` always picks the path that yields
///   >= tokens compared to a simple no-hook mint. When it chooses to swap, the guaranteed
///   minimum output (minimumSwapAmountOut) exceeds what minting alone would produce.
///   When it chooses to mint, the original weight is returned unchanged.
contract BuybackHookInvariantTest is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    InvBuybackHook hook;
    MockPoolManager mockPm;
    MockOracleHook mockOracle;
    InvProjectToken projectToken;
    BuybackHookHandler handler;

    // Mock JB core contracts (address-only, mocked via vm.mockCall).
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));
    IJBController controller = IJBController(makeAddr("controller"));
    IJBMultiTerminal terminal = IJBMultiTerminal(makeAddr("terminal"));

    address owner = makeAddr("owner");
    uint256 constant PROJECT_ID = 42;
    uint32 constant TWAP_WINDOW = 600; // 10 minutes

    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        // Deploy real contracts.
        mockPm = new MockPoolManager();
        mockOracle = new MockOracleHook();
        projectToken = new InvProjectToken();

        // Etch code at mock addresses so calls don't revert with "no code".
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        // Deploy hook.
        hook = new InvBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            poolManager: IPoolManager(address(mockPm)),
            oracleHook: IHooks(address(mockOracle)),
            trustedForwarder: address(0)
        });

        // Build pool key: native ETH (address(0)) is always currency0.
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        poolId = poolKey.toId();

        // Set up default mock responses for JB core.
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (PROJECT_ID)), abi.encode(owner));
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (PROJECT_ID)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (PROJECT_ID, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );
        vm.mockCall(
            address(tokens),
            abi.encodeCall(tokens.tokenOf, (PROJECT_ID)),
            abi.encode(IJBToken(address(projectToken)))
        );
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

        // Configure pool in MockPoolManager.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);

        // Use setPoolFor so _poolIsSet = true (required for _getQuote to query the oracle).
        vm.prank(owner);
        hook.setPoolFor(PROJECT_ID, poolKey, TWAP_WINDOW, JBConstants.NATIVE_TOKEN);

        // Deploy handler.
        handler = new BuybackHookHandler(
            hook,
            mockPm,
            mockOracle,
            projectToken,
            directory,
            prices,
            projects,
            tokens,
            controller,
            terminal,
            poolKey
        );

        // Target only the handler for invariant testing.
        targetContract(address(handler));

        // Only target the two entry points.
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = BuybackHookHandler.exerciseBeforePay.selector;
        selectors[1] = BuybackHookHandler.exerciseBeforePayWithQuote.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Core invariant: the hook's decision should never produce fewer tokens than a no-hook mint.
    /// This is checked inside the handler on every call. The invariant function verifies no violations
    /// were recorded.
    function invariant_swapOrMintAlwaysGteNoHookMint() public view {
        assertFalse(handler.invariantViolated(), handler.violationReason());
    }

    /// @notice Invariant: every call results in either swap path (weight=0, specs=1) or
    /// mint path (weight>0, specs=0). No other combinations should occur.
    /// This is also checked inside the handler; this assertion is a secondary guard.
    function invariant_noViolationsRecorded() public view {
        assertFalse(handler.invariantViolated(), handler.violationReason());
    }

    /// @notice Non-invariant test to verify the handler is actually callable.
    /// This runs as a regular test (not an invariant check) to confirm basic operation.
    function test_handlerIsCallable() public {
        // Exercise the handler directly to confirm it works.
        handler.exerciseBeforePay(1 ether, 1e18, 0, 1_000_000 ether);
        assertTrue(handler.callCount() > 0, "Handler should have been called");
        assertFalse(handler.invariantViolated(), "No invariant violation on direct call");
    }
}
