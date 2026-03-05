// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

import {IJBBuybackHook} from "./interfaces/IJBBuybackHook.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";
import {JBSwapLib} from "./libraries/JBSwapLib.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/// @notice The buyback hook allows beneficiaries of a payment to a project to either:
/// - Get tokens by paying the project through its terminal OR
/// - Buy tokens from the configured Uniswap v3 pool.
/// Depending on which route would yield more tokens for the beneficiary. The project's reserved rate applies to either
/// route.
/// @dev Compatible with any `JBTerminal` and any project token that can be pooled on Uniswap v3.
contract JBBuybackHook is JBPermissioned, ERC2771Context, IJBBuybackHook {
    // A library that parses the packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBBuybackHook_CallerNotPool(address caller);
    error JBBuybackHook_InsufficientPayAmount(uint256 swapAmount, uint256 totalPaid);
    error JBBuybackHook_InvalidTwapWindow(uint256 value, uint256 min, uint256 max);
    error JBBuybackHook_PoolAlreadySet(IUniswapV3Pool pool);
    error JBBuybackHook_SpecifiedSlippageExceeded(uint256 amount, uint256 minimum);
    error JBBuybackHook_TerminalTokenIsProjectToken(address terminalToken, address projectToken);
    error JBBuybackHook_Unauthorized(address caller);
    error JBBuybackHook_ZeroProjectToken();
    error JBBuybackHook_AmountOverflow();
    error JBBuybackHook_ZeroTerminalToken();

    //*********************************************************************//
    // --------------------- public constant properties ------------------ //
    //*********************************************************************//

    /// @notice Projects cannot specify a TWAP window longer than this constant.
    /// @dev This serves to avoid excessively long TWAP windows that could lead to outdated pricing information and
    /// higher gas costs due to increased computational requirements.
    uint256 public constant override MAX_TWAP_WINDOW = 2 days;

    /// @notice Projects cannot specify a TWAP window shorter than this constant.
    /// @dev This serves to avoid extremely short TWAP windows that could be manipulated or subject to high volatility.
    uint256 public constant override MIN_TWAP_WINDOW = 2 minutes;

    /// @notice The denominator used when calculating TWAP slippage percent values.
    uint256 public constant override TWAP_SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice The uncertain slippage tolerance allowed.
    /// @dev This serves to avoid extremely low slippage tolerances that could result in failed swaps.
    uint256 public constant override UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE = 1050;

    //*********************************************************************//
    // -------------------- public immutable properties ------------------ //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice  The contract that exposes price feeds.
    IJBPrices public immutable override PRICES;

    /// @notice The project registry.
    IJBProjects public immutable override PROJECTS;

    /// @notice The token registry.
    IJBTokens public immutable override TOKENS;

    /// @notice The address of the Uniswap v3 factory. Used to calculate pool addresses.
    address public immutable override UNISWAP_V3_FACTORY;

    /// @notice The wETH contract.
    IWETH9 public immutable override WETH;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The Uniswap pool where a given project's token and terminal token pair are traded.
    /// @custom:param projectId The ID of the project whose token is traded in the pool.
    /// @custom:param terminalToken The address of the terminal token that the project accepts for payments (and is
    /// traded in the pool).
    mapping(uint256 projectId => mapping(address terminalToken => IUniswapV3Pool)) public override poolOf;

    /// @notice The address of each project's token.
    /// @custom:param projectId The ID of the project the token belongs to.
    mapping(uint256 projectId => address) public override projectTokenOf;

    /// @notice The TWAP window for the given project. The TWAP window is the period of time over which the TWAP is
    /// computed.
    /// @custom:param projectId The ID of the project to get the twap window for.
    mapping(uint256 projectId => uint256) public override twapWindowOf;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory The directory of terminals and controllers.
    /// @param permissions The permissions contract.
    /// @param prices The contract that exposes price feeds.
    /// @param projects The project registry.
    /// @param tokens The token registry.
    /// @param weth The WETH contract.
    /// @param factory The address of the Uniswap v3 factory. Used to calculate pool addresses.
    /// @param trustedForwarder A trusted forwarder of transactions to this contract.
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBPrices prices,
        IJBProjects projects,
        IJBTokens tokens,
        IWETH9 weth,
        address factory,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
    {
        DIRECTORY = directory;
        TOKENS = tokens;
        PROJECTS = projects;
        PRICES = prices;
        UNISWAP_V3_FACTORY = factory;
        WETH = weth;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice The `IJBRulesetDataHook` implementation which determines whether tokens should be minted from the
    /// project or bought from the pool.
    /// @param context Payment context passed to the data hook by `terminalStore.recordPaymentFrom(...)`.
    /// `context.metadata` can specify a Uniswap quote and specify how much of the payment should be used to swap.
    /// If `context.metadata` does not specify a quote, one will be calculated based on the TWAP.
    /// If `context.metadata` does not specify how much of the payment should be used, the hook uses the full amount
    /// paid in.
    /// @return weight The weight to use. If tokens are being minted from the project, this is the original weight.
    /// If tokens are being bought from the pool, the weight is 0.
    /// If tokens are being minted AND bought from the pool, this weight is adjusted to take both into account.
    /// @return hookSpecifications Specifications containing pay hooks, as well as the amount and metadata to send to
    /// them. Fulfilled by the terminal.
    /// If tokens are only being minted, `hookSpecifications` will be empty.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        // Keep a reference to the amount paid in.
        uint256 totalPaid = context.amount.value;

        // Keep a reference to the weight.
        weight = context.weight;

        // Keep a reference to the minimum number of tokens expected from the swap.
        uint256 minimumSwapAmountOut;

        // Keep a reference to the amount to be used to swap (out of `totalPaid`).
        uint256 amountToSwapWith;

        // Scoped section to prevent stack too deep.
        {
            // The metadata ID is the first 4 bytes of this contract's address.
            bytes4 metadataId = JBMetadataResolver.getId("quote");

            // Unpack the quote specified by the payer/client (typically from the pool).
            (bool quoteExists, bytes memory metadata) =
                JBMetadataResolver.getDataFor({id: metadataId, metadata: context.metadata});
            if (quoteExists) (amountToSwapWith, minimumSwapAmountOut) = abi.decode(metadata, (uint256, uint256));
        }

        // If the amount to swap with is greater than the actual amount paid in, revert.
        if (amountToSwapWith > totalPaid) revert JBBuybackHook_InsufficientPayAmount(amountToSwapWith, totalPaid);

        // If the payer/client did not specify an amount to use towards the swap, use the `totalPaid`.
        if (amountToSwapWith == 0) amountToSwapWith = totalPaid;

        // Get a reference to the controller.
        IJBController controller = IJBController(address(DIRECTORY.controllerOf(context.projectId)));

        // Get a reference to the ruleset.
        // slither-disable-next-line unused-return
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(context.projectId);

        // If the hook should base its weight on a currency other than the terminal's currency, determine the
        // factor. The weight is always a fixed point number with 18 decimals. To ensure this, the ratio should use the
        // same number of decimals as the `amountToSwapWith`.
        uint256 weightRatio = context.amount.currency == ruleset.baseCurrency()
            ? 10 ** context.amount.decimals
            : PRICES.pricePerUnitOf({
                projectId: context.projectId,
                pricingCurrency: context.amount.currency,
                unitCurrency: ruleset.baseCurrency(),
                decimals: context.amount.decimals
            });

        // Calculate how many tokens would be minted by a direct payment to the project.
        // `tokenCountWithoutHook` is a fixed point number with 18 decimals.
        uint256 tokenCountWithoutHook = mulDiv(amountToSwapWith, weight, weightRatio);

        // Keep a reference to the project's token.
        address projectToken = projectTokenOf[context.projectId];

        // Keep a reference to the token being used by the terminal that is calling this hook. Default to wETH if the
        // terminal uses the native token.
        address terminalToken = context.amount.token == JBConstants.NATIVE_TOKEN ? address(WETH) : context.amount.token;

        // If a minimum amount of tokens to swap for wasn't specified by the player/client, calculate a minimum based on
        // the TWAP.
        if (minimumSwapAmountOut == 0) {
            minimumSwapAmountOut = _getQuote({
                projectId: context.projectId,
                projectToken: projectToken,
                amountIn: amountToSwapWith,
                terminalToken: terminalToken
            });
        }

        // If the minimum amount of tokens from the swap exceeds the amount that paying the project directly would
        // yield, swap.
        if (tokenCountWithoutHook < minimumSwapAmountOut) {
            // Keep a reference to a flag indicating whether the Uniswap pool will reference the project token first in
            // the pair.
            bool projectTokenIs0 = address(projectToken) < terminalToken;

            // Specify this hook as the one to use, the amount to swap with, and metadata which allows the swap to be
            // executed.
            hookSpecifications = new JBPayHookSpecification[](1);
            hookSpecifications[0] = JBPayHookSpecification({
                hook: IJBPayHook(this),
                amount: amountToSwapWith,
                metadata: abi.encode(
                    projectTokenIs0,
                    totalPaid == amountToSwapWith ? 0 : totalPaid - amountToSwapWith,
                    minimumSwapAmountOut,
                    controller
                )
            });

            // All the minting will be done in `afterPayRecordedWith`. Return a weight of 0 to any additional minting
            // from the terminal.
            return (0, hookSpecifications);
        }
    }

    /// @notice To fulfill the `IJBRulesetDataHook` interface.
    /// @dev Pass cash out context back to the terminal without changes.
    /// @param context The cash out context passed in by the terminal.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory hookSpecifications)
    {
        return (context.cashOutTaxRate, context.cashOutCount, context.totalSupply, hookSpecifications);
    }

    /// @notice Required by the `IJBRulesetDataHook` interfaces. Return false to not leak any permissions.
    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure override returns (bool) {
        return false;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBPayHook).interfaceId
            || interfaceId == type(IJBBuybackHook).interfaceId || interfaceId == type(IJBPermissioned).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice Get a quote based on the TWAP, using the TWAP window and slippage tolerance for the specified project.
    /// @param projectId The ID of the project which the swap is associated with.
    /// @param projectToken The project token being swapped for.
    /// @param amountIn The number of terminal tokens being used to swap.
    /// @param terminalToken The terminal token being paid in and used to swap.
    /// @return amountOut The minimum number of tokens to receive based on the TWAP and its params.
    function _getQuote(
        uint256 projectId,
        address projectToken,
        uint256 amountIn,
        address terminalToken
    )
        internal
        view
        returns (uint256 amountOut)
    {
        // Get a reference to the pool that'll be used to make the swap.
        IUniswapV3Pool pool = poolOf[projectId][address(terminalToken)];

        // Make sure the pool exists, if not, return an empty quote.
        if (address(pool).code.length == 0) return 0;

        // If there is a contract at the address, try to get the pool's slot 0.
        // slither-disable-next-line unused-return
        try pool.slot0() returns (uint160, int24, uint16, uint16, uint16, uint8, bool unlocked) {
            // If the pool hasn't been initialized, return an empty quote.
            if (!unlocked) return 0;
        } catch {
            // If the address is invalid, return an empty quote.
            return 0;
        }

        // Unpack the TWAP params and get a reference to the period.
        uint256 twapWindow = twapWindowOf[projectId];

        // If the oldest observation is younger than the TWAP window, use the oldest observation.
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(address(pool));
        if (oldestObservation < twapWindow) twapWindow = oldestObservation;

        // Keep a reference to the TWAP tick.
        int24 arithmeticMeanTick;

        // Keep a reference to the liquidity.
        uint128 liquidity;

        // If no observation history, fall back to minting (skip buyback) — slot0 is flash-loan manipulable.
        if (oldestObservation == 0) return 0;

        (arithmeticMeanTick, liquidity) =
            OracleLibrary.consult({pool: address(pool), secondsAgo: uint32(twapWindow)});

        // If there's no liquidity, fall back to minting.
        if (liquidity == 0) return 0;

        // Get the pool fee in basis points for the sigmoid formula.
        uint256 poolFeeBps = uint256(pool.fee()) / 100;

        // Calculate the slippage tolerance using the continuous sigmoid formula.
        uint256 slippageTolerance = _getSlippageTolerance({
            amountIn: amountIn,
            liquidity: liquidity,
            projectToken: projectToken,
            terminalToken: terminalToken,
            arithmeticMeanTick: arithmeticMeanTick,
            poolFeeBps: poolFeeBps
        });

        // If the slippage tolerance meets or exceeds the maximum, return an empty quote.
        if (slippageTolerance >= TWAP_SLIPPAGE_DENOMINATOR) return 0;

        // Make sure the amount doesn't overflow uint128 before passing to Uniswap.
        if (amountIn > type(uint128).max) revert JBBuybackHook_AmountOverflow();

        // Get a quote based on this TWAP tick.
        amountOut = OracleLibrary.getQuoteAtTick({
            tick: arithmeticMeanTick,
            baseAmount: uint128(amountIn),
            baseToken: terminalToken,
            quoteToken: address(projectToken)
        });

        // return the lowest acceptable return based on the TWAP and its parameters.
        amountOut -= (amountOut * slippageTolerance) / TWAP_SLIPPAGE_DENOMINATOR;
    }

    /// @notice Get the slippage tolerance for a given amount in and liquidity.
    /// @dev Uses the continuous sigmoid formula from JBSwapLib for smoother behavior across all swap sizes.
    /// @param amountIn The amount in to get the slippage tolerance for.
    /// @param liquidity The liquidity to get the slippage tolerance for.
    /// @param projectToken The project token to get the slippage tolerance for.
    /// @param terminalToken The terminal token to get the slippage tolerance for.
    /// @param arithmeticMeanTick The arithmetic mean tick to get the slippage tolerance for.
    /// @param poolFeeBps The pool fee in basis points (e.g., 30 for 0.3%).
    /// @return slippageTolerance The slippage tolerance for the given amount in and liquidity.
    function _getSlippageTolerance(
        uint256 amountIn,
        uint128 liquidity,
        address projectToken,
        address terminalToken,
        int24 arithmeticMeanTick,
        uint256 poolFeeBps
    )
        internal
        pure
        returns (uint256)
    {
        // Direction: is terminalToken token0?
        (address token0,) = projectToken < terminalToken ? (projectToken, terminalToken) : (terminalToken, projectToken);
        bool zeroForOne = terminalToken == token0;

        // sqrtP in Q96 from the TWAP tick
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);

        // If the sqrtP is 0, there's no valid price so we'll return the maximum slippage tolerance.
        if (sqrtP == 0) return TWAP_SLIPPAGE_DENOMINATOR;

        // Calculate impact using 1e18 precision (prevents rounding to 0 for small swaps).
        uint256 impact = JBSwapLib.calculateImpact({
            amountIn: amountIn,
            liquidity: liquidity,
            sqrtP: sqrtP,
            zeroForOne: zeroForOne
        });

        // Use the continuous sigmoid formula with pool fee awareness.
        return JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps});
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Swap the specified amount of terminal tokens for project tokens, using any leftover terminal tokens to
    /// mint from the project.
    /// @dev This function is only called if the minimum return from the swap exceeds the return from minting by paying
    /// the project.
    /// If the swap reverts (due to slippage, insufficient liquidity, or something else),
    /// then the hook mints the number of tokens which a payment to the project would have minted.
    /// @param context The pay context passed in by the terminal.
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
        // Make sure only the project's payment terminals can access this function.
        if (!DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})) {
            revert JBBuybackHook_Unauthorized(msg.sender);
        }

        // Parse the metadata forwarded from the data hook.
        (bool projectTokenIs0, uint256 amountToMintWith, uint256 minimumSwapAmountOut, IJBController controller) =
            abi.decode(context.hookMetadata, (bool, uint256, uint256, IJBController));

        // If the token paid in isn't the native token, pull the amount to swap from the terminal.
        if (context.forwardedAmount.token != JBConstants.NATIVE_TOKEN) {
            IERC20(context.forwardedAmount.token).safeTransferFrom(
                msg.sender, address(this), context.forwardedAmount.value
            );
        }

        // Get a reference to the number of project tokens that was swapped for.
        // slither-disable-next-line reentrancy-events
        uint256 exactSwapAmountOut = _swap({
            context: context,
            projectTokenIs0: projectTokenIs0,
            controller: controller,
            minimumSwapAmountOut: minimumSwapAmountOut
        });

        // Ensure swap satisfies payer/client minimum amount or calculated TWAP if payer/client did not specify.
        if (exactSwapAmountOut < minimumSwapAmountOut) {
            revert JBBuybackHook_SpecifiedSlippageExceeded(exactSwapAmountOut, minimumSwapAmountOut);
        }

        // Get a reference to any terminal tokens which were paid in and are still held by this contract.
        uint256 leftoverAmountInThisContract = context.forwardedAmount.token == JBConstants.NATIVE_TOKEN
            ? address(this).balance
            : IERC20(context.forwardedAmount.token).balanceOf(address(this));

        // Get a reference to the ruleset.
        // slither-disable-next-line unused-return
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(context.projectId);

        // If the hook should base its weight on a currency other than the terminal's currency, determine the
        // factor. The weight is always a fixed point number with 18 decimals. To ensure this, the ratio should use
        // the same number of decimals as the `leftoverAmountInThisContract`.
        uint256 weightRatio = context.amount.currency == ruleset.baseCurrency()
            ? 10 ** context.amount.decimals
            : PRICES.pricePerUnitOf({
                projectId: context.projectId,
                pricingCurrency: context.amount.currency,
                unitCurrency: ruleset.baseCurrency(),
                decimals: context.amount.decimals
            });

        // Mint a corresponding number of project tokens using any terminal tokens left over.
        // Keep a reference to the number of tokens being minted.
        uint256 partialMintTokenCount;
        if (leftoverAmountInThisContract != 0) {
            partialMintTokenCount = mulDiv(leftoverAmountInThisContract, context.weight, weightRatio);

            // If the token paid in wasn't the native token, grant the terminal permission to pull them back into its
            // balance.
            if (context.forwardedAmount.token != JBConstants.NATIVE_TOKEN) {
                // slither-disable-next-line unused-return
                IERC20(context.forwardedAmount.token).forceApprove(msg.sender, leftoverAmountInThisContract);
            }

            // Keep a reference to the amount being paid as `msg.value`.
            uint256 payValue =
                context.forwardedAmount.token == JBConstants.NATIVE_TOKEN ? leftoverAmountInThisContract : 0;

            emit Mint({
                projectId: context.projectId,
                leftoverAmount: leftoverAmountInThisContract,
                tokenCount: partialMintTokenCount,
                caller: msg.sender
            });

            // Add the paid amount back to the project's balance in the terminal.
            // slither-disable-next-line arbitrary-send-eth
            IJBMultiTerminal(msg.sender).addToBalanceOf{value: payValue}({
                projectId: context.projectId,
                token: context.forwardedAmount.token,
                amount: leftoverAmountInThisContract,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: bytes("")
            });
        }

        // Add the amount to mint to the leftover mint amount.
        partialMintTokenCount += mulDiv(amountToMintWith, context.weight, weightRatio);

        // Mint the calculated amount of tokens for the beneficiary, including any leftover amount.
        // This takes the reserved rate into account.
        // slither-disable-next-line unused-return
        controller.mintTokensOf({
            projectId: context.projectId,
            tokenCount: exactSwapAmountOut + partialMintTokenCount,
            beneficiary: address(context.beneficiary),
            memo: "",
            useReservedPercent: true
        });
    }

    /// @notice Set the pool to use for a given project and terminal token (the default for the project's token <->
    /// terminal token pair).
    /// @dev Uses create2 for callback auth and to allow adding pools which haven't been deployed yet.
    /// This can be called by the project's owner or an address which has the `JBPermissionIds.SET_BUYBACK_POOL`
    /// permission from the owner.
    /// @dev L-13: Pool addresses are intentionally immutable once set. This prevents manipulation of swap routing
    /// after a project's buyback hook is configured. If a project needs to use a different pool (e.g., one with
    /// better liquidity), a new buyback hook must be deployed and configured for the project.
    /// @param projectId The ID of the project to set the pool for.
    /// @param fee The fee used in the pool being set, as a fixed-point number of basis points with 2 decimals. A 0.01%
    /// fee is `100`, a 0.05% fee is `500`, a 0.3% fee is `3000`, and a 1% fee is `10000`.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param terminalToken The address of the terminal token that payments to the project are made in.
    /// @return newPool The pool that was set for the project and terminal token.
    function setPoolFor(
        uint256 projectId,
        uint24 fee,
        uint256 twapWindow,
        address terminalToken
    )
        external
        returns (IUniswapV3Pool newPool)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        // Make sure this pool hasn't already been set in this hook.
        // L-13: This is intentional — pool addresses are permanently locked after being set to prevent
        // swap routing manipulation. Changing pools requires deploying a new buyback hook.
        if (poolOf[projectId][terminalToken] != IUniswapV3Pool(address(0))) {
            revert JBBuybackHook_PoolAlreadySet(poolOf[projectId][terminalToken]);
        }

        // Make sure the provided TWAP window is within reasonable bounds.
        if (twapWindow < MIN_TWAP_WINDOW || twapWindow > MAX_TWAP_WINDOW) {
            revert JBBuybackHook_InvalidTwapWindow(twapWindow, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);
        }

        // Make sure the terminal token is not zero.
        if (terminalToken == address(0)) revert JBBuybackHook_ZeroTerminalToken();

        // Keep a reference to the project's token.
        address projectToken = address(TOKENS.tokenOf(projectId));

        // Make sure the project has issued a token.
        if (projectToken == address(0)) revert JBBuybackHook_ZeroProjectToken();

        // Make sure the terminal token is not the project token.
        if (terminalToken == projectToken) {
            revert JBBuybackHook_TerminalTokenIsProjectToken(terminalToken, projectToken);
        }

        // If the specified terminal token is the native token, use wETH instead.
        if (terminalToken == JBConstants.NATIVE_TOKEN) terminalToken = address(WETH);

        // Keep a reference to a flag indicating whether the pool will reference the project token first in the pair.
        bool projectTokenIs0 = address(projectToken) < terminalToken;

        // Compute the pool's address, which is a function of the factory, both tokens, and the fee.
        newPool = IUniswapV3Pool(
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                UNISWAP_V3_FACTORY,
                                keccak256(
                                    abi.encode(
                                        projectTokenIs0 ? projectToken : terminalToken,
                                        projectTokenIs0 ? terminalToken : projectToken,
                                        fee
                                    )
                                ),
                                // POOL_INIT_CODE_HASH from
                                // https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/PoolAddress.sol
                                bytes32(0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54)
                            )
                        )
                    )
                )
            )
        );

        // Store the pool.
        poolOf[projectId][terminalToken] = newPool;

        // Store the TWAP window and the project token.
        twapWindowOf[projectId] = twapWindow;
        projectTokenOf[projectId] = address(projectToken);

        emit TwapWindowChanged({projectId: projectId, oldWindow: 0, newWindow: twapWindow, caller: _msgSender()});
        emit PoolAdded({
            projectId: projectId,
            terminalToken: terminalToken,
            pool: address(newPool),
            caller: _msgSender()
        });
    }

    /// @notice Change the TWAP window for a project.
    /// The TWAP window is the period of time over which the TWAP is computed.
    /// @dev This can be called by the project's owner or an address with `JBPermissionIds.SET_BUYBACK_TWAP`
    /// permission from the owner.
    /// @param projectId The ID of the project to set the TWAP window of.
    /// @param newWindow The new TWAP window.
    function setTwapWindowOf(uint256 projectId, uint256 newWindow) external {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_BUYBACK_TWAP
        });

        // Make sure the specified window is within reasonable bounds.
        if (newWindow < MIN_TWAP_WINDOW || newWindow > MAX_TWAP_WINDOW) {
            revert JBBuybackHook_InvalidTwapWindow(newWindow, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);
        }

        // Keep a reference to the old window value.
        uint256 oldWindow = twapWindowOf[projectId];

        // Store the new packed value of the TWAP params (with the updated window).
        twapWindowOf[projectId] = newWindow;

        emit TwapWindowChanged({projectId: projectId, oldWindow: oldWindow, newWindow: newWindow, caller: _msgSender()});
    }

    /// @notice The Uniswap v3 pool callback where the token transfer is expected to happen.
    /// @param amount0Delta The amount of token 0 being used for the swap.
    /// @param amount1Delta The amount of token 1 being used for the swap.
    /// @param data Data passed in by the swap operation.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Unpack the data passed in through the swap hook.
        (uint256 projectId, address terminalToken) = abi.decode(data, (uint256, address));

        // Get the terminal token, using wETH if the token paid in is the native token.
        address terminalTokenWithWETH = terminalToken == JBConstants.NATIVE_TOKEN ? address(WETH) : terminalToken;

        // Make sure this call is being made from the right pool.
        if (msg.sender != address(poolOf[projectId][terminalTokenWithWETH])) {
            revert JBBuybackHook_CallerNotPool(msg.sender);
        }

        // Keep a reference to the number of tokens that should be sent to fulfill the swap (the positive delta).
        uint256 amountToSendToPool = amount0Delta < 0 ? uint256(amount1Delta) : uint256(amount0Delta);

        // Wrap native tokens as needed.
        if (terminalToken == JBConstants.NATIVE_TOKEN) WETH.deposit{value: amountToSendToPool}();

        // Transfer the token to the pool.
        IERC20(terminalTokenWithWETH).safeTransfer(msg.sender, amountToSendToPool);
    }

    //*********************************************************************//
    // ---------------------- internal functions ------------------------- //
    //*********************************************************************//

    /// @notice Swap the terminal token to receive project tokens.
    /// @param context The `afterPayRecordedContext` passed in by the terminal.
    /// @param projectTokenIs0 A flag indicating whether the pool references the project token as the first in the pair.
    /// @param controller The controller used to mint and burn tokens.
    /// @param minimumSwapAmountOut The minimum acceptable output from the swap (used for sqrtPriceLimit).
    /// @return amountReceived The amount of project tokens received from the swap.
    function _swap(
        JBAfterPayRecordedContext calldata context,
        bool projectTokenIs0,
        IJBController controller,
        uint256 minimumSwapAmountOut
    )
        internal
        returns (uint256 amountReceived)
    {
        // The number of terminal tokens being used for the swap.
        uint256 amountToSwapWith = context.forwardedAmount.value;

        // Get the terminal token. Use wETH if the terminal token is the native token.
        address terminalTokenWithWETH =
            context.forwardedAmount.token == JBConstants.NATIVE_TOKEN ? address(WETH) : context.forwardedAmount.token;

        // Get a reference to the pool that'll be used to make the swap.
        IUniswapV3Pool pool = poolOf[context.projectId][terminalTokenWithWETH];

        // Compute a dynamic sqrtPriceLimit from the minimum acceptable output (MEV protection).
        // When selling terminalToken for projectToken:
        //   zeroForOne = !projectTokenIs0
        uint160 sqrtPriceLimit = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: amountToSwapWith,
            minimumAmountOut: minimumSwapAmountOut,
            zeroForOne: !projectTokenIs0
        });

        // Try swapping.
        // slither-disable-next-line reentrancy-events
        try pool.swap({
            recipient: address(this),
            zeroForOne: !projectTokenIs0,
            amountSpecified: int256(amountToSwapWith),
            sqrtPriceLimitX96: sqrtPriceLimit,
            data: abi.encode(context.projectId, context.forwardedAmount.token)
        }) returns (int256 amount0, int256 amount1) {
            // If the swap succeded, take note of the amount of tokens received.
            // This will be returned as a negative value, which Uniswap uses to represent the outputs of exact input
            // swaps.
            amountReceived = uint256(-(projectTokenIs0 ? amount0 : amount1));
        } catch {
            // If the swap failed, return.
            return 0;
        }

        // Return the amount we received/burned, which we will mint to the beneficiary later.
        emit Swap({
            projectId: context.projectId,
            amountToSwapWith: amountToSwapWith,
            pool: pool,
            amountReceived: amountReceived,
            caller: msg.sender
        });

        // Burn the whole amount received.
        if (amountReceived != 0) {
            controller.burnTokensOf({
                holder: address(this),
                projectId: context.projectId,
                tokenCount: amountReceived,
                memo: ""
            });
        }
    }
}
