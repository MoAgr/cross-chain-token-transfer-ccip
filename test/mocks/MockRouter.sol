// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

contract MockRouter {
    mapping(uint64 => bool) public supportedChains;
    uint256 public feeToReturn;
    bytes32 public messageIdToReturn = keccak256("mockMessageId");

    function isChainSupported(uint64 chainSelector) external view returns (bool) {
        return supportedChains[chainSelector];
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return feeToReturn;
    }

    function ccipSend(uint64, Client.EVM2AnyMessage memory) external payable returns (bytes32) {
        return messageIdToReturn;
    }

    // --- test helpers ---
    function setSupportedChain(uint64 chainSelector, bool supported) external {
        supportedChains[chainSelector] = supported;
    }

    function setFee(uint256 fee) external {
        feeToReturn = fee;
    }

    function setMessageId(bytes32 id) external {
        messageIdToReturn = id;
    }
}
