# Gas Audit Baseline (Foundry + Local CCIP)

## Scope

This baseline uses:

- Foundry tests and snapshots
- Chainlink local simulator and mock router execution path
- Local `MsgExecuted(bool success, bytes retData, uint256 gasUsed)` data for destination execution

No Hardhat gas reporter or Tenderly was used in this pass.

## Baseline Snapshot

The current baseline is stored in `.gas-snapshot`.

Generated with:

```bash
forge snapshot
```

## Key Baseline Observations

### Receiver-focused

- `test_gasAudit_routedPaths_under3M_with20PctBuffer`: `779210`
- `test_retryFailedMessage_succeedsAndTransfersTokens`: `2811288`
- `test_retryFailedMessage_multiToken_transfersAllAmountsInLoop`: `2832975`
- `test_retryFailedMessage_idempotency_revertsAfterCleanup`: `2807536`
- `test_ccipReceive_replayProtection_blocksDuplicateFailedMessageId`: `2962651`

Interpretation:

- Worst observed receiver-heavy paths are below the 3,000,000 gas envelope.
- Retry and replay-heavy tests are the dominant high-gas paths and should be treated as optimization hotspots.

### Sender-focused

- `test_gasAudit_sendTokens_mutableGasLimitBuckets`: `605184`
- `test_send_revertsIfRefundFails`: `636704`
- `test_send_reentrancyGuard_blocksMaliciousTokenReentry`: `1404902`
- `test_send_revertsIfChainNotSupportedByRouter`: `2405785`

Interpretation:

- Typical send paths are moderate.
- Specialized adversarial or unsupported-router paths are expectedly expensive and should be excluded from strict production-path budgets.

## Current Guardrails in Tests

Receiver gas audit tests now assert:

- destination execution remains below `3_000_000` gas
- recommended destination gasLimit uses `20%` headroom over observed peak

Sender gas audit tests now assert:

- destination execution is observable through `MsgExecuted`
- execution remains below `3_000_000` gas across gasLimit buckets (`0`, `300000`, `500000`)
- gasLimit is externally controllable (not hardcoded in API usage)

## Repeatable Workflow

1. Run baseline snapshot:

```bash
forge snapshot
```

2. After changes, run diff:

```bash
forge snapshot --diff
```

3. Run focused suites for quick verification:

```bash
forge test --match-path "test/CCIPToken*.t.sol" -vv
```

## Suggested Regression Policy

Use these review gates for production paths:

- investigate any increase greater than `5%` on core send/receive success-path tests
- investigate any increase greater than `10%` on retry/replay handling paths
- fail review if receiver worst-case path exceeds `3_000_000` gas

## Prioritized Optimization Backlog (No Refactors Applied Yet)

1. Receiver retry path micro-optimizations

- focus: storage reads/writes and loop body in `retryFailedMessage`
- expected impact: high

2. Receiver failed-message storage path

- focus: minimize repeated storage writes and dynamic array handling overhead
- expected impact: medium-high

3. Sender message build and fee/refund path

- focus: reduce redundant memory work and repeated state reads
- expected impact: medium

4. Event and accounting overhead review

- focus: ensure emissions and checks are minimal for hot paths
- expected impact: low-medium

## Notes

- This document is a baseline and should be updated after each optimization pass.
- Use `forge snapshot --diff` output as the source of truth for delta reporting.
