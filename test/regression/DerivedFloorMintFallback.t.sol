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
contract DFMF_MockProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal terminal mock that accepts ETH and has a real addToBalanceOf.
contract DFMF_MockTerminal {
    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}

    receive() external payable {}
}

/// @notice Test harness exposing JBBuybackHook internals.
contract DFMF_ForTest_BuybackHook is JBBuybackHook {
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

/// @notice Oracle-derived floors must never revert a payment. A swap that fills below the derived floor is
/// unwound inside the unlock and the full payment falls back to minting at the issuance rate. Only explicit
/// caller-provided minima hard-revert.
///
/// Regression for the ART/USDC incident on Base (block 49454401): a $15 REVLoans fee pay filled at 6.46x the
/// issuance rate but sat below a stale 2-day-TWAP floor, hard-reverting the pay. REVLoans forgave the fee, so
/// the revnet was stiffed while the loan kept its prepaid window — a standing fee-evasion vector, since any
/// borrower could force the miss by nudging the thin pool before borrowing.
contract DFMF_DerivedFloorMintFallback is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    DFMF_ForTest_BuybackHook hook;
    MockPoolManager mockPm;
    MockOracleHook mockOracle;
    DFMF_MockProjectToken projectToken;

    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));
    IJBController controller = IJBController(makeAddr("controller"));
    DFMF_MockTerminal mockTerminal;
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
        projectToken = new DFMF_MockProjectToken();
        mockTerminal = new DFMF_MockTerminal();
        terminal = IJBMultiTerminal(address(mockTerminal));

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");

        hook = new DFMF_ForTest_BuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants({
            newPoolManager: IPoolManager(address(mockPm)), newOracleHook: IHooks(address(mockOracle))
        });

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
    function _buildContext(
        uint256 payAmount,
        uint256 minimumSwapAmountOut,
        bool hasExplicitMinimumSwapAmountOut,
        uint256 tokenCountWithoutHook
    )
        internal
        view
        returns (JBAfterPayRecordedContext memory)
    {
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
                false, // Native ETH < any deployed address, so the project token is currency1.
                uint256(0), // amountToMintWith
                minimumSwapAmountOut,
                hasExplicitMinimumSwapAmountOut,
                controller,
                tokenCountWithoutHook,
                1e18,
                payAmount,
                int24(0),
                uint128(0),
                bytes32(0),
                uint256(0),
                uint256(0),
                uint256(0),
                false, // oracleUnseeded
                false, // skipSplits
                uint256(0) // reservedPercent
            ),
            payerMetadata: ""
        });
    }

    /// @notice The incident shape: the swap fills 6x better than issuance but below a stale derived floor.
    /// The pay must NOT revert — the swap unwinds and the full payment mints at the issuance rate, with the
    /// terminal tokens returned to the project's balance.
    function test_derivedFloorMiss_unwindsSwapAndFallsBackToMint() public {
        uint256 payAmount = 1 ether;
        uint256 swapOut = 6000e18; // 6x issuance, but below the stale derived floor.
        uint256 derivedFloor = 9700e18;

        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        projectToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx = _buildContext({
            payAmount: payAmount,
            minimumSwapAmountOut: derivedFloor,
            hasExplicitMinimumSwapAmountOut: false,
            tokenCountWithoutHook: 1000e18
        });

        // The full payment falls back to minting at the issuance rate.
        vm.expectCall(
            address(controller), abi.encodeCall(IJBController.mintTokensOf, (projectId, 1000e18, beneficiary, "", true))
        );

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        assertFalse(mockPm.swapCalled(), "swap should have been unwound by the derived-floor miss");
        assertEq(address(mockTerminal).balance, payAmount, "full payment should return to the project's terminal");
        assertEq(address(hook).balance, 0, "hook should hold no residual ETH");
    }

    /// @notice A fill at or above the derived floor keeps the swap.
    function test_derivedFloorMet_swapExecutes() public {
        uint256 payAmount = 1 ether;
        uint256 swapOut = 9800e18; // Above the derived floor.
        uint256 derivedFloor = 9700e18;

        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        projectToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx = _buildContext({
            payAmount: payAmount,
            minimumSwapAmountOut: derivedFloor,
            hasExplicitMinimumSwapAmountOut: false,
            tokenCountWithoutHook: 1000e18
        });

        // The swapped tokens are burned and re-minted with the reserved rate applied.
        vm.expectCall(
            address(controller), abi.encodeCall(IJBController.mintTokensOf, (projectId, swapOut, beneficiary, "", true))
        );

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        assertTrue(mockPm.swapCalled(), "swap should have executed");
    }

    /// @notice The derived floor is pro-rated by consumed input: a partial fill whose per-unit rate satisfies the
    /// floor keeps the swap, and the unconsumed remainder mints at the issuance rate.
    function test_derivedFloorPartialFill_proRatedByConsumedInput() public {
        uint256 payAmount = 1 ether;
        uint256 ethConsumed = 0.6 ether;
        uint256 swapOut = 700e18; // Pro-rated floor is 1100 * 0.6 = 660. 700 >= 660 passes.
        uint256 derivedFloor = 1100e18;

        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(-int128(uint128(ethConsumed)), int128(uint128(swapOut)));
        projectToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx = _buildContext({
            payAmount: payAmount,
            minimumSwapAmountOut: derivedFloor,
            hasExplicitMinimumSwapAmountOut: false,
            tokenCountWithoutHook: 1000e18
        });

        // 700 swapped + 400 leftover mint.
        vm.expectCall(
            address(controller), abi.encodeCall(IJBController.mintTokensOf, (projectId, 1100e18, beneficiary, "", true))
        );

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        assertTrue(mockPm.swapCalled(), "partial fill meeting the pro-rated floor should keep the swap");
    }

    /// @notice A partial fill below the pro-rated derived floor unwinds and the FULL payment mints.
    function test_derivedFloorPartialFill_belowProRatedFloor_unwinds() public {
        uint256 payAmount = 1 ether;
        uint256 ethConsumed = 0.6 ether;
        uint256 swapOut = 600e18; // Pro-rated floor is 1100 * 0.6 = 660. 600 < 660 unwinds.
        uint256 derivedFloor = 1100e18;

        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(-int128(uint128(ethConsumed)), int128(uint128(swapOut)));
        projectToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx = _buildContext({
            payAmount: payAmount,
            minimumSwapAmountOut: derivedFloor,
            hasExplicitMinimumSwapAmountOut: false,
            tokenCountWithoutHook: 1000e18
        });

        // The whole 1 ETH mints at the issuance rate — not just the unconsumed 0.4.
        vm.expectCall(
            address(controller), abi.encodeCall(IJBController.mintTokensOf, (projectId, 1000e18, beneficiary, "", true))
        );

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        assertFalse(mockPm.swapCalled(), "swap should have been unwound by the pro-rated floor miss");
        assertEq(address(mockTerminal).balance, payAmount, "full payment should return to the project's terminal");
    }

    /// @notice An EXPLICIT caller minimum remains a settlement guarantee: a successful swap whose combined output
    /// falls short still hard-reverts. The derived-floor unwind never applies to explicit minima.
    function test_explicitMinimum_stillHardReverts() public {
        uint256 payAmount = 1 ether;
        uint256 swapOut = 800e18;
        uint256 explicitMinimum = 1100e18;

        // forge-lint: disable-next-line(unsafe-typecast)
        mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        projectToken.mint(address(mockPm), swapOut);

        JBAfterPayRecordedContext memory ctx = _buildContext({
            payAmount: payAmount,
            minimumSwapAmountOut: explicitMinimum,
            hasExplicitMinimumSwapAmountOut: true,
            tokenCountWithoutHook: 1000e18
        });

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, 800e18, 1100e18)
        );
        hook.afterPayRecordedWith{value: payAmount}(ctx);
    }
}
