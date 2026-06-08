// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {MockOracleHook} from "test/mock/MockOracleHook.sol";
import {MockPoolManager} from "test/mock/MockPoolManager.sol";

contract FeeOnTransferTerminalToken is ERC20 {
    uint256 internal constant FEE_BPS = 1000;
    uint256 internal constant BPS = 10_000;

    constructor() ERC20("Fee Terminal Token", "FTT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value * FEE_BPS / BPS;
        super._update(from, address(0xBEEF), fee);
        super._update(from, to, value - fee);
    }
}

contract StubController {
    uint256 public minted;
    address public mintBeneficiary;

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
        minted += tokenCount;
        mintBeneficiary = beneficiary;
        return tokenCount;
    }
}

contract StubTerminal {
    FeeOnTransferTerminalToken public immutable token;

    constructor(FeeOnTransferTerminalToken token_) {
        token = token_;
    }

    function callAfterPay(JBBuybackHook hook, JBAfterPayRecordedContext calldata context) external {
        token.approve(address(hook), context.forwardedAmount.value);
        hook.afterPayRecordedWith(context);
    }

    function addToBalanceOf(uint256, address, uint256 amount, bool, string calldata, bytes calldata) external {
        bool success = token.transferFrom(msg.sender, address(this), amount);
        require(success, "TRANSFER_FAILED");
    }
}

contract BuySideFeeOnTransferTerminalTokenTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ACCEPTED_AMOUNT = 100 ether;

    JBBuybackHook internal hook;
    MockPoolManager internal poolManager;
    MockOracleHook internal oracleHook;
    FeeOnTransferTerminalToken internal token;
    StubTerminal internal terminal;
    StubController internal controller;

    IJBDirectory internal directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBPrices internal prices = IJBPrices(makeAddr("prices"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IJBTokens internal tokens = IJBTokens(makeAddr("tokens"));

    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        poolManager = new MockPoolManager();
        oracleHook = new MockOracleHook();
        token = new FeeOnTransferTerminalToken();
        terminal = new StubTerminal(token);
        controller = new StubController();

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
            newPoolManager: IPoolManager(address(poolManager)), newOracleHook: IHooks(address(oracleHook))
        });

        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (PROJECT_ID, IJBTerminal(address(terminal)))),
            abi.encode(true)
        );

        poolManager.setShouldRevertOnUnlock(true);
        token.mint(address(terminal), ACCEPTED_AMOUNT);
    }

    function test_swapFailureFallbackMintsLessThanDirectWithFotTerminalToken() public {
        JBAfterPayRecordedContext memory context = JBAfterPayRecordedContext({
            payer: makeAddr("payer"),
            projectId: PROJECT_ID,
            rulesetId: 1,
            amount: JBTokenAmount({
                token: address(token), value: ACCEPTED_AMOUNT, decimals: 18, currency: uint32(uint160(address(token)))
            }),
            forwardedAmount: JBTokenAmount({
                token: address(token), value: ACCEPTED_AMOUNT, decimals: 18, currency: uint32(uint160(address(token)))
            }),
            weight: 1 ether,
            newlyIssuedTokenCount: 0,
            beneficiary: beneficiary,
            hookMetadata: abi.encode(
                false,
                uint256(0),
                ACCEPTED_AMOUNT,
                false,
                IJBController(address(controller)),
                ACCEPTED_AMOUNT,
                1 ether,
                ACCEPTED_AMOUNT,
                int24(0),
                uint128(0),
                bytes32(0),
                uint256(0),
                uint256(0),
                uint256(0)
            ),
            payerMetadata: ""
        });

        terminal.callAfterPay(hook, context);

        assertEq(controller.mintBeneficiary(), beneficiary);
        assertEq(controller.minted(), 81 ether, "two extra 10% transfer-fee hops reduce fallback mint");
        assertLt(controller.minted(), ACCEPTED_AMOUNT, "fallback mints less than the direct terminal path");
    }
}
