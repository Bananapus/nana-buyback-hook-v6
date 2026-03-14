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
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
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
contract BDL_MockProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Simple ERC20 terminal token for testing.
contract BDL_MockTerminalToken is ERC20 {
    constructor() ERC20("TerminalToken", "TT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Test harness exposing JBBuybackHook internals.
contract BDL_ForTest_BuybackHook is JBBuybackHook {
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
        twapWindowOf[projectId] = twapWindow;
        projectTokenOf[projectId] = projectToken;
    }
}

/// @notice Leftover accounting should use balance deltas
///         instead of absolute balanceOf, preventing pre-existing balances from inflating
///         the leftover amount. Verifies both native ETH and ERC-20 paths do not underflow.
contract BDL_BalanceDeltaLeftover is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    BDL_ForTest_BuybackHook hook;
    MockPoolManager mockPm;
    MockOracleHook mockOracle;
    BDL_MockProjectToken projectToken;
    BDL_MockTerminalToken terminalToken;

    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));
    IJBController controller = IJBController(makeAddr("controller"));
    IJBMultiTerminal terminal = IJBMultiTerminal(makeAddr("terminal"));

    address beneficiary = makeAddr("beneficiary");
    address payer = makeAddr("payer");
    uint256 projectId = 42;
    uint32 twapWindow = 600;

    PoolKey nativePoolKey;
    PoolKey erc20PoolKey;

    function setUp() public {
        mockPm = new MockPoolManager();
        mockOracle = new MockOracleHook();
        projectToken = new BDL_MockProjectToken();
        terminalToken = new BDL_MockTerminalToken();

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        hook = new BDL_ForTest_BuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            poolManager: IPoolManager(address(mockPm)),
            oracleHook: IHooks(address(mockOracle)),
            trustedForwarder: address(0)
        });

        // Build native pool key: native ETH (address(0)) is always currency0.
        {
            nativePoolKey = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(projectToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(mockOracle))
            });
        }

        // Build ERC-20 pool key (sorted: projectToken vs terminalToken).
        {
            address token0;
            address token1;
            if (address(projectToken) < address(terminalToken)) {
                token0 = address(projectToken);
                token1 = address(terminalToken);
            } else {
                token0 = address(terminalToken);
                token1 = address(projectToken);
            }

            erc20PoolKey = PoolKey({
                currency0: Currency.wrap(token0),
                currency1: Currency.wrap(token1),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(mockOracle))
            });
        }

        // Mock JB core.
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

        // Configure pools in MockPoolManager.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(nativePoolKey.toId(), sqrtPrice, 0, 3000);
        mockPm.setLiquidity(nativePoolKey.toId(), 1_000_000 ether);
        mockPm.setSlot0(erc20PoolKey.toId(), sqrtPrice, 0, 3000);
        mockPm.setLiquidity(erc20PoolKey.toId(), 1_000_000 ether);
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
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller), abi.encodeCall(IJBController.currentRulesetOf, (projectId)), abi.encode(ruleset, meta)
        );
    }

    /// @notice CORE REGRESSION (native ETH): A full swap through a native ETH pool must not underflow
    ///         when computing the leftover balance delta. Before the fix, balanceBefore included
    ///         msg.value, causing balanceAfter < balanceBefore.
    function test_nativeETH_fullSwap_noUnderflow() public {
        // Native ETH (address(0)) < any deployed address, so projectTokenIs0 = false.
        bool projectTokenIs0 = false;
        uint256 payAmount = 2 ether;
        uint256 swapOut = 1000e18;

        // Initialize pool in hook.
        hook.forTestInitPool(projectId, nativePoolKey, twapWindow, address(projectToken), address(0));

        // Configure mock deltas for full swap (no leftover).
        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        // Pre-fund pool manager with project tokens.
        projectToken.mint(address(mockPm), swapOut);

        // Mock addToBalanceOf.
        vm.mockCall(
            address(terminal),
            abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
            abi.encode()
        );

        JBAfterPayRecordedContext memory ctx = JBAfterPayRecordedContext({
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
            weight: 1e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(projectTokenIs0, uint256(0), uint256(0), controller),
            payerMetadata: ""
        });

        // This should NOT underflow — the fix captures balanceBefore excluding msg.value.
        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        assertTrue(mockPm.swapCalled(), "swap should have been called");
    }

    /// @notice CORE REGRESSION (ERC-20): A full ERC-20 swap must not underflow when computing
    ///         the leftover balance delta. Before the fix, balanceBefore was captured AFTER
    ///         safeTransferFrom, including the forwarded tokens. The swap consumed those tokens,
    ///         leaving balanceAfter < balanceBefore.
    function test_erc20_fullSwap_noUnderflow() public {
        bool projectTokenIs0 = address(projectToken) < address(terminalToken);
        uint256 payAmount = 1000e18;
        uint256 swapOut = 500e18;

        // Initialize ERC-20 pool in hook.
        hook.forTestInitPool(projectId, erc20PoolKey, twapWindow, address(projectToken), address(terminalToken));

        // Configure mock deltas for full swap (no leftover).
        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        // Pre-fund pool manager with project tokens.
        projectToken.mint(address(mockPm), swapOut);

        // Fund terminal with terminal tokens and approve the hook.
        terminalToken.mint(address(terminal), payAmount);
        vm.prank(address(terminal));
        IERC20(address(terminalToken)).approve(address(hook), payAmount);

        // Mock addToBalanceOf.
        vm.mockCall(
            address(terminal),
            abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
            abi.encode()
        );

        JBAfterPayRecordedContext memory ctx = JBAfterPayRecordedContext({
            payer: payer,
            projectId: projectId,
            rulesetId: 1,
            amount: JBTokenAmount({
                token: address(terminalToken),
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: payAmount
            }),
            forwardedAmount: JBTokenAmount({
                token: address(terminalToken),
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: payAmount
            }),
            weight: 1e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(projectTokenIs0, uint256(0), uint256(0), controller),
            payerMetadata: ""
        });

        // This should NOT underflow — the fix captures balanceBefore BEFORE safeTransferFrom.
        vm.prank(address(terminal));
        hook.afterPayRecordedWith(ctx);

        assertTrue(mockPm.swapCalled(), "swap should have been called");
    }

    /// @notice Verify that pre-existing ETH balance does NOT inflate leftovers.
    ///         The delta approach should yield 0 leftover when the swap consumes everything,
    ///         regardless of pre-existing balance.
    function test_nativeETH_preExistingBalance_notInflated() public {
        // Native ETH (address(0)) < any deployed address, so projectTokenIs0 = false.
        bool projectTokenIs0 = false;
        uint256 payAmount = 1 ether;
        uint256 swapOut = 500e18;
        uint256 preExisting = 10 ether;

        // Initialize pool in hook.
        hook.forTestInitPool(projectId, nativePoolKey, twapWindow, address(projectToken), address(0));

        // Configure mock deltas for full swap.
        if (projectTokenIs0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(int128(uint128(swapOut)), -int128(uint128(payAmount)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            mockPm.setMockDeltas(-int128(uint128(payAmount)), int128(uint128(swapOut)));
        }

        // Pre-fund pool manager with project tokens.
        projectToken.mint(address(mockPm), swapOut);

        // Send pre-existing ETH to the hook (should NOT be counted as leftover).
        vm.deal(address(hook), preExisting);

        // Mock addToBalanceOf — should NOT be called since leftover should be 0.
        // (The mock will accept it if called, but we verify via swapCalled that the swap path ran.)
        vm.mockCall(
            address(terminal),
            abi.encodeWithSignature("addToBalanceOf(uint256,address,uint256,bool,string,bytes)"),
            abi.encode()
        );

        JBAfterPayRecordedContext memory ctx = JBAfterPayRecordedContext({
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
            weight: 1e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(projectTokenIs0, uint256(0), uint256(0), controller),
            payerMetadata: ""
        });

        vm.deal(address(terminal), payAmount);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: payAmount}(ctx);

        assertTrue(mockPm.swapCalled(), "swap should have been called");
        // The pre-existing 10 ETH should still be in the hook, not sent to terminal.
        assertGe(address(hook).balance, preExisting, "pre-existing ETH should remain in hook");
    }
}
