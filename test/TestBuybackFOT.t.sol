// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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

import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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
import {MockPoolManager} from "./mock/MockPoolManager.sol";
import {MockOracleHook} from "./mock/MockOracleHook.sol";

/// @notice ERC20 with a 1% fee on every transfer (fee-on-transfer token).
/// @dev The recipient receives 99% of the amount; 1% is burned/lost.
contract FOT_Token is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    constructor() ERC20("FeeOnTransfer", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * FEE_BPS) / BPS_DENOMINATOR;
        uint256 netAmount = amount - fee;
        // Burn the fee (deduct from sender, only credit net to recipient).
        _transfer(msg.sender, to, netAmount);
        _burn(msg.sender, fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = (amount * FEE_BPS) / BPS_DENOMINATOR;
        uint256 netAmount = amount - fee;
        _transfer(from, to, netAmount);
        _burn(from, fee);
        return true;
    }
}

/// @notice Simple ERC20 project token for testing.
contract FOT_ProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Test harness exposing JBBuybackHook internals.
contract FOT_ForTest_BuybackHook is JBBuybackHook {
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

/// @title TestBuybackFOT
/// @notice Tests the buyback hook's behavior with fee-on-transfer (FOT) tokens.
/// FOT tokens charge a fee during transfer, so the received amount is less than the sent amount.
/// These tests verify the hook handles this discrepancy safely in both the swap and mint-fallback paths.
contract TestBuybackFOT is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    FOT_ForTest_BuybackHook hook;
    MockPoolManager mockPm;
    MockOracleHook mockOracle;
    FOT_ProjectToken projectToken;
    FOT_Token fotToken;

    // Mock JB core contracts (address-only, mocked via vm.mockCall)
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

    uint256 projectId = 42;
    uint32 twapWindow = 600;

    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        mockPm = new MockPoolManager();
        mockOracle = new MockOracleHook();
        projectToken = new FOT_ProjectToken();
        fotToken = new FOT_Token();

        // Etch code at mock addresses so calls don't revert with "no code".
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");
        vm.mockCall(
            address(terminal), abi.encodeWithSignature("feeFreeSurplusOf(uint256,address)"), abi.encode(uint256(0))
        );

        hook = new FOT_ForTest_BuybackHook({
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

        // Build pool key: FOT token as terminal token, project token as project token.
        // Sort currencies numerically (lower address = currency0).
        (Currency c0, Currency c1) = address(fotToken) < address(projectToken)
            ? (Currency.wrap(address(fotToken)), Currency.wrap(address(projectToken)))
            : (Currency.wrap(address(projectToken)), Currency.wrap(address(fotToken)));

        poolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(mockOracle))});
        poolId = poolKey.toId();

        // Set up default mock responses for JB core.
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(owner));
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
            address(permissions),
            abi.encodeWithSignature("hasPermission(address,address,uint256,uint256)"),
            abi.encode(true)
        );

        _mockCurrentRuleset();
        _mockControllerMint();
        _mockControllerBurn();

        // Configure the pool in MockPoolManager.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);

        // Initialize pool in hook (bypass permissions).
        hook.forTestInitPool(projectId, poolKey, twapWindow, address(projectToken), address(fotToken));
    }

    function _mockCurrentRuleset() internal {
        JBRulesetMetadata memory meta = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(fotToken))),
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
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller), abi.encodeCall(IJBController.currentRulesetOf, (projectId)), abi.encode(ruleset, meta)
        );
    }

    function _mockControllerMint() internal {
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.previewMintOf.selector), abi.encode(0, 0));

        vm.mockCall(
            address(controller),
            abi.encodeWithSignature("mintTokensOf(uint256,uint256,address,string,bool)"),
            abi.encode(0)
        );
    }

    function _mockControllerBurn() internal {
        vm.mockCall(
            address(controller), abi.encodeWithSignature("burnTokensOf(address,uint256,uint256,string)"), abi.encode()
        );
    }

    function _makeAfterPayContext(
        uint256 payValue,
        bool projectTokenIs0,
        uint256 amountToMintWith,
        uint256 minimumSwapAmountOut
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
                token: address(fotToken), decimals: 18, currency: uint32(uint160(address(fotToken))), value: payValue
            }),
            forwardedAmount: JBTokenAmount({
                token: address(fotToken), decimals: 18, currency: uint32(uint160(address(fotToken))), value: payValue
            }),
            weight: 1e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(
                projectTokenIs0,
                amountToMintWith,
                minimumSwapAmountOut,
                false,
                controller,
                uint256(0),
                1e18,
                payValue,
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

    //*********************************************************************//
    // ----------------------------- tests ------------------------------- //
    //*********************************************************************//

    /// @notice When the swap fails with a FOT terminal token, the hook falls back to the mint path.
    /// The hook calls addToBalanceOf on the terminal with the leftover FOT tokens. This tests that
    /// the entire flow completes without revert even though the FOT token deducts fees on transfer.
    function test_fot_mintFallback_afterSwapFailure() public {
        bool projectTokenIs0 = address(projectToken) < address(fotToken);
        uint256 payAmount = 10 ether;
        uint256 fotFee = (payAmount * 100) / 10_000; // 1% = 0.1 ether
        uint256 netReceived = payAmount - fotFee; // 9.9 ether

        // Force the swap to fail (unlock reverts).
        mockPm.setShouldRevertOnUnlock(true);

        // Build context with minimumSwapAmountOut = 0 so slippage check passes.
        JBAfterPayRecordedContext memory ctx = _makeAfterPayContext(payAmount, projectTokenIs0, 0, 0);

        // Mint FOT tokens to the terminal so it can transfer them to the hook.
        fotToken.mint(address(terminal), payAmount);

        // Approve the hook to pull FOT tokens from the terminal.
        vm.prank(address(terminal));
        fotToken.approve(address(hook), payAmount);

        // Mock addToBalanceOf on terminal (for leftover funds returned by the hook).
        vm.mockCall(
            address(terminal),
            abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
            abi.encode()
        );

        // Expect the hook to call addToBalanceOf on the terminal with the net received amount
        // (after FOT deduction). Since it's an ERC20 (not native token), msg.value = 0.
        vm.expectCall(
            address(terminal),
            0, // no ETH value (ERC20 token, not native)
            abi.encodeWithSignature(
                "addToBalanceOf(uint256,address,uint256,bool,string,bytes)",
                projectId,
                address(fotToken),
                netReceived,
                false,
                "",
                bytes("")
            )
        );

        // Execute from terminal. Should not revert despite FOT deduction.
        vm.prank(address(terminal));
        hook.afterPayRecordedWith(ctx);

        // The swap should NOT have been called (unlock reverted).
        assertFalse(mockPm.swapCalled(), "swap() should NOT have been called when unlock reverts");
    }

    /// @notice DOCUMENTED BEHAVIOR: When the hook tries to swap FOT terminal tokens, the swap
    /// naturally fails because the hook receives less than the nominal amount (due to the FOT fee)
    /// but tries to settle with the pool manager using the full nominal amount. This causes an
    /// ERC20InsufficientBalance revert inside unlockCallback, which is caught by the try/catch in
    /// _swap, and the hook gracefully falls back to the mint path.
    ///
    /// This means FOT tokens are effectively incompatible with the swap path but safely degrade
    /// to the mint path. The hook does not revert; tokens are minted based on the leftover
    /// balance delta (which correctly reflects the actual received amount after the FOT deduction).
    function test_fot_swapPath_fallsBackToMintDueToInsufficientBalance() public {
        bool projectTokenIs0 = address(projectToken) < address(fotToken);
        uint256 payAmount = 10 ether;
        uint256 swapOut = 500e18;

        // Configure mock deltas for a swap that would succeed if the full amount were available.
        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        // Pre-fund MockPoolManager with project tokens so take() would work if swap succeeded.
        projectToken.mint(address(mockPm), swapOut);

        // Build context.
        JBAfterPayRecordedContext memory ctx = _makeAfterPayContext(payAmount, projectTokenIs0, 0, 0);

        // Mint FOT tokens to the terminal and approve the hook.
        fotToken.mint(address(terminal), payAmount);
        vm.prank(address(terminal));
        fotToken.approve(address(hook), payAmount);

        // Mock addToBalanceOf on terminal (for leftover funds returned by the hook).
        vm.mockCall(
            address(terminal),
            abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
            abi.encode()
        );

        // Execute from terminal. The hook pulls FOT tokens (receives 99% = 9.9 ETH),
        // then the unlockCallback tries to transfer the full 10 ETH to the pool manager,
        // which reverts with ERC20InsufficientBalance. The try/catch catches this revert
        // and falls through to the mint path.
        vm.prank(address(terminal));
        hook.afterPayRecordedWith(ctx);

        // Swap should NOT have been called — the unlock callback reverted during the
        // ERC20 transfer (before reaching MockPoolManager.swap), and the revert was caught.
        assertFalse(
            mockPm.swapCalled(),
            "swap() should NOT have been called - FOT causes insufficient balance in unlockCallback"
        );
    }

    /// @notice Documents that beforePayRecordedWith works correctly with FOT tokens for the TWAP
    /// oracle query path. The beforePay logic is view-only and doesn't transfer tokens, so FOT
    /// behavior has no impact on the decision to swap vs mint.
    function test_fot_beforePay_oracleQueryUnaffected() public {
        // Set oracle to return a valid TWAP (tick=0, price=1.0).
        mockOracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        // Use setPoolFor so _poolIsSet = true.
        uint256 fotProjectId = 99;
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (fotProjectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (fotProjectId)), abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (fotProjectId)), abi.encode(controller));

        // Mock currentRulesetOf for this project.
        JBRulesetMetadata memory meta = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(fotToken))),
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
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });
        vm.mockCall(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (fotProjectId)),
            abi.encode(ruleset, meta)
        );

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);

        vm.prank(owner);
        hook.setPoolFor(fotProjectId, poolKey, twapWindow, address(fotToken));

        // Build beforePay context with FOT token. This is a view call, no transfers happen.
        JBBeforePayRecordedContext memory beforeCtx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: address(fotToken), decimals: 18, currency: uint32(uint160(address(fotToken))), value: 1 ether
            }),
            projectId: fotProjectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 1e18,
            reservedPercent: 0,
            metadata: "" // no explicit quote => falls back to TWAP
        });

        // This should not revert. The oracle query is view-only and unaffected by FOT.
        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

        // The result depends on the TWAP quote vs mint calculation — just verify it completes.
        // Either swap path (specs.length == 1, weight == 0, noop == false) or mint path
        // (specs.length == 0, weight > 0) / (specs.length == 1, weight > 0, noop == true).
        assertTrue(
            (specs.length == 0 && weight > 0) || (specs.length == 1 && weight == 0 && !specs[0].noop)
                || (specs.length == 1 && weight > 0 && specs[0].noop),
            "beforePayRecordedWith should choose swap or mint path without reverting"
        );
    }

    /// @notice When the swap fails and the hook falls back to mint with a FOT terminal token,
    /// the hook transfers leftover FOT tokens back to the terminal via addToBalanceOf.
    /// Due to the FOT deduction, the hook received less than the nominal amount. The leftover
    /// calculation uses balance deltas (balanceAfter - balanceBefore), which correctly reflects
    /// the actual amount received after the FOT deduction.
    function test_fot_leftoverCalculation_usesBalanceDelta() public {
        bool projectTokenIs0 = address(projectToken) < address(fotToken);
        uint256 payAmount = 100 ether;
        uint256 fotFee = (payAmount * 100) / 10_000; // 1% = 1 ether
        uint256 netReceived = payAmount - fotFee; // 99 ether

        // Force the swap to fail.
        mockPm.setShouldRevertOnUnlock(true);

        // Build context with minimumSwapAmountOut = 0.
        JBAfterPayRecordedContext memory ctx = _makeAfterPayContext(payAmount, projectTokenIs0, 0, 0);

        // Mint FOT tokens to the terminal and approve the hook.
        fotToken.mint(address(terminal), payAmount);
        vm.prank(address(terminal));
        fotToken.approve(address(hook), payAmount);

        // Mock addToBalanceOf on terminal (for leftover funds returned by the hook).
        vm.mockCall(
            address(terminal),
            abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
            abi.encode()
        );

        // Expect addToBalanceOf to be called with the net received amount (99 ether, not the
        // nominal 100 ether), proving the balance-delta calculation correctly accounts for FOT.
        vm.expectCall(
            address(terminal),
            0, // no ETH value (ERC20 token, not native)
            abi.encodeWithSignature(
                "addToBalanceOf(uint256,address,uint256,bool,string,bytes)",
                projectId,
                address(fotToken),
                netReceived,
                false,
                "",
                bytes("")
            )
        );

        // Execute from terminal.
        vm.prank(address(terminal));
        hook.afterPayRecordedWith(ctx);

        // After execution, the hook should have returned the net received amount (99 ether) to the terminal
        // via addToBalanceOf + approve. The hook's balance should be zero.
        uint256 hookBalance = fotToken.balanceOf(address(hook));
        // The hook approved the terminal to pull the leftover. The mock addToBalanceOf doesn't
        // actually pull, so the balance remains. What we can verify is that the hook didn't revert
        // and that its FOT balance is exactly netReceived (since addToBalanceOf is mocked and
        // doesn't actually transfer tokens back).
        assertEq(hookBalance, netReceived, "Hook should hold exactly the net received FOT tokens (mock doesn't pull)");
    }
}
