// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBFeeTerminal} from "@bananapus/core-v6/src/interfaces/IJBFeeTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract RegressionZeroTaxProjectToken is ERC20 {
    constructor() ERC20("RegressionZeroTaxProjectToken", "RZTP") {}
}

/// @notice Regression test: when `cashOutTaxRate == 0` and the core terminal will still charge a fee against
/// `_feeFreeSurplusOf`, the hook must deduct the terminal fee from the direct-path comparison amount. Otherwise the
/// hook routes to a direct path that pays less than the available AMM floor.
contract RegressionZeroTaxFeeFreeSurplusTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant CASH_OUT_COUNT = 10 ether;
    uint256 internal constant TOTAL_SUPPLY = 100 ether;
    uint256 internal constant SURPLUS = 10 ether;
    uint256 internal constant AMM_FLOOR = 0.99 ether;
    uint256 internal constant TERMINAL_FEE = 25;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));
    IJBController internal controller = IJBController(makeAddr("controller"));
    IJBFeeTerminal internal terminal = IJBFeeTerminal(makeAddr("terminal"));

    address internal owner = makeAddr("owner");
    address internal holder = makeAddr("holder");

    JBBuybackHook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    RegressionZeroTaxProjectToken internal projectToken;

    function setUp() public {
        vm.etch(address(directory), "0x01");
        vm.etch(address(permissions), "0x01");
        vm.etch(address(prices), "0x01");
        vm.etch(address(projects), "0x01");
        vm.etch(address(tokens), "0x01");
        vm.etch(address(controller), "0x01");
        vm.etch(address(terminal), "0x01");

        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        projectToken = new RegressionZeroTaxProjectToken();

        hook = new JBBuybackHook({
            directory: directory,
            permissions: permissions,
            prices: prices,
            projects: projects,
            tokens: tokens,
            poolManager: IPoolManager(address(poolManager)),
            oracleHook: IHooks(address(oracleHook)),
            trustedForwarder: address(0)
        });

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (PROJECT_ID)), abi.encode(owner));
        vm.mockCall(
            address(tokens), abi.encodeCall(tokens.tokenOf, (PROJECT_ID)), abi.encode(IJBToken(address(projectToken)))
        );
        vm.mockCall(address(directory), abi.encodeCall(directory.controllerOf, (PROJECT_ID)), abi.encode(controller));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (PROJECT_ID, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );
        vm.mockCall(address(terminal), abi.encodeCall(terminal.FEE, ()), abi.encode(TERMINAL_FEE));
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature("hasPermission(address,address,uint256,uint256,bool,bool)"),
            abi.encode(true)
        );

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(oracleHook))
        });
        poolManager.setSlot0(poolKey.toId(), TickMath.getSqrtPriceAtTick(0), 0, 3000);

        vm.prank(owner);
        hook.setPoolFor(PROJECT_ID, poolKey, 5 minutes, JBConstants.NATIVE_TOKEN);
    }

    function test_zeroTaxNonFeelessCashOutRoutesToAmmWhenAmmFloorBeatsNetDirect() public {
        bytes memory metadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId("cashOutMinReclaimed", address(hook)),
            dataToAdd: abi.encode(AMM_FLOOR)
        });

        vm.prank(address(terminal));
        (
            uint256 returnedTaxRate,,
            uint256 returnedTotalSupply,
            uint256 returnedSurplus,
            JBCashOutHookSpecification[] memory specs
        ) = hook.beforeCashOutRecordedWith(
            _context({cashOutTaxRate: 0, beneficiaryIsFeeless: false, metadata: metadata})
        );

        uint256 grossDirect = JBCashOuts.cashOutFrom(SURPLUS, CASH_OUT_COUNT, TOTAL_SUPPLY, 0);
        uint256 netDirectAfterFee = grossDirect - JBFees.feeAmountFrom(grossDirect, TERMINAL_FEE);

        // Pre-conditions documenting the comparison the hook must make.
        assertGt(AMM_FLOOR, netDirectAfterFee, "AMM floor must beat post-fee direct path");
        assertLt(AMM_FLOOR, grossDirect, "AMM floor must be below gross direct (otherwise no bug to exhibit)");

        assertEq(specs.length, 1, "one hook spec");
        assertFalse(
            specs[0].noop,
            "hook must route to AMM because post-fee direct < AMM floor; previously the hook compared against gross direct and incorrectly noop'd"
        );
        // When the hook takes the AMM path it caps tax rate so the terminal does not reclaim surplus directly.
        assertEq(returnedTaxRate, 10_000, "AMM path maxes tax rate");
        assertEq(returnedSurplus, 0, "AMM path zeroes terminal surplus");
        assertEq(returnedTotalSupply, TOTAL_SUPPLY, "supply passes through");
    }

    function test_zeroTaxFeelessCashOutKeepsDirectPathBecauseNoFeeIsCharged() public {
        // For feeless beneficiaries the direct path pays gross. AMM_FLOOR < grossDirect means the direct path wins.
        bytes memory metadata = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId("cashOutMinReclaimed", address(hook)),
            dataToAdd: abi.encode(AMM_FLOOR)
        });

        vm.prank(address(terminal));
        (,,,, JBCashOutHookSpecification[] memory specs) = hook.beforeCashOutRecordedWith(
            _context({cashOutTaxRate: 0, beneficiaryIsFeeless: true, metadata: metadata})
        );

        assertTrue(specs[0].noop, "feeless beneficiary keeps gross direct path");
    }

    function _context(
        uint16 cashOutTaxRate,
        bool beneficiaryIsFeeless,
        bytes memory metadata
    )
        internal
        view
        returns (JBBeforeCashOutRecordedContext memory)
    {
        return JBBeforeCashOutRecordedContext({
            terminal: address(terminal),
            holder: holder,
            projectId: PROJECT_ID,
            rulesetId: 1,
            cashOutCount: CASH_OUT_COUNT,
            totalSupply: TOTAL_SUPPLY,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: SURPLUS
            }),
            scopeCashOutsToLocalBalances: true,
            cashOutTaxRate: cashOutTaxRate,
            beneficiaryIsFeeless: beneficiaryIsFeeless,
            metadata: metadata
        });
    }
}
