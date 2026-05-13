// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract RegressionCashOutProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract RegressionCashOutTerminalToken is ERC20 {
    constructor() ERC20("TerminalToken", "TT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RegressionCashOutController {
    RegressionCashOutProjectToken internal immutable TOKEN;

    uint256 internal _lastMintCount;
    address internal _lastBeneficiary;
    uint256 internal _lastBurnCount;

    constructor(RegressionCashOutProjectToken token) {
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
        _lastBeneficiary = beneficiary;
        TOKEN.mint(beneficiary, tokenCount);
        return tokenCount;
    }

    function lastMintCount() external view returns (uint256) {
        return _lastMintCount;
    }

    function lastBeneficiary() external view returns (address) {
        return _lastBeneficiary;
    }

    function burnTokensOf(address holder, uint256, uint256 tokenCount, string memory) external {
        _lastBurnCount = tokenCount;
        TOKEN.burn(holder, tokenCount);
    }

    function lastBurnCount() external view returns (uint256) {
        return _lastBurnCount;
    }
}

contract RegressionCashOutMetadataHook is JBBuybackHook {
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

contract RegressionCashOutMetadataInflationRegression is Test {
    using PoolIdLibrary for PoolKey;

    RegressionCashOutMetadataHook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    RegressionCashOutProjectToken internal projectToken;
    RegressionCashOutTerminalToken internal terminalToken;
    RegressionCashOutController internal controller;

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
        projectToken = new RegressionCashOutProjectToken();
        terminalToken = new RegressionCashOutTerminalToken();
        controller = new RegressionCashOutController(projectToken);

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");

        hook = new RegressionCashOutMetadataHook({
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

    function test_afterCashOutRecordedWith_inflatedMetadataCannotOverpayBeneficiary() public {
        uint256 actualBurnedCount = 100 ether;
        uint256 inflatedCashOutCount = 200 ether;

        if (address(projectToken) < address(terminalToken)) {
            // token0 in, token1 out
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(-int128(uint128(actualBurnedCount)), int128(uint128(actualBurnedCount)));
        } else {
            // token1 in, token0 out
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(int128(uint128(actualBurnedCount)), -int128(uint128(actualBurnedCount)));
        }

        terminalToken.mint(address(poolManager), actualBurnedCount);

        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: makeAddr("holder"),
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: actualBurnedCount,
            reclaimedAmount: JBTokenAmount({
                token: address(terminalToken), value: 0, decimals: 18, currency: uint32(uint160(address(terminalToken)))
            }),
            forwardedAmount: JBTokenAmount({
                token: address(terminalToken), value: 0, decimals: 18, currency: uint32(uint160(address(terminalToken)))
            }),
            cashOutTaxRate: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(uint256(0), inflatedCashOutCount),
            cashOutMetadata: ""
        });

        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        assertEq(controller.lastMintCount(), actualBurnedCount, "remint should clamp to the actual burned count");
        assertEq(controller.lastBurnCount(), 0, "full fill should not leave reminted residue to burn");
        assertEq(
            terminalToken.balanceOf(beneficiary),
            actualBurnedCount,
            "beneficiary payout should be capped to burned tokens"
        );
        assertEq(projectToken.balanceOf(address(hook)), 0, "hook should not retain reminted project tokens");
    }
}
