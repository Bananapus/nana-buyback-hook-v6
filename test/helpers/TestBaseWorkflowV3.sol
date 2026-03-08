// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import "@bananapus/core-v5/src/abstract/JBPermissioned.sol";
import "@bananapus/core-v5/src/JBController.sol";
import "@bananapus/core-v5/src/JBDirectory.sol";
import "@bananapus/core-v5/src/JBMultiTerminal.sol";
import "@bananapus/core-v5/src/JBFundAccessLimits.sol";
import "@bananapus/core-v5/src/JBTerminalStore.sol";
import "@bananapus/core-v5/src/JBRulesets.sol";
import "@bananapus/core-v5/src/JBFeelessAddresses.sol";
import "@bananapus/core-v5/src/JBPermissions.sol";
import "@bananapus/core-v5/src/JBPrices.sol";
import "@bananapus/core-v5/src/JBProjects.sol";
import "@bananapus/core-v5/src/JBSplits.sol";
import "@bananapus/core-v5/src/JBTokens.sol";
import "@bananapus/core-v5/src/JBERC20.sol";

import "@bananapus/core-v5/src/structs/JBAfterPayRecordedContext.sol";
import "@bananapus/core-v5/src/structs/JBAfterCashOutRecordedContext.sol";
import "@bananapus/core-v5/src/structs/JBFee.sol";
import "@bananapus/core-v5/src/structs/JBFundAccessLimitGroup.sol";
import "@bananapus/core-v5/src/structs/JBRuleset.sol";
import "@bananapus/core-v5/src/structs/JBRulesetMetadata.sol";
import "@bananapus/core-v5/src/structs/JBSplitGroup.sol";
import "@bananapus/core-v5/src/structs/JBPermissionsData.sol";
import "@bananapus/core-v5/src/structs/JBBeforePayRecordedContext.sol";
import "@bananapus/core-v5/src/structs/JBBeforeCashOutRecordedContext.sol";
import "@bananapus/core-v5/src/structs/JBSplit.sol";
import "@bananapus/core-v5/src/interfaces/IJBTerminal.sol";
import "@bananapus/core-v5/src/interfaces/IJBToken.sol";
import "@bananapus/core-v5/src/libraries/JBConstants.sol";
import "@bananapus/core-v5/src/interfaces/IJBTerminalStore.sol";

import "src/interfaces/external/IWETH9.sol";
import "src/JBBuybackHook.sol";

