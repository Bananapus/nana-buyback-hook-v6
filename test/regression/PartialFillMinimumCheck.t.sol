// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {Test} from "forge-std/Test.sol";

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
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Buyback hook
import {JBBuybackHook} from "src/JBBuybackHook.sol";

// Test mocks
import {MockPoolManager} from "../mock/MockPoolManager.sol";
import {MockOracleHook} from "../mock/MockOracleHook.sol";

/// @notice Simple ERC20 token for testing.
contract PFMC_MockProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal terminal mock that accepts ETH and has a real addToBalanceOf.
/// vm.mockCall does not transfer ETH, so we need a real contract for the leftover path.
contract PFMC_MockTerminal {
    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}

    receive() external payable {}
}

/// @notice Test harness exposing JBBuybackHook internals.
contract PFMC_ForTest_BuybackHook is JBBuybackHook {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBPrices prices,
        IJBProjects projects,
        IJBTokens tokens,
        address deployer,
        address trustedForwarder
    )
        JBBuybackHook(directory, permissions, prices, projects, tokens, deployer, trustedForwarder)
    {}

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

/// @notice Tests for the partial-fill + minimum-check behavior in afterPayRecordedWith.
/// The buyback hook uses the issuance rate as the swap's price limit. A partial fill produces
/// swap output + leftover mint. The combined total is checked against the user's minimumSwapAmountOut.
/// When the swap fails entirely, the mint-only fallback is still checked against the user's minimum.
contract PFMC_PartialFillMinimumCheck is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    PFMC_ForTest_BuybackHook hook;
    MockPoolManager mockPm;
    MockOracleHook mockOracle;
    PFMC_MockProjectToken projectToken;

    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));
    IJBController controller = IJBController(makeAddr("controller"));
    PFMC_MockTerminal mockTerminal;
    IJBMultiTerminal terminal;

    address beneficiary = makeAddr("beneficiary");
    address payer = makeAddr("payer");
    uint256 projectId = 42;
    uint32 twapWindow = 600;

    /// @dev Weight of 1000e18 means 1 ETH mints 1000 tokens (weightRatio = 1e18).
    uint112 constant WEIGHT = 1000e18;

    PoolKey nativePoolKey;

    function setUp() public {
        mockPm = new MockPoolManager();
        mockOracle = new MockOracleHook();
        projectToken = new PFMC_MockProjectToken();
        mockTerminal = new PFMC_MockTerminal();
        terminal = IJBMultiTerminal(address(mockTerminal));

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");

        hook = new PFMC_ForTest_BuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants(IPoolManager(address(mockPm)), IHooks(address(mockOracle)));

        // Native ETH pool key: ETH (address(0)) is always currency0.
        nativePoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });

        // Mock JB core calls.
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(makeAddr("owner")));
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (projectId)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (projectId, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature("hasPermission(address,address,uint256,uint256,bool,bool)"),
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

        _mockCurrentRuleset();

        // Configure pool in MockPoolManager.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(nativePoolKey.toId(), sqrtPrice, 0, 3000);
        mockPm.setLiquidity(nativePoolKey.toId(), 1_000_000 ether);

        // Initialize pool in hook.
        hook.forTestInitPool(projectId, nativePoolKey, twapWindow, address(projectToken), address(0));
    }

    function _mockCurrentRuleset() internal {
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
            scopeCashOutsToLocalBalances: true,
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
            weight: WEIGHT,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller), abi.encodeCall(IJBController.currentRulesetOf, (projectId)), abi.encode(ruleset, meta)
        );
    }

    /// @dev Build the afterPay context for a native ETH payment.
    /// hookMetadata encodes: (projectTokenIs0, amountToMintWith, minimumSwapAmountOut, hasExplicitMinimumSwapAmountOut,
    /// controller, tokenCountWithoutHook)
    function _buildContext(
        uint256 payAmount,
        uint256 minimumSwapAmountOut,
        uint256 tokenCountWithoutHook
    )
        internal
        view
        returns (JBAfterPayRecordedContext memory)
    {
        // Native ETH < any deployed address, so projectTokenIs0 = false.
        bool projectTokenIs0 = false;

        return JBAfterPayRecordedContext({
            payer: payer,
            projectId: projectId,
            rulesetId: 1,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: payAmount
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: payAmount
            }),
            weight: WEIGHT,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(
                projectTokenIs0,
                uint256(0), // amountToMintWith
                minimumSwapAmountOut,
                true,
                controller,
                tokenCountWithoutHook,
                1e18,
                int24(0),
                uint128(0),
                bytes32(0),
                uint256(0),
                uint256(0),
                uint256(0)
            ),
            payerMetadata: ""
        });
    }

    /// @notice Partial fill where combined output (swap + leftover mint) meets the minimum.
    /// Pool consumes 0.6 ETH and outputs 700 tokens. Leftover 0.4 ETH mints 400 tokens.
    /// Combined 1100 >= 900 minimum → succeeds.
    function test_partialFill_combinedOutputMeetsMinimum() public {
        uint256 payAmount = 1 ether;
        uint256 swapOut = 700e18;
        uint256 ethConsumed = 0.6 ether;

        // Configure mock deltas: pool consumes 0.6 ETH, outputs 700 tokens.
        // projectTokenIs0 = false → zeroForOne = true → delta0 = input (negative), delta1 = output (positive).
        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(-int128(uint128(ethConsumed)), int128(uint128(swapOut)));

        // Pre-fund pool manager with project tokens for the take.
        projectToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx = _buildContext({
            payAmount: payAmount,
            minimumSwapAmountOut: 900e18, // 700 swap + 400 mint = 1100 >= 900
            tokenCountWithoutHook: 1000e18 // issuance rate: 1000 tokens per 1 ETH
        });

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        assertTrue(mockPm.swapCalled(), "swap should have been called");
    }

    /// @notice Partial fill where combined output is below the minimum → reverts.
    /// Pool consumes 0.3 ETH and outputs 350 tokens. Leftover 0.7 ETH mints 700 tokens.
    /// Combined 1050 < 1100 minimum → reverts with JBBuybackHook_SpecifiedSlippageExceeded.
    function test_partialFill_combinedOutputBelowMinimum_reverts() public {
        uint256 payAmount = 1 ether;
        uint256 swapOut = 350e18;
        uint256 ethConsumed = 0.3 ether;

        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(-int128(uint128(ethConsumed)), int128(uint128(swapOut)));

        projectToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx = _buildContext({
            payAmount: payAmount,
            minimumSwapAmountOut: 1100e18, // 350 swap + 700 mint = 1050 < 1100
            tokenCountWithoutHook: 1000e18
        });

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, 1050e18, 1100e18)
        );
        hook.afterPayRecordedWith{value: payAmount}(ctx);
    }

    /// @notice Complete swap failure still enforces an explicit caller-provided minimum output.
    /// minimumSwapAmountOut = 1100 is higher than the pure-mint fallback (1000), so the payment reverts.
    function test_swapFailure_stillEnforcesMinimumCheck() public {
        uint256 payAmount = 1 ether;

        // Force the swap to revert entirely.
        mockPm.setShouldRevertOnUnlock(true);

        JBAfterPayRecordedContext memory ctx = _buildContext({
            payAmount: payAmount,
            minimumSwapAmountOut: 1100e18, // higher than what mint yields (1000)
            tokenCountWithoutHook: 1000e18
        });

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, 1000e18, 1100e18)
        );
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        assertFalse(mockPm.swapCalled(), "swap should NOT have been called (unlock reverted)");
    }

    /// @notice Full swap meets minimum → succeeds (backward-compatible case).
    /// Pool consumes all 1 ETH and outputs 1200 tokens. No leftover.
    /// Combined 1200 >= 1100 minimum → succeeds.
    function test_fullSwap_meetsMinimum() public {
        uint256 payAmount = 1 ether;
        uint256 swapOut = 1200e18;

        // Full swap: pool consumes all input.
        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));

        projectToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx = _buildContext({
            payAmount: payAmount,
            minimumSwapAmountOut: 1100e18, // 1200 >= 1100
            tokenCountWithoutHook: 1000e18
        });

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        assertTrue(mockPm.swapCalled(), "swap should have been called");
    }
}
