// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {CCIPTokenSender} from "../../src/Sender.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

import {
    CCIPLocalSimulator
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {
    IRouterClient
} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {
    MockCCIPRouter
} from "@chainlink/local/src/vendor/chainlink-ccip/test/mocks/MockRouter.sol";

contract SenderHandler is Test {
    CCIPTokenSender internal sender;
    MockERC20 internal token;
    MockCCIPRouter internal router;

    address internal owner;
    address internal alice;
    uint64 internal destChain;
    address internal receiver = address(0xBEEF);

    bool public failedSendRetainedBalanceDetected;

    constructor(
        CCIPTokenSender _sender,
        MockERC20 _token,
        MockCCIPRouter _router,
        address _owner,
        address _alice,
        uint64 _destChain
    ) {
        sender = _sender;
        token = _token;
        router = _router;
        owner = _owner;
        alice = _alice;
        destChain = _destChain;
    }

    function sendTokensRandom(uint256 amount, uint256 gasLimit) external {
        amount = bound(amount, 1, 1_000e18);
        gasLimit = bound(gasLimit, 0, 600_000);

        if (token.balanceOf(alice) < amount) {
            token.mint(alice, amount);
        }

        vm.startPrank(alice);
        token.approve(address(sender), amount);

        // Intentionally overpay to avoid fee underflow edge cases while fuzzing sequence calls.
        try
            sender.sendTokens{value: 1 ether}(
                destChain,
                receiver,
                address(token),
                amount,
                gasLimit
            )
        {} catch {}
        vm.stopPrank();
    }

    function setFeeBufferRandom(uint16 bps) external {
        bps = uint16(bound(bps, 0, sender.MAX_FEE_BUFFER_BPS()));
        vm.prank(owner);
        sender.setFeeBufferBps(bps);
    }

    function setAllowlist(bool allowed) external {
        vm.prank(owner);
        sender.setDestinationChainAllowlist(destChain, allowed);
    }

    function ownerWithdrawTokenAfterFunding(uint256 amount) external {
        amount = bound(amount, 1, 1_000e18);

        token.mint(address(sender), amount);

        vm.prank(owner);
        try sender.withdrawToken(address(token), owner) {} catch {}
    }

    function ownerWithdrawNativeAfterFunding(uint256 amountWei) external {
        amountWei = bound(amountWei, 1, 10 ether);

        vm.deal(address(sender), address(sender).balance + amountWei);

        vm.prank(owner);
        try sender.withdrawNative(owner) {} catch {}
    }

    function sendTokensExpectedToFailNoRetain(
        uint256 amount,
        uint256 gasLimit
    ) external {
        amount = bound(amount, 1, 1_000e18);
        gasLimit = bound(gasLimit, 0, 600_000);

        if (token.balanceOf(alice) < amount) {
            token.mint(alice, amount);
        }

        uint256 senderBalanceBefore = token.balanceOf(address(sender));

        vm.prank(owner);
        sender.setDestinationChainAllowlist(destChain, false);

        vm.startPrank(alice);
        token.approve(address(sender), amount);
        try
            sender.sendTokens{value: 1 ether}(
                destChain,
                receiver,
                address(token),
                amount,
                gasLimit
            )
        {
            failedSendRetainedBalanceDetected = true;
        } catch {
            uint256 senderBalanceAfter = token.balanceOf(address(sender));
            if (senderBalanceAfter != senderBalanceBefore) {
                failedSendRetainedBalanceDetected = true;
            }
        }
        vm.stopPrank();

        vm.prank(owner);
        sender.setDestinationChainAllowlist(destChain, true);
    }
}

contract SenderInvariants is StdInvariant, Test {
    uint256 internal constant BASE_FEE = 0.01 ether;

    CCIPLocalSimulator internal simulator;
    CCIPTokenSender internal sender;
    MockCCIPRouter internal router;
    MockERC20 internal token;
    SenderHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    uint64 internal destChain;

    function setUp() public {
        simulator = new CCIPLocalSimulator();
        (uint64 chainSelector, IRouterClient sourceRouter, , , , , ) = simulator
            .configuration();
        destChain = chainSelector;
        router = MockCCIPRouter(payable(address(sourceRouter)));

        sender = new CCIPTokenSender(address(router), owner);
        token = new MockERC20("Mock USDC", "mUSDC");

        router.setFee(BASE_FEE);

        vm.prank(owner);
        sender.setDestinationChainAllowlist(destChain, true);

        token.mint(alice, 10_000e18);
        vm.deal(alice, 1_000 ether);

        handler = new SenderHandler(
            sender,
            token,
            router,
            owner,
            alice,
            destChain
        );
        targetContract(address(handler));
    }

    /// @dev Sender should never leave residual approval to router after any call sequence.
    function invariant_routerAllowanceAlwaysZero() public view {
        assertEq(token.allowance(address(sender), address(router)), 0);
    }

    /// @dev Failed send attempts should not leave retained sender token balance for the attempted transfer.
    function invariant_failedSendAttemptDoesNotRetainSenderBalance()
        public
        view
    {
        assertFalse(handler.failedSendRetainedBalanceDetected());
    }
}
