// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBFeeTerminal} from "@bananapus/core-v6/src/interfaces/IJBFeeTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract RegressionSellSideProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract RegressionSellSideFeeOnTransferToken is ERC20 {
    uint256 internal constant FEE_BPS = 100; // 1%

    constructor() ERC20("FeeOnTransferToken", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value / FEE_BPS;
        uint256 net = value - fee;
        super._update(from, address(0xBEEF), fee);
        super._update(from, to, net);
    }
}

contract RegressionSellSideController {
    RegressionSellSideProjectToken internal immutable TOKEN;

    constructor(RegressionSellSideProjectToken token) {
        TOKEN = token;
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

    function burnTokensOf(address holder, uint256, uint256 tokenCount, string memory) external {
        TOKEN.burn(holder, tokenCount);
    }
}

contract RegressionSellSideHook is JBBuybackHook {
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

contract RegressionSellSideFOTOutputDoSTest is Test {
    RegressionSellSideHook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    RegressionSellSideProjectToken internal projectToken;
    RegressionSellSideFeeOnTransferToken internal terminalToken;
    RegressionSellSideController internal controller;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));

    uint256 internal projectId = 101;
    uint256 internal twapWindow = 600;
    address internal terminal = makeAddr("terminal");
    address payable internal beneficiary = payable(makeAddr("beneficiary"));

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new RegressionSellSideProjectToken();
        terminalToken = new RegressionSellSideFeeOnTransferToken();
        controller = new RegressionSellSideController(projectToken);

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");

        hook = new RegressionSellSideHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants({
            poolManager: IPoolManager(address(poolManager)), oracleHook: IHooks(address(oracleHook))
        });

        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (projectId)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (projectId, IJBTerminal(terminal))),
            abi.encode(true)
        );
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(address(this)));
        vm.mockCall(terminal, abi.encodeCall(IJBFeeTerminal.FEE, ()), abi.encode(uint256(25)));
        vm.mockCall(address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(address(projectToken)));
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

        (Currency currency0, Currency currency1) = address(projectToken) < address(terminalToken)
            ? (Currency.wrap(address(projectToken)), Currency.wrap(address(terminalToken)))
            : (Currency.wrap(address(terminalToken)), Currency.wrap(address(projectToken)));

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(oracleHook))
        });

        // forge-lint: disable-next-line(unsafe-typecast)
        oracleHook.setObserveData(0, 0, 0, uint160(uint256(twapWindow) << 64));
        poolManager.setSlot0(key.toId(), 79_228_162_514_264_337_593_543_950_336, 0, 3000); // sqrtPriceX96 at tick 0
        poolManager.setLiquidity(key.toId(), 1_000_000 ether);
        hook.setPoolFor({
            projectId: projectId, poolKey: key, twapWindow: twapWindow, terminalToken: address(terminalToken)
        });
    }

    function test_afterCashOut_revertsWhenOutputTokenTaxesPoolTransfer() public {
        uint256 cashOutCount = 10 ether;
        uint256 quotedAmountOut = 12 ether;

        if (address(projectToken) < address(terminalToken)) {
            // token0 in, token1 out
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(-int128(uint128(cashOutCount)), int128(uint128(quotedAmountOut)));
        } else {
            // token1 in, token0 out
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(int128(uint128(quotedAmountOut)), -int128(uint128(cashOutCount)));
        }

        terminalToken.mint(address(poolManager), quotedAmountOut);

        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: makeAddr("holder"),
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
            reclaimedAmount: JBTokenAmount({
                token: address(terminalToken), value: 0, decimals: 18, currency: uint32(uint160(address(terminalToken)))
            }),
            forwardedAmount: JBTokenAmount({
                token: address(terminalToken), value: 0, decimals: 18, currency: uint32(uint160(address(terminalToken)))
            }),
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(quotedAmountOut, cashOutCount),
            cashOutMetadata: ""
        });

        vm.expectRevert();
        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);
    }

    function test_beforeCashOut_canStillSelectSellPath_withExplicitMinimumForFeeOnTransferTerminalToken() public {
        uint256 quotedAmountOut = 12 ether;
        bytes4 metadataId = JBMetadataResolver.getId("cashOutMinReclaimed", address(hook));
        bytes memory metadata = JBMetadataResolver.addToMetadata({
            originalMetadata: bytes(""), idToAdd: metadataId, dataToAdd: abi.encode(quotedAmountOut)
        });

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: terminal,
            holder: makeAddr("holder"),
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: 10 ether,
            totalSupply: 100 ether,
            surplus: JBTokenAmount({
                token: address(terminalToken),
                value: 5 ether,
                decimals: 18,
                currency: uint32(uint160(address(terminalToken)))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: metadata
        });

        (uint256 cashOutTaxRate,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE, "hook should choose the sell path");
        assertEq(specs.length, 1, "hook should return one specification");
        assertFalse(specs[0].noop, "sell path should be active");
    }
}
