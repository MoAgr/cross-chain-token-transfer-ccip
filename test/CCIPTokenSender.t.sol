// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CCIPTokenSender} from "../src/Sender.sol";
import {
    CCIPLocalSimulator
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {
    IRouterClient
} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {
    MockCCIPRouter
} from "@chainlink/local/src/vendor/chainlink-ccip/test/mocks/MockRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {RefundRejecter} from "./mocks/RefundRejecter.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

contract CCIPTokenSenderTest is Test {
    // ── constants ──────────────────────────────────────────────
    uint64 constant UNLISTED_CHAIN = 9999999999999999999;
    address constant RECEIVER = address(0xBEEF);
    uint256 constant TOKEN_AMOUNT = 100e18;
    uint256 constant BASE_FEE = 0.01 ether;

    // ── actors ─────────────────────────────────────────────────
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // ── contracts ──────────────────────────────────────────────
    CCIPLocalSimulator simulator;
    uint64 destChain;
    CCIPTokenSender sender;
    MockCCIPRouter router;
    MockERC20 token;

    // ─────────────────────────────────────────────────────────
    //  Setup
    // ─────────────────────────────────────────────────────────

    function setUp() public {
        simulator = new CCIPLocalSimulator();
        (uint64 chainSelector, IRouterClient sourceRouter, , , , , ) = simulator
            .configuration();
        destChain = chainSelector;

        router = MockCCIPRouter(payable(address(sourceRouter)));
        token = new MockERC20("Mock USDC", "mUSDC");
        sender = new CCIPTokenSender(address(router), owner);

        router.setFee(BASE_FEE);

        vm.prank(owner);
        sender.setDestinationChainAllowlist(destChain, true);

        token.mint(alice, 1_000e18);
        token.mint(bob, 1_000e18);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ─────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────

    function test_constructor_setsRouter() public view {
        assertEq(address(sender.i_router()), address(router));
    }

    function test_constructor_setsOwner() public view {
        assertEq(sender.owner(), owner);
    }

    function test_constructor_defaultFeeBufferIs10Pct() public view {
        assertEq(sender.feeBufferBps(), 1000);
    }

    function test_constructor_revertsOnZeroRouter() public {
        vm.expectRevert(CCIPTokenSender.InvalidAddress.selector);
        new CCIPTokenSender(address(0), owner);
    }

    // ─────────────────────────────────────────────────────────
    //  setDestinationChainAllowlist
    // ─────────────────────────────────────────────────────────

    function test_allowlist_allowsChain() public {
        assertFalse(sender.allowlistedDestinationChains(UNLISTED_CHAIN));
        vm.prank(owner);
        sender.setDestinationChainAllowlist(UNLISTED_CHAIN, true);
        assertTrue(sender.allowlistedDestinationChains(UNLISTED_CHAIN));
    }

    function test_allowlist_disallowsChain() public {
        vm.prank(owner);
        sender.setDestinationChainAllowlist(destChain, false);
        assertFalse(sender.allowlistedDestinationChains(destChain));
    }

    function test_allowlist_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit CCIPTokenSender.DestinationChainAllowlistUpdated(destChain, false);
        sender.setDestinationChainAllowlist(destChain, false);
    }

    function test_allowlist_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sender.setDestinationChainAllowlist(destChain, false);
    }

    // ─────────────────────────────────────────────────────────
    //  setFeeBufferBps
    // ─────────────────────────────────────────────────────────

    function test_feeBuffer_setsValue() public {
        vm.prank(owner);
        sender.setFeeBufferBps(500);
        assertEq(sender.feeBufferBps(), 500);
    }

    function test_feeBuffer_allowsZero() public {
        vm.prank(owner);
        sender.setFeeBufferBps(0);
        assertEq(sender.feeBufferBps(), 0);
    }

    function test_feeBuffer_allowsMax() public {
        uint16 max = sender.MAX_FEE_BUFFER_BPS();
        vm.prank(owner);
        sender.setFeeBufferBps(max);
        assertEq(sender.feeBufferBps(), max);
    }

    function test_feeBuffer_revertsAboveMax() public {
        uint16 tooHigh = sender.MAX_FEE_BUFFER_BPS() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTokenSender.InvalidFeeBufferBps.selector,
                tooHigh,
                sender.MAX_FEE_BUFFER_BPS()
            )
        );
        vm.prank(owner);
        sender.setFeeBufferBps(tooHigh);
    }

    function test_feeBuffer_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit CCIPTokenSender.FeeBufferUpdated(1000, 500);
        sender.setFeeBufferBps(500);
    }

    function test_feeBuffer_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sender.setFeeBufferBps(500);
    }

    // ─────────────────────────────────────────────────────────
    //  sendTokens — happy path
    // ─────────────────────────────────────────────────────────

    function test_send_returnsMessageId() public {
        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        bytes32 messageId = sender.sendTokens{value: 0.02 ether}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();

        assertTrue(messageId != bytes32(0));
    }

    function test_send_emitsTokensSent() public {
        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);

        vm.expectEmit(false, true, true, true);
        emit CCIPTokenSender.TokensSent(
            bytes32(0),
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            BASE_FEE
        );
        sender.sendTokens{value: 0.02 ether}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();
    }

    function test_send_pullsTokensFromCaller() public {
        uint256 before = token.balanceOf(alice);

        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        sender.sendTokens{value: 0.02 ether}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();

        assertEq(token.balanceOf(alice), before - TOKEN_AMOUNT);
    }

    function test_send_clearsRouterApprovalAfterSend() public {
        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        sender.sendTokens{value: 0.02 ether}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();

        assertEq(token.allowance(address(sender), address(router)), 0);
    }

    function test_send_refundsExcessFee() public {
        uint256 before = alice.balance;

        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        sender.sendTokens{value: 0.05 ether}(
            // BASE_FEE = 0.01
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();

        assertEq(alice.balance, before - BASE_FEE);
    }

    function test_send_emitsExcessFeeRefunded() public {
        uint256 excess = 0.05 ether - BASE_FEE;

        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        vm.expectEmit(true, false, false, true);
        emit CCIPTokenSender.ExcessFeeRefunded(alice, excess);
        sender.sendTokens{value: 0.05 ether}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();
    }

    function test_send_noRefundEventWhenExactFeeProvided() public {
        // With zero buffer configured, sending exactly BASE_FEE should not emit a refund event.
        vm.prank(owner);
        sender.setFeeBufferBps(0);

        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        vm.recordLogs();
        sender.sendTokens{value: BASE_FEE}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();

        bytes32 refundTopic = keccak256("ExcessFeeRefunded(address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundRefundEvent;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == refundTopic) {
                foundRefundEvent = true;
                break;
            }
        }
        assertFalse(foundRefundEvent);
    }

    function test_send_withCustomGasLimit() public {
        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        sender.sendTokens{value: 0.02 ether}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            500_000
        );
        vm.stopPrank();
    }

    function test_send_withZeroFeeBuffer() public {
        vm.prank(owner);
        sender.setFeeBufferBps(0);

        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        sender.sendTokens{value: BASE_FEE}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    //  sendTokens — revert paths
    // ─────────────────────────────────────────────────────────

    function test_send_revertsIfChainNotAllowlisted() public {
        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTokenSender.DestinationChainNotAllowed.selector,
                UNLISTED_CHAIN
            )
        );
        sender.sendTokens{value: 0.02 ether}(
            UNLISTED_CHAIN,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();
    }

    function test_send_revertsIfChainNotSupportedByRouter() public {
        MockRouter unsupportedRouter = new MockRouter();
        unsupportedRouter.setFee(BASE_FEE);
        CCIPTokenSender unsupportedSender = new CCIPTokenSender(
            address(unsupportedRouter),
            owner
        );

        // Allowlisted in sender, but unsupported by this specific test router.
        vm.prank(owner);
        unsupportedSender.setDestinationChainAllowlist(UNLISTED_CHAIN, true);

        vm.startPrank(alice);
        token.approve(address(unsupportedSender), TOKEN_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTokenSender.DestinationChainNotSupported.selector,
                UNLISTED_CHAIN
            )
        );
        unsupportedSender.sendTokens{value: 0.02 ether}(
            UNLISTED_CHAIN,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();
    }

    function test_send_revertsOnZeroAmount() public {
        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        vm.expectRevert(CCIPTokenSender.NoTokensToTransfer.selector);
        sender.sendTokens{value: 0.02 ether}(
            destChain,
            RECEIVER,
            address(token),
            0,
            0
        );
        vm.stopPrank();
    }

    function test_send_revertsOnZeroReceiver() public {
        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        vm.expectRevert(CCIPTokenSender.InvalidAddress.selector);
        sender.sendTokens{value: 0.02 ether}(
            destChain,
            address(0),
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();
    }

    function test_send_revertsIfInsufficientFee() public {
        uint256 bufferedFee = BASE_FEE + (BASE_FEE * 1000) / 10_000;
        uint256 tooLittle = bufferedFee - 1;

        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTokenSender.InsufficientNativeFee.selector,
                bufferedFee,
                tooLittle
            )
        );
        sender.sendTokens{value: tooLittle}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();
    }

    function test_send_revertsIfRefundFails() public {
        RefundRejecter rejecter = new RefundRejecter(
            address(sender),
            address(token)
        );
        token.mint(address(rejecter), TOKEN_AMOUNT);
        vm.deal(address(rejecter), 1 ether);

        vm.expectRevert(CCIPTokenSender.NativeTransferFailed.selector);
        rejecter.callSend{value: 0.05 ether}(
            destChain,
            RECEIVER,
            TOKEN_AMOUNT,
            0
        );
    }

    function test_send_revertsOnMaxUintAmountBoundary() public {
        vm.startPrank(alice);
        token.approve(address(sender), type(uint256).max);
        vm.expectRevert();
        sender.sendTokens{value: 0.02 ether}(
            destChain,
            RECEIVER,
            address(token),
            type(uint256).max,
            0
        );
        vm.stopPrank();
    }

    function test_send_reentrancyGuard_blocksMaliciousTokenReentry() public {
        ReentrantToken reentrant = new ReentrantToken();
        reentrant.mint(alice, TOKEN_AMOUNT);

        // Ensure the reentrant inner call can pass fee checks with zero msg.value.
        router.setFee(0);
        vm.prank(owner);
        sender.setFeeBufferBps(0);

        reentrant.configureReentry(address(sender), destChain, RECEIVER, true);

        vm.startPrank(alice);
        reentrant.approve(address(sender), TOKEN_AMOUNT);
        sender.sendTokens{value: 0}(
            destChain,
            RECEIVER,
            address(reentrant),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();

        assertTrue(reentrant.reentryAttempted());
        assertFalse(reentrant.reentrySucceeded());
    }

    // ─────────────────────────────────────────────────────────
    //  Fee buffer math
    // ─────────────────────────────────────────────────────────

    function test_feeBuffer_correctBoundary() public {
        uint256 bufferedFee = BASE_FEE + (BASE_FEE * 1000) / 10_000; // 0.011 ether

        // One wei short → revert
        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        vm.expectRevert();
        sender.sendTokens{value: bufferedFee - 1}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();

        // Exactly the buffered fee → success
        token.mint(alice, TOKEN_AMOUNT);
        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        sender.sendTokens{value: bufferedFee}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();
    }

    function testFuzz_send_refundIsAlwaysCorrect(uint256 extra) public {
        extra = bound(extra, 0, 5 ether);
        uint256 bufferedFee = BASE_FEE + (BASE_FEE * 1000) / 10_000;
        uint256 totalSent = bufferedFee + extra;

        vm.deal(alice, totalSent + 1 ether);
        token.mint(alice, TOKEN_AMOUNT);

        uint256 before = alice.balance;

        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        sender.sendTokens{value: totalSent}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();

        // Alice is always charged exactly BASE_FEE, regardless of how much extra she sent
        assertEq(alice.balance, before - BASE_FEE);
    }

    function testFuzz_feeBuffer_anyValidBuffer(uint16 bps) public {
        bps = uint16(bound(bps, 0, sender.MAX_FEE_BUFFER_BPS()));

        vm.prank(owner);
        sender.setFeeBufferBps(bps);

        uint256 bufferedFee = BASE_FEE + (BASE_FEE * bps) / 10_000;

        // One below → revert
        if (bufferedFee > 0) {
            vm.startPrank(alice);
            token.approve(address(sender), TOKEN_AMOUNT);
            vm.expectRevert();
            sender.sendTokens{value: bufferedFee - 1}(
                destChain,
                RECEIVER,
                address(token),
                TOKEN_AMOUNT,
                0
            );
            vm.stopPrank();
        }

        // Exactly buffered → success
        token.mint(alice, TOKEN_AMOUNT);
        vm.deal(alice, bufferedFee + 1 ether);
        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        sender.sendTokens{value: bufferedFee}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();
    }

    function testFuzz_send_refundArithmetic_extremeRange(
        uint16 bps,
        uint96 fee,
        uint96 extra,
        uint256 amount
    ) public {
        bps = uint16(bound(bps, 0, sender.MAX_FEE_BUFFER_BPS()));
        amount = bound(amount, 1, 1_000e18);

        vm.prank(owner);
        sender.setFeeBufferBps(bps);
        router.setFee(uint256(fee));

        uint256 bufferedFee = uint256(fee) + (uint256(fee) * bps) / 10_000;
        uint256 totalSent = bufferedFee + uint256(extra);

        if (token.balanceOf(alice) < amount) {
            token.mint(alice, amount);
        }
        vm.deal(alice, totalSent + 1 ether);

        uint256 before = alice.balance;

        vm.startPrank(alice);
        token.approve(address(sender), amount);
        sender.sendTokens{value: totalSent}(
            destChain,
            RECEIVER,
            address(token),
            amount,
            0
        );
        vm.stopPrank();

        // Sender should charge exactly the router fee and refund buffer + extra.
        assertEq(alice.balance, before - uint256(fee));
        assertEq(address(sender).balance, 0);
    }

    // ─────────────────────────────────────────────────────────
    //  withdrawToken
    // ─────────────────────────────────────────────────────────

    function test_withdrawToken_transfersFullBalance() public {
        token.mint(address(sender), 50e18);
        uint256 before = token.balanceOf(owner);

        vm.prank(owner);
        sender.withdrawToken(address(token), owner);

        assertEq(token.balanceOf(owner), before + 50e18);
        assertEq(token.balanceOf(address(sender)), 0);
    }

    function test_withdrawToken_emitsEvent() public {
        token.mint(address(sender), 50e18);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit CCIPTokenSender.TokensWithdrawn(address(token), owner, 50e18);
        sender.withdrawToken(address(token), owner);
    }

    function test_withdrawToken_revertsIfNotOwner() public {
        token.mint(address(sender), 50e18);

        vm.prank(alice);
        vm.expectRevert();
        sender.withdrawToken(address(token), alice);
    }

    function test_withdrawToken_revertsOnZeroRecipient() public {
        token.mint(address(sender), 50e18);

        vm.prank(owner);
        vm.expectRevert(CCIPTokenSender.InvalidAddress.selector);
        sender.withdrawToken(address(token), address(0));
    }

    // ─────────────────────────────────────────────────────────
    //  withdrawNative
    // ─────────────────────────────────────────────────────────

    function test_withdrawNative_transfersBalance() public {
        vm.deal(address(sender), 1 ether);
        uint256 before = owner.balance;

        vm.prank(owner);
        sender.withdrawNative(owner);

        assertEq(owner.balance, before + 1 ether);
        assertEq(address(sender).balance, 0);
    }

    function test_withdrawNative_emitsEvent() public {
        vm.deal(address(sender), 1 ether);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit CCIPTokenSender.NativeWithdrawn(owner, 1 ether);
        sender.withdrawNative(owner);
    }

    function test_withdrawNative_revertsIfNotOwner() public {
        vm.deal(address(sender), 1 ether);

        vm.prank(alice);
        vm.expectRevert();
        sender.withdrawNative(alice);
    }

    function test_withdrawNative_revertsOnZeroRecipient() public {
        vm.deal(address(sender), 1 ether);

        vm.prank(owner);
        vm.expectRevert(CCIPTokenSender.InvalidAddress.selector);
        sender.withdrawNative(payable(address(0)));
    }

    // ─────────────────────────────────────────────────────────
    //  receive()
    // ─────────────────────────────────────────────────────────

    function test_receive_acceptsETH() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, ) = address(sender).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(address(sender).balance, 0.5 ether);
    }

    // ─────────────────────────────────────────────────────────
    //  Multi-user independence
    // ─────────────────────────────────────────────────────────

    function test_multipleUsers_sendTokensIndependently() public {
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);

        vm.startPrank(alice);
        token.approve(address(sender), TOKEN_AMOUNT);
        sender.sendTokens{value: 0.02 ether}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT,
            0
        );
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(sender), TOKEN_AMOUNT / 2);
        sender.sendTokens{value: 0.02 ether}(
            destChain,
            RECEIVER,
            address(token),
            TOKEN_AMOUNT / 2,
            0
        );
        vm.stopPrank();

        assertEq(token.balanceOf(alice), aliceBefore - TOKEN_AMOUNT);
        assertEq(token.balanceOf(bob), bobBefore - TOKEN_AMOUNT / 2);
    }
}
