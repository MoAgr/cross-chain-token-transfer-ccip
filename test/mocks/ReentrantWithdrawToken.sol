// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Malicious ERC20 used to probe receiver withdraw reentrancy.
contract ReentrantWithdrawToken is ERC20 {
    address public receiver;
    address public recipient;

    bool public attackEnabled;
    bool public reentryAttempted;
    bool public reentryBlocked;

    constructor() ERC20("Reentrant Withdraw Token", "RWT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(
        address _receiver,
        address _recipient,
        bool _enabled
    ) external {
        receiver = _receiver;
        recipient = _recipient;
        attackEnabled = _enabled;
    }

    function initiateOwnerWithdraw() external {
        (bool ok, ) = receiver.call(
            abi.encodeWithSignature(
                "withdrawToken(address,address)",
                address(this),
                recipient
            )
        );
        require(ok, "init withdraw failed");
    }

    function transfer(
        address to,
        uint256 value
    ) public override returns (bool) {
        if (attackEnabled && !reentryAttempted && msg.sender == receiver) {
            reentryAttempted = true;
            (bool ok, ) = receiver.call(
                abi.encodeWithSignature(
                    "withdrawToken(address,address)",
                    address(this),
                    recipient
                )
            );
            if (!ok) {
                reentryBlocked = true;
            }
        }

        return super.transfer(to, value);
    }
}