/// @notice Basic test setup for buyback hook tests. Deploys and pre-configures common contracts.
contract TestBaseWorkflowV3 is Test {
    using stdStorage for StdStorage;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    // Multisig (project owner) and beneficiary addresses used for testing.
    address internal multisig = makeAddr("mooltichig");
    address internal beneficiary = makeAddr("benefishary");

    JBPermissions internal jbPermissions;
    JBProjects internal jbProjects;
    JBPrices internal jbPrices;
    JBDirectory internal jbDirectory;
    JBFundAccessLimits internal jbFundAccessLimits;
    JBRulesets internal jbRulesets;
    JBFeelessAddresses internal jbFeelessAddresses;
    JBTokens internal jbTokens;
    JBSplits internal jbSplits;
    JBController internal jbController;
    JBTerminalStore internal jbTerminalStore;
    JBMultiTerminal internal jbMultiTerminal;

    JBBuybackHook hook;

    uint256 projectId;
    uint16 reservedPercent = 4500;
    uint112 weight = 10 ether; // Minting 10 token per eth
    uint32 cardinality = 1000;
    uint256 twapDelta = 500;

    JBRulesetMetadata metadata;

    // Use the old JBX<->ETH pair with a 1% fee as the `UniswapV3Pool` throughout tests.
    // IUniswapV3Pool pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);
    IJBToken jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);
    IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address uniswapFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    uint24 fee = 10;

    IUniswapV3Pool pool;

    //*********************************************************************//
    // --------------------------- test setup ---------------------------- //
    //*********************************************************************//

    // Deploys and initializes contracts for testing.
    function setUp() public virtual {
        // Labels.
        vm.label(multisig, "projectOwner");
        vm.label(beneficiary, "beneficiary");
        vm.label(address(pool), "uniswapPool");
        vm.label(address(uniswapFactory), "uniswapFactory");
        vm.label(address(weth), "$WETH");
        vm.label(address(jbx), "$JBX");

        // Mock.
        vm.etch(address(pool), "0x69");
        vm.etch(address(weth), "0x69");

        // JBPermissions
        jbPermissions = new JBPermissions(address(0));
        vm.label(address(jbPermissions), "JBPermissions");

        // JBProjects
        jbProjects = new JBProjects(multisig, address(0), address(0));
        vm.label(address(jbProjects), "JBProjects");

        // JBDirectory
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        vm.label(address(jbDirectory), "JBDirectory");

        // JBPrices
        jbPrices = new JBPrices(jbDirectory, jbPermissions, jbProjects, multisig, address(0));
        vm.label(address(jbPrices), "JBPrices");

        // JBRulesets
        jbRulesets = new JBRulesets(jbDirectory);
        vm.label(address(jbRulesets), "JBRulesets");

        // JBTokens
        jbTokens = new JBTokens(jbDirectory, new JBERC20());
        vm.label(address(jbTokens), "JBTokens");

        // JBSplits
        jbSplits = new JBSplits(jbDirectory);
        vm.label(address(jbSplits), "JBSplits");

        // JBFundAccessLimits
        jbFundAccessLimits = new JBFundAccessLimits(jbDirectory);
        vm.label(address(jbFundAccessLimits), "JBFundAccessLimits");

        // JBFeelessAddresses
        jbFeelessAddresses = new JBFeelessAddresses(address(69));
        vm.label(address(jbFeelessAddresses), "JBFeelessAddresses");

        // JBController
        jbController = new JBController(
            jbDirectory,
            jbFundAccessLimits,
            jbPermissions,
            jbPrices,
            jbProjects,
            jbRulesets,
            jbSplits,
            jbTokens,
            address(0),
            address(0)
        );
        vm.label(address(jbController), "JBController");

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);

        // JBTerminalStore
        jbTerminalStore = new JBTerminalStore(jbDirectory, jbPrices, jbRulesets);
        vm.label(address(jbTerminalStore), "JBTerminalStore");

        // JBMultiTerminal
        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses,
            jbPermissions,
            jbProjects,
            jbSplits,
            jbTerminalStore,
            jbTokens,
            IPermit2(address(0)),
            address(0)
        );
        vm.label(address(jbMultiTerminal), "JBMultiTerminal");

        // Deploy the buyback hook.
        hook = new JBBuybackHook({
            weth: weth,
            factory: uniswapFactory,
            directory: IJBDirectory(address(jbDirectory)),
            permissions: jbPermissions,
            projects: jbProjects,
            tokens: jbTokens,
            prices: jbPrices,
            trustedForwarder: address(0)
        });

        // Ruleset metadata: use the hook for payments.
        metadata = JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: 5000,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: true,
            useDataHookForCashOut: false,
            dataHook: address(hook),
            metadata: 0
        });

        // More ruleset configuration.
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        JBCurrencyAmount[] memory surplusAllowances = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: 2 ether, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        surplusAllowances[0] =
            JBCurrencyAmount({amount: type(uint224).max, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: surplusAllowances
        });

        // Package up the ruleset configuration.
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].mustStartAtOrAfter = 0;
        rulesetConfigurations[0].duration = 6 days;
        rulesetConfigurations[0].weight = weight;
        rulesetConfigurations[0].weightCutPercent = 0;
        rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));

        rulesetConfigurations[0].metadata = metadata;
        rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigurations[0].fundAccessLimitGroups = fundAccessLimitGroups;

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, currency: uint32(uint160(JBConstants.NATIVE_TOKEN)), decimals: 18
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: accountingContextsToAccept});

        // Launch the project with the `multisig` as the owner.
        projectId = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "myIPFSHash",
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations, // Set terminals to receive fees.
            memo: ""
        });

        // Deploy the JBX ERC-20 for the project.
        vm.prank(multisig);
        jbController.deployERC20For(projectId, "jbx", "jbx", bytes32(0));

        // Set the buyback hook pool up for the project.
        vm.prank(multisig);
        pool = hook.setPoolFor(projectId, fee, uint32(cardinality), address(weth));
    }
}
