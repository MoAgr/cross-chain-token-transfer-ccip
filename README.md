# Cross-Chain Token Transfer (Chainlink CCIP)

A production-quality Foundry project demonstrating cross-chain ERC-20 token transfers using **Chainlink CCIP (Cross-Chain Interoperability Protocol)**.

Transfers flow from **Ethereum Sepolia** (source) → **Avalanche Fuji** (destination).

---

## Architecture

```
 Sepolia                                          Fuji
┌──────────────────────┐                    ┌───────────────────────┐
│   CCIPTokenSender    │   CCIP Message     │   CCIPTokenReceiver   │
│                      │ ─────────────────► │                       │
│ • sendTokens()       │                    │ • ccipReceive()       │
│ • Fee estimation     │                    │ • Defensive try/catch │
│ • Dest chain allow   │                    │ • Source chain allow   │
│ • Native fee payment │                    │ • Sender allowlist    │
│ • Token recovery     │                    │ • Replay protection   │
│                      │                    │ • Failed msg retry    │
│                      │                    │ • Token recovery      │
└──────────────────────┘                    └───────────────────────┘
```

### Sender (`CCIPTokenSender.sol`)

Deployed on the **source chain** (Sepolia). Accepts ERC-20 tokens from a user, constructs a CCIP message, estimates fees via `router.getFee()`, and dispatches the message via `router.ccipSend()`. Fees are paid in native currency (ETH).

**Key features:**

- Destination chain allowlist (owner-managed)
- Native fee payment with insufficient-fee revert
- Token and native currency recovery functions
- Custom errors and events for every state change

### Receiver (`CCIPTokenReceiver.sol`)

Deployed on the **destination chain** (Fuji). Implements `IAny2EVMMessageReceiver.ccipReceive()` with a defensive try/catch pattern.

**Key features:**

- `onlyRouter` modifier — only the CCIP Router can call `ccipReceive`
- Source chain allowlist (owner-managed)
- Sender address allowlist, per source chain (owner-managed)
- Replay protection — processed `messageId` tracking
- Reentrancy guard on all state-changing functions
- **Defensive pattern** — failures are caught, stored, and emitted as events. The top-level `ccipReceive` never reverts, preventing token loss
- `retryFailedMessage()` — owner can manually re-execute failed messages
- Token recovery for stuck or failed-message tokens

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- An EOA with:
  - Sepolia ETH (for deployment + CCIP fees) — [Sepolia Faucet](https://sepoliafaucet.com)
  - Fuji AVAX (for deployment) — [Fuji Faucet](https://faucets.chain.link/fuji)
  - CCIP-BnM test tokens on Sepolia — [CCIP Faucet](https://faucets.chain.link)

---

## Project Structure

```
├── src/
│   ├── Sender.sol          # CCIPTokenSender — source chain contract
│   └── Receiver.sol        # CCIPTokenReceiver — destination chain contract
├── script/
│   └── Deploy.s.sol        # Deployment & helper scripts
├── lib/
│   ├── ccip/               # Chainlink CCIP contracts
│   ├── openzeppelin-contracts/  # OpenZeppelin v5.2
│   └── forge-std/          # Forge standard library
├── foundry.toml            # Foundry configuration
└── README.md
```

---

## Setup

### 1. Clone & Install Dependencies

```bash
git clone <repo-url>
cd CrossChainTokenTransfer
forge install
```

### 2. Environment Variables

Create a `.env` file (do **not** commit this):

```bash
# Deployer wallet
PRIVATE_KEY=0x...
DEPLOYER_ADDRESS=0x...

# RPC endpoints
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc

# (Optional) Etherscan / Snowtrace API keys for verification
ETHERSCAN_API_KEY=...
SNOWTRACE_API_KEY=...
```

Load them:

```bash
source .env
```

---

## Deployment

### Step 1 — Deploy Receiver on Avalanche Fuji

```bash
forge script script/Deploy.s.sol:DeployReceiver \
  --rpc-url $FUJI_RPC_URL \
  --broadcast \
  -vvvv
```

Note the deployed `CCIPTokenReceiver` address.

### Step 2 — Deploy Sender on Ethereum Sepolia

```bash
forge script script/Deploy.s.sol:DeploySender \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

Note the deployed `CCIPTokenSender` address.

### Step 3 — Allowlist the Sender on the Receiver

```bash
SENDER_ADDRESS=0x<sender-address> \
RECEIVER_ADDRESS=0x<receiver-address> \
forge script script/Deploy.s.sol:AllowlistSender \
  --rpc-url $FUJI_RPC_URL \
  --broadcast \
  -vvvv
```

---

## Sending a Test Transfer

### Option A — Using the helper script

```bash
SENDER_ADDRESS=0x<sender-address> \
RECEIVER_ADDRESS=0x<receiver-address> \
AMOUNT=1000000000000000000 \
forge script script/Deploy.s.sol:SendTokens \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

### Option B — Using `cast`

```bash
# 1. Approve the Sender contract to spend CCIP-BnM tokens
cast send 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
  "approve(address,uint256)" \
  $SENDER_ADDRESS 1000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# 2. Send tokens cross-chain (with 0.1 ETH for CCIP fees)
cast send $SENDER_ADDRESS \
  "sendTokens(uint64,address,address,uint256,uint256)" \
  14767482510784806043 \
  $RECEIVER_ADDRESS \
  0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
  1000000000000000000 \
  200000 \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 3. Track the Message

Copy the `messageId` from the transaction logs and track it at:

```
https://ccip.chain.link
```

Messages typically take **5–20 minutes** to finalize on the destination chain.

---

## Key Addresses (Testnet)

| Resource               | Network | Address                                      |
| ---------------------- | ------- | -------------------------------------------- |
| CCIP Router            | Sepolia | `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59` |
| CCIP Router            | Fuji    | `0xF694E193200268f9a4868e4Aa017A0118C9a8177` |
| CCIP-BnM Token         | Sepolia | `0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05` |
| CCIP-BnM Token         | Fuji    | `0xD21341536c5cF5EB1bcb58f6723cE26e8D8E90e4` |
| Sepolia Chain Selector | —       | `16015286601757825753`                       |
| Fuji Chain Selector    | —       | `14767482510784806043`                       |

---

## Security Considerations

- **Allowlists** — Both contracts restrict interactions to pre-approved chains and addresses. Always verify allowlist entries before sending real value.
- **Defensive Receiver** — `ccipReceive` never reverts at the top level. Failed messages are stored and can be retried by the owner, preventing permanent token loss.
- **Replay Protection** — Each `messageId` can only be processed once.
- **Reentrancy** — The Receiver uses OpenZeppelin's `ReentrancyGuard` on all state-changing functions.
- **Token Recovery** — Both contracts expose owner-only `withdrawToken` functions to recover mistakenly sent tokens.
- **No Hardcoded Secrets** — All chain-specific values are passed via constructor or set post-deployment.

---

## Build & Test

```bash
# Compile
forge build

# Run tests (if you add tests in test/)
forge test -vvv

# Gas report
forge test --gas-report

# Create gas baseline snapshot
forge snapshot

# Compare gas against the stored snapshot after changes
forge snapshot --diff
```

Gas audit baseline and workflow details are documented in `GAS_AUDIT.md`.

---

## License

MIT
