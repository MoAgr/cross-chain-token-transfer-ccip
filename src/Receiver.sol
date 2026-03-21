// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    CCIPReceiver
} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {
    Client
} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CCIPTokenReceiver
/// @author CrossChainTokenTransfer
/// @notice Receives ERC-20 tokens cross-chain via Chainlink CCIP with defensive error handling.
/// @dev Deployed on the **destination** chain (e.g. Avalanche Fuji).
///
/// Security features:
///   - Source chain allowlist
///   - Sender address allowlist (per source chain)
///   - Replay protection via processed messageId tracking
///   - Reentrancy guard on all state-changing functions
///   - Defensive try/catch in `ccipReceive` — failures are stored for manual retry
contract CCIPTokenReceiver is CCIPReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    /// @notice Thrown when a message arrives from an unlisted source chain.
    error SourceChainNotAllowed(uint64 sourceChainSelector);

    /// @notice Thrown when the sender address on the source chain is not allowlisted.
    error SenderNotAllowed(uint64 sourceChainSelector, address sender);

    /// @notice Thrown when a message with the same `messageId` has already been processed.
    error MessageAlreadyProcessed(bytes32 messageId);

    /// @notice Thrown when a message carries more token entries than supported.
    error TooManyTokens(uint256 provided, uint256 maximum);

    /// @notice Thrown when attempting to retry a message that has not failed.
    error MessageNotFailed(bytes32 messageId);

    /// @notice Thrown when attempting to retry a failed message that was marked non-retryable.
    error MessageNotRetryable(bytes32 messageId);

    /// @notice Thrown when a zero address is provided where a non-zero address is expected.
    error InvalidAddress();

    /// @notice Thrown when the retry of a failed message reverts again.
    error RetryFailed(bytes32 messageId);

    // ──────────────────────────────────────────────
    //  Enums
    // ──────────────────────────────────────────────

    /// @notice Processing status of a received CCIP message.
    enum MessageStatus {
        NotReceived, // 0 — never seen
        Succeeded, // 1 — processed successfully
        Failed // 2 — processing reverted; stored for retry
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a cross-chain message is received and processed successfully.
    /// @param messageId The unique CCIP message identifier.
    /// @param sourceChainSelector The CCIP chain selector of the source chain.
    /// @param sender The sender address on the source chain.
    /// @param tokensReceived The tokens and amounts received.
    event MessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed sender,
        Client.EVMTokenAmount[] tokensReceived
    );

    /// @notice Emitted when processing a received message fails (defensive catch).
    /// @param messageId The unique CCIP message identifier.
    /// @param reason The low-level revert reason.
    event MessageFailed(bytes32 indexed messageId, bytes reason);

    /// @notice Emitted when a previously failed message is successfully retried.
    /// @param messageId The unique CCIP message identifier.
    event MessageRetried(bytes32 indexed messageId);

    /// @notice Emitted when a source chain selector is added to or removed from the allowlist.
    /// @param chainSelector The CCIP chain selector that was updated.
    /// @param allowed Whether the chain is now allowed.
    event SourceChainAllowlistUpdated(
        uint64 indexed chainSelector,
        bool allowed
    );

    /// @notice Emitted when a sender address allowlist entry is updated.
    /// @param sourceChainSelector The source chain selector.
    /// @param sender The sender address.
    /// @param allowed Whether the sender is now allowed.
    event SenderAllowlistUpdated(
        uint64 indexed sourceChainSelector,
        address indexed sender,
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

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    /// @notice Mapping of allowed source chain selectors.
    mapping(uint64 chainSelector => bool allowed)
        public allowlistedSourceChains;

    /// @notice Mapping of allowed sender addresses per source chain selector.
    mapping(uint64 chainSelector => mapping(address sender => bool allowed))
        public allowlistedSenders;

    /// @notice Maximum number of token entries accepted per CCIP message.
    uint16 public constant MAX_TOKENS_PER_MESSAGE = 10;

    /// @notice Processing status of each received message.
    mapping(bytes32 messageId => MessageStatus status) public messageStatuses;

    /// @notice Raw CCIP message data stored for failed messages to enable retry. @mohit-> gas?
    mapping(bytes32 messageId => Client.Any2EVMMessage message)
        private s_failedMessages;

    /// @notice Whether failed message data is complete and safe to retry.
    mapping(bytes32 messageId => bool retryable)
        private s_retryableFailedMessages;

    // ──────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────

    /// @dev Reverts if the source chain is not allowlisted.
    modifier onlyAllowlistedSourceChain(uint64 sourceChainSelector) {
        if (!allowlistedSourceChains[sourceChainSelector]) {
            revert SourceChainNotAllowed(sourceChainSelector);
        }
        _;
    }

    /// @dev Reverts if the sender is not allowlisted for the given source chain.
    modifier onlyAllowlistedSender(uint64 sourceChainSelector, address sender) {
        if (!allowlistedSenders[sourceChainSelector][sender]) {
            revert SenderNotAllowed(sourceChainSelector, sender);
        }
        _;
    }

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    /// @notice Deploys the receiver contract.
    /// @param router The address of the CCIP Router on the destination chain.
    /// @param initialOwner The address that will own this contract.
    constructor(
        address router,
        address initialOwner
    ) CCIPReceiver(router) Ownable(initialOwner) {}

    // ──────────────────────────────────────────────
    //  ERC-165
    // ──────────────────────────────────────────────

    /// @inheritdoc CCIPReceiver
    /// @dev Delegates to CCIPReceiver's supportsInterface which handles
    ///      IAny2EVMMessageReceiver and IERC165 interface detection.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ──────────────────────────────────────────────
    //  Admin — Allowlist Management
    // ──────────────────────────────────────────────

    /// @notice Adds or removes a source chain selector from the allowlist.
    /// @param chainSelector The CCIP chain selector.
    /// @param allowed `true` to allow, `false` to disallow.
    function setSourceChainAllowlist(
        uint64 chainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedSourceChains[chainSelector] = allowed;
        emit SourceChainAllowlistUpdated(chainSelector, allowed);
    }

    /// @notice Adds or removes a sender address from the allowlist for a specific source chain.
    /// @param sourceChainSelector The source chain selector.
    /// @param sender The sender contract address on the source chain.
    /// @param allowed `true` to allow, `false` to disallow.
    function setSenderAllowlist(
        uint64 sourceChainSelector,
        address sender,
        bool allowed
    ) external onlyOwner {
        allowlistedSenders[sourceChainSelector][sender] = allowed;
        emit SenderAllowlistUpdated(sourceChainSelector, sender, allowed);
    }

    // ──────────────────────────────────────────────
    //  CCIP — Message Reception (Defensive Pattern)
    // ──────────────────────────────────────────────

    /// @inheritdoc CCIPReceiver
    /// @notice Entry point called by the CCIP Router when a cross-chain message arrives.
    /// @dev Overrides the base CCIPReceiver to add reentrancy protection.
    ///      The `onlyRouter` modifier is inherited from CCIPReceiver.
    function ccipReceive(
        Client.Any2EVMMessage calldata message
    ) external override onlyRouter nonReentrant {
        _ccipReceive(message);
    }

    /// @notice Defensive receive logic with try/catch pattern.
    /// @dev Uses a defensive try/catch pattern:
    ///   - On success: marks the message as `Succeeded` and emits `MessageReceived`.
    ///   - On failure: marks the message as `Failed`, stores the raw message, and emits `MessageFailed`.
    ///   The top-level call **never reverts**, ensuring tokens are not stuck in the protocol.
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        // Decode the sender address from the source chain.
        address sender = abi.decode(message.sender, (address));

        // Validate source chain and sender allowlists.
        if (!allowlistedSourceChains[message.sourceChainSelector]) {
            // Store as failed so owner can recover tokens.
            _storeFailed(
                message,
                abi.encodeWithSelector(
                    SourceChainNotAllowed.selector,
                    message.sourceChainSelector
                )
            );
            return;
        }
        if (!allowlistedSenders[message.sourceChainSelector][sender]) {
            _storeFailed(
                message,
                abi.encodeWithSelector(
                    SenderNotAllowed.selector,
                    message.sourceChainSelector,
                    sender
                )
            );
            return;
        }

        // Replay protection.
        if (messageStatuses[message.messageId] != MessageStatus.NotReceived) {
            revert MessageAlreadyProcessed(message.messageId);
        }

        // Attempt to process the message inside a try/catch.
        try this.processMessage(message) {
            // Success path — status already set inside processMessage.
        } catch (bytes memory reason) {
            _storeFailed(message, reason);
        }
    }

    /// @notice Internal processing logic, called via `this.processMessage()` so that
    ///         reverts are caught by the try/catch in `_ccipReceive`.
    /// @dev This function MUST only be called by the contract itself.
    /// @param message The decoded CCIP message.
    function processMessage(Client.Any2EVMMessage calldata message) external {
        // Only callable by self (from the try/catch in _ccipReceive).
        if (msg.sender != address(this)) revert InvalidRouter(msg.sender);

        uint256 tokenCount = message.destTokenAmounts.length;
        if (tokenCount > MAX_TOKENS_PER_MESSAGE) {
            revert TooManyTokens(tokenCount, MAX_TOKENS_PER_MESSAGE);
        }

        _processMessage(message);
    }

    /// @notice Core business logic for handling a received message.
    /// @dev Override this in derived contracts to add custom logic.
    /// @param message The decoded CCIP message.
    function _processMessage(Client.Any2EVMMessage calldata message) internal {
        // ── Effects ─────────────────────────────────
        messageStatuses[message.messageId] = MessageStatus.Succeeded;

        address sender = abi.decode(message.sender, (address));

        emit MessageReceived(
            message.messageId,
            message.sourceChainSelector,
            sender,
            message.destTokenAmounts
        );

        // Tokens are automatically transferred to this contract by the Router
        // before ccipReceive is called. No additional transfer logic needed here.
        // Extend this function to forward tokens, update accounting, etc.
    }

    /// @dev Stores a failed message for later retry and emits `MessageFailed`.
    /// @param message The raw CCIP message.
    /// @param reason The revert reason bytes.
    function _storeFailed(
        Client.Any2EVMMessage memory message,
        bytes memory reason
    ) private {
        bytes32 msgId = message.messageId;

        uint256 len = message.destTokenAmounts.length;
        if (len > MAX_TOKENS_PER_MESSAGE) {
            _storeFailedWithoutTokenAmounts(
                message,
                abi.encodeWithSelector(
                    TooManyTokens.selector,
                    len,
                    MAX_TOKENS_PER_MESSAGE
                )
            );
            return;
        }

        messageStatuses[msgId] = MessageStatus.Failed;
        s_retryableFailedMessages[msgId] = true;

        Client.Any2EVMMessage storage stored = s_failedMessages[msgId];
        stored.messageId = msgId;
        stored.sourceChainSelector = message.sourceChainSelector;
        stored.sender = message.sender;
        stored.data = message.data;

        for (uint256 i; i < len; ) {
            stored.destTokenAmounts.push(message.destTokenAmounts[i]);
            unchecked {
                ++i;
            }
        }

        emit MessageFailed(msgId, reason);
    }

    /// @dev Stores a failed message without token amounts when payload is too large for safe retries.
    function _storeFailedWithoutTokenAmounts(
        Client.Any2EVMMessage memory message,
        bytes memory reason
    ) private {
        bytes32 msgId = message.messageId;
        messageStatuses[msgId] = MessageStatus.Failed;
        s_retryableFailedMessages[msgId] = false;

        Client.Any2EVMMessage storage stored = s_failedMessages[msgId];
        stored.messageId = msgId;
        stored.sourceChainSelector = message.sourceChainSelector;
        stored.sender = message.sender;
        stored.data = message.data;

        emit MessageFailed(msgId, reason);
    }

    // ──────────────────────────────────────────────
    //  Admin — Retry Failed Messages
    // ──────────────────────────────────────────────

    /// @notice Retries processing of a previously failed message.
    /// @dev Only callable by the owner. The message must be in `Failed` status.
    ///      On success the status is updated to `Succeeded`. On failure it reverts.
    /// @param messageId The CCIP message identifier of the failed message.
    function retryFailedMessage(
        bytes32 messageId
    ) external onlyOwner nonReentrant {
        if (messageStatuses[messageId] != MessageStatus.Failed) {
            revert MessageNotFailed(messageId);
        }
        if (!s_retryableFailedMessages[messageId]) {
            revert MessageNotRetryable(messageId);
        }

        // ── Effects ─────────────────────────────────
        messageStatuses[messageId] = MessageStatus.Succeeded;

        Client.Any2EVMMessage storage message = s_failedMessages[messageId];
        address sender = abi.decode(message.sender, (address));

        emit MessageRetried(messageId);
        emit MessageReceived(
            message.messageId,
            message.sourceChainSelector,
            sender,
            message.destTokenAmounts
        );

        // ── Interactions ────────────────────────────
        // Forward tokens that are sitting in this contract to the owner.
        // This is the safest default — the owner can then distribute as needed.
        uint256 len = message.destTokenAmounts.length;
        if (len > MAX_TOKENS_PER_MESSAGE) {
            revert TooManyTokens(len, MAX_TOKENS_PER_MESSAGE);
        }

        for (uint256 i = 0; i < len; ) {
            IERC20(message.destTokenAmounts[i].token).safeTransfer(
                owner(),
                message.destTokenAmounts[i].amount
            );
            unchecked {
                ++i;
            }
        }

        // Clean up storage (gas refund).
        delete s_failedMessages[messageId];
        delete s_retryableFailedMessages[messageId];
    }

    // ──────────────────────────────────────────────
    //  Admin — Token Recovery
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

    // ──────────────────────────────────────────────
    //  View — Failed Message Data
    // ──────────────────────────────────────────────

    /// @notice Returns the stored data for a failed message.
    /// @param messageId The CCIP message identifier.
    /// @return The stored `Any2EVMMessage` struct.
    function getFailedMessage(
        bytes32 messageId
    ) external view returns (Client.Any2EVMMessage memory) {
        return s_failedMessages[messageId];
    }

    /// @notice Returns the CCIP Router address.
    /// @return The router address.
    function getRouter() public view override returns (address) {
        return super.getRouter();
    }
}
