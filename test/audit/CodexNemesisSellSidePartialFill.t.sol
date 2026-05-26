// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract CNProjectToken is ERC20 {
    constructor() ERC20("CodexNemesisProjectToken", "CNPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract CNTerminalToken is ERC20 {
    constructor() ERC20("CodexNemesisTerminalToken", "CNTT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CNController {
    CNProjectToken internal immutable TOKEN;

    uint256 internal _lastBurnCount;

    constructor(CNProjectToken token) {
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
        _lastBurnCount = tokenCount;
        TOKEN.burn(holder, tokenCount);
    }

    function lastBurnCount() external view returns (uint256) {
        return _lastBurnCount;
    }
}

contract CNHook is JBBuybackHook {
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

contract CodexNemesisSellSidePartialFillTest is Test {
    CNHook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    CNProjectToken internal projectToken;
    CNTerminalToken internal terminalToken;
    CNController internal controller;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));

    uint256 internal constant PROJECT_ID = 811;
    uint256 internal constant TWAP_WINDOW = 600;
    uint256 internal constant CASH_OUT_COUNT = 10 ether;
    uint256 internal constant SURPLUS = 50 ether;
    uint256 internal constant TOTAL_SUPPLY = 100 ether;
    uint128 internal constant TWAP_LIQUIDITY = 1_000_000 ether;

    address internal terminal = makeAddr("terminal");
    address internal holder = makeAddr("holder");
    address payable internal beneficiary = payable(makeAddr("beneficiary"));

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new CNProjectToken();
        terminalToken = new CNTerminalToken();
        controller = new CNController(projectToken);

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(terminal, "0x01");
        vm.mockCall(terminal, abi.encodeWithSignature("feeFreeSurplusOf(uint256,address)"), abi.encode(uint256(0)));

        hook = new CNHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants({
            newPoolManager: IPoolManager(address(poolManager)), newOracleHook: IHooks(address(oracleHook))
        });

        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (PROJECT_ID)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (PROJECT_ID, IJBTerminal(terminal))),
            abi.encode(true)
        );
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (PROJECT_ID)), abi.encode(address(this)));
        vm.mockCall(address(tokens), abi.encodeCall(tokens.tokenOf, (PROJECT_ID)), abi.encode(address(projectToken)));
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

        uint160 secondsPerLiquidityDelta = uint160((uint256(TWAP_WINDOW) << 128) / uint256(TWAP_LIQUIDITY));
        oracleHook.setObserveData(0, 0, 0, secondsPerLiquidityDelta);
        poolManager.setSlot0(key.toId(), 79_228_162_514_264_337_593_543_950_336, 0, 3000);
        poolManager.setLiquidity(key.toId(), TWAP_LIQUIDITY);

        hook.setPoolFor({
            projectId: PROJECT_ID, poolKey: key, twapWindow: TWAP_WINDOW, terminalToken: address(terminalToken)
        });
    }

    function test_codexNemesis_sellSidePartialFillReturnsUnsoldProjectTokens() public {
        (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 surplusValue,
            JBCashOutHookSpecification[] memory specs
        ) = hook.beforeCashOutRecordedWith(_beforeContext());

        assertEq(cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE);
        assertEq(cashOutCount, CASH_OUT_COUNT);
        assertEq(totalSupply, TOTAL_SUPPLY);
        assertEq(surplusValue, 0);
        assertEq(specs.length, 1);
        assertFalse(specs[0].noop);

        (
            uint256 minimumSwapAmountOut,,
            uint256 directReclaimAmount,,,,
            uint256 rawSwapQuote,
            bool shouldEnforceMinimumSwapAmountOut
        ) = abi.decode(specs[0].metadata, (uint256, uint256, uint256, int24, uint128, bytes32, uint256, bool));

        assertGt(rawSwapQuote, directReclaimAmount, "route was selected because AMM quote beats direct reclaim");
        assertGt(minimumSwapAmountOut, directReclaimAmount, "derived AMM floor also beats direct reclaim");
        assertFalse(shouldEnforceMinimumSwapAmountOut, "derived floor is not enforced after the swap");

        uint256 amountSpent = 1 ether;
        uint256 amountReceived = 1 ether;

        if (address(projectToken) < address(terminalToken)) {
            poolManager.setMockDeltas(-int128(uint128(amountSpent)), int128(uint128(amountReceived)));
        } else {
            poolManager.setMockDeltas(int128(uint128(amountReceived)), -int128(uint128(amountSpent)));
        }
        terminalToken.mint(address(poolManager), amountReceived);

        vm.prank(terminal);
        hook.afterCashOutRecordedWith(_afterContext(specs[0].metadata));

        assertEq(terminalToken.balanceOf(beneficiary), amountReceived, "beneficiary receives the partial fill output");
        assertLt(
            terminalToken.balanceOf(beneficiary),
            directReclaimAmount,
            "beneficiary gets less than the direct protocol reclaim path"
        );
        assertEq(controller.lastBurnCount(), 0, "unsold project tokens should not be burned");
        assertEq(
            projectToken.balanceOf(holder),
            CASH_OUT_COUNT - amountSpent,
            "holder receives the project tokens that the pool did not buy"
        );
    }

    function _beforeContext() internal view returns (JBBeforeCashOutRecordedContext memory) {
        return JBBeforeCashOutRecordedContext({
            terminal: terminal,
            holder: holder,
            projectId: PROJECT_ID,
            rulesetId: 1,
            cashOutCount: CASH_OUT_COUNT,
            totalSupply: TOTAL_SUPPLY,
            surplus: JBTokenAmount({
                token: address(terminalToken),
                value: SURPLUS,
                decimals: 18,
                currency: uint32(uint160(address(terminalToken)))
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: ""
        });
    }

    function _afterContext(bytes memory hookMetadata) internal view returns (JBAfterCashOutRecordedContext memory) {
        return JBAfterCashOutRecordedContext({
            holder: holder,
            projectId: PROJECT_ID,
            rulesetId: 1,
            cashOutCount: CASH_OUT_COUNT,
            reclaimedAmount: JBTokenAmount({
                token: address(terminalToken), value: 0, decimals: 18, currency: uint32(uint160(address(terminalToken)))
            }),
            forwardedAmount: JBTokenAmount({
                token: address(terminalToken), value: 0, decimals: 18, currency: uint32(uint160(address(terminalToken)))
            }),
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: beneficiary,
            hookMetadata: hookMetadata,
            cashOutMetadata: ""
        });
    }
}
