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

/// @notice ERC20 project token with a 1% fee on transfer (fee-on-transfer).
/// Minting and burning bypass the fee; only transfers between non-zero addresses are taxed.
contract FOTProjectToken is ERC20 {
    uint256 internal constant FEE_DIVISOR = 100; // 1% fee

    constructor() ERC20("FOTProjectToken", "FPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /// @dev Override _update to apply fee on transfer between non-zero addresses.
    function _update(address from, address to, uint256 value) internal override {
        // Mints and burns bypass the fee.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value / FEE_DIVISOR;
        uint256 net = value - fee;
        // Send fee to a dead address (simulating burn/tax).
        super._update(from, address(0xBEEF), fee);
        super._update(from, to, net);
    }
}

/// @notice Simple ERC20 terminal token for testing.
contract FOTTerminalToken is ERC20 {
    constructor() ERC20("TerminalToken", "TT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal controller that mints/burns FOT project tokens.
/// When `mintTokensOf` is called, the controller mints tokens to the beneficiary.
/// Because the project token has a fee on transfer, the beneficiary (the hook) will
/// receive fewer tokens than requested if the mint goes through a transfer path.
/// However, _mint bypasses the fee, so the controller uses `transfer` to simulate
/// a realistic scenario where the hook receives tokens via a transfer that triggers FOT.
contract FOTController {
    FOTProjectToken internal immutable TOKEN;

    uint256 internal _lastMintCount;

    constructor(FOTProjectToken token) {
        TOKEN = token;
    }

    /// @notice Mints tokens to THIS contract, then transfers to the beneficiary.
    /// The transfer triggers the FOT fee, so the beneficiary receives less than `tokenCount`.
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
        // Mint to controller first (no fee on mint).
        TOKEN.mint(address(this), tokenCount);
        // Transfer to beneficiary triggers FOT fee — beneficiary receives 99%.
        require(TOKEN.transfer(beneficiary, tokenCount));
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
contract FOTHook is JBBuybackHook {
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

/// @title FOTProjectTokenTest
/// @notice When the project token is a fee-on-transfer token, afterCashOutRecordedWith
/// should use the actual received balance (not the nominal cashOutCountToSell) for swap input,
/// fallback transfer, and burn calculations.
///
/// Before fix: the hook assumes it received exactly `cashOutCountToSell` tokens from mintTokensOf,
/// but with a FOT project token it actually receives less. This causes:
/// 1. `_swapExactInput` tries to sell more tokens than the hook holds -> revert
/// 2. `swapFailed` fallback tries to transfer `cashOutCountToSell` -> revert (insufficient balance)
///
/// After fix: the hook snapshots balanceOf before/after mintTokensOf and uses `actualReceived`.
contract FOTProjectTokenTest is Test {
    FOTHook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    FOTProjectToken internal projectToken;
    FOTTerminalToken internal terminalToken;
    FOTController internal controller;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));

    uint256 internal projectId = 777;
    address internal terminal = makeAddr("terminal");
    address payable internal beneficiary = payable(makeAddr("beneficiary"));

    PoolKey internal poolKey;

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new FOTProjectToken();
        terminalToken = new FOTTerminalToken();
        controller = new FOTController(projectToken);

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");

        hook = new FOTHook({
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

    /// @notice Swap-failed path: With a FOT project token, the hook receives fewer tokens than
    /// `cashOutCountToSell` from mintTokensOf. When the swap fails, the hook should transfer only the
    /// actual received amount to the holder, not `cashOutCountToSell`.
    ///
    /// Before fix: reverts with ERC20InsufficientBalance because the hook tries to transfer
    /// `cashOutCountToSell` but only holds 99% of that.
    ///
    /// After fix: transfers `actualReceived` (99%) to the holder successfully.
    function test_swapFailed_FOTProjectToken_transfersActualReceived() public {
        uint256 cashOutCount = 100 ether;
        uint256 expectedFee = cashOutCount / 100; // 1% = 1 ether
        uint256 expectedNet = cashOutCount - expectedFee; // 99 ether

        // Force the pool swap to revert so we hit the swapFailed fallback path.
        poolManager.setShouldRevertOnUnlock(true);

        JBAfterCashOutRecordedContext memory context = _buildCashOutContext({
            cashOutCount: cashOutCount, minimumSwapAmountOut: 0, cashOutCountToSell: cashOutCount
        });

        // Execute from terminal. Before fix: reverts. After fix: succeeds.
        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        // The holder should receive the net amount (after FOT deduction).
        assertEq(
            projectToken.balanceOf(context.holder),
            _afterFOTFee(expectedNet), // FOT applies again on transfer to holder
            "holder should receive the net tokens after both FOT deductions"
        );

        // The hook should have zero project token balance (all transferred out).
        assertEq(projectToken.balanceOf(address(hook)), 0, "hook should not retain any project tokens");
    }

    /// @notice Swap path: With a FOT project token, the hook passes `actualReceived` to
    /// `_swapExactInput` instead of `cashOutCountToSell`. This prevents the swap from trying
    /// to sell more tokens than the hook actually holds.
    ///
    /// Before fix: the swap tries to sell `cashOutCountToSell` tokens but the hook only holds 99%,
    /// causing a revert during the pool settlement.
    ///
    /// After fix: the swap uses `actualReceived` (99%) as the input amount, which succeeds.
    function test_swapSucceeds_FOTProjectToken_usesActualReceived() public {
        uint256 cashOutCount = 100 ether;
        uint256 expectedFee = cashOutCount / 100; // 1%
        uint256 expectedNet = cashOutCount - expectedFee; // 99 ether — what the hook actually receives
        // Swap consumes all project tokens, swap also triggers FOT so pool receives 99% of expectedNet.
        uint256 swapAmountReceived = 80 ether;

        // Configure mock pool to consume all project tokens and return terminal tokens.
        if (address(projectToken) < address(terminalToken)) {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(-int128(uint128(expectedNet)), int128(uint128(swapAmountReceived)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(int128(uint128(swapAmountReceived)), -int128(uint128(expectedNet)));
        }

        // Fund pool manager with terminal tokens for the take.
        terminalToken.mint(address(poolManager), swapAmountReceived);

        JBAfterCashOutRecordedContext memory context = _buildCashOutContext({
            cashOutCount: cashOutCount, minimumSwapAmountOut: 0, cashOutCountToSell: cashOutCount
        });

        // Execute from terminal. Before fix: reverts. After fix: succeeds.
        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        // Beneficiary should receive terminal tokens from the swap.
        assertEq(
            terminalToken.balanceOf(beneficiary),
            swapAmountReceived,
            "beneficiary should receive terminal token proceeds"
        );
    }

    /// @notice Unsold residue return: With a FOT project token, the unsold token calculation
    /// should use `actualReceived` instead of `cashOutCountToSell` to avoid returning more tokens
    /// than the hook actually holds.
    function test_partialSwap_FOTProjectToken_returnsCorrectResidue() public {
        uint256 cashOutCount = 100 ether;
        uint256 swapConsumed = 50 ether; // Pool only consumes 50 ether of the 99 ether received
        uint256 swapAmountReceived = 40 ether;

        // Configure mock pool for partial consumption.
        if (address(projectToken) < address(terminalToken)) {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(-int128(uint128(swapConsumed)), int128(uint128(swapAmountReceived)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(int128(uint128(swapAmountReceived)), -int128(uint128(swapConsumed)));
        }

        // Fund pool manager with terminal tokens.
        terminalToken.mint(address(poolManager), swapAmountReceived);

        JBAfterCashOutRecordedContext memory context = _buildCashOutContext({
            cashOutCount: cashOutCount, minimumSwapAmountOut: 0, cashOutCountToSell: cashOutCount
        });

        // Execute from terminal. Before fix: reverts because unsoldProjectTokenCount = cashOutCountToSell - amountSpent
        // = 100e18 - 50e18 = 50e18, but the hook only has 99e18 - 50e18 = 49e18 unsold tokens.
        // After fix: unsoldProjectTokenCount = actualReceived - amountSpent = 99e18 - 50e18 = 49e18, which is correct.
        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        // Beneficiary should receive terminal tokens.
        assertEq(
            terminalToken.balanceOf(beneficiary),
            swapAmountReceived,
            "beneficiary should receive terminal token proceeds"
        );

        // The hook's residual project tokens should have been returned to the holder.
        // The return transfer is itself fee-on-transfer, so the holder receives the net residue.
        assertEq(projectToken.balanceOf(address(hook)), 0, "hook should not retain unsold residue");
        assertEq(
            projectToken.balanceOf(context.holder),
            _afterFOTFee(49 ether),
            "holder should receive the unsold residue net of transfer fee"
        );
    }

    /// @notice Helper: calculate the amount received after a 1% FOT deduction.
    function _afterFOTFee(uint256 amount) internal pure returns (uint256) {
        return amount - amount / 100;
    }
}
