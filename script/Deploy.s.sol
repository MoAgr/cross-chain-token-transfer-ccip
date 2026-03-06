// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CCIPTokenSender} from "../src/Sender.sol";
import {CCIPTokenReceiver} from "../src/Receiver.sol";

/// @title DeployCCIP
/// @notice Foundry deployment script for the CCIPTokenSender and CCIPTokenReceiver contracts.
/// @dev Deploys either the Sender (source chain) or the Receiver (destination chain)
///      depending on which function is called.
///
/// Usage — deploy Sender on Sepolia:
///   forge script script/Deploy.s.sol:DeploySender \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
///
/// Usage — deploy Receiver on Fuji:
///   forge script script/Deploy.s.sol:DeployReceiver \
///     --rpc-url $FUJI_RPC_URL --broadcast --verify -vvvv
///
/// Required environment variables:
///   PRIVATE_KEY          — deployer private key
///   DEPLOYER_ADDRESS     — deployer / initial owner address

// ──────────────────────────────────────────────────
//  Network Constants
// ──────────────────────────────────────────────────

/// @dev Chainlink CCIP Router addresses and chain selectors for supported testnets.
///      See: https://docs.chain.link/ccip/supported-networks/v1_2_0/testnet
library CCIPConfig {
    // ── Ethereum Sepolia ────────────────────────────
    address constant SEPOLIA_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    uint64 constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;

    // ── Avalanche Fuji ──────────────────────────────
    address constant FUJI_ROUTER = 0xF694E193200268f9a4868e4Aa017A0118C9a8177;
    uint64 constant FUJI_CHAIN_SELECTOR = 14767482510784806043;

    // ── CCIP-BnM Test Token ─────────────────────────
    address constant SEPOLIA_CCIP_BNM = 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05;
    address constant FUJI_CCIP_BNM = 0xD21341536c5cF5EB1bcb58f6723cE26e8D8E90e4;
}

// ──────────────────────────────────────────────────
//  Deploy Sender (Ethereum Sepolia)
// ──────────────────────────────────────────────────

/// @title DeploySender
/// @notice Deploys CCIPTokenSender on Sepolia and allowlists the Fuji destination chain.
contract DeploySender is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        console.log("=== Deploying CCIPTokenSender on Sepolia ===");
        console.log("Deployer:", deployer);
        console.log("Router:  ", CCIPConfig.SEPOLIA_ROUTER);

        vm.startBroadcast(deployerKey);

        // Deploy
        CCIPTokenSender sender = new CCIPTokenSender(CCIPConfig.SEPOLIA_ROUTER, deployer);
        console.log("CCIPTokenSender deployed at:", address(sender));

        // Allowlist Avalanche Fuji as a destination chain
        sender.setDestinationChainAllowlist(CCIPConfig.FUJI_CHAIN_SELECTOR, true);
        console.log("Fuji chain selector allowlisted:", CCIPConfig.FUJI_CHAIN_SELECTOR);

        vm.stopBroadcast();
    }
}

// ──────────────────────────────────────────────────
//  Deploy Receiver (Avalanche Fuji)
// ──────────────────────────────────────────────────

/// @title DeployReceiver
/// @notice Deploys CCIPTokenReceiver on Fuji and allowlists Sepolia as a source chain.
/// @dev After deploying, call `setSenderAllowlist` with the Sender contract address
///      once it is deployed on Sepolia.
contract DeployReceiver is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        console.log("=== Deploying CCIPTokenReceiver on Fuji ===");
        console.log("Deployer:", deployer);
        console.log("Router:  ", CCIPConfig.FUJI_ROUTER);

        vm.startBroadcast(deployerKey);

        // Deploy
        CCIPTokenReceiver receiver = new CCIPTokenReceiver(CCIPConfig.FUJI_ROUTER, deployer);
        console.log("CCIPTokenReceiver deployed at:", address(receiver));

        // Allowlist Ethereum Sepolia as a source chain
        receiver.setSourceChainAllowlist(CCIPConfig.SEPOLIA_CHAIN_SELECTOR, true);
        console.log("Sepolia chain selector allowlisted:", CCIPConfig.SEPOLIA_CHAIN_SELECTOR);

        vm.stopBroadcast();

        console.log("");
        console.log("NOTE: After deploying the Sender on Sepolia, run:");
        console.log("  receiver.setSenderAllowlist(SEPOLIA_CHAIN_SELECTOR, <SENDER_ADDRESS>, true)");
    }
}

// ──────────────────────────────────────────────────
//  Post-Deploy: Allowlist Sender on Receiver
// ──────────────────────────────────────────────────

/// @title AllowlistSender
/// @notice Adds the deployed Sender contract address to the Receiver's sender allowlist.
/// @dev Run on Fuji after both contracts are deployed.
///
/// Usage:
///   SENDER_ADDRESS=0x... RECEIVER_ADDRESS=0x... \
///   forge script script/Deploy.s.sol:AllowlistSender \
///     --rpc-url $FUJI_RPC_URL --broadcast -vvvv
contract AllowlistSender is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address senderAddress = vm.envAddress("SENDER_ADDRESS");
        address receiverAddress = vm.envAddress("RECEIVER_ADDRESS");

        console.log("=== Allowlisting Sender on Receiver ===");
        console.log("Receiver:", receiverAddress);
        console.log("Sender:  ", senderAddress);

        vm.startBroadcast(deployerKey);

        CCIPTokenReceiver receiver = CCIPTokenReceiver(receiverAddress);
        receiver.setSenderAllowlist(CCIPConfig.SEPOLIA_CHAIN_SELECTOR, senderAddress, true);

        console.log("Sender allowlisted on Receiver for Sepolia chain selector.");

        vm.stopBroadcast();
    }
}

// ──────────────────────────────────────────────────
//  Helper: Send Tokens (for testing)
// ──────────────────────────────────────────────────

/// @title SendTokens
/// @notice Sends CCIP-BnM tokens from Sepolia to Fuji via the deployed Sender contract.
/// @dev Run on Sepolia.
///
/// Usage:
///   SENDER_ADDRESS=0x... RECEIVER_ADDRESS=0x... AMOUNT=1000000000000000000 \
///   forge script script/Deploy.s.sol:SendTokens \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv --value 0.1ether
contract SendTokens is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address senderAddress = vm.envAddress("SENDER_ADDRESS");
        address receiverAddress = vm.envAddress("RECEIVER_ADDRESS");
        uint256 amount = vm.envUint("AMOUNT");

        console.log("=== Sending Tokens via CCIP ===");
        console.log("Sender contract:", senderAddress);
        console.log("Receiver:       ", receiverAddress);
        console.log("Token:          ", CCIPConfig.SEPOLIA_CCIP_BNM);
        console.log("Amount:         ", amount);

        vm.startBroadcast(deployerKey);

        // Approve the Sender contract to pull tokens
        IERC20Minimal(CCIPConfig.SEPOLIA_CCIP_BNM).approve(senderAddress, amount);

        // Send tokens cross-chain
        CCIPTokenSender sender = CCIPTokenSender(payable(senderAddress));
        bytes32 messageId = sender.sendTokens{value: 0.1 ether}(
            CCIPConfig.FUJI_CHAIN_SELECTOR,
            receiverAddress,
            CCIPConfig.SEPOLIA_CCIP_BNM,
            amount,
            200_000 // gas limit on destination
        );

        console.log("Message sent! messageId:");
        console.logBytes32(messageId);
        console.log("Track at: https://ccip.chain.link/msg/", vm.toString(messageId));

        vm.stopBroadcast();
    }
}

/// @dev Minimal ERC20 interface for the deployment script.
interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
}
