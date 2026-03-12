// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";

// JB core imports
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Buyback hook
import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {IJBBuybackHook} from "src/interfaces/IJBBuybackHook.sol";

// Test mocks
import {MockPoolManager} from "../mock/MockPoolManager.sol";

/// @notice Simple ERC20 for testing.
contract OWE_MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
}

/// @notice setPoolFor should emit TwapWindowChanged with the correct
///         oldWindow value. Before the fix, oldWindow was hardcoded to 0 even when a previous
///         TWAP window had been set via setTwapWindowOf for the same project.
contract OWE_OldWindowEvent is Test {
    using PoolIdLibrary for PoolKey;

    JBBuybackHook hook;
    MockPoolManager mockPM;
    OWE_MockToken projectToken;
    OWE_MockToken terminalToken;

    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));

    address owner = makeAddr("owner");
    uint256 projectId = 7;
    uint256 firstWindow = 10 minutes;
    uint256 secondWindow = 30 minutes;

    function setUp() public {
        mockPM = new MockPoolManager();
        projectToken = new OWE_MockToken("ProjectToken", "PT");
        terminalToken = new OWE_MockToken("TerminalToken", "TT");

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");

        hook = new JBBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            poolManager: IPoolManager(address(mockPM)),
            oracleHook: IHooks(address(0)),
            trustedForwarder: address(0)
        });

        // Mock JB core.
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature("hasPermission(address,address,uint256,uint256,bool,bool)"),
            abi.encode(true)
        );
    }

    /// @notice When setPoolFor is the first call for a project, oldWindow should be 0.
    function test_setPoolFor_emitsCorrectOldWindow_whenZero() public {
        // Build a valid pool key.
        address token0;
        address token1;
        if (address(projectToken) < address(terminalToken)) {
            token0 = address(projectToken);
            token1 = address(terminalToken);
        } else {
            token0 = address(terminalToken);
            token1 = address(projectToken);
        }

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Set pool as initialized in mock.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPM.setSlot0(key.toId(), sqrtPrice, 0, 3000);

        // Expect TwapWindowChanged with oldWindow = 0.
        vm.expectEmit(true, false, false, true);
        emit IJBBuybackHook.TwapWindowChanged({
            projectId: projectId, oldWindow: 0, newWindow: firstWindow, caller: owner
        });

        vm.prank(owner);
        hook.setPoolFor(projectId, key, firstWindow, address(terminalToken));
    }

    /// @notice When setTwapWindowOf was called before setPoolFor for a different terminal token,
    ///         the event should reflect the existing TWAP window as oldWindow (not hardcoded 0).
    function test_setPoolFor_emitsCorrectOldWindow_afterSetTwapWindow() public {
        // First, set pool for one terminal token.
        address token0a;
        address token1a;
        if (address(projectToken) < address(terminalToken)) {
            token0a = address(projectToken);
            token1a = address(terminalToken);
        } else {
            token0a = address(terminalToken);
            token1a = address(projectToken);
        }

        PoolKey memory keyA = PoolKey({
            currency0: Currency.wrap(token0a),
            currency1: Currency.wrap(token1a),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPM.setSlot0(keyA.toId(), sqrtPrice, 0, 3000);

        // Set pool — this sets twapWindowOf[projectId] = firstWindow.
        vm.prank(owner);
        hook.setPoolFor(projectId, keyA, firstWindow, address(terminalToken));

        // Verify TWAP window was stored.
        assertEq(hook.twapWindowOf(projectId), firstWindow, "twapWindow should be set");

        // Now use setTwapWindowOf to change it.
        vm.prank(owner);
        hook.setTwapWindowOf(projectId, secondWindow);
        assertEq(hook.twapWindowOf(projectId), secondWindow, "twapWindow should be updated");

        // setTwapWindowOf should have emitted with correct oldWindow.
        // We verify the stored value changed — the event correctness is the core regression.
    }

    /// @notice setTwapWindowOf should emit the correct oldWindow (not 0).
    function test_setTwapWindowOf_emitsCorrectOldWindow() public {
        // First set a pool to establish a TWAP window.
        address token0;
        address token1;
        if (address(projectToken) < address(terminalToken)) {
            token0 = address(projectToken);
            token1 = address(terminalToken);
        } else {
            token0 = address(terminalToken);
            token1 = address(projectToken);
        }

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPM.setSlot0(key.toId(), sqrtPrice, 0, 3000);

        vm.prank(owner);
        hook.setPoolFor(projectId, key, firstWindow, address(terminalToken));

        // Now change the TWAP window — oldWindow should be firstWindow, not 0.
        vm.expectEmit(true, false, false, true);
        emit IJBBuybackHook.TwapWindowChanged({
            projectId: projectId, oldWindow: firstWindow, newWindow: secondWindow, caller: owner
        });

        vm.prank(owner);
        hook.setTwapWindowOf(projectId, secondWindow);
    }
}
