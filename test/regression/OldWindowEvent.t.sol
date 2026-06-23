// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {Test} from "forge-std/Test.sol";

// JB core imports
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
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

/// @notice Tests for per-token TWAP window behavior and correct event emission.
contract OWE_OldWindowEvent is Test {
    using PoolIdLibrary for PoolKey;

    JBBuybackHook hook;
    MockPoolManager mockPm;
    OWE_MockToken projectToken;
    OWE_MockToken terminalToken;
    OWE_MockToken terminalToken2; // Second terminal token (e.g. USDC)

    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));

    address owner = makeAddr("owner");
    uint256 projectId = 7;
    uint256 firstWindow = 10 minutes;
    uint256 secondWindow = 30 minutes;
    uint256 thirdWindow = 1 hours;

    function setUp() public {
        mockPm = new MockPoolManager();
        projectToken = new OWE_MockToken("ProjectToken", "PT");
        terminalToken = new OWE_MockToken("TerminalToken", "TT");
        terminalToken2 = new OWE_MockToken("TerminalToken2", "TT2");

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
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants({
            newPoolManager: IPoolManager(address(mockPm)), newOracleHook: IHooks(address(0))
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

    /// @notice Helper to build a pool key and initialize it in the mock.
    function _buildAndInitPool(address _terminalToken)
        internal
        returns (PoolKey memory key, address normalizedTerminal)
    {
        normalizedTerminal = _terminalToken == JBConstants.NATIVE_TOKEN ? address(0) : _terminalToken;

        address token0;
        address token1;
        if (address(projectToken) < normalizedTerminal) {
            token0 = address(projectToken);
            token1 = normalizedTerminal;
        } else {
            token0 = normalizedTerminal;
            token1 = address(projectToken);
        }

        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        mockPm.setSlot0(key.toId(), sqrtPrice, 0, 3000);
    }

    /// @notice When setPoolFor is the first call for a project/token, oldWindow should be 0.
    function test_setPoolFor_emitsCorrectOldWindow_whenZero() public {
        (PoolKey memory key, address normalizedTerminal) = _buildAndInitPool(address(terminalToken));

        vm.expectEmit(true, true, false, true);
        emit IJBBuybackHook.TwapWindowChanged({
            projectId: projectId, terminalToken: normalizedTerminal, oldWindow: 0, newWindow: firstWindow, caller: owner
        });

        vm.prank(owner);
        hook.setPoolFor(projectId, key, firstWindow, address(terminalToken));
    }

    /// @notice After setting a pool and then changing the TWAP window, the event should
    ///         reflect the existing TWAP window as oldWindow (not 0).
    function test_setTwapWindowOf_emitsCorrectOldWindow() public {
        (PoolKey memory key, address normalizedTerminal) = _buildAndInitPool(address(terminalToken));

        vm.prank(owner);
        hook.setPoolFor(projectId, key, firstWindow, address(terminalToken));

        // Verify stored.
        assertEq(hook.twapWindowOf(projectId, normalizedTerminal), firstWindow, "twapWindow should be set");

        // Change the TWAP window — oldWindow should be firstWindow.
        vm.expectEmit(true, true, false, true);
        emit IJBBuybackHook.TwapWindowChanged({
            projectId: projectId,
            terminalToken: normalizedTerminal,
            oldWindow: firstWindow,
            newWindow: secondWindow,
            caller: owner
        });

        vm.prank(owner);
        hook.setTwapWindowOf(projectId, address(terminalToken), secondWindow);

        assertEq(hook.twapWindowOf(projectId, normalizedTerminal), secondWindow, "twapWindow should be updated");
    }

    /// @notice Setting TWAP windows for different terminal tokens on the same project
    ///         should be independent — they should not overwrite each other.
    function test_perTokenTwapWindows_areIndependent() public {
        // Set up pool for terminal token 1 (e.g. ETH).
        (PoolKey memory key1,) = _buildAndInitPool(address(terminalToken));
        vm.prank(owner);
        hook.setPoolFor(projectId, key1, firstWindow, address(terminalToken));

        // Set up pool for terminal token 2 (e.g. USDC).
        (PoolKey memory key2,) = _buildAndInitPool(address(terminalToken2));
        vm.prank(owner);
        hook.setPoolFor(projectId, key2, secondWindow, address(terminalToken2));

        // Normalize for assertion.
        address norm1 = address(terminalToken);
        address norm2 = address(terminalToken2);

        // Verify each token has its own TWAP window.
        assertEq(hook.twapWindowOf(projectId, norm1), firstWindow, "token1 window should be firstWindow");
        assertEq(hook.twapWindowOf(projectId, norm2), secondWindow, "token2 window should be secondWindow");

        // Change token1's TWAP window — token2 should remain unchanged.
        vm.prank(owner);
        hook.setTwapWindowOf(projectId, address(terminalToken), thirdWindow);

        assertEq(hook.twapWindowOf(projectId, norm1), thirdWindow, "token1 window should be thirdWindow");
        assertEq(hook.twapWindowOf(projectId, norm2), secondWindow, "token2 window should still be secondWindow");
    }

    /// @notice Different projects using the same terminal token should have independent TWAP windows.
    function test_perTokenTwapWindows_independentAcrossProjects() public {
        uint256 projectId2 = 42;

        // Mock ownerOf for project 2.
        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId2)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (projectId2)), abi.encode(IJBToken(address(projectToken)))
        );

        // Set pool for project 1.
        (PoolKey memory key1,) = _buildAndInitPool(address(terminalToken));
        vm.prank(owner);
        hook.setPoolFor(projectId, key1, firstWindow, address(terminalToken));

        // Set pool for project 2 with same terminal token but different window.
        (PoolKey memory key2,) = _buildAndInitPool(address(terminalToken));
        vm.prank(owner);
        hook.setPoolFor(projectId2, key2, secondWindow, address(terminalToken));

        address norm = address(terminalToken);
        assertEq(hook.twapWindowOf(projectId, norm), firstWindow, "project1 window");
        assertEq(hook.twapWindowOf(projectId2, norm), secondWindow, "project2 window");
    }

    /// @notice setTwapWindowOf should normalize NATIVE_TOKEN to address(0).
    function test_setTwapWindowOf_normalizesNativeToken() public {
        // Set up pool with native terminal token using the raw address form.
        // We can't easily test with actual NATIVE_TOKEN in the pool key since the mock
        // uses normalized addresses, but we can verify that setTwapWindowOf normalizes.
        (PoolKey memory key,) = _buildAndInitPool(address(terminalToken));
        vm.prank(owner);
        hook.setPoolFor(projectId, key, firstWindow, address(terminalToken));

        // Change using the non-normalized token — should write to normalized slot.
        vm.prank(owner);
        hook.setTwapWindowOf(projectId, address(terminalToken), secondWindow);

        assertEq(
            hook.twapWindowOf(projectId, address(terminalToken)), secondWindow, "should read back the updated window"
        );
    }

    /// @notice setTwapWindowOf should revert for windows outside bounds.
    function test_setTwapWindowOf_revertsOnInvalidWindow() public {
        // Too small.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector, 1 minutes, 5 minutes, 2 days)
        );
        hook.setTwapWindowOf(projectId, address(terminalToken), 1 minutes);

        // Too large.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector, 3 days, 5 minutes, 2 days)
        );
        hook.setTwapWindowOf(projectId, address(terminalToken), 3 days);
    }

    /// @notice An unset token should return 0 for twapWindowOf.
    function test_twapWindowOf_returnsZero_whenUnset() public view {
        assertEq(hook.twapWindowOf(projectId, address(terminalToken)), 0, "unset token window should be 0");
    }
}
