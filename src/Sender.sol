// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CCIPTokenSender
/// @author CrossChainTokenTransfer
/// @notice Sends ERC-20 tokens cross-chain via Chainlink CCIP, paying fees in native currency.
/// @dev Deployed on the **source** chain (e.g. Ethereum Sepolia).
contract CCIPTokenSender is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    /// @notice Thrown when a destination chain selector is not allowlisted.
    error DestinationChainNotAllowed(uint64 destinationChainSelector);

    /// @notice Thrown when the destination chain is not supported by the CCIP Router.
    error DestinationChainNotSupported(uint64 destinationChainSelector);

    /// @notice Thrown when no tokens are specified for transfer.
    error NoTokensToTransfer();

    /// @notice Thrown when msg.value is less than the buffered CCIP fee.
    error InsufficientNativeFee(uint256 required, uint256 provided);

    /// @notice Thrown when a zero address is provided where a non-zero address is expected.
    error InvalidAddress();

    /// @notice Thrown when a native transfer fails.
    error NativeTransferFailed();

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a cross-chain token transfer message is dispatched.
    /// @param messageId The unique CCIP message identifier.
    /// @param destinationChainSelector The CCIP chain selector of the destination chain.
    /// @param receiver The recipient address on the destination chain.
    /// @param token The ERC-20 token address on the source chain.
    /// @param amount The amount of tokens sent.
    /// @param fees The CCIP fee paid in native currency.
    event TokensSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed receiver,
        address token,
        uint256 amount,
        uint256 fees
    );

    /// @notice Emitted when a destination chain selector is added to or removed from the allowlist.
    /// @param chainSelector The CCIP chain selector that was updated.
    /// @param allowed Whether the chain is now allowed (`true`) or disallowed (`false`).
    event DestinationChainAllowlistUpdated(
        uint64 indexed chainSelector,
        bool allowed
    );

    /// @notice Emitted when ERC-20 tokens are withdrawn from the contract.
    /// @param token The token address.
    /// @param to The recipient address.
    /// @param amount The amount withdrawn.
    event TokensWithdrawn(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    /// @notice Emitted when native currency is withdrawn from the contract.
    /// @param to The recipient address.
    /// @param amount The amount withdrawn.
    event NativeWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when the fee buffer is updated.
    /// @param oldBufferBps The previous buffer in basis points.
    /// @param newBufferBps The new buffer in basis points.
    event FeeBufferUpdated(uint16 oldBufferBps, uint16 newBufferBps);

    /// @notice Emitted when excess native fee is refunded to the caller.
    /// @param user The address that received the refund.
    /// @param amount The amount refunded.
    event ExcessFeeRefunded(address indexed user, uint256 amount);

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    /// @notice The Chainlink CCIP Router contract on this chain.
    IRouterClient public immutable i_router;

    /// @notice Mapping of allowed destination chain selectors.
    /// @dev Only chains set to `true` can be targeted by `sendTokens`.
    mapping(uint64 chainSelector => bool allowed)
        public allowlistedDestinationChains;

    /// @notice Fee buffer in basis points (e.g. 1000 = 10%).
    /// @dev Applied on top of the CCIP fee to account for fee fluctuations between
    ///      off-chain estimation and on-chain execution. Excess is refunded to the caller.
    uint16 public feeBufferBps = 1000;

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    /// @notice Deploys the sender contract.
    /// @param router The address of the CCIP Router on the source chain.
    /// @param initialOwner The address that will own this contract.
    constructor(address router, address initialOwner) Ownable(initialOwner) {
        if (router == address(0)) revert InvalidAddress();
        i_router = IRouterClient(router);
    }

    // ──────────────────────────────────────────────
    //  Admin — Allowlist Management
    // ──────────────────────────────────────────────

    /// @notice Adds or removes a destination chain selector from the allowlist.
    /// @param chainSelector The CCIP chain selector to update.
    /// @param allowed `true` to allow, `false` to disallow.
    function setDestinationChainAllowlist(
        uint64 chainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedDestinationChains[chainSelector] = allowed;
        emit DestinationChainAllowlistUpdated(chainSelector, allowed);
    }

    /// @notice Updates the fee buffer percentage.
    /// @param newBufferBps The new buffer in basis points (e.g. 500 = 5%, 1000 = 10%).
    function setFeeBufferBps(uint16 newBufferBps) external onlyOwner {
        uint16 oldBufferBps = feeBufferBps;
        feeBufferBps = newBufferBps;
        emit FeeBufferUpdated(oldBufferBps, newBufferBps);
    }

    // ──────────────────────────────────────────────
    //  Core — Send Tokens
    // ──────────────────────────────────────────────

    /// @notice Sends ERC-20 tokens to a receiver on a destination chain via CCIP.
    /// @dev Fees are paid in native currency (ETH / AVAX). The caller must:
    ///   1. Approve this contract to spend at least `amount` of `token`.
    ///   2. Send enough native currency to cover the CCIP fee.
    /// @param destinationChainSelector The CCIP chain selector of the destination chain.
    /// @param receiver The address of the receiving contract / EOA on the destination chain.
    /// @param token The ERC-20 token address on the source chain.
    /// @param amount The amount of tokens to transfer.
    /// @param gasLimit The gas limit for execution on the destination chain (use 0 for default 200k).
    /// @return messageId The unique CCIP message identifier.
    function sendTokens(
        uint64 destinationChainSelector,
        address receiver,
        address token,
        uint256 amount,
        uint256 gasLimit
    ) external payable nonReentrant returns (bytes32 messageId) {
        // ── Checks ──────────────────────────────────
        if (!allowlistedDestinationChains[destinationChainSelector]) {
            revert DestinationChainNotAllowed(destinationChainSelector);
        }
        if (!i_router.isChainSupported(destinationChainSelector)) {
            revert DestinationChainNotSupported(destinationChainSelector);
        }
        if (amount == 0) revert NoTokensToTransfer();
        if (receiver == address(0)) revert InvalidAddress();

        // ── Build the CCIP message ──────────────────
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: "", // no additional data payload
            tokenAmounts: tokenAmounts,
            feeToken: address(0), // pay fees in native
            extraArgs: gasLimit > 0
                ? Client._argsToBytes(
                    Client.EVMExtraArgsV2({
                        gasLimit: gasLimit,
                        allowOutOfOrderExecution: true
                    })
                )
                : Client._argsToBytes(
                    Client.EVMExtraArgsV2({
                        gasLimit: 200_000,
                        allowOutOfOrderExecution: true
                    })
                )
        });

        // ── Get the fee (with buffer) ────────────────
        uint256 fee = i_router.getFee(destinationChainSelector, message);
        uint256 bufferedFee = fee + (fee * feeBufferBps) / 10_000;
        if (msg.value < bufferedFee) {
            revert InsufficientNativeFee(bufferedFee, msg.value);
        }

        // ── Interactions ────────────────────────────
        // Pull tokens from caller into this contract, then approve the router.
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).safeIncreaseAllowance(address(i_router), amount);

        // Dispatch the CCIP message (send exact fee, not the buffered amount).
        messageId = i_router.ccipSend{value: fee}(
            destinationChainSelector,
            message
        );

        emit TokensSent(
            messageId,
            destinationChainSelector,
            receiver,
            token,
            amount,
            fee
        );

        // ── Refund excess fee to caller ─────────────
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool refundSuccess, ) = msg.sender.call{value: excess}("");
            if (!refundSuccess) revert NativeTransferFailed();
            emit ExcessFeeRefunded(msg.sender, excess);
        }
    }

    // ──────────────────────────────────────────────
    //  Admin — Token & Native Recovery
    // ──────────────────────────────────────────────

    /// @notice Withdraws ERC-20 tokens stuck in this contract.
    /// @param token The ERC-20 token address.
    /// @param to The recipient address.
    function withdrawToken(
        address token,
        address to
    ) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);
        emit TokensWithdrawn(token, to, balance);
    }

    /// @notice Withdraws native currency stuck in this contract.
    /// @param to The recipient address.
    function withdrawNative(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        uint256 balance = address(this).balance;
        (bool success, ) = to.call{value: balance}("");
        if (!success) revert NativeTransferFailed();
        emit NativeWithdrawn(to, balance);
    }

    // ──────────────────────────────────────────────
    //  Receive
    // ──────────────────────────────────────────────

    /// @notice Allows the contract to receive native currency (e.g. fee refunds).
    receive() external payable {}
}
