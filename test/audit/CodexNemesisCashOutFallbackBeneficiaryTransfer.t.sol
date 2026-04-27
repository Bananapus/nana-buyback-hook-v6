// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";

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

contract NemesisFallbackToken is ERC20 {
    constructor() ERC20("Project Token", "PRJ") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract NemesisFallbackController {
    NemesisFallbackToken internal immutable TOKEN;

    constructor(NemesisFallbackToken token) {
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

contract NemesisFallbackDirectory {
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

contract NemesisRevertingPoolManager {
    function unlock(bytes calldata) external pure returns (bytes memory) {
        revert("forced swap failure");
    }
}

contract NemesisFallbackHook is JBBuybackHook {
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

    function setProjectTokenForTest(uint256 projectId, address token) external {
        projectTokenOf[projectId] = token;
    }
}

contract CodexNemesisCashOutFallbackBeneficiaryTransferTest is Test {
    function test_failedSellFallbackTransfersRemintedTokensToHolder() public {
        uint256 projectId = 1;
        uint256 cashOutCount = 100 ether;
        address holder = address(0xA11CE);
        address beneficiary = address(0xB0B);

        NemesisFallbackToken projectToken = new NemesisFallbackToken();
        NemesisFallbackController controller = new NemesisFallbackController(projectToken);
        NemesisFallbackDirectory directory = new NemesisFallbackDirectory(address(this), IERC165(address(controller)));
        NemesisRevertingPoolManager poolManager = new NemesisRevertingPoolManager();

        NemesisFallbackHook hook = new NemesisFallbackHook({
            directory: IJBDirectory(address(directory)),
            permissions: IJBPermissions(address(0x1)),
            prices: IJBPrices(address(0x2)),
            projects: IJBProjects(address(0x3)),
            tokens: IJBTokens(address(0x4)),
            poolManager: IPoolManager(address(poolManager)),
            oracleHook: IHooks(address(0x5)),
            trustedForwarder: address(0)
        });
        hook.setProjectTokenForTest(projectId, address(projectToken));

        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: holder,
            projectId: projectId,
            rulesetId: 1,
            cashOutCount: cashOutCount,
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
            beneficiary: payable(beneficiary),
            hookMetadata: abi.encode(uint256(1 ether), cashOutCount),
            cashOutMetadata: ""
        });

        hook.afterCashOutRecordedWith(context);

        // M-45 fix: tokens go to holder, not beneficiary.
        assertEq(projectToken.balanceOf(holder), cashOutCount);
        assertEq(projectToken.balanceOf(beneficiary), 0);
        assertEq(projectToken.balanceOf(address(hook)), 0);
    }
}
