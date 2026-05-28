// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// JB core
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
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
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

contract V4BuybackHookEfficiency_MockProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Tests for the A2 efficiency fix: when the mint path wins in `beforePayRecordedWith`, the buyback hook
///         returns an empty `hookSpecifications` array so the terminal short-circuits and skips the after-pay
///         callback entirely. The previous behavior returned a single noop spec carrying diagnostic metadata.
contract V4BuybackHookEfficiencyTest is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    JBBuybackHook hook;
    MockPoolManager mockPm;
    MockOracleHook mockOracle;
    V4BuybackHookEfficiency_MockProjectToken projectToken;

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

    uint256 projectId = 7777;
    uint32 twapWindow = 600;

    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        mockPm = new MockPoolManager();
        mockOracle = new MockOracleHook();
        projectToken = new V4BuybackHookEfficiency_MockProjectToken();

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

        hook = new JBBuybackHook({
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

        // native ETH (address(0)) is always currency0 — the smallest address.
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockOracle))
        });
        poolId = poolKey.toId();

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

        // preview mint: returns (beneficiary share, reserved share). Zero is fine for these tests.
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.previewMintOf.selector), abi.encode(0, 0));

        _mockCurrentRuleset(projectId);

        // Pool initialized at tick 0 (price=1) with deep liquidity.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(poolId, sqrtPrice, 0, 3000);
        mockPm.setLiquidity(poolId, 1_000_000 ether);

        vm.prank(owner);
        hook.setPoolFor(projectId, poolKey, twapWindow, JBConstants.NATIVE_TOKEN);
    }

    function _mockCurrentRuleset(uint256 pid) internal {
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
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller), abi.encodeCall(IJBController.currentRulesetOf, (pid)), abi.encode(ruleset, meta)
        );
    }

    /// @notice When the mint path wins (tokenCountWithoutHook >= minimumSwapAmountOut), no hook specification is
    ///         returned and the original weight is preserved so the terminal mints normally and skips the after-pay
    ///         callback entirely.
    /// @dev Achieved by setting the payer's explicit minimum to 0 — the mint path always satisfies a minimum of 0.
    function test_beforePayRecordedWith_noopReturnsEmptySpecs() public {
        uint256 amountToSwapWith = 1 ether;
        uint256 minOut = 0; // any non-zero mint path satisfies this -> noop wins.

        bytes memory quoteMetadata = abi.encode(amountToSwapWith, minOut);
        bytes4 metadataId = JBMetadataResolver.getId("quote", address(hook));
        bytes memory fullMetadata = JBMetadataResolver.addToMetadata("", metadataId, quoteMetadata);

        JBBeforePayRecordedContext memory beforeCtx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: amountToSwapWith
            }),
            projectId: projectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 1e18,
            reservedPercent: 0,
            metadata: fullMetadata
        });

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

        // Mint path: weight passed through unchanged, no hook specifications returned.
        assertEq(weight, beforeCtx.weight, "noop mint path must return the original weight unchanged");
        assertEq(specs.length, 0, "noop mint path must return an empty hookSpecifications array");
    }

    /// @notice Regression — when the swap path wins, exactly one spec is returned, it is NOT noop, and the weight
    ///         is zero so all minting is deferred to `afterPayRecordedWith`.
    function test_beforePayRecordedWith_swapPathStillReturnsSpec() public {
        // Configure the oracle so the TWAP-derived quote produces a real minimum. With weight=1e18 and 1 ETH paid,
        // tokenCountWithoutHook = 1e18; we ask the payer for a much higher minimum so the swap path must win.
        mockOracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        uint256 amountToSwapWith = 1 ether;
        uint256 highMinOut = 5e18;

        bytes memory quoteMetadata = abi.encode(amountToSwapWith, highMinOut);
        bytes4 metadataId = JBMetadataResolver.getId("quote", address(hook));
        bytes memory fullMetadata = JBMetadataResolver.addToMetadata("", metadataId, quoteMetadata);

        JBBeforePayRecordedContext memory beforeCtx = JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: amountToSwapWith
            }),
            projectId: projectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 1e18,
            reservedPercent: 0,
            metadata: fullMetadata
        });

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeCtx);

        assertEq(weight, 0, "swap path must return weight=0 so minting is deferred to afterPayRecordedWith");
        assertEq(specs.length, 1, "swap path must return exactly one hook specification");
        assertFalse(specs[0].noop, "swap path spec must NOT be marked noop");
        assertEq(specs[0].amount, amountToSwapWith, "swap path spec must forward the full amountToSwapWith");
    }
}
