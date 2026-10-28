# ERC-8004 — AI Agent Payment Standard

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-363636?logo=solidity)](https://docs.soliditylang.org/)
[![EIP: Draft](https://img.shields.io/badge/EIP-Draft-yellow)](https://eips.ethereum.org/)

> A standard interface for trust-minimized on-chain payments between AI agents and service providers (tool calls, model inference, API access).

## Abstract

AI agents running on-chain (or signing on behalf of users) need a predictable way to pay
for services — tool calls, inference, oracle queries, cross-chain actions, etc. — without
handing providers unlimited allowances. ERC-8004 defines two complementary mechanisms:

1. **PaymentPolicy** — a reusable, on-chain allowlist mapping `(agent, spender, token)` to
   a spend cap, per-call limit, and validity window. Service providers call `chargePolicy`
   to pull payment incrementally.
2. **PaymentIntent** — a one-off EIP-712 signed message authorizing a specific payment for
   a specific `(serviceId, requestHash)`. Usable out of the box without prior on-chain setup.

Both paths emit `PaymentSettled` events and call the optional `onPaymentSettled` hook on the
agent's smart account (if implemented), so agents can stream telemetry, enforce budgets,
or trigger refunds.

## Repository layout

```
contracts/
├── interfaces/IERC8004.sol      # the EIP interface
├── ERC8004.sol                  # registry + settlement logic
└── examples/
    └── AgentWallet.sol          # minimal smart-account example
test/ERC8004.t.sol               # Foundry tests
```

## Install / Build

```bash
forge install
forge build
forge test -vvv
```

## Quick start

```solidity
ERC8004 pay = ERC8004(DEPLOYED_ADDR);

// 1) Register a persistent policy (by agent owner)
pay.setPolicy(IERC8004.PaymentPolicy({
    agent: address(myAgentWallet),
    token: USDC,
    spender: openaiRouter,
    maxAmount: 1_000e6,
    spent: 0,
    perCallMax: 5e6,
    validAfter: uint64(block.timestamp),
    validBefore: uint64(block.timestamp + 30 days),
    nonce: 1
}));

// 2) Provider charges after serving a request
pay.chargePolicy(policyId, 0.01e6, keccak256("openai:gpt-4o-mini"), requestHash);
```

For one-off flows: the agent signs a `PaymentIntent` off-chain and hands it to the
provider, who calls `chargeIntent(intent, signature)` on-chain.

## Tags / metadata

- `erc8004`
- `ai-agent`
- `payment`
- `agent-wallet`
- `eip`
- `llm`
- `web3`

## License

MIT.
