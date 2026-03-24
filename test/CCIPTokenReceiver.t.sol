// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {CCIPTokenSender} from "../src/Sender.sol";
import {CCIPTokenReceiver} from "../src/Receiver.sol";

import {
    CCIPLocalSimulator
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {
    IRouterClient
} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {
    MockCCIPRouter
} from "@chainlink/local/src/vendor/chainlink-ccip/test/mocks/MockRouter.sol";
import {
    Client
} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantWithdrawToken} from "./mocks/ReentrantWithdrawToken.sol";

contract RetryHarnessReceiver is CCIPTokenReceiver {
    bool public failProcessing;

    constructor(
        address router,
        address initialOwner
    ) CCIPTokenReceiver(router, initialOwner) {}

    function setFailProcessing(bool shouldFail) external {
        failProcessing = shouldFail;
    }

    function _processMessage(
        Client.Any2EVMMessage calldata message
    ) internal override {
        if (failProcessing) {
            revert RetryFailed(message.messageId);
        }
        super._processMessage(message);
    }
}

contract CCIPTokenReceiverTest is Test {
    uint64 internal constant SOURCE_CHAIN_SELECTOR = 16015286601757825753;
    uint256 internal constant BASE_FEE = 0.01 ether;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    CCIPLocalSimulator internal simulator;
    MockCCIPRouter internal router;
    CCIPTokenSender internal sourceSender;
    CCIPTokenReceiver internal receiver;
    MockERC20 internal token;
    uint64 internal destChain;
    uint256 internal sendNonce;

    function setUp() public {
        simulator = new CCIPLocalSimulator();
        (uint64 chainSelector, IRouterClient sourceRouter, , , , , ) = simulator
            .configuration();

        destChain = chainSelector;
        router = MockCCIPRouter(payable(address(sourceRouter)));

        sourceSender = new CCIPTokenSender(address(router), owner);
        receiver = new CCIPTokenReceiver(address(router), owner);
        token = new MockERC20("Mock USDC", "mUSDC");

        router.setFee(BASE_FEE);

        vm.startPrank(owner);
        sourceSender.setDestinationChainAllowlist(destChain, true);
        receiver.setSourceChainAllowlist(SOURCE_CHAIN_SELECTOR, true);
        receiver.setSenderAllowlist(
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            true
        );
        vm.stopPrank();

        token.mint(alice, 100_000e18);
        vm.deal(alice, 100 ether);
    }

    function _buildMessage(
        bytes32 messageId,
        uint64 sourceChainSelector,
        address srcSender,
        uint256 tokenCount,
        uint256 amountEach
    ) internal view returns (Client.Any2EVMMessage memory message) {
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](tokenCount);
        for (uint256 i; i < tokenCount; ) {
            tokenAmounts[i] = Client.EVMTokenAmount({
                token: address(token),
                amount: amountEach
            });
            unchecked {
                ++i;
            }
        }

        message = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: sourceChainSelector,
            sender: abi.encode(srcSender),
            data: "",
            destTokenAmounts: tokenAmounts
        });
    }

    function _sendFromSource(
        uint256 amount
    ) internal returns (bytes32 messageId) {
        vm.startPrank(alice);
        token.approve(address(sourceSender), amount);

        uint256 gasLimit = 500_000 + sendNonce;
        ++sendNonce;

        messageId = sourceSender.sendTokens{value: 0.02 ether}(
            destChain,
            address(receiver),
            address(token),
            amount,
            gasLimit
        );
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    //  Constructor + Views
    // ─────────────────────────────────────────────────────────

    function test_getRouter_returnsConfiguredRouter() public view {
        assertEq(receiver.getRouter(), address(router));
    }

    function test_supportsInterface_erc165() public view {
        assertTrue(receiver.supportsInterface(0x01ffc9a7));
    }

    function test_getFailedMessage_defaultEmpty() public view {
        Client.Any2EVMMessage memory stored = receiver.getFailedMessage(
            bytes32(uint256(1))
        );
        assertEq(stored.messageId, bytes32(0));
        assertEq(stored.destTokenAmounts.length, 0);
    }

    // ─────────────────────────────────────────────────────────
    //  Allowlists
    // ─────────────────────────────────────────────────────────

    function test_setSourceChainAllowlist_updatesStateAndEmits() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit CCIPTokenReceiver.SourceChainAllowlistUpdated(
            SOURCE_CHAIN_SELECTOR,
            false
        );
        receiver.setSourceChainAllowlist(SOURCE_CHAIN_SELECTOR, false);

        assertFalse(receiver.allowlistedSourceChains(SOURCE_CHAIN_SELECTOR));
    }

    function test_setSourceChainAllowlist_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        receiver.setSourceChainAllowlist(SOURCE_CHAIN_SELECTOR, false);
    }

    function test_setSenderAllowlist_updatesStateAndEmits() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit CCIPTokenReceiver.SenderAllowlistUpdated(
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            false
        );
        receiver.setSenderAllowlist(
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            false
        );

        assertFalse(
            receiver.allowlistedSenders(
                SOURCE_CHAIN_SELECTOR,
                address(sourceSender)
            )
        );
    }

    function test_setSenderAllowlist_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        receiver.setSenderAllowlist(
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            false
        );
    }

    // ─────────────────────────────────────────────────────────
    //  ccipReceive + processMessage
    // ─────────────────────────────────────────────────────────

    function test_ccipReceive_onlyRouter() public {
        Client.Any2EVMMessage memory message = _buildMessage(
            keccak256("not-router"),
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            1,
            1e18
        );

        vm.prank(alice);
        vm.expectRevert();
        receiver.ccipReceive(message);
    }

    function test_processMessage_onlySelf() public {
        Client.Any2EVMMessage memory message = _buildMessage(
            keccak256("external-process"),
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            1,
            1e18
        );

        vm.expectRevert();
        receiver.processMessage(message);
    }

    function test_ccipReceive_sourceDisallowed_storesFailedNoTopLevelRevert()
        public
    {
        bytes32 messageId = keccak256("source-disallowed");
        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            1,
            1e18
        );

        vm.prank(owner);
        receiver.setSourceChainAllowlist(SOURCE_CHAIN_SELECTOR, false);

        vm.prank(address(router));
        receiver.ccipReceive(message);

        assertEq(
            uint256(receiver.messageStatuses(messageId)),
            uint256(CCIPTokenReceiver.MessageStatus.Failed)
        );

        Client.Any2EVMMessage memory stored = receiver.getFailedMessage(
            messageId
        );
        assertEq(stored.messageId, messageId);
    }

    function test_ccipReceive_senderDisallowed_storesFailedNoTopLevelRevert()
        public
    {
        bytes32 messageId = keccak256("sender-disallowed");
        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            1,
            1e18
        );

        vm.prank(owner);
        receiver.setSenderAllowlist(
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            false
        );

        vm.prank(address(router));
        receiver.ccipReceive(message);

        assertEq(
            uint256(receiver.messageStatuses(messageId)),
            uint256(CCIPTokenReceiver.MessageStatus.Failed)
        );
    }

    function test_ccipReceive_replayProtection_blocksDuplicateMessageId()
        public
    {
        bytes32 messageId = keccak256("replay");
        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            1,
            1e18
        );

        vm.prank(address(router));
        receiver.ccipReceive(message);

        assertEq(
            uint256(receiver.messageStatuses(messageId)),
            uint256(CCIPTokenReceiver.MessageStatus.Succeeded)
        );

        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTokenReceiver.MessageAlreadyProcessed.selector,
                messageId
            )
        );
        receiver.ccipReceive(message);
    }

    function test_ccipReceive_replayProtection_blocksDuplicateFailedMessageId()
        public
    {
        RetryHarnessReceiver harness = new RetryHarnessReceiver(
            address(router),
            owner
        );

        vm.startPrank(owner);
        harness.setSourceChainAllowlist(SOURCE_CHAIN_SELECTOR, true);
        harness.setSenderAllowlist(
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            true
        );
        harness.setFailProcessing(true);
        vm.stopPrank();

        bytes32 messageId = keccak256("replay-failed");
        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            1,
            1e18
        );

        token.mint(address(harness), 1e18);

        vm.prank(address(router));
        harness.ccipReceive(message);

        assertEq(
            uint256(harness.messageStatuses(messageId)),
            uint256(CCIPTokenReceiver.MessageStatus.Failed)
        );

        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTokenReceiver.MessageAlreadyProcessed.selector,
                messageId
            )
        );
        harness.ccipReceive(message);
    }

    function test_ccipReceive_tooManyTokens_marksNonRetryableFailure() public {
        bytes32 messageId = keccak256("too-many");
        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            receiver.MAX_TOKENS_PER_MESSAGE() + 1,
            1
        );

        vm.prank(address(router));
        receiver.ccipReceive(message);

        assertEq(
            uint256(receiver.messageStatuses(messageId)),
            uint256(CCIPTokenReceiver.MessageStatus.Failed)
        );

        Client.Any2EVMMessage memory stored = receiver.getFailedMessage(
            messageId
        );
        assertEq(stored.messageId, messageId);
        assertEq(stored.destTokenAmounts.length, 0);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTokenReceiver.MessageNotRetryable.selector,
                messageId
            )
        );
        receiver.retryFailedMessage(messageId);
    }

    function test_ccipReceive_emitsMessageReceived_onSuccess() public {
        bytes32 receivedTopic = keccak256(
            "MessageReceived(bytes32,uint64,address,(address,uint256)[])"
        );

        vm.recordLogs();
        _sendFromSource(5e18);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ) {
            if (
                logs[i].topics.length > 0 && logs[i].topics[0] == receivedTopic
            ) {
                found = true;
                break;
            }
            unchecked {
                ++i;
            }
        }
        assertTrue(found);
    }

    function test_ccipReceive_emitsMessageFailed_onDefensiveFailure() public {
        bytes32 failedTopic = keccak256("MessageFailed(bytes32,bytes)");

        vm.prank(owner);
        receiver.setSenderAllowlist(
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            false
        );

        vm.recordLogs();
        _sendFromSource(2e18);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == failedTopic) {
                found = true;
                break;
            }
            unchecked {
                ++i;
            }
        }
        assertTrue(found);
    }

    // ─────────────────────────────────────────────────────────
    //  retryFailedMessage
    // ─────────────────────────────────────────────────────────

    function test_retryFailedMessage_revertsForNonFailedMessage() public {
        bytes32 messageId = keccak256("never-failed");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTokenReceiver.MessageNotFailed.selector,
                messageId
            )
        );
        receiver.retryFailedMessage(messageId);
    }

    function test_retryFailedMessage_succeedsAndTransfersTokens() public {
        RetryHarnessReceiver harness = new RetryHarnessReceiver(
            address(router),
            owner
        );

        vm.startPrank(owner);
        harness.setSourceChainAllowlist(SOURCE_CHAIN_SELECTOR, true);
        harness.setSenderAllowlist(
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            true
        );
        harness.setFailProcessing(true);
        vm.stopPrank();

        bytes32 messageId = keccak256("retry-success");
        uint256 amount = 9e18;

        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            1,
            amount
        );

        token.mint(address(harness), amount);

        vm.prank(address(router));
        harness.ccipReceive(message);

        assertEq(
            uint256(harness.messageStatuses(messageId)),
            uint256(CCIPTokenReceiver.MessageStatus.Failed)
        );

        uint256 ownerBefore = token.balanceOf(owner);

        vm.prank(owner);
        harness.setFailProcessing(false);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit CCIPTokenReceiver.MessageRetried(messageId);
        harness.retryFailedMessage(messageId);

        assertEq(
            uint256(harness.messageStatuses(messageId)),
            uint256(CCIPTokenReceiver.MessageStatus.Succeeded)
        );
        assertEq(token.balanceOf(owner), ownerBefore + amount);

        Client.Any2EVMMessage memory stored = harness.getFailedMessage(
            messageId
        );
        assertEq(stored.messageId, bytes32(0));
        assertEq(stored.destTokenAmounts.length, 0);
    }

    function test_retryFailedMessage_multiToken_transfersAllAmountsInLoop()
        public
    {
        RetryHarnessReceiver harness = new RetryHarnessReceiver(
            address(router),
            owner
        );

        vm.startPrank(owner);
        harness.setSourceChainAllowlist(SOURCE_CHAIN_SELECTOR, true);
        harness.setSenderAllowlist(
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            true
        );
        harness.setFailProcessing(true);
        vm.stopPrank();

        bytes32 messageId = keccak256("retry-multi-token");
        uint256 tokenCount = 3;
        uint256 amountEach = 4e18;

        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            tokenCount,
            amountEach
        );

        uint256 totalAmount = tokenCount * amountEach;
        token.mint(address(harness), totalAmount);

        vm.prank(address(router));
        harness.ccipReceive(message);

        assertEq(
            uint256(harness.messageStatuses(messageId)),
            uint256(CCIPTokenReceiver.MessageStatus.Failed)
        );

        uint256 ownerBefore = token.balanceOf(owner);

        vm.prank(owner);
        harness.setFailProcessing(false);

        vm.prank(owner);
        harness.retryFailedMessage(messageId);

        assertEq(
            uint256(harness.messageStatuses(messageId)),
            uint256(CCIPTokenReceiver.MessageStatus.Succeeded)
        );
        assertEq(token.balanceOf(owner), ownerBefore + totalAmount);
        assertEq(token.balanceOf(address(harness)), 0);
    }

    function test_retryFailedMessage_idempotency_revertsAfterCleanup() public {
        RetryHarnessReceiver harness = new RetryHarnessReceiver(
            address(router),
            owner
        );

        vm.startPrank(owner);
        harness.setSourceChainAllowlist(SOURCE_CHAIN_SELECTOR, true);
        harness.setSenderAllowlist(
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            true
        );
        harness.setFailProcessing(true);
        vm.stopPrank();

        bytes32 messageId = keccak256("retry-idempotent");
        uint256 amount = 6e18;

        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            1,
            amount
        );

        token.mint(address(harness), amount);

        vm.prank(address(router));
        harness.ccipReceive(message);

        vm.prank(owner);
        harness.setFailProcessing(false);

        vm.prank(owner);
        harness.retryFailedMessage(messageId);

        assertEq(
            uint256(harness.messageStatuses(messageId)),
            uint256(CCIPTokenReceiver.MessageStatus.Succeeded)
        );

        Client.Any2EVMMessage memory stored = harness.getFailedMessage(
            messageId
        );
        assertEq(stored.messageId, bytes32(0));
        assertEq(stored.destTokenAmounts.length, 0);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTokenReceiver.MessageNotFailed.selector,
                messageId
            )
        );
        harness.retryFailedMessage(messageId);
    }

    // ─────────────────────────────────────────────────────────
    //  withdrawToken
    // ─────────────────────────────────────────────────────────

    function test_withdrawToken_transfersFullBalanceAndEmits() public {
        token.mint(address(receiver), 11e18);

        uint256 before = token.balanceOf(owner);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit CCIPTokenReceiver.TokensWithdrawn(address(token), owner, 11e18);
        receiver.withdrawToken(address(token), owner);

        assertEq(token.balanceOf(owner), before + 11e18);
        assertEq(token.balanceOf(address(receiver)), 0);
    }

    function test_withdrawToken_revertsIfNotOwner() public {
        token.mint(address(receiver), 1e18);

        vm.prank(alice);
        vm.expectRevert();
        receiver.withdrawToken(address(token), alice);
    }

    function test_withdrawToken_revertsOnZeroRecipient() public {
        token.mint(address(receiver), 1e18);

        vm.prank(owner);
        vm.expectRevert(CCIPTokenReceiver.InvalidAddress.selector);
        receiver.withdrawToken(address(token), address(0));
    }

    // ─────────────────────────────────────────────────────────
    //  Security: Reentrancy
    // ─────────────────────────────────────────────────────────

    function test_withdrawToken_nonReentrant_blocksTokenCallbackReentry()
        public
    {
        ReentrantWithdrawToken reentrant = new ReentrantWithdrawToken();
        reentrant.mint(address(receiver), 15e18);

        vm.prank(owner);
        receiver.transferOwnership(address(reentrant));

        reentrant.configure(address(receiver), alice, true);
        reentrant.initiateOwnerWithdraw();

        assertTrue(reentrant.reentryAttempted());
        assertTrue(reentrant.reentryBlocked());
        assertEq(reentrant.balanceOf(alice), 15e18);
        assertEq(reentrant.balanceOf(address(receiver)), 0);
    }

    // ─────────────────────────────────────────────────────────
    //  Token accounting + gas benchmark
    // ─────────────────────────────────────────────────────────

    function test_ccipRoute_increasesReceiverBalanceExactlyByAmount() public {
        uint256 amount = 13e18;
        uint256 before = token.balanceOf(address(receiver));

        _sendFromSource(amount);

        assertEq(token.balanceOf(address(receiver)), before + amount);
    }

    function test_gasBenchmark_ccipReceive_payloadSizes_with20PctBuffer()
        public
    {
        Client.Any2EVMMessage memory small = _buildMessage(
            keccak256("gas-small"),
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            1,
            1
        );
        Client.Any2EVMMessage memory large = _buildMessage(
            keccak256("gas-large"),
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            receiver.MAX_TOKENS_PER_MESSAGE(),
            1
        );

        uint256 gasStart = gasleft();
        vm.prank(address(router));
        receiver.ccipReceive(small);
        uint256 gasSmall = gasStart - gasleft();

        gasStart = gasleft();
        vm.prank(address(router));
        receiver.ccipReceive(large);
        uint256 gasLarge = gasStart - gasleft();

        assertGe(gasLarge, gasSmall);

        uint256 recommendedGasLimit = (gasLarge * 120) / 100;
        assertGe(recommendedGasLimit, gasLarge);
    }

    // ─────────────────────────────────────────────────────────
    //  Fuzz tests
    // ─────────────────────────────────────────────────────────

    function testFuzz_ccipReceive_tokenCountBoundary(uint8 tokenCount) public {
        tokenCount = uint8(bound(tokenCount, 0, 20));

        bytes32 messageId = keccak256(abi.encodePacked("boundary", tokenCount));
        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            SOURCE_CHAIN_SELECTOR,
            address(sourceSender),
            tokenCount,
            1
        );

        vm.prank(address(router));
        receiver.ccipReceive(message);

        if (tokenCount <= receiver.MAX_TOKENS_PER_MESSAGE()) {
            assertEq(
                uint256(receiver.messageStatuses(messageId)),
                uint256(CCIPTokenReceiver.MessageStatus.Succeeded)
            );
        } else {
            assertEq(
                uint256(receiver.messageStatuses(messageId)),
                uint256(CCIPTokenReceiver.MessageStatus.Failed)
            );
            Client.Any2EVMMessage memory stored = receiver.getFailedMessage(
                messageId
            );
            assertEq(stored.destTokenAmounts.length, 0);
        }
    }

    function testFuzz_ccipRoute_receiverBalanceIncreaseExact(
        uint256 amount
    ) public {
        amount = bound(amount, 1, 500e18);

        if (token.balanceOf(alice) < amount) {
            token.mint(alice, amount);
        }

        uint256 before = token.balanceOf(address(receiver));
        _sendFromSource(amount);

        assertEq(token.balanceOf(address(receiver)), before + amount);
    }
}
