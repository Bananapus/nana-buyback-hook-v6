// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice A minimal mock IJBToken used to test setTokenFor after a token is already set.
contract MockExternalToken is IJBToken {
    function balanceOf(address) external pure override returns (uint256) {
        return 0;
    }

    function canBeAddedTo(uint256) external pure override returns (bool) {
        return true;
    }

    function decimals() external pure override returns (uint8) {
        return 18;
    }

    function totalSupply() external pure override returns (uint256) {
        return 0;
    }

    function burn(address, uint256) external override {}
    function initialize(string memory, string memory, address) external override {}
    function mint(address, uint256) external override {}
}

/// @notice JBTokens prevents token migration, so the projectTokenOf cache can never become stale.
///
/// The nemesis auditor claimed that projectTokenOf[projectId] cached in setPoolFor()
/// could become stale if the project migrates its token via setTokenFor or deployERC20For.
///
/// This test deploys a REAL JBTokens contract (not a mock) and demonstrates that once a
/// project has an ERC-20 token, BOTH setTokenFor() and deployERC20For() revert with
/// JBTokens_ProjectAlreadyHasToken. Therefore the projectTokenOf cache in JBBuybackHook
/// can NEVER become stale.
contract JBBuybackHook_FalsePositives is Test {
    JBTokens tokensContract;
    JBERC20 tokenImpl;
    IJBDirectory directory;
    address controller;

    uint256 projectId = 42;

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        controller = makeAddr("controller");

        // Deploy the real JBERC20 implementation (used as the clone template).
        tokenImpl = new JBERC20();

        // Deploy the real JBTokens contract.
        vm.etch(address(directory), bytes("0x01"));
        tokensContract = new JBTokens(directory, IJBToken(address(tokenImpl)));

        // Mock the directory so it recognizes `controller` as the controller for our project.
        // JBControlled._onlyControllerOf checks: DIRECTORY.controllerOf(projectId) == msg.sender
        // controllerOf returns IERC165 in the interface, so we encode the controller address.
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, projectId),
            abi.encode(IERC165(controller))
        );
    }

    /// @notice JBTokens prevents token migration, so projectTokenOf is guaranteed stable.
    /// The nemesis auditor assumed setTokenFor could succeed after a token is set,
    /// but both deployERC20For and setTokenFor revert with JBTokens_ProjectAlreadyHasToken.
    /// Therefore projectTokenOf cache in JBBuybackHook can never become stale.
    function test_tokenMigrationIsImpossible_FP2() public {
        // Step 1: Deploy an ERC-20 token for the project (this succeeds).
        vm.prank(controller);
        IJBToken deployedToken = tokensContract.deployERC20For(projectId, "ProjectToken", "PT", bytes32(0));

        // Sanity check: the token was set.
        assertEq(
            address(tokensContract.tokenOf(projectId)),
            address(deployedToken),
            "Token should be set after deployERC20For"
        );
        assertTrue(address(deployedToken) != address(0), "Deployed token should be non-zero");

        // Step 2: Attempt to call setTokenFor with a different token — must revert.
        MockExternalToken newToken = new MockExternalToken();
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(JBTokens.JBTokens_ProjectAlreadyHasToken.selector, deployedToken));
        tokensContract.setTokenFor(projectId, IJBToken(address(newToken)));

        // Step 3: Attempt to call deployERC20For again — must also revert.
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(JBTokens.JBTokens_ProjectAlreadyHasToken.selector, deployedToken));
        tokensContract.deployERC20For(projectId, "NewToken", "NT", bytes32(0));

        // Conclusion: Once a project's token is set, it cannot be changed or replaced.
        // The projectTokenOf cache in JBBuybackHook.setPoolFor() is therefore permanently valid.
        assertEq(
            address(tokensContract.tokenOf(projectId)),
            address(deployedToken),
            "Token must remain unchanged after failed migration attempts"
        );
    }
}
