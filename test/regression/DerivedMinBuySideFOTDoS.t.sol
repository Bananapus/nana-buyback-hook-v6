// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract DerivedBuySideTerminalToken is ERC20 {
    constructor() ERC20("TerminalToken", "TT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DerivedBuySideProjectToken is ERC20 {
    uint256 internal constant FEE_BPS = 500;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    constructor() ERC20("FeeOnTransferProjectToken", "FPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value * FEE_BPS / BPS_DENOMINATOR;
        uint256 net = value - fee;
        super._update(from, address(0xBEEF), fee);
        super._update(from, to, net);
    }
}

contract DerivedBuySideController {
    DerivedBuySideProjectToken internal immutable TOKEN;

    constructor(DerivedBuySideProjectToken token) {
        TOKEN = token;
    }

    function burnTokensOf(address holder, uint256, uint256 tokenCount, string memory) external {
        TOKEN.burn(holder, tokenCount);
    }

    function mintTokensOf(
        uint256,
        uint256 tokenCount,
        address beneficiary,
        string memory,
        bool
    )
        external
        returns (uint256)
    {
        TOKEN.mint(beneficiary, tokenCount);
        return tokenCount;
    }

    function previewMintOf(uint256, uint256 tokenCount, bool) external pure returns (uint256, uint256) {
        return (tokenCount, 0);
    }
}

contract DerivedBuySideHook is JBBuybackHook {
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
}

contract DerivedMinBuySideFOTDoSTest is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    DerivedBuySideHook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    DerivedBuySideProjectToken internal projectToken;
    DerivedBuySideTerminalToken internal terminalToken;
    DerivedBuySideController internal controller;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));

    uint256 internal constant PROJECT_ID = 303;
    uint256 internal constant TWAP_WINDOW = 600;
    uint256 internal constant AMOUNT_IN = 10 ether;
    uint128 internal constant TWAP_LIQUIDITY = 1_000_000 ether;
    uint112 internal constant DIRECT_MINT_WEIGHT = 0.96 ether;

    address internal terminal = makeAddr("terminal");

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new DerivedBuySideProjectToken();
        terminalToken = new DerivedBuySideTerminalToken();
        controller = new DerivedBuySideController(projectToken);

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");

        hook = new DerivedBuySideHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants(IPoolManager(address(poolManager)), IHooks(address(oracleHook)));

        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (PROJECT_ID)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (PROJECT_ID, IJBTerminal(terminal))),
            abi.encode(true)
        );
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (PROJECT_ID)), abi.encode(IJBToken(address(projectToken)))
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

        JBRulesetMetadata memory meta = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(terminalToken))),
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
            weight: DIRECT_MINT_WEIGHT,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: meta.packRulesetMetadata()
        });
        vm.mockCall(
            address(controller), abi.encodeCall(IJBController.currentRulesetOf, (PROJECT_ID)), abi.encode(ruleset, meta)
        );

        (Currency currency0, Currency currency1) = address(projectToken) < address(terminalToken)
            ? (Currency.wrap(address(projectToken)), Currency.wrap(address(terminalToken)))
            : (Currency.wrap(address(terminalToken)), Currency.wrap(address(projectToken)));
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(oracleHook))
        });

        uint160 secondsPerLiquidityDelta = uint160((uint256(TWAP_WINDOW) << 128) / uint256(TWAP_LIQUIDITY));
        oracleHook.setObserveData(0, 0, 0, secondsPerLiquidityDelta);
        poolManager.setSlot0(key.toId(), 79_228_162_514_264_337_593_543_950_336, 0, 3000);
        poolManager.setLiquidity(key.toId(), TWAP_LIQUIDITY);
        hook.setPoolFor({
            projectId: PROJECT_ID, poolKey: key, twapWindow: TWAP_WINDOW, terminalToken: address(terminalToken)
        });

        bool projectTokenIs0 = address(projectToken) < address(terminalToken);
        if (projectTokenIs0) {
            // token1 in, token0 out
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(int128(uint128(AMOUNT_IN)), -int128(uint128(AMOUNT_IN)));
        } else {
            // token0 in, token1 out
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(-int128(uint128(AMOUNT_IN)), int128(uint128(AMOUNT_IN)));
        }

        projectToken.mint(address(poolManager), AMOUNT_IN);
        terminalToken.mint(terminal, AMOUNT_IN);
    }

    function test_protocolDerivedMinimumSupportsCustomProjectTokens() public {
        JBBeforePayRecordedContext memory beforeContext = JBBeforePayRecordedContext({
            terminal: terminal,
            payer: makeAddr("payer"),
            amount: JBTokenAmount({
                token: address(terminalToken),
                value: AMOUNT_IN,
                decimals: 18,
                currency: uint32(uint160(address(terminalToken)))
            }),
            projectId: PROJECT_ID,
            rulesetId: 1,
            beneficiary: makeAddr("beneficiary"),
            weight: DIRECT_MINT_WEIGHT,
            reservedPercent: 0,
            metadata: ""
        });

        (uint256 weight, JBPayHookSpecification[] memory specs) = hook.beforePayRecordedWith(beforeContext);

        assertEq(weight, 0, "custom project token should be eligible for TWAP buyback routing");
        assertEq(specs.length, 1, "hook should return one pay-hook specification");
        assertFalse(specs[0].noop, "protocol-derived swap path should be active when it beats minting");
        assertEq(specs[0].amount, AMOUNT_IN, "tokens should be forwarded into the hook");

        (
            ,
            uint256 amountToMintWith,
            uint256 minimumSwapAmountOut,
            bool hasExplicitQuote,
            IJBController decodedController,
            uint256 tokenCountWithoutHook,
            uint256 weightRatio
        ) = abi.decode(specs[0].metadata, (bool, uint256, uint256, bool, IJBController, uint256, uint256));

        assertEq(amountToMintWith, 0, "no partial-mint override should be needed for the direct path");
        assertEq(address(decodedController), address(controller), "metadata should keep the live controller");
        assertFalse(hasExplicitQuote, "metadata-less path should not be explicit");
        assertEq(tokenCountWithoutHook, 9.6 ether, "direct mint path should still be computed");
        assertEq(weightRatio, 1 ether, "weight ratio should stay encoded for explicit follow-up routes");
        assertGt(minimumSwapAmountOut, tokenCountWithoutHook, "custom project token should get a derived AMM floor");
    }
}
