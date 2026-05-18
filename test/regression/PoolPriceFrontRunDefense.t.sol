// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract PoolPriceFrontRunDefenseProjectToken is ERC20 {
    constructor() ERC20("PoolPriceProjectToken", "PPT") {}
}

/// @notice Regression test: initializePoolFor must reject pools that were front-run with the wrong sqrtPriceX96.
/// The project token's address is deterministic via CREATE2, so an attacker can pre-initialize the V4 pool at an
/// arbitrary price. Before the fix, `initializePoolFor` wrapped V4 initialize in try/catch and unconditionally
/// called `_setPoolFor`, locking the poisoned pool in. The fix reads the pool's actual sqrtPriceX96 and reverts
/// when it diverges from the caller's expected value.
contract PoolPriceFrontRunDefenseTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant PROJECT_ID = 1;
    uint160 internal constant EXPECTED_PRICE = 79_228_162_514_264_337_593_543_950_336; // sqrt(1) at Q96
    uint160 internal constant ATTACKER_PRICE = 158_456_325_028_528_675_187_087_900_672; // 2 * Q96 (different price)

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));

    address internal owner = makeAddr("owner");

    JBBuybackHook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    PoolPriceFrontRunDefenseProjectToken internal projectToken;

    function setUp() public {
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");

        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new PoolPriceFrontRunDefenseProjectToken();

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
            newPoolManager: IPoolManager(address(poolManager)), newOracleHook: IHooks(address(oracleHook))
        });

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (PROJECT_ID)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (PROJECT_ID)), abi.encode(IJBToken(address(projectToken)))
        );
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
    }

    /// @notice When the pool was front-run and initialized at an attacker-chosen price, `initializePoolFor` must
    /// revert before calling `_setPoolFor`. Otherwise the poisoned pool is locked in as the immutable buyback
    /// route.
    function test_initializePoolFor_revertsWhenExistingPoolPriceMismatches() public {
        // Build the pool key the hook will derive.
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(oracleHook))
        });

        // Simulate the front-run: pool already initialized at ATTACKER_PRICE. In the real V4 PoolManager, a
        // second `initialize` call on an already-initialized pool reverts with `PoolAlreadyInitialized`. The
        // hook wraps the call in try/catch and swallows that revert. We replicate that by making `initialize`
        // revert here and leaving slot0 at ATTACKER_PRICE for the subsequent getSlot0 read.
        poolManager.setSlot0({poolId: poolKey.toId(), sqrtPriceX96: ATTACKER_PRICE, tick: 0, lpFee: 3000});
        vm.mockCallRevert(
            address(poolManager),
            abi.encodeWithSelector(IPoolManager.initialize.selector, poolKey, EXPECTED_PRICE),
            abi.encodeWithSignature("PoolAlreadyInitialized()")
        );

        // Honest project deployer calls initializePoolFor with EXPECTED_PRICE. After the fix, the hook reads
        // back the actual on-chain price (ATTACKER_PRICE) and reverts with the bound mismatch error.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_PoolInitializedAtWrongPrice.selector, ATTACKER_PRICE, EXPECTED_PRICE
            )
        );
        hook.initializePoolFor({
            projectId: PROJECT_ID,
            fee: 3000,
            tickSpacing: 60,
            twapWindow: 5 minutes,
            terminalToken: JBConstants.NATIVE_TOKEN,
            sqrtPriceX96: EXPECTED_PRICE
        });
    }

    /// @notice Idempotent re-init: when the pool is already initialized at the expected price (e.g., a deploy
    /// script is re-run), the strict check passes and `initializePoolFor` succeeds. We mock the inner
    /// `initialize` to revert (already-initialized) and pre-seed slot0 at EXPECTED_PRICE so the post-call read
    /// matches.
    function test_initializePoolFor_succeedsWhenExistingPoolPriceMatches() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(oracleHook))
        });
        poolManager.setSlot0({poolId: poolKey.toId(), sqrtPriceX96: EXPECTED_PRICE, tick: 0, lpFee: 3000});
        vm.mockCallRevert(
            address(poolManager),
            abi.encodeWithSelector(IPoolManager.initialize.selector, poolKey, EXPECTED_PRICE),
            abi.encodeWithSignature("PoolAlreadyInitialized()")
        );

        // Should not revert — actual price equals expected.
        vm.prank(owner);
        hook.initializePoolFor({
            projectId: PROJECT_ID,
            fee: 3000,
            tickSpacing: 60,
            twapWindow: 5 minutes,
            terminalToken: JBConstants.NATIVE_TOKEN,
            sqrtPriceX96: EXPECTED_PRICE
        });
    }
}
