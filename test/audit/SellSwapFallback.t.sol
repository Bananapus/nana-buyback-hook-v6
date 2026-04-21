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

import {IJBBuybackHook} from "../../src/interfaces/IJBBuybackHook.sol";
import {JBBuybackHook} from "../../src/JBBuybackHook.sol";
import {MockOracleHook} from "../mock/MockOracleHook.sol";
import {MockPoolManager} from "../mock/MockPoolManager.sol";

/// @notice Simple ERC20 project token for testing.
contract SSF_ProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Simple ERC20 terminal token for testing.
contract SSF_TerminalToken is ERC20 {
    constructor() ERC20("TerminalToken", "TT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal controller that actually mints/burns project tokens.
contract SSF_Controller {
    SSF_ProjectToken internal immutable TOKEN;

    uint256 internal _lastMintCount;

    constructor(SSF_ProjectToken token) {
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
        TOKEN.burn(holder, tokenCount);
    }

    function lastMintCount() external view returns (uint256) {
        return _lastMintCount;
    }
}

/// @notice Test harness exposing JBBuybackHook internals for pool initialization.
contract SSF_Hook is JBBuybackHook {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBPrices prices,
        IJBProjects projects,
        IJBTokens tokens,
        IPoolManager poolManager,
        IHooks oracleHook,
        address trustedForwarder
    )
        JBBuybackHook(directory, permissions, prices, projects, tokens, poolManager, oracleHook, trustedForwarder)
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

/// @notice When the V4 pool reverts during a sell-side cash-out, the hook should return
/// reminted project tokens to the beneficiary instead of reverting the entire cash-out.
contract SellSwapFallback is Test {
    SSF_Hook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    SSF_ProjectToken internal projectToken;
    SSF_TerminalToken internal terminalToken;
    SSF_Controller internal controller;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));

    uint256 internal projectId = 88;
    address internal terminal = makeAddr("terminal");
    address payable internal beneficiary = payable(makeAddr("beneficiary"));

    PoolKey internal poolKey;

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new SSF_ProjectToken();
        terminalToken = new SSF_TerminalToken();
        controller = new SSF_Controller(projectToken);

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");

        hook = new SSF_Hook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            poolManager: IPoolManager(address(poolManager)),
            oracleHook: IHooks(address(oracleHook)),
            trustedForwarder: address(0)
        });

        // Mock directory responses.
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (projectId)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (projectId, IJBTerminal(terminal))),
            abi.encode(true)
        );

        // Sort currencies for pool key construction.
        (Currency currency0, Currency currency1) = address(projectToken) < address(terminalToken)
            ? (Currency.wrap(address(projectToken)), Currency.wrap(address(terminalToken)))
            : (Currency.wrap(address(terminalToken)), Currency.wrap(address(projectToken)));

        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(oracleHook))
        });

        hook.forTestInitPool({
            projectId: projectId,
            key: poolKey,
            projectToken: address(projectToken),
            terminalToken: address(terminalToken)
        });
    }

    /// @notice Build a sell-side afterCashOutRecordedWith context.
    function _buildCashOutContext(
        uint256 cashOutCount,
        uint256 minimumSwapAmountOut,
        uint256 cashOutCountToSell
    )
        internal
        returns (JBAfterCashOutRecordedContext memory)
    {
        return JBAfterCashOutRecordedContext({
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
            cashOutTaxRate: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(minimumSwapAmountOut, cashOutCountToSell),
            cashOutMetadata: ""
        });
    }

    /// @notice When the V4 pool reverts (e.g., zero liquidity), afterCashOutRecordedWith should NOT
    /// revert. Instead, it should transfer project tokens to the beneficiary and emit SellSwapReverted.
    function test_sellSwapFallback_returnsTokensOnPoolRevert() public {
        uint256 cashOutCount = 100 ether;

        // Force pool manager to revert on unlock.
        poolManager.setShouldRevertOnUnlock(true);

        JBAfterCashOutRecordedContext memory context = _buildCashOutContext({
            cashOutCount: cashOutCount, minimumSwapAmountOut: 0, cashOutCountToSell: cashOutCount
        });

        // Expect the SellSwapReverted event.
        vm.expectEmit(true, true, true, true);
        emit IJBBuybackHook.SellSwapReverted({projectId: projectId, beneficiary: beneficiary, amount: cashOutCount});

        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        // The beneficiary should have received the reminted project tokens.
        assertEq(
            projectToken.balanceOf(beneficiary), cashOutCount, "beneficiary should receive reminted project tokens"
        );

        // The hook should have zero project token balance (all transferred out).
        assertEq(projectToken.balanceOf(address(hook)), 0, "hook should not retain any project tokens");

        // The controller should have minted exactly the cashOutCount.
        assertEq(controller.lastMintCount(), cashOutCount, "controller should have minted the sell count");
    }

    /// @notice When the swap succeeds, behavior is unchanged — tokens are sold, proceeds go to beneficiary.
    function test_sellSwapFallback_normalSwapStillWorks() public {
        uint256 cashOutCount = 100 ether;
        uint256 swapConsumed = 100 ether;
        uint256 amountReceived = 80 ether;

        // Configure mock pool to return valid deltas.
        if (address(projectToken) < address(terminalToken)) {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(-int128(uint128(swapConsumed)), int128(uint128(amountReceived)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(int128(uint128(amountReceived)), -int128(uint128(swapConsumed)));
        }

        // Fund pool manager with terminal tokens for the take.
        terminalToken.mint(address(poolManager), amountReceived);

        JBAfterCashOutRecordedContext memory context = _buildCashOutContext({
            cashOutCount: cashOutCount, minimumSwapAmountOut: 0, cashOutCountToSell: cashOutCount
        });

        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        // Beneficiary should receive terminal tokens from the swap, not project tokens.
        assertEq(
            terminalToken.balanceOf(beneficiary), amountReceived, "beneficiary should receive terminal token proceeds"
        );
        assertEq(projectToken.balanceOf(beneficiary), 0, "beneficiary should NOT receive project tokens on success");
    }

    /// @notice With a smaller metadata-provided sell count, only that portion is reminted and returned on failure.
    function test_sellSwapFallback_respectsMetadataSellCount() public {
        uint256 cashOutCount = 100 ether;
        uint256 cashOutCountToSell = 60 ether;

        // Force revert.
        poolManager.setShouldRevertOnUnlock(true);

        JBAfterCashOutRecordedContext memory context = _buildCashOutContext({
            cashOutCount: cashOutCount, minimumSwapAmountOut: 0, cashOutCountToSell: cashOutCountToSell
        });

        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        // Only the metadata-provided count should be minted and returned.
        assertEq(
            projectToken.balanceOf(beneficiary),
            cashOutCountToSell,
            "only metadata sell count should be returned to beneficiary"
        );
        assertEq(controller.lastMintCount(), cashOutCountToSell, "controller should mint only the metadata sell count");
    }

    /// @notice Pre-existing project token balances on the hook are not affected by the fallback.
    function test_sellSwapFallback_preservesPreExistingBalance() public {
        uint256 cashOutCount = 50 ether;
        uint256 preExisting = 25 ether;

        // Give hook a pre-existing project token balance.
        projectToken.mint(address(hook), preExisting);

        // Force revert.
        poolManager.setShouldRevertOnUnlock(true);

        JBAfterCashOutRecordedContext memory context = _buildCashOutContext({
            cashOutCount: cashOutCount, minimumSwapAmountOut: 0, cashOutCountToSell: cashOutCount
        });

        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        // Pre-existing balance should be untouched; only the reminted tokens should go to beneficiary.
        assertEq(
            projectToken.balanceOf(address(hook)), preExisting, "pre-existing hook balance should remain untouched"
        );
        assertEq(
            projectToken.balanceOf(beneficiary), cashOutCount, "beneficiary should receive only the reminted tokens"
        );
    }

    /// @notice When the pool reverts during a native ETH cash-out, the fallback still works
    /// (project tokens go to beneficiary, no ETH involved in fallback path).
    function test_sellSwapFallback_nativeTokenCashOut() public {
        uint256 cashOutCount = 100 ether;

        // Force revert.
        poolManager.setShouldRevertOnUnlock(true);

        // Build context with native token as the reclaimed token.
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
            cashOutTaxRate: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(uint256(0), cashOutCount),
            cashOutMetadata: ""
        });

        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        assertEq(
            projectToken.balanceOf(beneficiary), cashOutCount, "beneficiary should receive project tokens on failure"
        );
    }
}
