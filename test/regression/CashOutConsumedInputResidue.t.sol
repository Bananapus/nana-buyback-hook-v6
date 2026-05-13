// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract CCIR_ProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract CCIR_TerminalToken is ERC20 {
    constructor() ERC20("TerminalToken", "TT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CCIR_Controller {
    CCIR_ProjectToken internal immutable TOKEN;

    uint256 internal _lastMintCount;
    uint256 internal _lastBurnCount;

    constructor(CCIR_ProjectToken token) {
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
        _lastMintCount = tokenCount;
        TOKEN.mint(beneficiary, tokenCount);
        return tokenCount;
    }

    function burnTokensOf(address holder, uint256, uint256 tokenCount, string memory) external {
        _lastBurnCount = tokenCount;
        TOKEN.burn(holder, tokenCount);
    }

    function lastMintCount() external view returns (uint256) {
        return _lastMintCount;
    }

    function lastBurnCount() external view returns (uint256) {
        return _lastBurnCount;
    }
}

contract CCIR_Hook is JBBuybackHook {
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
        address projectToken,
        address terminalToken
    )
        external
    {
        _poolKeyOf[projectId][terminalToken] = key;
        projectTokenOf[projectId] = projectToken;
    }
}

contract CashOutConsumedInputResidue is Test {
    CCIR_Hook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    CCIR_ProjectToken internal projectToken;
    CCIR_TerminalToken internal terminalToken;
    CCIR_Controller internal controller;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));

    uint256 internal projectId = 77;
    address internal terminal = makeAddr("terminal");
    address payable internal beneficiary = payable(makeAddr("beneficiary"));

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new CCIR_ProjectToken();
        terminalToken = new CCIR_TerminalToken();
        controller = new CCIR_Controller(projectToken);

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");

        hook = new CCIR_Hook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants(IPoolManager(address(poolManager)), IHooks(address(oracleHook)));

        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (projectId)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (projectId, IJBTerminal(terminal))),
            abi.encode(true)
        );

        (Currency currency0, Currency currency1) = address(projectToken) < address(terminalToken)
            ? (Currency.wrap(address(projectToken)), Currency.wrap(address(terminalToken)))
            : (Currency.wrap(address(terminalToken)), Currency.wrap(address(projectToken)));

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(oracleHook))
        });

        hook.forTestInitPool({
            projectId: projectId, key: key, projectToken: address(projectToken), terminalToken: address(terminalToken)
        });
    }

    function test_afterCashOutRecordedWith_burnsOnlyCurrentUnsoldResidue() public {
        uint256 cashOutCountToSell = 100 ether;
        uint256 swapConsumed = 60 ether;
        uint256 amountReceived = 60 ether;
        uint256 preExistingHookBalance = 25 ether;

        if (address(projectToken) < address(terminalToken)) {
            // token0 in, token1 out
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(-int128(uint128(swapConsumed)), int128(uint128(amountReceived)));
        } else {
            // token1 in, token0 out
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(int128(uint128(amountReceived)), -int128(uint128(swapConsumed)));
        }

        projectToken.mint(address(hook), preExistingHookBalance);
        terminalToken.mint(address(poolManager), amountReceived);

        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: makeAddr("holder"),
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCountToSell,
            reclaimedAmount: JBTokenAmount({
                token: address(terminalToken), value: 0, decimals: 18, currency: uint32(uint160(address(terminalToken)))
            }),
            forwardedAmount: JBTokenAmount({
                token: address(terminalToken), value: 0, decimals: 18, currency: uint32(uint160(address(terminalToken)))
            }),
            cashOutTaxRate: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(uint256(0), cashOutCountToSell),
            cashOutMetadata: ""
        });

        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        assertEq(controller.lastMintCount(), cashOutCountToSell, "hook should remint the requested sell amount");
        assertEq(
            controller.lastBurnCount(), cashOutCountToSell - swapConsumed, "only unsold reminted residue should burn"
        );
        assertEq(
            projectToken.balanceOf(address(hook)),
            preExistingHookBalance,
            "pre-existing project token balance should remain untouched"
        );
        assertEq(terminalToken.balanceOf(beneficiary), amountReceived, "beneficiary should receive swap proceeds");
    }
}
