// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IJBBuybackHook} from "./interfaces/IJBBuybackHook.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";
import {JBSwapLib} from "./libraries/JBSwapLib.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/// @notice The buyback hook allows beneficiaries of a payment to a project to either:
/// - Get tokens by paying the project through its terminal OR
/// - Buy tokens from the configured Uniswap V4 pool.
/// Depending on which route would yield more tokens for the beneficiary. The project's reserved rate applies to either
/// route.
/// @dev Compatible with any `JBTerminal` and any project token that can be pooled on Uniswap V4.
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

    error JBBuybackHook_CallerNotPoolManager(address caller);
    error JBBuybackHook_InsufficientPayAmount(uint256 swapAmount, uint256 totalPaid);
    error JBBuybackHook_InvalidTwapWindow(uint256 value, uint256 min, uint256 max);
    error JBBuybackHook_PoolAlreadySet(PoolId poolId);
    error JBBuybackHook_PoolNotInitialized(PoolId poolId);
    error JBBuybackHook_SpecifiedSlippageExceeded(uint256 amount, uint256 minimum);
    error JBBuybackHook_TerminalTokenIsProjectToken(address terminalToken, address projectToken);
    error JBBuybackHook_Unauthorized(address caller);
    error JBBuybackHook_ZeroProjectToken();
    error JBBuybackHook_ZeroTerminalToken();

    //*********************************************************************//
    // --------------------- public constant properties ------------------ //
    //*********************************************************************//

    /// @notice Projects cannot specify a TWAP window longer than this constant.
    uint256 public constant override MAX_TWAP_WINDOW = 2 days;

    /// @notice Projects cannot specify a TWAP window shorter than this constant.
    uint256 public constant override MIN_TWAP_WINDOW = 5 minutes;

    /// @notice The denominator used when calculating TWAP slippage percent values.
    uint256 public constant override TWAP_SLIPPAGE_DENOMINATOR = 10_000;

    //*********************************************************************//
    // -------------------- public immutable properties ------------------ //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The contract that exposes price feeds.
    IJBPrices public immutable override PRICES;

    /// @notice The project registry.
    IJBProjects public immutable override PROJECTS;

    /// @notice The token registry.
    IJBTokens public immutable override TOKENS;

    /// @notice The Uniswap V4 PoolManager singleton.
    IPoolManager public immutable override POOL_MANAGER;

    /// @notice The wETH contract.
    IWETH9 public immutable override WETH;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The PoolKey for a given project's token and terminal token pair.
    /// @custom:param projectId The ID of the project whose token is traded in the pool.
    /// @custom:param terminalToken The address of the terminal token (normalized to WETH for native).
    mapping(uint256 projectId => mapping(address terminalToken => PoolKey)) internal _poolKeyOf;

    /// @notice The address of each project's token.
    /// @custom:param projectId The ID of the project the token belongs to.
    mapping(uint256 projectId => address) public override projectTokenOf;

    /// @notice The TWAP window for the given project.
    /// @custom:param projectId The ID of the project to get the twap window for.
    mapping(uint256 projectId => uint256) public override twapWindowOf;

    //*********************************************************************//
    // --------------------- private stored properties ------------------- //
    //*********************************************************************//

    /// @notice Tracks whether a pool has been set for a project/terminal token pair.
    mapping(uint256 projectId => mapping(address terminalToken => bool)) private _poolIsSet;

    //*********************************************************************//
    // ----------------------------- structs ----------------------------- //
    //*********************************************************************//

    /// @notice Data passed through to the unlock callback.
    struct SwapCallbackData {
        PoolKey key;
        bool projectTokenIs0;
        uint256 amountIn;
        uint256 minimumSwapAmountOut;
        address terminalToken;
    }

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory The directory of terminals and controllers.
    /// @param permissions The permissions contract.
    /// @param prices The contract that exposes price feeds.
    /// @param projects The project registry.
    /// @param tokens The token registry.
    /// @param weth The WETH contract.
    /// @param poolManager The Uniswap V4 PoolManager singleton.
    /// @param trustedForwarder A trusted forwarder of transactions to this contract.
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBPrices prices,
        IJBProjects projects,
        IJBTokens tokens,
        IWETH9 weth,
        IPoolManager poolManager,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
    {
        DIRECTORY = directory;
        TOKENS = tokens;
        PROJECTS = projects;
        PRICES = prices;
        POOL_MANAGER = poolManager;
        WETH = weth;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice To fulfill the `IJBRulesetDataHook` interface.
    /// @dev Pass cash out context back to the terminal without changes.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory hookSpecifications)
    {
        return (context.cashOutTaxRate, context.cashOutCount, context.totalSupply, hookSpecifications);
    }

    /// @notice The `IJBRulesetDataHook` implementation which determines whether tokens should be minted from the
    /// project or bought from the pool.
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

        // Keep a reference to the amount to be used to swap (out of `totalPaid`).
        uint256 amountToSwapWith;

        // Scoped section to prevent stack too deep.
        {
            // Unpack the quote specified by the payer/client (typically from the pool).
            bytes4 metadataId = JBMetadataResolver.getId("quote");
            (bool quoteExists, bytes memory metadata) = JBMetadataResolver.getDataFor(metadataId, context.metadata);
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
        uint256 tokenCountWithoutHook = mulDiv(amountToSwapWith, weight, weightRatio);

        // Keep a reference to the project's token.
        address projectToken = projectTokenOf[context.projectId];

        // Keep a reference to the token being used by the terminal. Default to wETH if the terminal uses native.
        address terminalToken = context.amount.token == JBConstants.NATIVE_TOKEN ? address(WETH) : context.amount.token;

        // Always compute the TWAP-based minimum.
        uint256 twapMinimum = _getQuote({
            projectId: context.projectId,
            projectToken: projectToken,
            amountIn: amountToSwapWith,
            terminalToken: terminalToken
        });

        // Use the higher of the payer's quote and the TWAP quote.
        // This prevents a stale/malicious payer quote from getting a worse deal than the oracle suggests.
        if (twapMinimum > minimumSwapAmountOut) minimumSwapAmountOut = twapMinimum;

        // If the minimum amount from the swap exceeds what minting directly would yield, swap.
        if (tokenCountWithoutHook < minimumSwapAmountOut) {
            bool projectTokenIs0 = address(projectToken) < terminalToken;

            // Specify this hook as the one to use.
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

            // All the minting will be done in `afterPayRecordedWith`. Return a weight of 0.
            return (0, hookSpecifications);
        }
    }

    /// @notice Required by the `IJBRulesetDataHook` interfaces. Return false to not leak any permissions.
    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure override returns (bool) {
        return false;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the PoolKey for a given project and terminal token pair.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address (normalized to WETH for native).
    /// @return key The V4 PoolKey.
    function poolKeyOf(uint256 projectId, address terminalToken) public view override returns (PoolKey memory key) {
        return _poolKeyOf[projectId][terminalToken];
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBPayHook).interfaceId
            || interfaceId == type(IJBBuybackHook).interfaceId || interfaceId == type(IJBPermissioned).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Swap the specified amount of terminal tokens for project tokens, using any leftover terminal tokens to
    /// mint from the project.
    /// @dev If the swap reverts (due to slippage, insufficient liquidity, or something else),
    /// then the hook mints the number of tokens which a payment to the project would have minted.
    /// @param context The pay context passed in by the terminal.
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
        // Make sure only the project's payment terminals can access this function.
        if (!DIRECTORY.isTerminalOf(context.projectId, IJBTerminal(msg.sender))) {
            revert JBBuybackHook_Unauthorized(msg.sender);
        }

        // Parse the metadata forwarded from the data hook.
        (bool projectTokenIs0, uint256 amountToMintWith, uint256 minimumSwapAmountOut, IJBController controller) =
            abi.decode(context.hookMetadata, (bool, uint256, uint256, IJBController));

        // Record the terminal token balance BEFORE pulling payment tokens so we can compute leftover as a delta.
        // For native ETH, `msg.value` is already included in `address(this).balance` at this point,
        // so we subtract it. For ERC-20, we capture BEFORE safeTransferFrom.
        // This prevents both pre-existing balances AND the payment itself from inflating leftovers.
        uint256 balanceBefore = _terminalTokenBalance(context.forwardedAmount.token);
        if (context.forwardedAmount.token == JBConstants.NATIVE_TOKEN) {
            balanceBefore -= msg.value;
        }

        // If the token paid in isn't the native token, pull the amount to swap from the terminal.
        if (context.forwardedAmount.token != JBConstants.NATIVE_TOKEN) {
            IERC20(context.forwardedAmount.token)
                .safeTransferFrom(msg.sender, address(this), context.forwardedAmount.value);
        }

        // Get a reference to the number of project tokens that was swapped for.
        // `swapFailed` is true when the try/catch in _swap caught a revert (pool unavailable, etc.).
        // slither-disable-next-line reentrancy-events
        (uint256 exactSwapAmountOut, bool swapFailed) = _swap({
            context: context,
            projectTokenIs0: projectTokenIs0,
            minimumSwapAmountOut: minimumSwapAmountOut,
            controller: controller
        });

        // Ensure swap satisfies payer/client minimum amount or calculated TWAP.
        // Skip this check when the swap failed (caught revert) — in that case, fall through to the mint path.
        if (!swapFailed && exactSwapAmountOut < minimumSwapAmountOut) {
            revert JBBuybackHook_SpecifiedSlippageExceeded(exactSwapAmountOut, minimumSwapAmountOut);
        }

        // If native ETH was wrapped to WETH for the swap (pool uses WETH), unwrap any leftover WETH
        // back to ETH so the balance delta below correctly captures leftovers.
        if (context.forwardedAmount.token == JBConstants.NATIVE_TOKEN) {
            uint256 wethBalance = IERC20(address(WETH)).balanceOf(address(this));
            if (wethBalance != 0) WETH.withdraw(wethBalance);
        }

        // Compute leftover terminal tokens as a delta (balanceAfter - balanceBefore).
        uint256 leftoverAmountInThisContract = _terminalTokenBalance(context.forwardedAmount.token) - balanceBefore;

        // Get a reference to the ruleset.
        // slither-disable-next-line unused-return
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(context.projectId);

        // Determine the weight ratio for currency conversion.
        uint256 weightRatio = context.amount.currency == ruleset.baseCurrency()
            ? 10 ** context.amount.decimals
            : PRICES.pricePerUnitOf({
                projectId: context.projectId,
                pricingCurrency: context.amount.currency,
                unitCurrency: ruleset.baseCurrency(),
                decimals: context.amount.decimals
            });

        // Mint a corresponding number of project tokens using any terminal tokens left over.
        uint256 partialMintTokenCount;
        if (leftoverAmountInThisContract != 0) {
            partialMintTokenCount = mulDiv(leftoverAmountInThisContract, context.weight, weightRatio);

            // If the token paid in wasn't the native token, grant the terminal permission to pull them back.
            if (context.forwardedAmount.token != JBConstants.NATIVE_TOKEN) {
                // slither-disable-next-line unused-return
                IERC20(context.forwardedAmount.token).forceApprove(msg.sender, leftoverAmountInThisContract);
            }

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
        // slither-disable-next-line unused-return
        controller.mintTokensOf({
            projectId: context.projectId,
            tokenCount: exactSwapAmountOut + partialMintTokenCount,
            beneficiary: address(context.beneficiary),
            memo: "",
            useReservedPercent: true
        });
    }

    /// @notice Set the V4 pool to use for a given project and terminal token pair.
    /// @dev Pool keys are intentionally immutable once set. This prevents manipulation of swap routing
    /// after a project's buyback hook is configured.
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
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        // Normalize the terminal token — use WETH for native.
        address normalizedTerminalToken = terminalToken == JBConstants.NATIVE_TOKEN ? address(WETH) : terminalToken;

        // Make sure this pool hasn't already been set for this project/token pair.
        if (_poolIsSet[projectId][normalizedTerminalToken]) {
            revert JBBuybackHook_PoolAlreadySet(_poolKeyOf[projectId][normalizedTerminalToken].toId());
        }

        // Make sure the provided TWAP window is within reasonable bounds.
        if (twapWindow < MIN_TWAP_WINDOW || twapWindow > MAX_TWAP_WINDOW) {
            revert JBBuybackHook_InvalidTwapWindow(twapWindow, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);
        }

        // Make sure the terminal token is not zero.
        if (normalizedTerminalToken == address(0)) revert JBBuybackHook_ZeroTerminalToken();

        // Get the project's token.
        address projectToken = address(TOKENS.tokenOf(projectId));

        // Make sure the project has issued a token.
        if (projectToken == address(0)) revert JBBuybackHook_ZeroProjectToken();

        // Make sure the terminal token is not the project token.
        if (normalizedTerminalToken == projectToken) {
            revert JBBuybackHook_TerminalTokenIsProjectToken(normalizedTerminalToken, projectToken);
        }

        // Validate the pool is initialized in the PoolManager.
        PoolId poolId = poolKey.toId();
        // slither-disable-next-line unused-return
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
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
        uint256 oldWindow = twapWindowOf[projectId];

        // Store the TWAP window and project token.
        twapWindowOf[projectId] = twapWindow;
        projectTokenOf[projectId] = projectToken;

        emit TwapWindowChanged({
            projectId: projectId, oldWindow: oldWindow, newWindow: twapWindow, caller: _msgSender()
        });
        emit PoolAdded({
            projectId: projectId, terminalToken: normalizedTerminalToken, poolId: poolId, caller: _msgSender()
        });
    }

    /// @notice Change the TWAP window for a project.
    /// @param projectId The ID of the project to set the TWAP window of.
    /// @param newWindow The new TWAP window.
    function setTwapWindowOf(uint256 projectId, uint256 newWindow) external override {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_TWAP
        });

        // Make sure the specified window is within reasonable bounds.
        if (newWindow < MIN_TWAP_WINDOW || newWindow > MAX_TWAP_WINDOW) {
            revert JBBuybackHook_InvalidTwapWindow(newWindow, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);
        }

        uint256 oldWindow = twapWindowOf[projectId];
        twapWindowOf[projectId] = newWindow;

        emit TwapWindowChanged({projectId: projectId, oldWindow: oldWindow, newWindow: newWindow, caller: _msgSender()});
    }

    /// @notice The V4 PoolManager unlock callback. Executes the swap and settles/takes tokens.
    /// @dev ONLY callable by the PoolManager singleton.
    /// @param data ABI-encoded SwapCallbackData.
    /// @return result ABI-encoded amount of project tokens received.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        // Only the PoolManager can call this.
        if (msg.sender != address(POOL_MANAGER)) revert JBBuybackHook_CallerNotPoolManager(msg.sender);

        SwapCallbackData memory params = abi.decode(data, (SwapCallbackData));

        // Compute a price limit that stops the swap if the rate is worse than the minimum acceptable output.
        bool zeroForOne = !params.projectTokenIs0;
        uint160 sqrtPriceLimit = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: params.amountIn, minimumAmountOut: params.minimumSwapAmountOut, zeroForOne: zeroForOne
        });

        // Execute the swap: we're buying project tokens (the output) with terminal tokens (the input).
        // zeroForOne = !projectTokenIs0 (we swap terminal→project, terminal is the "other" token).
        BalanceDelta delta = POOL_MANAGER.swap({
            key: params.key,
            params: SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(params.amountIn), // Negative = exact input
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            hookData: ""
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

        if (params.projectTokenIs0) {
            // project token is currency0, terminal token is currency1
            // zeroForOne = false: swap currency1 (terminal) → currency0 (project)
            inputCurrency = params.key.currency1; // terminal token (we pay)
            outputCurrency = params.key.currency0; // project token (we receive)
            inputAmount = uint256(uint128(-delta1)); // negative = we spent, negate to get positive
            outputAmount = uint256(uint128(delta0)); // positive = we received
        } else {
            // project token is currency1, terminal token is currency0
            // zeroForOne = true: swap currency0 (terminal) → currency1 (project)
            inputCurrency = params.key.currency0;
            outputCurrency = params.key.currency1;
            inputAmount = uint256(uint128(-delta0)); // negative = we spent, negate to get positive
            outputAmount = uint256(uint128(delta1)); // positive = we received
        }

        // Settle the input (we owe the PoolManager).
        if (inputCurrency.isAddressZero()) {
            // Native ETH: settle with value.
            // slither-disable-next-line unused-return
            POOL_MANAGER.settle{value: inputAmount}();
        } else {
            // ERC-20: sync → transfer → settle.
            POOL_MANAGER.sync(inputCurrency);
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer(address(POOL_MANAGER), inputAmount);
            // slither-disable-next-line unused-return
            POOL_MANAGER.settle();
        }

        // Take the output (PoolManager owes us).
        POOL_MANAGER.take(outputCurrency, address(this), outputAmount);

        return abi.encode(outputAmount);
    }

    /// @notice Receive native ETH. Required for V4 native ETH take() and WETH unwrap.
    receive() external payable {}

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice Get a quote based on the oracle hook TWAP or spot price.
    /// @param projectId The ID of the project.
    /// @param projectToken The project token being swapped for.
    /// @param amountIn The number of terminal tokens being used to swap.
    /// @param terminalToken The terminal token being paid in (normalized to WETH for native).
    /// @return amountOut The minimum number of tokens to receive based on the TWAP and slippage.
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
        // Get the pool key for this project/terminal token pair.
        PoolKey memory key = _poolKeyOf[projectId][terminalToken];

        // Make sure a pool has been configured.
        if (!_poolIsSet[projectId][terminalToken]) return 0;

        // Get the TWAP window.
        uint256 twapWindow = twapWindowOf[projectId];

        // Query the oracle hook (or spot if twapWindow is 0).
        int24 arithmeticMeanTick;
        uint128 meanLiquidity;
        (amountOut, arithmeticMeanTick, meanLiquidity) = JBSwapLib.getQuoteFromOracle({
            poolManager: POOL_MANAGER,
            key: key,
            twapWindow: uint32(twapWindow),
            amountIn: uint128(amountIn),
            baseToken: terminalToken,
            quoteToken: projectToken
        });

        // If oracle returned 0, no quote available — trigger mint fallback.
        if (amountOut == 0) return 0;

        // If there's no liquidity data, return 0 to trigger mint.
        if (meanLiquidity == 0) return 0;

        // Calculate price impact.
        bool zeroForOne = terminalToken < projectToken;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(arithmeticMeanTick);
        uint256 impact = JBSwapLib.calculateImpact(amountIn, meanLiquidity, sqrtP, zeroForOne);

        // Get the pool fee in bps (V4 fees are in hundredths of a bip, so divide by 100).
        uint256 poolFeeBps = uint256(key.fee) / 100;

        // Calculate continuous sigmoid slippage tolerance.
        uint256 slippageTolerance = JBSwapLib.getSlippageTolerance(impact, poolFeeBps);

        // If the slippage tolerance is the maximum, return 0 to trigger mint.
        if (slippageTolerance >= TWAP_SLIPPAGE_DENOMINATOR) return 0;

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

    /// @notice Returns this contract's balance of the given terminal token.
    /// @param token The terminal token address (NATIVE_TOKEN for ETH).
    /// @return balance The current balance held by this contract.
    function _terminalTokenBalance(address token) internal view returns (uint256 balance) {
        return token == JBConstants.NATIVE_TOKEN ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    //*********************************************************************//
    // ---------------------- internal functions ------------------------- //
    //*********************************************************************//

    /// @notice Swap the terminal token to receive project tokens via V4.
    /// @param context The `afterPayRecordedContext` passed in by the terminal.
    /// @param projectTokenIs0 Whether the project token is currency0 in the pool.
    /// @param minimumSwapAmountOut The minimum acceptable output, used for sqrtPriceLimit computation.
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

        // Get the terminal token, normalized to WETH.
        address terminalTokenWithWETH =
            context.forwardedAmount.token == JBConstants.NATIVE_TOKEN ? address(WETH) : context.forwardedAmount.token;

        // Get the pool key for this project/token pair.
        PoolKey memory key = _poolKeyOf[context.projectId][terminalTokenWithWETH];

        // Wrap native tokens to WETH if needed (for ERC-20 settle path).
        // For native ETH pools (currency0 or currency1 is address(0)), we use settle{value:} instead.
        bool inputIsNative = context.forwardedAmount.token == JBConstants.NATIVE_TOKEN;
        Currency inputCurrency = projectTokenIs0 ? key.currency1 : key.currency0;

        if (inputIsNative && !inputCurrency.isAddressZero()) {
            // Pool uses WETH, but we received ETH — wrap it.
            WETH.deposit{value: amountToSwapWith}();
        }

        // Encode the callback data.
        bytes memory callbackData = abi.encode(
            SwapCallbackData({
                key: key,
                projectTokenIs0: projectTokenIs0,
                amountIn: amountToSwapWith,
                minimumSwapAmountOut: minimumSwapAmountOut,
                terminalToken: context.forwardedAmount.token
            })
        );

        // Try the V4 unlock/callback swap. On failure, fall back to minting.
        // slither-disable-next-line reentrancy-events
        try POOL_MANAGER.unlock(callbackData) returns (bytes memory result) {
            amountReceived = abi.decode(result, (uint256));
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
}
