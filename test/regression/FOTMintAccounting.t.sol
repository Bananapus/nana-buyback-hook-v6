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
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract RegressionFOTToken is ERC20 {
    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    constructor() ERC20("FeeOnTransfer", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount * FEE_BPS / BPS_DENOMINATOR;
        _transfer(msg.sender, to, amount - fee);
        _burn(msg.sender, fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = amount * FEE_BPS / BPS_DENOMINATOR;
        _transfer(from, to, amount - fee);
        _burn(from, fee);
        return true;
    }
}

contract RegressionProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RegressionTerminal {
    uint256 public recordedReceived;

    function approveToken(address token, address spender, uint256 amount) external {
        ERC20(token).approve(spender, amount);
    }

    function addToBalanceOf(uint256, address token, uint256 amount, bool, string calldata, bytes calldata) external {
        uint256 beforeBalance = ERC20(token).balanceOf(address(this));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        ERC20(token).transferFrom(msg.sender, address(this), amount);
        recordedReceived += ERC20(token).balanceOf(address(this)) - beforeBalance;
    }

    function runAfterPay(JBBuybackHook hook, JBAfterPayRecordedContext calldata context) external {
        hook.afterPayRecordedWith(context);
    }
}

contract RegressionFOTMintAccountingRegression is Test {
    using PoolIdLibrary for PoolKey;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    JBBuybackHook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    RegressionTerminal internal terminal;
    RegressionProjectToken internal projectToken;
    RegressionFOTToken internal terminalToken;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));
    IJBController internal controller = IJBController(makeAddr("controller"));

    uint256 internal projectId = 7;
    address internal owner = makeAddr("owner");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        terminal = new RegressionTerminal();
        projectToken = new RegressionProjectToken();
        terminalToken = new RegressionFOTToken();

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");

        hook = new JBBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            poolManager: IPoolManager(address(poolManager)),
            oracleHook: IHooks(address(oracleHook)),
            trustedForwarder: address(0)
        });

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

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
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
            metadata: metadata.packRulesetMetadata()
        });
        vm.mockCall(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (projectId)),
            abi.encode(ruleset, metadata)
        );

        (Currency c0, Currency c1) = address(terminalToken) < address(projectToken)
            ? (Currency.wrap(address(terminalToken)), Currency.wrap(address(projectToken)))
            : (Currency.wrap(address(projectToken)), Currency.wrap(address(terminalToken)));
        PoolKey memory poolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(oracleHook))});
        PoolId poolId = poolKey.toId();
        poolManager.setSlot0(poolId, TickMath.getSqrtPriceAtTick(0), 0, 3000);
        poolManager.setLiquidity(poolId, 1_000_000 ether);

        vm.prank(owner);
        hook.setPoolFor(projectId, poolKey, 600, address(terminalToken));
    }

    function test_fotFallback_mints_only_what_terminal_reacquires() public {
        uint256 nominalPayment = 100 ether;
        uint256 secondTransferNet = 98.01 ether;

        poolManager.setShouldRevertOnUnlock(true);

        vm.expectCall(
            address(controller),
            abi.encodeWithSignature(
                "mintTokensOf(uint256,uint256,address,string,bool)", projectId, secondTransferNet, beneficiary, "", true
            )
        );
        vm.mockCall(
            address(controller),
            abi.encodeWithSignature(
                "mintTokensOf(uint256,uint256,address,string,bool)", projectId, secondTransferNet, beneficiary, "", true
            ),
            abi.encode(secondTransferNet)
        );

        terminalToken.mint(address(terminal), nominalPayment);
        terminal.approveToken(address(terminalToken), address(hook), nominalPayment);

        JBAfterPayRecordedContext memory context = JBAfterPayRecordedContext({
            payer: makeAddr("payer"),
            projectId: projectId,
            rulesetId: 1,
            amount: JBTokenAmount({
                token: address(terminalToken),
                decimals: 18,
                currency: uint32(uint160(address(terminalToken))),
                value: nominalPayment
            }),
            forwardedAmount: JBTokenAmount({
                token: address(terminalToken),
                decimals: 18,
                currency: uint32(uint160(address(terminalToken))),
                value: nominalPayment
            }),
            weight: 1e18,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(
                address(projectToken) < address(terminalToken),
                0,
                0,
                false,
                controller,
                uint256(0),
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

        terminal.runAfterPay(hook, context);

        assertEq(terminal.recordedReceived(), secondTransferNet, "terminal only reacquired net-after-second-fee funds");
        assertEq(terminalToken.balanceOf(address(hook)), 0, "hook should not retain leftover after terminal pull");
    }
}
