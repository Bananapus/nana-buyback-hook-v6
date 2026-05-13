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
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract DerivedMinProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract DerivedMinTerminalToken is ERC20 {
    uint256 internal constant FEE_BPS = 500;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    constructor() ERC20("FeeOnTransferToken", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
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

contract DerivedMinController {
    DerivedMinProjectToken internal immutable TOKEN;

    constructor(DerivedMinProjectToken token) {
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

contract DerivedMinFOTSellSideHook is JBBuybackHook {
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

contract DerivedMinSellSideFOTDoSTest is Test {
    DerivedMinFOTSellSideHook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    DerivedMinProjectToken internal projectToken;
    DerivedMinTerminalToken internal terminalToken;
    DerivedMinController internal controller;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));

    uint256 internal constant PROJECT_ID = 202;
    uint256 internal constant TWAP_WINDOW = 600;
    uint256 internal constant CASH_OUT_COUNT = 10 ether;
    uint256 internal constant SURPLUS = 96 ether;
    uint256 internal constant TOTAL_SUPPLY = 100 ether;
    uint128 internal constant TWAP_LIQUIDITY = 1_000_000 ether;

    address internal terminal = makeAddr("terminal");

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new DerivedMinProjectToken();
        terminalToken = new DerivedMinTerminalToken();
        controller = new DerivedMinController(projectToken);

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");

        hook = new DerivedMinFOTSellSideHook({
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
        vm.mockCall(terminal, abi.encodeCall(IJBFeeTerminal.FEE, ()), abi.encode(uint256(25)));
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

        if (address(projectToken) < address(terminalToken)) {
            // token0 in, token1 out
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(-int128(uint128(CASH_OUT_COUNT)), int128(uint128(CASH_OUT_COUNT)));
        } else {
            // token1 in, token0 out
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(int128(uint128(CASH_OUT_COUNT)), -int128(uint128(CASH_OUT_COUNT)));
        }

        terminalToken.mint(address(poolManager), CASH_OUT_COUNT);
    }

    function test_protocolDerivedMinimumSupportsERC20OutputTokens() public {
        JBBeforeCashOutRecordedContext memory beforeContext = JBBeforeCashOutRecordedContext({
            terminal: terminal,
            holder: makeAddr("holder"),
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

        (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 surplusValue,
            JBCashOutHookSpecification[] memory specs
        ) = hook.beforeCashOutRecordedWith(beforeContext);

        assertEq(
            cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE, "ERC20 output should be eligible for TWAP sell routing"
        );
        assertEq(cashOutCount, CASH_OUT_COUNT, "cash-out count should stay unchanged");
        assertEq(totalSupply, TOTAL_SUPPLY, "total supply should stay unchanged");
        assertEq(surplusValue, 0, "surplus should be zeroed for hook-executed sell routing");
        assertEq(specs.length, 1, "hook should return one sell-side specification");
        assertFalse(specs[0].noop, "protocol-derived sell-side hook should be active when it beats reclaim");

        (uint256 minimumSwapAmountOut,,,,,, uint256 rawSwapQuote) =
            abi.decode(specs[0].metadata, (uint256, uint256, uint256, int24, uint128, bytes32, uint256));

        assertGt(rawSwapQuote, 0, "metadata-less ERC20 output should get a TWAP quote");
        assertGt(minimumSwapAmountOut, 0, "metadata-less ERC20 output should get an AMM floor");
    }
}
