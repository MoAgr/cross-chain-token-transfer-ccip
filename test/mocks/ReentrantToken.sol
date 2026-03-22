// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CCIPTokenSender} from "../../src/Sender.sol";

/// @dev ERC20 mock that attempts a nested sender.sendTokens call during transferFrom.
contract ReentrantToken is ERC20 {
    CCIPTokenSender public sender;
    uint64 public destinationChainSelector;
    address public receiver;
    bool public attemptReentry;

    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor() ERC20("Reentrant Token", "RNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureReentry(
        address senderAddress,
        uint64 destChain,
        address receiverAddress,
        bool enabled
    ) external {
        sender = CCIPTokenSender(payable(senderAddress));
        destinationChainSelector = destChain;
        receiver = receiverAddress;
        attemptReentry = enabled;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        if (attemptReentry && !reentryAttempted) {
            reentryAttempted = true;
            (reentrySucceeded, ) = address(sender).call(
                abi.encodeWithSelector(
                    CCIPTokenSender.sendTokens.selector,
                    destinationChainSelector,
                    receiver,
                    address(this),
                    0,
                    0
                )
            );
        }

        return super.transferFrom(from, to, value);
    }
}
