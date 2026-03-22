// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CCIPTokenSender} from "../../src/Sender.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev A contract with no receive() — forces the refund path to fail
contract RefundRejecter {
    CCIPTokenSender public sender;
    MockERC20 public token;

    constructor(address _sender, address _token) {
        sender = CCIPTokenSender(payable(_sender));
        token = MockERC20(_token);
    }

    function callSend(
        uint64 destChain,
        address receiver,
        uint256 amount,
        uint256 gasLimit
    ) external payable {
        token.approve(address(sender), amount);
        sender.sendTokens{value: msg.value}(
            destChain,
            receiver,
            address(token),
            amount,
            gasLimit
        );
    }

    // No receive() / fallback() → ETH refund transfer will revert
}
