// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
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
import {JBSwapLib} from "src/libraries/JBSwapLib.sol";

import {MockOracleHook} from "../mock/MockOracleHook.sol";
import {MockPoolManager} from "../mock/MockPoolManager.sol";

contract ColdStartProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ColdStartSpotFallbackTest is Test {
    using JBRulesetMetadataResolver for JBRulesetMetadata;
    using PoolIdLibrary for PoolKey;

    struct PayMetadata {
        bool projectTokenIs0;
        uint256 amountToMintWith;
        uint256 minimumSwapAmountOut;
        bool hasUserSpecifiedQuote;
        IJBController controller;
        uint256 tokenCountWithoutHook;
        uint256 weightRatio;
        uint256 quotedAmountToSwapWith;
        int24 twapTick;
        uint128 twapLiquidity;
        PoolId poolId;
        uint256 minimumBeneficiaryTokenCount;
        uint256 minimumReservedTokenCount;
        uint256 rawSwapQuote;
        bool oracleUnseeded;
    }

    JBBuybackHook hook;
    MockPoolManager poolManager;
    MockOracleHook oracle;
    ColdStartProjectToken projectToken;

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
        poolManager = new MockPoolManager();
        oracle = new MockOracleHook();
        projectToken = new ColdStartProjectToken();

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
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.previewMintOf.selector), abi.encode(0, 0));
        vm.mockCall(
            address(controller), abi.encodeWithSignature("burnTokensOf(address,uint256,uint256,string)"), abi.encode()
        );
        vm.mockCall(
            address(controller),
            abi.encodeWithSignature("mintTokensOf(uint256,uint256,address,string,bool)"),
            abi.encode(0)
        );

        _mockCurrentRuleset({mockProjectId: projectId});
        _setSpot({tick: 0, liquidity: 1_000_000 ether});

        vm.prank(owner);
        hook.setPoolFor({projectId: projectId, poolKey: poolKey, twapWindow: twapWindow, terminalToken: address(0)});
    }

    function test_coldStartLivePool_usesBoundedSpotFallbackForFirstPay() public {
        oracle.setShouldRevert(true);
        _setSpot({tick: 1000, liquidity: 1_000_000 ether});

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(1 ether));
        PayMetadata memory metadata = _decode(specs[0].metadata);

        assertEq(weight, 0, "cold-start spot route should zero mint weight");
        assertFalse(specs[0].noop, "better bounded spot quote should activate AMM route");
        assertEq(specs[0].amount, 1 ether, "entire payment should be forwarded to the hook");
        assertTrue(metadata.oracleUnseeded, "cold-start state should be explicit");
        assertEq(metadata.twapTick, 1000, "cold-start diagnostics should surface the spot tick used");
        assertEq(metadata.twapLiquidity, 0, "TWAP liquidity remains zero while oracle is unseeded");
        assertGt(
            metadata.rawSwapQuote, metadata.tokenCountWithoutHook, "spot quote should beat issuance before haircut"
        );
        assertEq(
            metadata.minimumSwapAmountOut,
            metadata.tokenCountWithoutHook,
            "cold-start metadata should expose the issuance execution floor"
        );
    }

    function test_coldStartNoQuote_underDeliveredSwapDoesNotRevert() public {
        oracle.setShouldRevert(true);
        _setSpot({tick: 1000, liquidity: 1_000_000 ether});

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(1 ether));
        PayMetadata memory metadata = _decode(specs[0].metadata);

        assertEq(weight, 0, "cold-start spot route should zero mint weight");
        assertFalse(specs[0].noop, "cold-start route should activate");
        assertEq(metadata.minimumSwapAmountOut, metadata.tokenCountWithoutHook, "cold-start floor should be issuance");
        assertGt(metadata.rawSwapQuote, 1.01 ether, "test needs a spot quote above the simulated output");
        assertTrue(metadata.oracleUnseeded, "test needs cold-start metadata");

        uint256 swapOut = 1.01 ether;
        poolManager.setMockDeltas(-int128(uint128(1 ether)), int128(uint128(swapOut)));
        projectToken.mint(address(poolManager), swapOut);

        vm.expectCall(
            address(controller),
            abi.encodeWithSignature(
                "mintTokensOf(uint256,uint256,address,string,bool)", projectId, swapOut, beneficiary, "", true
            )
        );

        vm.deal(address(terminal), 1 ether);
        vm.prank(address(terminal));
        hook.afterPayRecordedWith{value: 1 ether}(_afterPayContext({amount: 1 ether, hookMetadata: specs[0].metadata}));
    }

    function test_coldStartSpotFallback_rejectsLargeFirstTrade() public {
        oracle.setShouldRevert(true);
        _setSpot({tick: 1000, liquidity: 10 ether});

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(1 ether));
        PayMetadata memory metadata = _decode(specs[0].metadata);

        assertEq(weight, 1e18, "oversized cold-start payment should keep mint weight");
        assertTrue(specs[0].noop, "impact cap should block the AMM route");
        assertEq(metadata.minimumSwapAmountOut, 0, "blocked cold-start quote should not create an AMM floor");
        assertEq(metadata.rawSwapQuote, 0, "blocked cold-start quote should not report an executable quote");
        assertTrue(metadata.oracleUnseeded, "UI should still be able to identify the cold-start state");
    }

    function test_coldStartSpotFallback_routesHighFeePoolWhenFeeAdjustedQuoteBeatsIssuance() public {
        oracle.setShouldRevert(true);
        _setSpot({tick: 3000, liquidity: 1_000_000 ether, lpFee: 50_000});

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(1 ether));
        PayMetadata memory metadata = _decode(specs[0].metadata);

        assertEq(weight, 0, "high-fee cold-start pool should route when the adjusted quote beats issuance");
        assertFalse(specs[0].noop, "fee-adjusted bootstrap quote should activate the AMM route");
        assertEq(metadata.minimumSwapAmountOut, metadata.tokenCountWithoutHook, "active floor should be issuance-rate");
        assertGt(metadata.rawSwapQuote, metadata.tokenCountWithoutHook, "raw quote should show the executable market");
        assertTrue(metadata.oracleUnseeded, "UI should still be able to identify the cold-start state");
    }

    function test_coldStartSpotFallback_mintsWhenFeeAdjustedQuoteLosesToIssuance() public {
        oracle.setShouldRevert(true);
        _setSpot({tick: 1000, liquidity: 1_000_000 ether, lpFee: 90_000});

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(1 ether));
        PayMetadata memory metadata = _decode(specs[0].metadata);

        assertEq(weight, 1e18, "fee-adjusted cold-start quote below issuance should keep mint weight");
        assertTrue(specs[0].noop, "fee-adjusted quote should lose to issuance");
        assertEq(
            metadata.minimumSwapAmountOut, metadata.tokenCountWithoutHook, "cold-start metadata keeps issuance floor"
        );
        assertGt(metadata.rawSwapQuote, metadata.tokenCountWithoutHook, "raw spot can win before live fee discount");
        assertTrue(metadata.oracleUnseeded, "UI should still be able to identify the cold-start state");
    }

    function test_zeroTwapLiquidityWithValidTick_usesOracleTickInsteadOfSlot0() public {
        int24 twapTick = 1000;
        int24 spotTick = 20_000;
        oracle.setObserveData(0, int56(twapTick) * int56(uint56(twapWindow)), 0, 0);
        _setSpot({tick: spotTick, liquidity: 1_000_000 ether});

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(1 ether));
        PayMetadata memory metadata = _decode(specs[0].metadata);

        assertEq(weight, 0, "valid oracle tick should still allow a bounded bootstrap quote");
        assertFalse(specs[0].noop, "oracle-tick bootstrap should activate when it beats issuance");
        assertTrue(metadata.oracleUnseeded, "zero harmonic liquidity should remain detectable");
        assertEq(metadata.twapTick, twapTick, "route should use the oracle tick, not slot0");
        assertEq(metadata.twapLiquidity, 0, "harmonic liquidity remains unavailable");
        assertEq(
            metadata.rawSwapQuote,
            JBSwapLib.getQuoteAtTick({
                tick: twapTick, baseAmount: uint128(1 ether), baseToken: address(0), quoteToken: address(projectToken)
            }),
            "raw quote should come from the oracle tick"
        );
        assertLt(
            metadata.rawSwapQuote,
            JBSwapLib.getQuoteAtTick({
                tick: spotTick, baseAmount: uint128(1 ether), baseToken: address(0), quoteToken: address(projectToken)
            }),
            "slot0 quote should be ignored"
        );
    }

    function test_userSpecifiedQuote_reportsOracleUnseededWithoutChangingQuoteFloor() public {
        oracle.setShouldRevert(true);
        _setSpot({tick: 1000, liquidity: 1_000_000 ether});

        bytes memory metadata = _payMetadata({amountToSwapWith: 1 ether, minimumSwapAmountOut: 1.01 ether});
        (uint256 weight, JBPayHookSpecification[] memory specs) =
            hook.beforePayRecordedWith(_payContext({mockProjectId: projectId, amount: 1 ether, metadata: metadata}));
        PayMetadata memory decoded = _decode(specs[0].metadata);

        assertEq(weight, 0, "caller quote should still control route selection");
        assertFalse(specs[0].noop, "caller quote above issuance should activate the AMM route");
        assertTrue(decoded.hasUserSpecifiedQuote, "metadata should identify the caller quote path");
        assertEq(decoded.minimumSwapAmountOut, 1.01 ether, "caller quote should stay the settlement floor");
        assertTrue(decoded.oracleUnseeded, "diagnostics should still expose the cold-start oracle state");
    }

    function test_coldStartSpotFallback_rejectsPoolWithUnconfiguredHook() public {
        uint256 otherProjectId = 43;
        MockOracleHook otherHook = new MockOracleHook();
        PoolKey memory otherPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(otherHook))
        });
        PoolId otherPoolId = otherPoolKey.toId();

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (otherProjectId)), abi.encode(owner));
        vm.mockCall(
            address(directory), abi.encodeCall(directory.controllerOf, (otherProjectId)), abi.encode(controller)
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (otherProjectId, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );
        vm.mockCall(
            address(tokens),
            abi.encodeCall(tokens.tokenOf, (otherProjectId)),
            abi.encode(IJBToken(address(projectToken)))
        );
        _mockCurrentRuleset({mockProjectId: otherProjectId});
        poolManager.setSlot0(otherPoolId, TickMath.getSqrtPriceAtTick(1000), 1000, 3000);
        poolManager.setLiquidity(otherPoolId, 1_000_000 ether);

        vm.prank(owner);
        hook.setPoolFor({
            projectId: otherProjectId, poolKey: otherPoolKey, twapWindow: twapWindow, terminalToken: address(0)
        });

        (uint256 weight, JBPayHookSpecification[] memory specs) =
            hook.beforePayRecordedWith(_payContext({mockProjectId: otherProjectId, amount: 1 ether, metadata: ""}));
        PayMetadata memory decoded = _decode(specs[0].metadata);

        assertEq(weight, 1e18, "pool with unconfigured oracle hook should keep mint weight");
        assertTrue(specs[0].noop, "unconfigured oracle hook should block raw spot bootstrap");
        assertTrue(decoded.oracleUnseeded, "UI should still be able to identify the cold-start state");
        assertEq(decoded.rawSwapQuote, 0, "rejected bootstrap path should not report an executable quote");
    }

    function test_warmPool_usesTwapEvenWhenSpotIsDifferent() public {
        int24 twapTick = 1000;
        uint128 liquidity = 1_000_000 ether;
        uint160 secondsPerLiquidityDelta = uint160((uint256(twapWindow) << 128) / uint256(liquidity));

        oracle.setObserveData(0, int56(twapTick) * int56(uint56(twapWindow)), 0, secondsPerLiquidityDelta);
        _setSpot({tick: 20_000, liquidity: liquidity});

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(_payContext(1 ether));
        PayMetadata memory metadata = _decode(specs[0].metadata);

        assertEq(weight, 0, "warm TWAP route should still activate when TWAP beats issuance");
        assertFalse(specs[0].noop, "warm routing should be unchanged");
        assertFalse(metadata.oracleUnseeded, "warm oracle should not be flagged as cold-start");
        assertEq(metadata.twapTick, twapTick, "route should use the TWAP tick, not manipulated slot0");
        assertGt(metadata.twapLiquidity, 0, "warm oracle should report harmonic liquidity");
        assertEq(
            metadata.rawSwapQuote,
            JBSwapLib.getQuoteAtTick({
                tick: twapTick, baseAmount: uint128(1 ether), baseToken: address(0), quoteToken: address(projectToken)
            }),
            "raw quote should come from TWAP"
        );
    }

    function _decode(bytes memory metadata) internal pure returns (PayMetadata memory decoded) {
        decoded = abi.decode(metadata, (PayMetadata));
    }

    function _afterPayContext(
        uint256 amount,
        bytes memory hookMetadata
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
                value: amount
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: amount
            }),
            weight: 1e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: hookMetadata,
            payerMetadata: ""
        });
    }

    function _mockCurrentRuleset(uint256 mockProjectId) internal {
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
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (mockProjectId)),
            abi.encode(ruleset, meta)
        );
    }

    function _payContext(uint256 amount) internal view returns (JBBeforePayRecordedContext memory) {
        return _payContext({mockProjectId: projectId, amount: amount, metadata: ""});
    }

    function _payContext(
        uint256 mockProjectId,
        uint256 amount,
        bytes memory metadata
    )
        internal
        view
        returns (JBBeforePayRecordedContext memory)
    {
        return JBBeforePayRecordedContext({
            terminal: address(terminal),
            payer: payer,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: amount
            }),
            projectId: mockProjectId,
            rulesetId: 1,
            beneficiary: beneficiary,
            weight: 1e18,
            reservedPercent: 0,
            metadata: metadata
        });
    }

    function _payMetadata(uint256 amountToSwapWith, uint256 minimumSwapAmountOut) internal view returns (bytes memory) {
        bytes4 metadataId = JBMetadataResolver.getId("pay", address(hook));
        return JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: metadataId,
            dataToAdd: abi.encode(amountToSwapWith, minimumSwapAmountOut, false)
        });
    }

    function _setSpot(int24 tick, uint128 liquidity) internal {
        _setSpot({tick: tick, liquidity: liquidity, lpFee: 3000});
    }

    function _setSpot(int24 tick, uint128 liquidity, uint24 lpFee) internal {
        poolManager.setSlot0(poolId, TickMath.getSqrtPriceAtTick(tick), tick, lpFee);
        poolManager.setLiquidity(poolId, liquidity);
    }
}
