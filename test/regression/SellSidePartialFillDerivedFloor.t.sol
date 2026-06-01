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
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {JBBuybackHook} from "../../src/JBBuybackHook.sol";
import {MockOracleHook} from "../mock/MockOracleHook.sol";
import {MockPoolManager} from "../mock/MockPoolManager.sol";

/// @notice Simple ERC20 project token for testing.
contract SSPF_ProjectToken is ERC20 {
    constructor() ERC20("ProjectToken", "PT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Simple ERC20 terminal token for testing.
contract SSPF_TerminalToken is ERC20 {
    constructor() ERC20("TerminalToken", "TT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal controller that actually mints/burns project tokens.
contract SSPF_Controller {
    SSPF_ProjectToken internal immutable TOKEN;

    uint256 internal _lastMintCount;

    constructor(SSPF_ProjectToken token) {
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
contract SSPF_Hook is JBBuybackHook {
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

/// @notice A sell-side cash-out that fills successfully but only partially — stopping short of a non-zero floor that
/// the hook itself derived (no caller minimum) — should soft-land instead of reverting the whole cash-out: the
/// partial
/// proceeds go to the beneficiary and the unsold reminted residue is returned to the holder. This mirrors the
/// already-existing soft-land that the pool-revert branch performs for a derived floor. When the caller explicitly
/// specified the minimum, an underfill must still hard-revert.
contract SellSidePartialFillDerivedFloor is Test {
    SSPF_Hook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    SSPF_ProjectToken internal projectToken;
    SSPF_TerminalToken internal terminalToken;
    SSPF_Controller internal controller;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));

    uint256 internal projectId = 88;
    address internal terminal = makeAddr("terminal");
    address payable internal beneficiary = payable(makeAddr("beneficiary"));
    address internal holder = makeAddr("holder");

    PoolKey internal poolKey;

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new SSPF_ProjectToken();
        terminalToken = new SSPF_TerminalToken();
        controller = new SSPF_Controller(projectToken);

        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");

        hook = new SSPF_Hook({
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

        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (projectId)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (projectId, IJBTerminal(terminal))),
            abi.encode(true)
        );

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

    /// @notice Configure the mock pool to fill the sell partially: it consumes `amountSpent` project tokens and
    /// delivers `amountReceived` terminal tokens.
    function _configurePartialFill(uint256 amountSpent, uint256 amountReceived) internal {
        // Project token is the input; terminal token is the output. The delta on the input currency is negative
        // (spent), the delta on the output currency is positive (received).
        if (address(projectToken) < address(terminalToken)) {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(-int128(uint128(amountSpent)), int128(uint128(amountReceived)));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.setMockDeltas(int128(uint128(amountReceived)), -int128(uint128(amountSpent)));
        }

        // Fund the pool manager with terminal tokens for the take.
        terminalToken.mint(address(poolManager), amountReceived);
    }

    /// @notice Long-form (>= 256 byte) sell-side metadata that lets the test set the derived-vs-explicit flag
    /// independently of the floor value. The 8-tuple matches the wide branch decoded in `afterCashOutRecordedWith`.
    function _longFormMetadata(
        uint256 minimumSwapAmountOut,
        uint256 cashOutCountToSell,
        bool shouldEnforceMinimumSwapAmountOut
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            minimumSwapAmountOut,
            cashOutCountToSell,
            uint256(0),
            int24(0),
            uint128(0),
            PoolId.wrap(bytes32(0)),
            uint256(0),
            shouldEnforceMinimumSwapAmountOut
        );
    }

    function _buildCashOutContext(
        uint256 cashOutCount,
        bytes memory hookMetadata
    )
        internal
        view
        returns (JBAfterCashOutRecordedContext memory)
    {
        return JBAfterCashOutRecordedContext({
            holder: holder,
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
            hookMetadata: hookMetadata,
            cashOutMetadata: ""
        });
    }

    /// @notice A successful-but-partial fill that lands below a non-zero DERIVED floor
    /// (`shouldEnforceMinimumSwapAmountOut == false`) must soft-land: the partial proceeds reach the beneficiary and
    /// the unsold reminted residue returns to the holder. Before the fix this reverted the entire cash-out.
    function test_partialFill_belowDerivedFloor_softLands() public {
        uint256 cashOutCount = 100 ether;
        uint256 amountSpent = 60 ether;
        uint256 amountReceived = 50 ether;
        uint256 derivedFloor = 80 ether; // amountReceived (50) < derivedFloor (80): an underfill.

        _configurePartialFill({amountSpent: amountSpent, amountReceived: amountReceived});

        JBAfterCashOutRecordedContext memory context = _buildCashOutContext({
            cashOutCount: cashOutCount,
            hookMetadata: _longFormMetadata({
                minimumSwapAmountOut: derivedFloor,
                cashOutCountToSell: cashOutCount,
                shouldEnforceMinimumSwapAmountOut: false
            })
        });

        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        // The beneficiary receives the partial swap proceeds in the terminal token.
        assertEq(
            terminalToken.balanceOf(beneficiary), amountReceived, "beneficiary should receive partial swap proceeds"
        );

        // The unsold reminted residue (cashOutCount - amountSpent) returns to the holder.
        assertEq(
            projectToken.balanceOf(holder),
            cashOutCount - amountSpent,
            "holder should receive the unsold reminted residue"
        );

        // No funds are stranded on the hook.
        assertEq(projectToken.balanceOf(address(hook)), 0, "hook should not retain project tokens");
        assertEq(terminalToken.balanceOf(address(hook)), 0, "hook should not retain terminal tokens");
    }

    /// @notice The same partial fill, but with an EXPLICIT caller-specified minimum
    /// (`shouldEnforceMinimumSwapAmountOut == true`), must still hard-revert on the underfill.
    function test_partialFill_belowExplicitMinimum_reverts() public {
        uint256 cashOutCount = 100 ether;
        uint256 amountSpent = 60 ether;
        uint256 amountReceived = 50 ether;
        uint256 explicitMinimum = 80 ether;

        _configurePartialFill({amountSpent: amountSpent, amountReceived: amountReceived});

        JBAfterCashOutRecordedContext memory context = _buildCashOutContext({
            cashOutCount: cashOutCount,
            hookMetadata: _longFormMetadata({
                minimumSwapAmountOut: explicitMinimum,
                cashOutCountToSell: cashOutCount,
                shouldEnforceMinimumSwapAmountOut: true
            })
        });

        vm.prank(terminal);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, amountReceived, explicitMinimum
            )
        );
        hook.afterCashOutRecordedWith(context);
    }

    /// @notice A full-enough fill that meets the derived floor still settles to the beneficiary unchanged.
    function test_fill_meetsDerivedFloor_settlesToBeneficiary() public {
        uint256 cashOutCount = 100 ether;
        uint256 amountSpent = 100 ether;
        uint256 amountReceived = 90 ether;
        uint256 derivedFloor = 80 ether; // amountReceived (90) >= derivedFloor (80): meets the floor.

        _configurePartialFill({amountSpent: amountSpent, amountReceived: amountReceived});

        JBAfterCashOutRecordedContext memory context = _buildCashOutContext({
            cashOutCount: cashOutCount,
            hookMetadata: _longFormMetadata({
                minimumSwapAmountOut: derivedFloor,
                cashOutCountToSell: cashOutCount,
                shouldEnforceMinimumSwapAmountOut: false
            })
        });

        vm.prank(terminal);
        hook.afterCashOutRecordedWith(context);

        assertEq(terminalToken.balanceOf(beneficiary), amountReceived, "beneficiary should receive full swap proceeds");
        assertEq(projectToken.balanceOf(holder), 0, "no residue when the whole sell count is consumed");
    }
}
