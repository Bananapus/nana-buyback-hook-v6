// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
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
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IJBBuybackHook} from "./interfaces/IJBBuybackHook.sol";
import {JBSwapLib} from "./libraries/JBSwapLib.sol";
import {SwapCallbackData} from "./structs/SwapCallbackData.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/// @notice Automatically buys project tokens from a Uniswap V4 pool when the pool price is better than minting, and
/// sells project tokens into the pool during cash-outs when the pool offers more than the bonding curve reclaim. The
/// project's reserved rate is applied regardless of which route wins.
/// @dev Acts as both a pay hook (buy-side) and cash-out hook (sell-side). Uses a TWAP oracle for manipulation
/// resistance and falls back to minting/direct-reclaim when the pool is unavailable or offers worse rates.
contract JBBuybackHook is JBPermissioned, ERC2771Context, IUnlockCallback, IJBBuybackHook {
    // A library that parses the packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBBuybackHook_AlreadyConfigured();
    error JBBuybackHook_CallerNotPoolManager(address caller);
    error JBBuybackHook_CallerNotTerminal(address caller);
    error JBBuybackHook_InsufficientPayAmount(uint256 swapAmount, uint256 totalPaid);
    error JBBuybackHook_InvalidTwapWindow(uint256 value, uint256 min, uint256 max);
    error JBBuybackHook_PoolAlreadySet(PoolId poolId);
    error JBBuybackHook_PoolInitializedAtWrongPrice(uint160 actualSqrtPriceX96, uint160 expectedSqrtPriceX96);
    error JBBuybackHook_PoolNotInitialized(PoolId poolId);
    error JBBuybackHook_PoolNotSet(uint256 projectId, address terminalToken);
    error JBBuybackHook_SpecifiedSlippageExceeded(uint256 amount, uint256 minimum);
    error JBBuybackHook_TerminalTokenIsProjectToken(address terminalToken, address projectToken);
    error JBBuybackHook_Unauthorized(address caller);
    error JBBuybackHook_ZeroProjectToken(uint256 projectId);

    //*********************************************************************//
    // ------------------------- public constants ------------------------- //
    //*********************************************************************//

    /// @notice Projects cannot specify a TWAP window longer than this constant.
    uint256 public constant override MAX_TWAP_WINDOW = 2 days;

    /// @notice Projects cannot specify a TWAP window shorter than this constant.
    uint256 public constant override MIN_TWAP_WINDOW = 5 minutes;

    /// @notice The denominator used when calculating TWAP slippage percent values.
    uint256 public constant override TWAP_SLIPPAGE_DENOMINATOR = 10_000;

    //*********************************************************************//
    // ----------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The contract that exposes price feeds.
    IJBPrices public immutable override PRICES;

    /// @notice The project registry.
    IJBProjects public immutable override PROJECTS;

    /// @notice The token registry.
    IJBTokens public immutable override TOKENS;

    //*********************************************************************//
    // -------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    /// @notice The deployer authorized to set the chain-specific Uniswap V4 PoolManager and oracle hook.
    /// @dev Held as immutable so the constructor inputs are byte-identical on every chain. The chain-specific
    /// Uniswap V4 PoolManager (and the matching oracle hook deployed against it) are set by this
    /// deployer in a one-shot call to `setChainSpecificConstants`. This mirrors the
    /// `JBOptimismSuckerDeployer.setChainSpecificConstants` pattern in nana-suckers-v6, and makes this
    /// contract's CREATE2 address identical across chains.
    address internal immutable _DEPLOYER;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The Uniswap V4 PoolManager singleton. Set once by `_DEPLOYER` after construction via
    /// `setChainSpecificConstants` and never changed thereafter.
    IPoolManager public override poolManager;

    /// @notice The oracle hook used for configured Uniswap V4 pools. Set once by `_DEPLOYER`
    /// after construction via `setChainSpecificConstants` and never changed thereafter.
    IHooks public oracleHook;

    /// @notice The PoolKey for a given project's token and terminal token pair.
    /// @custom:param projectId The ID of the project whose token is traded in the pool.
    /// @custom:param terminalToken The address of the terminal token (normalized to address(0) for native).
    mapping(uint256 projectId => mapping(address terminalToken => PoolKey)) internal _poolKeyOf;

    /// @notice The address of each project's token.
    /// @custom:param projectId The ID of the project the token belongs to.
    mapping(uint256 projectId => address) public override projectTokenOf;

    /// @notice The TWAP window for a given project and terminal token pair.
    /// @custom:param projectId The ID of the project to get the TWAP window for.
    /// @custom:param terminalToken The terminal token address (normalized to address(0) for native).
    mapping(uint256 projectId => mapping(address terminalToken => uint256)) public override twapWindowOf;

    //*********************************************************************//
    // --------------------- private stored properties ------------------- //
    //*********************************************************************//

    /// @notice Tracks whether a pool has been set for a project/terminal token pair.
    mapping(uint256 projectId => mapping(address terminalToken => bool)) private _poolIsSet;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory The directory of terminals and controllers.
    /// @param permissions The permissions contract.
    /// @param prices The contract that exposes price feeds.
    /// @param projects The project registry.
    /// @param tokens The token registry.
    /// @param deployer The address authorized to call `setChainSpecificConstants` exactly once. Held immutable
    /// so the constructor inputs are byte-identical across chains and the CREATE2 address is unified.
    /// @param trustedForwarder A trusted forwarder of transactions to this contract.
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBPrices prices,
        IJBProjects projects,
        IJBTokens tokens,
        address deployer,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
    {
        DIRECTORY = directory;
        TOKENS = tokens;
        PROJECTS = projects;
        PRICES = prices;
        _DEPLOYER = deployer;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Sells project tokens into the configured Uniswap V4 pool and sends the proceeds to the beneficiary.
    /// Called by the terminal after `beforeCashOutRecordedWith` determined that the pool route beats direct reclaim.
    /// @dev This is called by the terminal after the buyback hook's data-hook path has chosen pool execution over the
    /// protocol cash out path.
    /// @dev The terminal has already burned the holder's project tokens by the time this callback runs, so this hook
    /// remints tokens to itself before executing the sell. The count to remint/sell comes from `hookMetadata`
    /// (set during `beforeCashOutRecordedWith`), NOT from `context.cashOutCount`. This distinction matters when a
    /// data hook wrapper (e.g. REVDeployer) splits the cash-out into fee and non-fee tranches — the terminal
    /// always passes the original full count in `context.cashOutCount`, but only the non-fee portion should be sold.
    /// @param context Standard Juicebox cash-out hook context. `hookMetadata` encodes (minimumSwapAmountOut,
    /// cashOutCountToSell) chosen during `beforeCashOutRecordedWith`, followed by informational sell-side routing
    /// metadata.
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context) external payable override {
        // Make sure only payment terminals of the project can trigger the sell-side hook.
        if (!DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})) {
            revert JBBuybackHook_CallerNotTerminal({caller: msg.sender});
        }

        // Normalize the native token address so it matches how pool keys are stored.
        address terminalToken =
            context.reclaimedAmount.token == JBConstants.NATIVE_TOKEN ? address(0) : context.reclaimedAmount.token;

        // Load the configured pool and project token for this project's cash-out token pair.
        PoolKey memory key = _poolKeyOf[context.projectId][terminalToken];
        address projectToken = projectTokenOf[context.projectId];

        // Decode the sell-side slippage floor and the token count to sell, both chosen during route selection.
        // The cashOutCount from metadata is the count the data hook intended for this swap — it may differ from
        // context.cashOutCount when a wrapper (e.g. REVDeployer) splits tokens into fee and non-fee tranches.
        uint256 minimumSwapAmountOut;
        uint256 cashOutCountToSell = context.cashOutCount;
        bool shouldEnforceMinimumSwapAmountOut;
        if (context.hookMetadata.length != 0) {
            if (context.hookMetadata.length >= 256) {
                (minimumSwapAmountOut, cashOutCountToSell,,,,,, shouldEnforceMinimumSwapAmountOut) = abi.decode(
                    context.hookMetadata, (uint256, uint256, uint256, int24, uint128, PoolId, uint256, bool)
                );
            } else {
                (minimumSwapAmountOut, cashOutCountToSell) = abi.decode(context.hookMetadata, (uint256, uint256));
                shouldEnforceMinimumSwapAmountOut = minimumSwapAmountOut != 0;
            }
        }
        // Wrappers can pass a smaller sell count through metadata, but they must never inflate it above
        // what the terminal actually burned in `context.cashOutCount`.
        if (cashOutCountToSell > context.cashOutCount) cashOutCountToSell = context.cashOutCount;

        // Remint project tokens to this hook so they can be sold into the pool.
        // Uses the metadata-provided count, not context.cashOutCount, to avoid selling fee-portion tokens.
        IJBController controller = IJBController(address(DIRECTORY.controllerOf(context.projectId)));

        // Snapshot balance before minting to handle fee-on-transfer tokens.
        uint256 preMintBalance = IERC20(projectToken).balanceOf(address(this));

        controller.mintTokensOf({
            projectId: context.projectId,
            tokenCount: cashOutCountToSell,
            beneficiary: address(this),
            memo: "",
            useReservedPercent: false
        });

        // Measure actual tokens received (handles fee-on-transfer tokens).
        uint256 actualReceived = IERC20(projectToken).balanceOf(address(this)) - preMintBalance;

        // Sell the reminted project tokens for the terminal token using the configured pool direction.
        (uint256 amountSpent, uint256 amountReceived, bool swapFailed) = _swapExactInput({
            key: key,
            amountIn: actualReceived,
            minimumSwapAmountOut: minimumSwapAmountOut,
            zeroForOne: projectToken < terminalToken
        });

        // If the pool reverted, return the reminted project tokens to the holder instead of
        // blocking the cash-out entirely. The holder keeps their tokens and can sell manually or retry.
        // BUT if the caller explicitly demanded a non-zero terminal-token minimum, returning project
        // tokens to the holder cannot satisfy that minimum — revert so the user is not silently
        // settled in the wrong token at less than they asked for.
        if (swapFailed) {
            if (shouldEnforceMinimumSwapAmountOut && minimumSwapAmountOut != 0) {
                revert JBBuybackHook_SpecifiedSlippageExceeded({amount: 0, minimum: minimumSwapAmountOut});
            }
            IERC20(projectToken).safeTransfer({to: context.holder, value: actualReceived});
            emit SellSwapReverted({
                projectId: context.projectId, holder: context.holder, amount: actualReceived, caller: msg.sender
            });
            return;
        }

        // A derived floor can still fall back to project tokens if the pool reverts, but a successful pool fill must
        // honor the non-zero floor that made this route preferable to the direct cash-out path.
        if (minimumSwapAmountOut != 0 && amountReceived < minimumSwapAmountOut) {
            revert JBBuybackHook_SpecifiedSlippageExceeded({amount: amountReceived, minimum: minimumSwapAmountOut});
        }

        // Return only the reminted residue left unsold by THIS execution. The terminal already burned the holder's
        // project tokens before this hook ran, so returning the unsold remint restores the portion that the pool did
        // not actually buy. Pre-existing project-token balances on the hook must not be swept into this transfer.
        uint256 unsoldProjectTokenCount = actualReceived > amountSpent ? actualReceived - amountSpent : 0;
        if (unsoldProjectTokenCount != 0) {
            IERC20(projectToken).safeTransfer({to: context.holder, value: unsoldProjectTokenCount});
        }

        // Forward the swap proceeds to the beneficiary in the same token they would have reclaimed natively.
        if (context.reclaimedAmount.token == JBConstants.NATIVE_TOKEN) {
            Address.sendValue({recipient: context.beneficiary, amount: amountReceived});
        } else {
            // Measure the actual delivery to guard against fee-on-transfer tokens.
            uint256 balBefore = IERC20(context.reclaimedAmount.token).balanceOf(context.beneficiary);
            IERC20(context.reclaimedAmount.token).safeTransfer({to: context.beneficiary, value: amountReceived});
            uint256 delivered = IERC20(context.reclaimedAmount.token).balanceOf(context.beneficiary) - balBefore;
            if (minimumSwapAmountOut != 0 && delivered < minimumSwapAmountOut) {
                revert JBBuybackHook_SpecifiedSlippageExceeded({amount: delivered, minimum: minimumSwapAmountOut});
            }
        }

        // Emit the executed sell-side cash-out details for offchain indexers and analytics.
        emit CashOutSwap({
            projectId: context.projectId,
            cashOutCount: cashOutCountToSell,
            poolId: key.toId(),
            amountReceived: amountReceived,
            caller: msg.sender
        });
    }

    /// @notice Buys project tokens from the Uniswap V4 pool, then mints any leftover at the issuance rate. The swap
    /// fills only while the pool price beats the mint rate — leftover input is returned to the project's terminal.
    /// @dev The swap uses the issuance rate as its price limit: it fills while the pool offers a better rate than
    /// minting, and any unswapped tokens are minted at the issuance rate. The combined output (swap + leftover mint)
    /// must meet the user's specified minimum, otherwise the transaction reverts. If the swap reverts entirely (due to
    /// insufficient liquidity or something else), all tokens are minted as a fallback. Explicit caller-provided
    /// minimums still apply in that case, but oracle-derived routing minimums do not.
    /// @param context The pay context passed in by the terminal.
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
        // Make sure only the project's payment terminals can access this function.
        if (!DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})) {
            revert JBBuybackHook_Unauthorized({caller: msg.sender});
        }

        // Parse the metadata forwarded from the data hook.
        // `minimumSwapAmountOut` is the payer's minimum acceptable total token output (swap + leftover mint).
        // `tokenCountWithoutHook` is the number of project tokens a direct payment (no swap) would have minted
        // for the swap portion. It sets the swap's price limit: the pool must offer a better rate than minting,
        // otherwise the remaining input is minted instead.
        // `weightRatio` is the currency conversion factor computed in `beforePayRecordedWith`, passed through
        // metadata to avoid a redundant `currentRulesetOf` + price lookup in this function.
        (
            bool projectTokenIs0,
            uint256 amountToMintWith,
            uint256 minimumSwapAmountOut,
            bool hasExplicitMinimumSwapAmountOut,
            IJBController controller,
            uint256 tokenCountWithoutHook,
            uint256 weightRatio
        ) = abi.decode(context.hookMetadata, (bool, uint256, uint256, bool, IJBController, uint256, uint256));

        // Cache the native token check to avoid repeated comparison (~50-100 gas).
        bool isNativeToken = context.forwardedAmount.token == JBConstants.NATIVE_TOKEN;

        // Record the terminal token balance BEFORE pulling payment tokens so we can compute leftover as a delta.
        // For native ETH, `msg.value` is already included in `address(this).balance` at this point,
        // so we subtract it. For ERC-20, we capture BEFORE safeTransferFrom.
        // This prevents both pre-existing balances AND the payment itself from inflating leftovers.
        uint256 balanceBefore = _terminalTokenBalance(context.forwardedAmount.token);
        if (isNativeToken) {
            balanceBefore -= msg.value;
        }

        // If the token paid in isn't the native token, pull the amount to swap from the terminal.
        if (!isNativeToken) {
            IERC20(context.forwardedAmount.token)
                .safeTransferFrom({from: msg.sender, to: address(this), value: context.forwardedAmount.value});
        }

        // Get a reference to the number of project tokens that was swapped for.
        // `swapFailed` is true when the try/catch in _swap caught a revert (pool unavailable, etc.).
        // The price limit is set to the issuance rate (tokenCountWithoutHook / amountIn), so the swap
        // fills only while the pool offers a better rate than minting. Any unconsumed input tokens
        // remain in this contract and are minted at the issuance rate below.
        (uint256 exactSwapAmountOut, bool swapFailed) = _swap({
            context: context,
            projectTokenIs0: projectTokenIs0,
            minimumSwapAmountOut: tokenCountWithoutHook,
            controller: controller
        });

        // Compute leftover terminal tokens as a delta (balanceAfter - balanceBefore).
        uint256 leftoverAmountInThisContract = _terminalTokenBalance(context.forwardedAmount.token) - balanceBefore;

        // Mint a corresponding number of project tokens using any terminal tokens left over.
        uint256 partialMintTokenCount;
        if (leftoverAmountInThisContract != 0) {
            uint256 terminalBalanceBeforeAdd;

            // If the token paid in wasn't the native token, grant the terminal permission to pull them back.
            if (!isNativeToken) {
                terminalBalanceBeforeAdd = IERC20(context.forwardedAmount.token).balanceOf(msg.sender);
                IERC20(context.forwardedAmount.token)
                    .forceApprove({spender: msg.sender, value: leftoverAmountInThisContract});
            }

            uint256 payValue = isNativeToken ? leftoverAmountInThisContract : 0;

            // Snapshot balance before `addToBalanceOf` so we can measure the actual amount transferred.
            uint256 balanceBeforeAdd = _terminalTokenBalance(context.forwardedAmount.token);

            // Add the paid amount back to the project's balance in the terminal.
            // Note: `leftoverAmountInThisContract` is already a measured balance delta (line 314), so it
            // reflects the real tokens held. The terminal's `_acceptFundsFor` independently measures
            // its own balance delta, so fee-on-transfer tokens are correctly accounted for on both sides.
            IJBMultiTerminal(msg.sender).addToBalanceOf{value: payValue}({
                projectId: context.projectId,
                token: context.forwardedAmount.token,
                amount: leftoverAmountInThisContract,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: bytes("")
            });

            // Reset the approval to 0 to avoid leaving a residual allowance for the terminal.
            if (!isNativeToken) {
                IERC20(context.forwardedAmount.token).forceApprove({spender: msg.sender, value: 0});
            }

            // Measure how much value the terminal actually reacquired. For fee-on-transfer tokens, the hook-side
            // debit can exceed the terminal's credited amount on the return hop. Native ETH cannot tax the transfer,
            // so the hook-side debit and terminal credit are identical there.
            uint256 amountActuallySent = isNativeToken
                ? balanceBeforeAdd - _terminalTokenBalance(context.forwardedAmount.token)
                : IERC20(context.forwardedAmount.token).balanceOf(msg.sender) - terminalBalanceBeforeAdd;

            partialMintTokenCount = mulDiv({x: amountActuallySent, y: context.weight, denominator: weightRatio});

            emit Mint({
                projectId: context.projectId,
                leftoverAmount: amountActuallySent,
                tokenCount: partialMintTokenCount,
                caller: msg.sender
            });
        }

        // Explicit caller minima are hard settlement guarantees and still apply if the swap path
        // fails completely. Oracle-derived minima are routing hints, so a total swap failure may
        // still degrade to mint-only fallback without reverting.
        bool shouldEnforceMinimum = hasExplicitMinimumSwapAmountOut || !swapFailed;
        if (shouldEnforceMinimum && exactSwapAmountOut + partialMintTokenCount < minimumSwapAmountOut) {
            revert JBBuybackHook_SpecifiedSlippageExceeded({
                amount: exactSwapAmountOut + partialMintTokenCount, minimum: minimumSwapAmountOut
            });
        }

        // Add the amount to mint to the leftover mint amount.
        partialMintTokenCount += mulDiv({x: amountToMintWith, y: context.weight, denominator: weightRatio});

        // Mint the calculated amount of tokens for the beneficiary, including any leftover amount.
        // Skip if there are no tokens to mint (e.g. weight=0 and swap failed).
        uint256 totalTokensToMint = exactSwapAmountOut + partialMintTokenCount;
        if (totalTokensToMint != 0) {
            controller.mintTokensOf({
                projectId: context.projectId,
                tokenCount: totalTokensToMint,
                beneficiary: address(context.beneficiary),
                memo: "",
                useReservedPercent: true
            });
        }
    }

    /// @notice Initialize a Uniswap V4 pool in the PoolManager and configure it as the buyback pool for a project.
    /// @dev Atomically initializes the pool (if not already initialized) and calls `_setPoolFor`.
    /// @dev Operator-only. Configuring the pool turns on the floor + ceiling arbitrage routing above
    /// for this `(projectId, terminalToken)` pair. Without a configured pool, the hook is a passthrough.
    /// @param projectId The ID of the project to set the pool for.
    /// @param fee The Uniswap V4 pool fee tier.
    /// @param tickSpacing The Uniswap V4 pool tick spacing.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param terminalToken The address of the terminal token that payments to the project are made in.
    /// @param sqrtPriceX96 The initial sqrtPriceX96 for the pool (if not already initialized).
    function initializePoolFor(
        uint256 projectId,
        uint24 fee,
        int24 tickSpacing,
        uint256 twapWindow,
        address terminalToken,
        uint160 sqrtPriceX96
    )
        external
        override
    {
        // Enforce permissions.
        // The buyback hook registry (or any other contract) can call these functions on behalf of project owners
        // by having SET_BUYBACK_POOL permission granted through JBPermissions — no special-casing needed here.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });
        (PoolKey memory poolKey, address normalizedTerminalToken, address projectToken) =
            _buildPoolKey({projectId: projectId, fee: fee, tickSpacing: tickSpacing, terminalToken: terminalToken});

        // Initialize pool in PoolManager if not already initialized.
        try poolManager.initialize({key: poolKey, sqrtPriceX96: sqrtPriceX96}) {} catch {}

        // The project token address can be predicted before deployment (CREATE2 with project-supplied salt), so an
        // attacker can front-run the buyback configuration by initializing the V4 pool at an arbitrary
        // `sqrtPriceX96`. Without this check, `_setPoolFor` would lock the poisoned price in for all future
        // buyback routing. Read the on-chain price after the initialize attempt and reject any mismatch — callers
        // pass the price they expect, so honest reinitialization is unaffected.
        (uint160 actualSqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        if (actualSqrtPriceX96 != sqrtPriceX96) {
            revert JBBuybackHook_PoolInitializedAtWrongPrice({
                actualSqrtPriceX96: actualSqrtPriceX96, expectedSqrtPriceX96: sqrtPriceX96
            });
        }

        _setPoolFor({
            projectId: projectId,
            poolKey: poolKey,
            twapWindow: twapWindow,
            normalizedTerminalToken: normalizedTerminalToken,
            projectToken: projectToken
        });
    }

    /// @notice One-shot setter for the chain-specific Uniswap V4 PoolManager and oracle hook.
    /// @dev Callable only by `_DEPLOYER` and only once (when `poolManager` is still `address(0)`). After this
    /// call both values are effectively immutable for the contract's lifetime. Mirrors the
    /// `JBOptimismSuckerDeployer.setChainSpecificConstants` pattern so the contract's CREATE2 inputs stay
    /// byte-identical across chains and its deployed address is unified.
    /// @param newPoolManager The Uniswap V4 PoolManager singleton on the current chain.
    /// @param newOracleHook The Uniswap V4 oracle hook deployed against `newPoolManager` on the current chain.
    function setChainSpecificConstants(IPoolManager newPoolManager, IHooks newOracleHook) external override {
        if (msg.sender != _DEPLOYER) revert JBBuybackHook_Unauthorized({caller: msg.sender});
        if (address(poolManager) != address(0)) revert JBBuybackHook_AlreadyConfigured();
        poolManager = newPoolManager;
        oracleHook = newOracleHook;
    }

    /// @notice Set the V4 pool to use for a given project and terminal token pair.
    /// @dev Pool keys are intentionally immutable once set. This prevents manipulation of swap routing
    /// after a project's buyback hook is configured.
    /// @dev WARNING: The `poolKey.hooks` field is NOT validated. A malicious or buggy V4 hook address in the pool key
    /// could interfere with swaps (e.g. manipulate pricing, revert, or extract value). Because this function is
    /// permissioned to the project owner (or a delegate with `SET_BUYBACK_POOL`), this is a self-harming-only risk.
    /// Callers MUST ensure the pool key — including its hooks field — references a trusted pool.
    /// @dev Operator-only. Configuring the pool turns on the floor + ceiling arbitrage routing above
    /// for this `(projectId, terminalToken)` pair. Without a configured pool, the hook is a passthrough.
    /// @param projectId The ID of the project to set the pool for.
    /// @param poolKey The V4 PoolKey identifying the pool.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param terminalToken The address of the terminal token that payments to the project are made in.
    function setPoolFor(
        uint256 projectId,
        PoolKey calldata poolKey,
        uint256 twapWindow,
        address terminalToken
    )
        external
        override
    {
        // Enforce permissions.
        // The buyback hook registry (or any other contract) can call these functions on behalf of project owners
        // by having SET_BUYBACK_POOL permission granted through JBPermissions — no special-casing needed here.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        // Normalize the terminal token — use address(0) for native.
        address normalizedTerminalToken = terminalToken == JBConstants.NATIVE_TOKEN ? address(0) : terminalToken;

        // Get the project's token.
        address projectToken = address(TOKENS.tokenOf(projectId));

        _setPoolFor({
            projectId: projectId,
            poolKey: poolKey,
            twapWindow: twapWindow,
            normalizedTerminalToken: normalizedTerminalToken,
            projectToken: projectToken
        });
    }

    /// @notice Set the V4 pool to use for a given project and terminal token pair, constructing the PoolKey internally.
    /// @dev Uses address(0) for the hooks field. The hook sorts the project token and terminal token into the correct
    /// currency order. Pool keys are intentionally immutable once set.
    /// @dev Operator-only. Configuring the pool turns on the floor + ceiling arbitrage routing above
    /// for this `(projectId, terminalToken)` pair. Without a configured pool, the hook is a passthrough.
    /// @param projectId The ID of the project to set the pool for.
    /// @param fee The Uniswap V4 pool fee tier.
    /// @param tickSpacing The Uniswap V4 pool tick spacing.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param terminalToken The address of the terminal token that payments to the project are made in.
    function setPoolFor(
        uint256 projectId,
        uint24 fee,
        int24 tickSpacing,
        uint256 twapWindow,
        address terminalToken
    )
        external
        override
    {
        // Enforce permissions.
        // The buyback hook registry (or any other contract) can call these functions on behalf of project owners
        // by having SET_BUYBACK_POOL permission granted through JBPermissions — no special-casing needed here.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        (PoolKey memory poolKey, address normalizedTerminalToken, address projectToken) =
            _buildPoolKey({projectId: projectId, fee: fee, tickSpacing: tickSpacing, terminalToken: terminalToken});

        _setPoolFor({
            projectId: projectId,
            poolKey: poolKey,
            twapWindow: twapWindow,
            normalizedTerminalToken: normalizedTerminalToken,
            projectToken: projectToken
        });
    }

    /// @notice Change the TWAP window for a project's terminal token.
    /// @param projectId The ID of the project to set the TWAP window of.
    /// @param terminalToken The terminal token address (use JBConstants.NATIVE_TOKEN for native ETH).
    /// @param newWindow The new TWAP window.
    function setTwapWindowOf(uint256 projectId, address terminalToken, uint256 newWindow) external override {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_TWAP
        });

        // Make sure the specified window is within reasonable bounds.
        if (newWindow < MIN_TWAP_WINDOW || newWindow > MAX_TWAP_WINDOW) {
            revert JBBuybackHook_InvalidTwapWindow({value: newWindow, min: MIN_TWAP_WINDOW, max: MAX_TWAP_WINDOW});
        }

        // Normalize the terminal token — use address(0) for native.
        address normalizedTerminalToken = terminalToken == JBConstants.NATIVE_TOKEN ? address(0) : terminalToken;

        // Make sure a pool has been configured for this project/terminal token pair.
        if (!_poolIsSet[projectId][normalizedTerminalToken]) {
            revert JBBuybackHook_PoolNotSet({projectId: projectId, terminalToken: normalizedTerminalToken});
        }

        uint256 oldWindow = twapWindowOf[projectId][normalizedTerminalToken];
        twapWindowOf[projectId][normalizedTerminalToken] = newWindow;

        emit TwapWindowChanged({
            projectId: projectId,
            terminalToken: normalizedTerminalToken,
            oldWindow: oldWindow,
            newWindow: newWindow,
            caller: _msgSender()
        });
    }

    /// @notice The V4 PoolManager unlock callback. Executes the swap and settles/takes tokens.
    /// @dev ONLY callable by the PoolManager singleton.
    /// @param data ABI-encoded SwapCallbackData.
    /// @return result ABI-encoded swap input consumed and output received.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        // Only the PoolManager can call this.
        if (msg.sender != address(poolManager)) revert JBBuybackHook_CallerNotPoolManager(msg.sender);

        SwapCallbackData memory params = abi.decode(data, (SwapCallbackData));

        // Compute a price limit that stops the swap if the rate is worse than the minimum acceptable output.
        uint160 sqrtPriceLimit = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: params.amountIn, minimumAmountOut: params.minimumSwapAmountOut, zeroForOne: params.zeroForOne
        });

        BalanceDelta delta = poolManager.swap({
            key: params.key,
            params: SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: -int256(params.amountIn), // Negative = exact input
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            hookData: abi.encode(uint256(0))
        });

        // Determine the input and output amounts from the delta.
        // V4 convention: negative delta = caller spent (input), positive delta = caller received (output).
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Identify input/output currencies.
        Currency inputCurrency;
        Currency outputCurrency;
        uint256 inputAmount;
        uint256 outputAmount;

        if (params.zeroForOne) {
            inputCurrency = params.key.currency0;
            outputCurrency = params.key.currency1;
            // forge-lint: disable-next-line(unsafe-typecast)
            inputAmount = uint256(uint128(-delta0));
            // forge-lint: disable-next-line(unsafe-typecast)
            outputAmount = uint256(uint128(delta1));
        } else {
            inputCurrency = params.key.currency1;
            outputCurrency = params.key.currency0;
            // forge-lint: disable-next-line(unsafe-typecast)
            inputAmount = uint256(uint128(-delta1));
            // forge-lint: disable-next-line(unsafe-typecast)
            outputAmount = uint256(uint128(delta0));
        }

        // Settle the input (we owe the PoolManager).
        if (inputCurrency.isAddressZero()) {
            // Native ETH: settle with value.
            poolManager.settle{value: inputAmount}();
        } else {
            // ERC-20: sync → transfer → settle.
            poolManager.sync(inputCurrency);
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer({to: address(poolManager), value: inputAmount});
            poolManager.settle();
        }

        // Take the output (PoolManager owes us).
        // Use balance-delta accounting to handle fee-on-transfer tokens that deliver less than `outputAmount`.
        uint256 balanceBeforeTake = outputCurrency.isAddressZero()
            ? address(this).balance
            : IERC20(Currency.unwrap(outputCurrency)).balanceOf(address(this));

        poolManager.take({currency: outputCurrency, to: address(this), amount: outputAmount});

        uint256 balanceAfterTake = outputCurrency.isAddressZero()
            ? address(this).balance
            : IERC20(Currency.unwrap(outputCurrency)).balanceOf(address(this));

        // The actual received amount accounts for any fee-on-transfer deduction.
        uint256 actualOutputAmount = balanceAfterTake - balanceBeforeTake;

        return abi.encode(inputAmount, actualOutputAmount);
    }

    /// @notice Receive native tokens. Required for V4 native take() and wrapped token unwrap.
    receive() external payable {}

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Compares the expected output from selling project tokens in the pool against the bonding-curve reclaim
    /// amount. If the pool offers more (net of fees), routes the cash-out through the pool via
    /// `afterCashOutRecordedWith`.
    /// @notice Data-hook callback consulted by the terminal during `cashOutTokensOf()`. Decides whether
    /// to settle the user's cash-out through the bonding curve or through the Uniswap V4 pool.
    /// @dev Returns the protocol cash-out values unchanged unless selling the burned project tokens into the
    /// configured pool is expected to return more of the terminal token than the direct reclaim path.
    /// @dev If the sell path wins, the hook returns an active cash-out hook specification (`noop = false`) and
    /// maxes the tax rate so the terminal does not reclaim surplus itself. The actual sell is executed in
    /// `afterCashOutRecordedWith`.
    /// @dev This function auto-applies the "floor arbitrage" path described in ARBITRAGE.md (Path 2,
    /// in revnet-core-v6). When the AMM bid is HIGHER than the bonding-curve reclaim, the hook routes
    /// the holder's burn through the pool — they get more ETH. When the AMM bid is LOWER, the hook
    /// passes through to the terminal — the bonding-curve floor is what they receive. Either way, the
    /// holder receives at least the bonding-curve reclaim.
    ///
    /// **Why this matters for protocol health:** when external actors arbitrage between the AMM and the
    /// terminal cash-out path directly (buying tokens cheap on the AMM, then cashing out via terminal
    /// at the higher floor), the cash-out tax (configured per ruleset, e.g. 10%) is retained in the
    /// project surplus — boosting per-token backing for remaining holders. The AMM price corrects
    /// upward toward fair value. This hook auto-captures the same incentive for ordinary users.
    ///
    /// **Diagnostic metadata in returned hook specs:** when the hook chooses to noop (passthrough),
    /// the spec carries pool state (twapTick, liquidity, poolId, etc.) so off-chain clients can preview
    /// what the routing decision would be. Do not optimize this away — it's the protocol's public
    /// preview API for the buyback cash-out decision surface.
    /// @param context Standard Juicebox cash-out data-hook context.
    /// @return cashOutTaxRate The tax rate the terminal should use for the cash out.
    /// @return cashOutCount The number of project tokens to cash out.
    /// @return totalSupply The total project token supply to use in reclaim math.
    /// @return effectiveSurplusValue The surplus to use for reclaim calculation.
    /// @return hookSpecifications Any cash-out hook specifications to fulfill after the terminal records the cash out.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // Normalize the native token address so it matches the pool-key storage convention.
        address terminalToken = context.surplus.token == JBConstants.NATIVE_TOKEN ? address(0) : context.surplus.token;

        // Load the project token that would be sold if the pool route is chosen.
        address projectToken = projectTokenOf[context.projectId];

        // Read any user-specified minimum reclaimed amount from metadata up front so the no-pool
        // fallback below can honor it. An explicit non-zero value is a hard floor — when no
        // pool/project-token is available, falling back to direct reclaim must still satisfy it.
        uint256 minimumSwapAmountOut;
        bool hasUserSpecifiedMinimumSwapAmountOut;
        (bool exists, bytes memory minData) = JBMetadataResolver.getDataFor({
            id: JBMetadataResolver.getId("cashOutMinReclaimed"), metadata: context.metadata
        });
        if (exists) {
            minimumSwapAmountOut = abi.decode(minData, (uint256));
            // Only honor user minimum when they specify an explicit value.
            // minimumSwapAmountOut=0 (programmatic orders) falls through to TWAP oracle.
            hasUserSpecifiedMinimumSwapAmountOut = minimumSwapAmountOut != 0;
        }

        // Fall back to the protocol cash-out path if no pool is configured, no project token is known,
        // or no project tokens are being cashed out. When the user supplied an explicit minimum, the
        // fallback must still satisfy it — otherwise revert so the user does not silently receive less
        // than they asked for.
        if (!_poolIsSet[context.projectId][terminalToken] || projectToken == address(0) || context.cashOutCount == 0) {
            if (hasUserSpecifiedMinimumSwapAmountOut) {
                uint256 fallbackReclaim = JBCashOuts.cashOutFrom({
                    surplus: context.surplus.value,
                    cashOutCount: context.cashOutCount,
                    totalSupply: context.totalSupply,
                    cashOutTaxRate: context.cashOutTaxRate
                });
                // Enforce the user's explicit minimum against the exact net the terminal would pay out.
                uint256 netFallbackReclaim = _netAfterTerminalFee({amount: fallbackReclaim, context: context});
                if (netFallbackReclaim < minimumSwapAmountOut) {
                    revert JBBuybackHook_SpecifiedSlippageExceeded({
                        amount: netFallbackReclaim, minimum: minimumSwapAmountOut
                    });
                }
            }
            return (
                context.cashOutTaxRate,
                context.cashOutCount,
                context.totalSupply,
                context.surplus.value,
                hookSpecifications
            );
        }

        // Compute the direct protocol reclaim amount for this cash-out request.
        uint256 directCashOutAmount = JBCashOuts.cashOutFrom({
            surplus: context.surplus.value,
            cashOutCount: context.cashOutCount,
            totalSupply: context.totalSupply,
            cashOutTaxRate: context.cashOutTaxRate
        });

        // Keep references to pool diagnostics. Explicit minimums skip the TWAP lookup, so diagnostics remain zeroed.
        uint256 rawSwapQuote;
        int24 twapTick;
        uint128 twapLiquidity;
        PoolId poolId;
        if (hasUserSpecifiedMinimumSwapAmountOut) {
            // Only compute poolId from storage when skipping _getQuote (which would return it).
            poolId = _poolKeyOf[context.projectId][terminalToken].toId();
        } else {
            (rawSwapQuote, minimumSwapAmountOut, twapTick, twapLiquidity, poolId) = _getQuote({
                projectId: context.projectId,
                amountIn: context.cashOutCount,
                baseToken: projectToken,
                quoteToken: terminalToken,
                terminalToken: terminalToken
            });
        }

        // Compute the executable net direct reclaim under the active fee semantics. The terminal's
        // effective payout depends on the cash-out tax rate, whether the beneficiary is feeless, and —
        // in the zero-tax branch — the terminal's `feeFreeSurplusOf` counter (a fee applies only up
        // to that surplus). Reading it via the now-public getter gives an exact net, so the
        // noop-vs-AMM comparison and any user-specified floor can both rely on the same number.
        uint256 netDirectCashOutAmount = _netAfterTerminalFee({amount: directCashOutAmount, context: context});

        bool noop = minimumSwapAmountOut <= netDirectCashOutAmount;

        // Return sell-side routing metadata in both cases so preview clients can inspect the route comparison without
        // forcing the terminal to execute `afterCashOutRecordedWith`.
        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(address(this)),
            noop: noop,
            amount: 0,
            metadata: abi.encode(
                minimumSwapAmountOut,
                context.cashOutCount,
                netDirectCashOutAmount,
                twapTick,
                twapLiquidity,
                poolId,
                rawSwapQuote,
                hasUserSpecifiedMinimumSwapAmountOut
            )
        });

        if (noop) {
            return (
                context.cashOutTaxRate,
                context.cashOutCount,
                context.totalSupply,
                context.surplus.value,
                hookSpecifications
            );
        }

        // Max the tax rate so the terminal does not reclaim surplus directly before the hook executes the sell.
        return (JBConstants.MAX_CASH_OUT_TAX_RATE, context.cashOutCount, context.totalSupply, 0, hookSpecifications);
    }

    /// @notice Compares the pool swap rate against the project's mint rate and chooses the better one. If the pool
    /// wins, returns weight=0 so all tokens come from the swap executed in `afterPayRecordedWith`.
    /// @notice Data-hook callback consulted by the terminal during `pay()`. Decides whether to route
    /// the user's payment through bonding-curve mint or through the configured Uniswap V4 pool.
    ///
    /// @dev This function auto-applies the "ceiling arbitrage" path described in ARBITRAGE.md (Path 3,
    /// in revnet-core-v6). When the AMM ask is HIGHER than the terminal's pay rate (`weight × ETH`),
    /// the hook returns `noop=true` and the terminal mints at the bonding-curve rate — saving the user
    /// money. When the AMM ask is LOWER, the hook routes through the pool — the user gets more tokens
    /// per ETH. Either way, the user receives at least the bonding-curve mint amount.
    ///
    /// The `noop` spec is intentionally returned with diagnostic metadata (twapTick, liquidity, poolId,
    /// weight ratio, raw swap quote) so off-chain clients (frontends, arbitrage bots, indexers) can
    /// preview what the routing decision would be without executing a pay. Do not optimize this away —
    /// it's the protocol's public preview API for the buyback decision surface.
    ///
    /// **Why this matters for protocol health:** when external actors arbitrage between the terminal
    /// pay path and the AMM directly (paying terminal at low weight, then selling on AMM at higher
    /// price), the AMM price converges downward toward the issuance rate. Their payment lands in
    /// project surplus, growing the protocol. This hook auto-captures the same incentive for ordinary
    /// users transacting through the terminal — they never need to know whether to mint or swap.
    /// @param context Payment context passed to the data hook by `terminalStore.recordPaymentFrom(...)`.
    /// `context.metadata` can specify a Uniswap quote and specify how much of the payment should be used to swap.
    /// If `context.metadata` does not specify a quote, one will be calculated based on the TWAP.
    /// If `context.metadata` does not specify how much of the payment should be used, the hook uses the full amount
    /// paid in.
    /// @return weight The weight to use for minting. 0 if all tokens come from the swap.
    /// @return hookSpecifications Specifications containing pay hooks, as well as the amount and metadata to send to
    /// them. Empty if only minting.
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
        bool hasUserSpecifiedQuote;

        // Keep a reference to the amount to be used to swap (out of `totalPaid`).
        uint256 amountToSwapWith;

        // Unpack the quote specified by the payer/client (typically from the pool).
        bytes4 metadataId = JBMetadataResolver.getId("quote");
        (bool quoteExists, bytes memory metadata) =
            JBMetadataResolver.getDataFor({id: metadataId, metadata: context.metadata});
        if (quoteExists) {
            (amountToSwapWith, minimumSwapAmountOut) = abi.decode(metadata, (uint256, uint256));
            // Only honor user quote when they specify an explicit minimum.
            // minimumSwapAmountOut=0 (programmatic orders) falls through to TWAP oracle.
            hasUserSpecifiedQuote = minimumSwapAmountOut != 0;
        }

        // If the amount to swap with is greater than the actual amount paid in, revert.
        if (amountToSwapWith > totalPaid) revert JBBuybackHook_InsufficientPayAmount(amountToSwapWith, totalPaid);

        // If the payer/client did not specify an amount to use towards the swap, use the `totalPaid`.
        if (amountToSwapWith == 0) amountToSwapWith = totalPaid;

        // Get a reference to the controller.
        IJBController controller = IJBController(address(DIRECTORY.controllerOf(context.projectId)));

        // Get a reference to the ruleset.
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(context.projectId);

        // If the hook should base its weight on a currency other than the terminal's currency, determine the factor.
        uint256 weightRatio = context.amount.currency == ruleset.baseCurrency()
            ? 10 ** context.amount.decimals
            : PRICES.pricePerUnitOf({
                projectId: context.projectId,
                pricingCurrency: context.amount.currency,
                unitCurrency: ruleset.baseCurrency(),
                decimals: context.amount.decimals
            });

        // Calculate how many tokens would be minted by a direct payment to the project.
        uint256 tokenCountWithoutHook = mulDiv({x: amountToSwapWith, y: weight, denominator: weightRatio});

        // Keep a reference to the project's token.
        address projectToken = projectTokenOf[context.projectId];

        // Keep a reference to the token being used by the terminal. Use address(0) for native ETH.
        address terminalToken = context.amount.token == JBConstants.NATIVE_TOKEN ? address(0) : context.amount.token;

        // Keep references to pool diagnostics. If the user provided a quote, honor it directly and skip the TWAP.
        uint256 rawSwapQuote;
        int24 twapTick;
        uint128 twapLiquidity;
        PoolId poolId;
        if (hasUserSpecifiedQuote) {
            // Only compute poolId from storage when skipping _getQuote (which would return it).
            poolId = _poolKeyOf[context.projectId][terminalToken].toId();
        } else {
            (rawSwapQuote, minimumSwapAmountOut, twapTick, twapLiquidity, poolId) = _getQuote({
                projectId: context.projectId,
                amountIn: amountToSwapWith,
                baseToken: terminalToken,
                quoteToken: projectToken,
                terminalToken: terminalToken
            });
        }

        uint256 minimumBeneficiaryTokenCount;
        uint256 minimumReservedTokenCount;

        // Use the controller's preview path so the metadata mirrors the actual beneficiary/reserved split logic.
        if (minimumSwapAmountOut != 0) {
            (minimumBeneficiaryTokenCount, minimumReservedTokenCount) = controller.previewMintOf({
                projectId: context.projectId, tokenCount: minimumSwapAmountOut, useReservedPercent: true
            });
        }

        if (_poolIsSet[context.projectId][terminalToken]) {
            bool projectTokenIs0 = address(projectToken) < terminalToken;
            uint256 amountToMintWith = totalPaid == amountToSwapWith ? 0 : totalPaid - amountToSwapWith;
            bool noop = tokenCountWithoutHook >= minimumSwapAmountOut;

            hookSpecifications = new JBPayHookSpecification[](1);
            hookSpecifications[0] = JBPayHookSpecification({
                hook: IJBPayHook(this),
                noop: noop,
                amount: noop ? 0 : amountToSwapWith,
                metadata: abi.encode(
                    projectTokenIs0,
                    amountToMintWith,
                    minimumSwapAmountOut,
                    hasUserSpecifiedQuote,
                    controller,
                    tokenCountWithoutHook,
                    weightRatio,
                    twapTick,
                    twapLiquidity,
                    poolId,
                    minimumBeneficiaryTokenCount,
                    minimumReservedTokenCount,
                    rawSwapQuote
                )
            });

            // All the minting will be done in `afterPayRecordedWith`. Return a weight of 0.
            if (!noop) return (0, hookSpecifications);
        } else if (hasUserSpecifiedQuote && tokenCountWithoutHook < minimumSwapAmountOut) {
            // User supplied an explicit pool quote with a non-zero minimum, but no pool is configured —
            // the direct mint alone cannot satisfy the requested minimum. Revert so the user does not
            // silently receive fewer tokens than they asked for.
            revert JBBuybackHook_SpecifiedSlippageExceeded({
                amount: tokenCountWithoutHook, minimum: minimumSwapAmountOut
            });
        }
    }

    /// @notice Always returns false — the buyback hook never claims mint permission directly. Minting is handled
    /// via the controller in `afterPayRecordedWith`/`afterCashOutRecordedWith` using permission from the registry.
    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure override returns (bool) {
        return false;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the PoolKey for a given project and terminal token pair.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address (normalized to address(0) for native).
    /// @return key The V4 PoolKey.
    function poolKeyOf(uint256 projectId, address terminalToken) public view override returns (PoolKey memory key) {
        return _poolKeyOf[projectId][terminalToken];
    }

    /// @notice Indicates which interfaces this contract implements (ERC-165).
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBPayHook).interfaceId
            || interfaceId == type(IJBCashOutHook).interfaceId || interfaceId == type(IJBBuybackHook).interfaceId
            || interfaceId == type(IJBPermissioned).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Shared internal logic for setting a pool. Both `setPoolFor` overloads delegate here after permission
    /// checks and token normalization.
    /// @param projectId The ID of the project.
    /// @param poolKey The V4 PoolKey identifying the pool.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param normalizedTerminalToken The terminal token address (already normalized: address(0) for native).
    /// @param projectToken The project's ERC-20 token address.
    function _setPoolFor(
        uint256 projectId,
        PoolKey memory poolKey,
        uint256 twapWindow,
        address normalizedTerminalToken,
        address projectToken
    )
        internal
    {
        // Make sure this pool hasn't already been set for this project/token pair.
        if (_poolIsSet[projectId][normalizedTerminalToken]) {
            revert JBBuybackHook_PoolAlreadySet({poolId: _poolKeyOf[projectId][normalizedTerminalToken].toId()});
        }

        // Make sure the provided TWAP window is within reasonable bounds.
        if (twapWindow < MIN_TWAP_WINDOW || twapWindow > MAX_TWAP_WINDOW) {
            revert JBBuybackHook_InvalidTwapWindow({value: twapWindow, min: MIN_TWAP_WINDOW, max: MAX_TWAP_WINDOW});
        }

        // Make sure the project has issued a token.
        if (projectToken == address(0)) revert JBBuybackHook_ZeroProjectToken(projectId);

        // Make sure the terminal token is not the project token.
        if (normalizedTerminalToken == projectToken) {
            revert JBBuybackHook_TerminalTokenIsProjectToken({
                terminalToken: normalizedTerminalToken, projectToken: projectToken
            });
        }

        // Validate the pool is initialized in the PoolManager.
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert JBBuybackHook_PoolNotInitialized(poolId);

        // Validate the PoolKey currencies match the project token and terminal token.
        address currency0 = Currency.unwrap(poolKey.currency0);
        address currency1 = Currency.unwrap(poolKey.currency1);
        bool validPair = (currency0 == projectToken && currency1 == normalizedTerminalToken)
            || (currency0 == normalizedTerminalToken && currency1 == projectToken);
        require(validPair, "JBBuybackHook: pool key currencies mismatch");

        // Store the pool key and mark it as set.
        _poolKeyOf[projectId][normalizedTerminalToken] = poolKey;
        _poolIsSet[projectId][normalizedTerminalToken] = true;

        // Read the current TWAP window before overwriting (for accurate event emission).
        uint256 oldWindow = twapWindowOf[projectId][normalizedTerminalToken];

        // Store the TWAP window and project token.
        twapWindowOf[projectId][normalizedTerminalToken] = twapWindow;
        projectTokenOf[projectId] = projectToken;

        emit TwapWindowChanged({
            projectId: projectId,
            terminalToken: normalizedTerminalToken,
            oldWindow: oldWindow,
            newWindow: twapWindow,
            caller: _msgSender()
        });
        emit PoolAdded({
            projectId: projectId, terminalToken: normalizedTerminalToken, poolId: poolId, caller: _msgSender()
        });
    }

    /// @notice Executes the buy-side swap: exchanges terminal tokens for project tokens through the V4 pool, then burns
    /// them so the controller can re-mint with the reserved rate applied.
    /// @param context The `afterPayRecordedContext` passed in by the terminal.
    /// @param projectTokenIs0 Whether the project token is currency0 in the pool.
    /// @param minimumSwapAmountOut The token count used to derive the swap's price limit via
    /// `JBSwapLib.sqrtPriceLimitFromAmounts`. When set to the issuance-rate equivalent (`tokenCountWithoutHook`),
    /// the swap fills only while the pool offers a better rate than minting.
    /// @param controller The controller used to mint and burn tokens.
    /// @return amountReceived The amount of project tokens received from the swap.
    /// @return swapFailed True if the swap reverted and was caught by try/catch (triggers mint fallback).
    function _swap(
        JBAfterPayRecordedContext calldata context,
        bool projectTokenIs0,
        uint256 minimumSwapAmountOut,
        IJBController controller
    )
        internal
        returns (uint256 amountReceived, bool swapFailed)
    {
        uint256 amountToSwapWith = context.forwardedAmount.value;

        // Get the terminal token, normalized to address(0) for native ETH.
        address normalizedTerminalToken =
            context.forwardedAmount.token == JBConstants.NATIVE_TOKEN ? address(0) : context.forwardedAmount.token;

        // Get the pool key for this project/token pair.
        PoolKey memory key = _poolKeyOf[context.projectId][normalizedTerminalToken];

        // Encode the callback data.
        bytes memory callbackData = abi.encode(
            SwapCallbackData({
                key: key,
                zeroForOne: !projectTokenIs0,
                amountIn: amountToSwapWith,
                minimumSwapAmountOut: minimumSwapAmountOut
            })
        );

        // Try the V4 unlock/callback swap. On failure, fall back to minting.
        try poolManager.unlock(callbackData) returns (bytes memory result) {
            (, amountReceived) = abi.decode(result, (uint256, uint256));
        } catch {
            return (0, true);
        }

        emit Swap({
            projectId: context.projectId,
            amountToSwapWith: amountToSwapWith,
            poolId: key.toId(),
            amountReceived: amountReceived,
            caller: msg.sender
        });

        // Burn the project tokens received from the swap (they'll be re-minted with reserves applied).
        if (amountReceived != 0) {
            controller.burnTokensOf({
                holder: address(this), projectId: context.projectId, tokenCount: amountReceived, memo: ""
            });
        }
    }

    /// @notice Swap an exact amount of the input token through the configured V4 pool.
    /// @dev Encodes the swap parameters into callback data, hands control to the PoolManager through `unlock(...)`,
    /// and decodes the amount received from the callback result. If the pool reverts, returns `swapFailed = true`
    /// instead of propagating the revert, allowing the caller to implement a fallback path.
    /// @param key The V4 pool key to swap against.
    /// @param amountIn The exact amount of input tokens to sell.
    /// @param minimumSwapAmountOut The minimum acceptable amount of output tokens.
    /// @param zeroForOne Whether the swap should move from `currency0` to `currency1`.
    /// @return amountSpent The amount of input tokens actually consumed by the swap.
    /// @return amountReceived The amount of output tokens received from the swap.
    /// @return swapFailed True if the swap reverted and was caught by try/catch.
    function _swapExactInput(
        PoolKey memory key,
        uint256 amountIn,
        uint256 minimumSwapAmountOut,
        bool zeroForOne
    )
        internal
        returns (uint256 amountSpent, uint256 amountReceived, bool swapFailed)
    {
        // Encode the swap parameters so `unlockCallback(...)` can execute the swap after the PoolManager unlocks.
        bytes memory callbackData = abi.encode(
            SwapCallbackData({
                key: key, zeroForOne: zeroForOne, amountIn: amountIn, minimumSwapAmountOut: minimumSwapAmountOut
            })
        );

        // Try the V4 unlock/callback swap. On failure, signal the caller to handle the fallback.
        try poolManager.unlock(callbackData) returns (bytes memory result) {
            (amountSpent, amountReceived) = abi.decode(result, (uint256, uint256));
        } catch {
            return (0, 0, true);
        }
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Normalize the terminal token, look up the project token, and construct the PoolKey.
    /// @param projectId The ID of the project.
    /// @param fee The Uniswap V4 pool fee tier.
    /// @param tickSpacing The Uniswap V4 pool tick spacing.
    /// @param terminalToken The terminal token address (may be NATIVE_TOKEN).
    /// @return poolKey The constructed PoolKey.
    /// @return normalizedTerminalToken The terminal token normalized to address(0) for native.
    /// @return projectToken The project's ERC-20 token address.
    function _buildPoolKey(
        uint256 projectId,
        uint24 fee,
        int24 tickSpacing,
        address terminalToken
    )
        internal
        view
        returns (PoolKey memory poolKey, address normalizedTerminalToken, address projectToken)
    {
        // Normalize the terminal token — use address(0) for native.
        normalizedTerminalToken = terminalToken == JBConstants.NATIVE_TOKEN ? address(0) : terminalToken;

        // Get the project's token.
        projectToken = address(TOKENS.tokenOf(projectId));

        // Sort currencies numerically (lower address = currency0).
        (Currency currency0, Currency currency1) = normalizedTerminalToken < projectToken
            ? (Currency.wrap(normalizedTerminalToken), Currency.wrap(projectToken))
            : (Currency.wrap(projectToken), Currency.wrap(normalizedTerminalToken));

        // Construct the pool key with the oracle hook.
        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: oracleHook
        });
    }

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice Queries the TWAP oracle for a price quote and applies sigmoid-based slippage to produce the minimum
    /// acceptable swap output. Returns 0 if the oracle is unavailable or liquidity is insufficient.
    /// @param projectId The ID of the project.
    /// @param amountIn The number of input tokens to swap.
    /// @param baseToken The token to swap in.
    /// @param quoteToken The token to swap out.
    /// @param terminalToken The terminal token address (already normalized: address(0) for native). Passed by the
    /// caller to avoid a redundant `projectTokenOf` SLOAD that would otherwise be needed to derive it.
    /// @return rawAmountOut The raw oracle quote before slippage adjustment.
    /// @return amountOut The minimum number of tokens to receive after slippage adjustment.
    /// @return twapTick The arithmetic mean tick from the TWAP oracle.
    /// @return twapLiquidity The harmonic mean liquidity from the TWAP oracle.
    /// @return poolId The V4 pool identifier used for the quote.
    function _getQuote(
        uint256 projectId,
        uint256 amountIn,
        address baseToken,
        address quoteToken,
        address terminalToken
    )
        internal
        view
        returns (uint256 rawAmountOut, uint256 amountOut, int24 twapTick, uint128 twapLiquidity, PoolId poolId)
    {
        // Check pool existence before loading the full PoolKey struct (~500 gas saved on early exit).
        if (!_poolIsSet[projectId][terminalToken]) return (0, 0, 0, 0, PoolId.wrap(0));

        // Get the pool key for this project/terminal token pair.
        PoolKey memory key = _poolKeyOf[projectId][terminalToken];

        // Get the TWAP window for this project/terminal token pair.
        uint256 twapWindow = twapWindowOf[projectId][terminalToken];

        // Keep a reference to the pool ID.
        poolId = key.toId();

        // Query the oracle hook (or spot if twapWindow is 0).
        (amountOut, twapTick, twapLiquidity) = JBSwapLib.getQuoteFromOracle({
            poolManager: poolManager,
            key: key,
            // Safe: twapWindow is validated <= MAX_TWAP_WINDOW (2 days = 172800), fits in uint32.
            // forge-lint: disable-next-line(unsafe-typecast)
            twapWindow: uint32(twapWindow),
            // Safe: amountIn is a token payment amount, bounded by realistic token supplies well within uint128.
            // forge-lint: disable-next-line(unsafe-typecast)
            amountIn: uint128(amountIn),
            baseToken: baseToken,
            quoteToken: quoteToken
        });

        // If oracle returned 0, no quote available — trigger mint fallback.
        if (amountOut == 0) return (0, 0, twapTick, twapLiquidity, poolId);

        // If there's no liquidity data, return 0 to trigger mint.
        if (twapLiquidity == 0) return (0, 0, twapTick, twapLiquidity, poolId);

        // Calculate price impact.
        bool zeroForOne = baseToken < quoteToken;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(twapTick);
        uint256 impact = JBSwapLib.calculateImpact({
            amountIn: amountIn, liquidity: twapLiquidity, sqrtP: sqrtP, zeroForOne: zeroForOne
        });

        // Get the actual LP fee from slot0 (key.fee may differ for dynamic-fee pools).
        // V4 fees are in hundredths of a bip, so divide by 100 to get basis points.
        (,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        uint256 poolFeeBps = uint256(lpFee) / 100;

        // Calculate continuous sigmoid slippage tolerance.
        uint256 slippageTolerance = JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps});

        // If the slippage tolerance is the maximum, return 0 to trigger mint.
        if (slippageTolerance >= TWAP_SLIPPAGE_DENOMINATOR) return (0, 0, twapTick, twapLiquidity, poolId);

        // Save the raw oracle quote before slippage adjustment.
        rawAmountOut = amountOut;

        // Apply slippage to the oracle quote.
        amountOut -= (amountOut * slippageTolerance) / TWAP_SLIPPAGE_DENOMINATOR;
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice The exact net the terminal will settle to the beneficiary after applying its fee policy.
    /// @dev Mirrors `JBMultiTerminal._cashOutTokensOf` fee math: feeless beneficiaries pay nothing; non-zero
    /// tax rate charges the full standard fee on the gross; zero tax rate charges only up to
    /// `feeFreeSurplusOf` (the per-(project, token) round-trip exposure counter the terminal exposes
    /// publicly). The hook reads the counter via the terminal address already present in the context.
    /// @param amount The gross reclaim amount before any terminal fee.
    /// @param context The before-cashout context the data hook is processing.
    /// @return The net the beneficiary will receive (gross minus any applicable terminal fee).
    function _netAfterTerminalFee(
        uint256 amount,
        JBBeforeCashOutRecordedContext calldata context
    )
        internal
        view
        returns (uint256)
    {
        if (context.beneficiaryIsFeeless) return amount;

        uint256 feeBase;
        if (context.cashOutTaxRate != 0) {
            // Non-zero tax: terminal charges the full standard fee on the gross.
            feeBase = amount;
        } else {
            // Zero tax: terminal charges only up to its fee-free surplus for this (project, token).
            uint256 feeFreeSurplus = IJBMultiTerminal(context.terminal)
                .feeFreeSurplusOf({projectId: context.projectId, token: context.surplus.token});
            feeBase = amount < feeFreeSurplus ? amount : feeFreeSurplus;
        }

        return amount - JBFees.standardFeeAmountFrom(feeBase);
    }

    /// @notice Returns this contract's balance of the given terminal token.
    /// @param token The terminal token address (NATIVE_TOKEN for ETH).
    /// @return balance The current balance held by this contract.
    function _terminalTokenBalance(address token) internal view returns (uint256 balance) {
        return token == JBConstants.NATIVE_TOKEN ? address(this).balance : IERC20(token).balanceOf(address(this));
    }
}
