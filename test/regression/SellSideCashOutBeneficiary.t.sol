// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {IJBBuybackHook} from "src/interfaces/IJBBuybackHook.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract SellSideRevertToken is ERC20 {
    constructor() ERC20("Project Token", "PRJ") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract SellSideRevertController {
    SellSideRevertToken internal immutable TOKEN;

    constructor(SellSideRevertToken token) {
        TOKEN = token;
    }

    function mintTokensOf(
        uint256,
        uint256 tokenCount,
        address beneficiary,
        string calldata,
        bool
    )
        external
        returns (uint256)
    {
        TOKEN.mint(beneficiary, tokenCount);
        return tokenCount;
    }
}

contract SellSideRevertDirectory {
    address internal immutable TERMINAL;
    IERC165 internal immutable CONTROLLER;

    constructor(address terminal, IERC165 controller) {
        TERMINAL = terminal;
        CONTROLLER = controller;
    }

    function isTerminalOf(uint256, IJBTerminal terminal) external view returns (bool) {
        return address(terminal) == TERMINAL;
    }

    function controllerOf(uint256) external view returns (IERC165) {
        return CONTROLLER;
    }
}

/// @dev Pool manager that always reverts on unlock, forcing a swap failure.
contract SellSideRevertRevertingPoolManager {
    function unlock(bytes calldata) external pure returns (bytes memory) {
        revert("forced swap failure");
    }
}

/// @dev Exposes `projectTokenOf` setter for testing.
contract SellSideRevertHook is JBBuybackHook {
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

    function setProjectTokenForTest(uint256 projectId, address token) external {
        projectTokenOf[projectId] = token;
    }
}

/// @title Sell-side swap failure should send tokens to holder, not beneficiary
/// @notice Tests that when a sell-side swap reverts during cashout, reminted tokens go to the holder (not beneficiary).
contract SellSideCashOutBeneficiaryTest is Test {
    uint256 constant PROJECT_ID = 1;
    uint256 constant CASH_OUT_COUNT = 100 ether;
    address constant HOLDER = address(0xA11CE);
    address constant BENEFICIARY = address(0xB0B);

    SellSideRevertToken projectToken;
    SellSideRevertHook hook;

    function setUp() public {
        projectToken = new SellSideRevertToken();
        SellSideRevertController controller = new SellSideRevertController(projectToken);
        SellSideRevertDirectory directory = new SellSideRevertDirectory(address(this), IERC165(address(controller)));
        SellSideRevertRevertingPoolManager poolManager = new SellSideRevertRevertingPoolManager();

        hook = new SellSideRevertHook({
            directory: IJBDirectory(address(directory)),
            permissions: IJBPermissions(address(0x1)),
            prices: IJBPrices(address(0x2)),
            projects: IJBProjects(address(0x3)),
            tokens: IJBTokens(address(0x4)),
            deployer: address(this),
            trustedForwarder: address(0)
        });
        hook.setChainSpecificConstants({
            poolManager: IPoolManager(address(poolManager)), oracleHook: IHooks(address(0x5))
        });
        hook.setProjectTokenForTest(PROJECT_ID, address(projectToken));
    }

    function _makeContext() internal pure returns (JBAfterCashOutRecordedContext memory) {
        return JBAfterCashOutRecordedContext({
            holder: HOLDER,
            projectId: PROJECT_ID,
            rulesetId: 1,
            cashOutCount: CASH_OUT_COUNT,
            reclaimedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 0,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: payable(BENEFICIARY),
            hookMetadata: abi.encode(uint256(1 ether), CASH_OUT_COUNT),
            cashOutMetadata: ""
        });
    }

    /// @notice Fix verification: when swap fails, reminted tokens go to the holder.
    function test_SellSideRevert_fix_swapFailure_tokensGoToHolder() public {
        hook.afterCashOutRecordedWith(_makeContext());

        assertEq(projectToken.balanceOf(HOLDER), CASH_OUT_COUNT, "holder should receive reminted tokens");
        assertEq(projectToken.balanceOf(BENEFICIARY), 0, "beneficiary should receive nothing");
        assertEq(projectToken.balanceOf(address(hook)), 0, "hook should hold nothing");
    }

    /// @notice Fix verification: correct event is emitted with holder address.
    function test_SellSideRevert_fix_swapFailure_emitsHolderEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IJBBuybackHook.SellSwapReverted({projectId: PROJECT_ID, holder: HOLDER, amount: CASH_OUT_COUNT});

        hook.afterCashOutRecordedWith(_makeContext());
    }
}
