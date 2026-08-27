// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Regression coverage for revnet-style projects that use JBBuybackHook as a fail-open data hook.
// For the standard data-hook pay path, where the payer supplies no buyback pay metadata and
// `hasUserSpecifiedQuote == false`, `beforePayRecordedWith` should not revert and should fall back
// to direct minting whenever the AMM route is not safely executable:
//   - empty / drained current pool liquidity,
//   - dust liquidity (max price impact),
//   - an oracle hook that reverts on observe(),
//   - a third party flipping pool liquidity to zero between quote and pay.
//
// The fail-closed branch is opt-in: a payer who supplies an explicit quote and minimum can revert
// their own payment when that minimum is unreachable, but another account cannot inject metadata into
// someone else's payment to brick the project.

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {IJBBuybackHook} from "src/interfaces/IJBBuybackHook.sol";

import {MockOracleHook} from "../mock/MockOracleHook.sol";
import {MockPoolManager} from "../mock/MockPoolManager.sol";

contract BrickResistanceProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}
}

contract LiveLiquidityPayBrickResistanceTest is Test {
    using JBRulesetMetadataResolver for JBRulesetMetadata;
    using PoolIdLibrary for PoolKey;

    JBBuybackHook hook;
    MockPoolManager poolManager;
    MockOracleHook oracle;
    BrickResistanceProjectToken projectToken;

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
    address attacker = makeAddr("attacker");

    uint256 projectId = 42;
    uint32 twapWindow = 600;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        poolManager = new MockPoolManager();
        oracle = new MockOracleHook();
        projectToken = new BrickResistanceProjectToken();

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

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
            newPoolManager: IPoolManager(address(poolManager)), newOracleHook: IHooks(address(oracle))
        });

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(oracle))
        });
        poolId = poolKey.toId();

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(owner));
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (projectId)), abi.encode(controller));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature("hasPermission(address,address,uint256,uint256,bool,bool)"),
            abi.encode(true)
        );
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.previewMintOf.selector), abi.encode(0, 0));

        _mockCurrentRuleset();

        // Initialize the pool with a valid price and full liquidity so the project owner can configure the pool.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        poolManager.setSlot0(poolId, sqrtPrice, 0, 3000);
        poolManager.setLiquidity(poolId, 1_000_000 ether);

        // Project owner wires the pool into the buyback hook (one-time, deploy-style).
        vm.prank(owner);
        hook.setPoolFor({
            projectId: projectId, fee: 3000, twapWindow: twapWindow, tickSpacing: 60, terminalToken: address(0)
        });
    }

    // --- Fail-open: standard data-hook pay path (no payer metadata) never reverts, always falls back to mint. ---

    function test_emptyLiquidity_noUserQuote_fallsBackToMint() public {
        poolManager.setLiquidity(poolId, 0);
        oracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(""));

        assertEq(weight, 1, "weight unchanged => mint path");
        assertTrue(specs[0].noop, "empty pool must noop to mint");
        assertEq(specs[0].amount, 0, "noop forwards no funds to afterPay");
    }

    function test_dustLiquidity_noUserQuote_fallsBackToMint() public {
        // A warm oracle observation but a drained pool (dust). Max impact => route disabled.
        poolManager.setLiquidity(poolId, 1);
        oracle.setObserveData(1, 1, 0, uint160(uint256(twapWindow) << 64));

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(""));

        assertEq(weight, 1, "dust pool keeps mint weight");
        assertTrue(specs[0].noop, "dust pool must noop to mint");
    }

    function test_revertingOracleHook_noUserQuote_canBootstrapWithBoundedSpot() public {
        // Worst-case grief: pool has live liquidity but the oracle hook itself reverts on observe().
        // JBSwapLib wraps observe() in try/catch. With live liquidity, the buy side can use the bounded
        // cold-start spot fallback to bootstrap without depending on TWAP observations.
        poolManager.setLiquidity(poolId, 1_000_000 ether);
        oracle.setShouldRevert(true);

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(""));

        assertEq(weight, 0, "bounded cold-start spot can activate the AMM route");
        assertFalse(specs[0].noop, "live cold-start pool should not remain issuance-locked");
        assertEq(specs[0].amount, 1 ether, "active route forwards the payment to the hook");
    }

    // --- Third-party manipulation: an attacker draining the pool cannot brick a normal payment. ---

    function test_attackerDrainsLiquidity_normalPaymentStillMints() public {
        // Attacker removes all in-range liquidity right before a victim's payment.
        vm.prank(attacker);
        poolManager.setLiquidity(poolId, 0);
        oracle.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));

        // Victim pays with empty buyback metadata (the revnet default). Must not revert.
        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(""));

        assertEq(weight, 1, "victim payment still mints after attacker drains pool");
        assertTrue(specs[0].noop, "drained pool routes victim to mint, no brick");
    }

    // --- Fail-closed is strictly opt-in: only the payer's OWN explicit minimum can revert their OWN pay. ---

    function test_emptyLiquidity_withPayerExplicitUnreachableMinimum_revertsOnlyForThatPayer() public {
        poolManager.setLiquidity(poolId, 0);

        // Payer asks to swap 1 ETH and demands a minimum that direct mint (weight 1 => 1 token) cannot meet.
        bytes memory payMeta = _payMetadata({amountToSwapWith: 1 ether, minimumSwapAmountOut: 1000 ether});

        // tokenCountWithoutHook = mulDiv(amountToSwapWith=1e18, weight=1, weightRatio=1e18) = 1.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, uint256(1), uint256(1000 ether)
            )
        );
        hook.beforePayRecordedWith(_payContext(payMeta));

        // Critical: the SAME project, SAME drained pool, with NO payer metadata still accepts payment.
        (, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(""));
        assertTrue(specs[0].noop, "default payment unaffected by another payer's strict quote");
    }

    function test_emptyLiquidity_withPayerSatisfiableMinimum_mintsWithoutRevert() public {
        poolManager.setLiquidity(poolId, 0);

        // Payer demands a minimum that direct mint CAN meet (weight 1, 1 ETH => 1e18 tokens; ask for 1).
        bytes memory payMeta = _payMetadata({amountToSwapWith: 1 ether, minimumSwapAmountOut: 1});

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(payMeta));

        assertEq(weight, 1, "satisfiable minimum mints at weight");
        assertTrue(specs[0].noop, "satisfiable minimum noops to mint when pool is empty");
    }

    // --------------------------------------------------------------------- //
    // Helpers
    // --------------------------------------------------------------------- //

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
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });

        vm.mockCall(
            address(controller), abi.encodeCall(IJBController.currentRulesetOf, (projectId)), abi.encode(ruleset, meta)
        );
    }

    function _payContext(bytes memory metadata) internal view returns (JBBeforePayRecordedContext memory) {
        return JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: 1 ether
            }),
            projectId: projectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 1,
            reservedPercent: 0,
            metadata: metadata
        });
    }

    function _payMetadata(uint256 amountToSwapWith, uint256 minimumSwapAmountOut) internal view returns (bytes memory) {
        bytes[] memory data = new bytes[](1);
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = JBMetadataResolver.getId("pay", address(hook));
        data[0] = abi.encode(amountToSwapWith, minimumSwapAmountOut, false);
        return JBMetadataResolver.addToMetadata({originalMetadata: "", idToAdd: ids[0], dataToAdd: data[0]});
    }
}
