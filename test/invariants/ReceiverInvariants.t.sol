// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {CCIPTokenReceiver} from "../../src/Receiver.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {
    Client
} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

import {
    CCIPLocalSimulator
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {
    IRouterClient
} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {
    MockCCIPRouter
} from "@chainlink/local/src/vendor/chainlink-ccip/test/mocks/MockRouter.sol";

contract ReceiverHandler is Test {
    uint64 internal constant SOURCE_CHAIN_SELECTOR = 16015286601757825753;

    CCIPTokenReceiver internal receiver;
    MockERC20 internal token;
    MockCCIPRouter internal router;

    address internal owner;
    address internal allowlistedSender;
    address internal randomUser;

    bool public unauthorizedReceiveSucceeded;
    bool public replaySecondPassSucceeded;
    bool public nonRetryableRetrySucceeded;

    constructor(
        CCIPTokenReceiver _receiver,
        MockERC20 _token,
        MockCCIPRouter _router,
        address _owner,
        address _allowlistedSender,
        address _randomUser
    ) {
        receiver = _receiver;
        token = _token;
        router = _router;
        owner = _owner;
        allowlistedSender = _allowlistedSender;
        randomUser = _randomUser;
    }

    function _buildMessage(
        bytes32 messageId,
        address sender,
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
            sourceChainSelector: SOURCE_CHAIN_SELECTOR,
            sender: abi.encode(sender),
            data: "",
            destTokenAmounts: tokenAmounts
        });
    }

    function unauthorizedReceiveAttempt(bytes32 messageId) external {
        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            allowlistedSender,
            1,
            1
        );

        vm.prank(randomUser);
        try receiver.ccipReceive(message) {
            unauthorizedReceiveSucceeded = true;
        } catch {}
    }

    function replayAttempt(bytes32 messageId, uint256 amount) external {
        amount = bound(amount, 1, 1e18);

        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            allowlistedSender,
            1,
            amount
        );

        vm.prank(address(router));
        try receiver.ccipReceive(message) {} catch {
            return;
        }
        vm.prank(address(router));
        try receiver.ccipReceive(message) {
            replaySecondPassSucceeded = true;
        } catch {}
    }

    function nonRetryableMessageRetryAttempt(bytes32 messageId) external {
        uint256 tooMany = uint256(receiver.MAX_TOKENS_PER_MESSAGE()) + 1;

        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            allowlistedSender,
            tooMany,
            1
        );

        vm.prank(address(router));
        try receiver.ccipReceive(message) {} catch {}
        vm.prank(owner);
        try receiver.retryFailedMessage(messageId) {
            nonRetryableRetrySucceeded = true;
        } catch {}
    }
}

contract ReceiverInvariants is StdInvariant, Test {
    uint64 internal constant SOURCE_CHAIN_SELECTOR = 16015286601757825753;

    CCIPLocalSimulator internal simulator;
    CCIPTokenReceiver internal receiver;
    MockCCIPRouter internal router;
    MockERC20 internal token;
    ReceiverHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal allowlistedSender = makeAddr("allowlistedSender");
    address internal randomUser = makeAddr("randomUser");

    function setUp() public {
        simulator = new CCIPLocalSimulator();
        (, IRouterClient sourceRouter, , , , , ) = simulator.configuration();
        router = MockCCIPRouter(payable(address(sourceRouter)));

        receiver = new CCIPTokenReceiver(address(router), owner);
        token = new MockERC20("Mock USDC", "mUSDC");

        vm.startPrank(owner);
        receiver.setSourceChainAllowlist(SOURCE_CHAIN_SELECTOR, true);
        receiver.setSenderAllowlist(
            SOURCE_CHAIN_SELECTOR,
            allowlistedSender,
            true
        );
        vm.stopPrank();

        handler = new ReceiverHandler(
            receiver,
            token,
            router,
            owner,
            allowlistedSender,
            randomUser
        );

        targetContract(address(handler));
    }

    function invariant_onlyRouterCanCallReceive() public view {
        assertFalse(handler.unauthorizedReceiveSucceeded());
    }

    function invariant_replaySecondPassNeverSucceeds() public view {
        assertFalse(handler.replaySecondPassSucceeded());
    }

    function invariant_nonRetryableMessagesCannotBeRetried() public view {
        assertFalse(handler.nonRetryableRetrySucceeded());
    }
}
