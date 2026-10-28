// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC8004 — AI Agent Payment Standard
 * @notice Interface for trust-minimized on-chain payments between AI agents
 *         and service providers.
 *
 * ERC-8004 specifies:
 *   - A `pay` flow where an agent (or its owner) attaches a signed policy
 *     (PaymentIntent) authorizing payment for a specific service invocation.
 *   - A standardized `PaymentPolicy` that encodes per-service rate limits,
 *     token allowances, and spend ceilings, similar to ERC-20 allowances
 *     but with time/usage-gated semantics tailored to AI agents.
 *   - A universal hook `onPaymentSettled` that lets agent wallets/tool
 *     registries react to payments (telemetry, billing, refunds).
 */
interface IERC8004 {
    // -----------------------------------------------------------------
    // TYPES
    // -----------------------------------------------------------------

    /// @notice A reusable policy an agent owner sets on-chain
    /// @param agent        The AI agent address (smart account / EOA)
    /// @param token        ERC-20 token the agent is allowed to spend (address(0) = native)
    /// @param spender      The service provider / tool contract allowed to pull funds
    /// @param maxAmount    Lifetime spend cap under this policy
    /// @param spent        Cumulative amount already settled
    /// @param perCallMax   Maximum amount the spender can pull per single call
    /// @param validAfter   Unix timestamp — policy not valid before
    /// @param validBefore  Unix timestamp — policy not valid after
    /// @param nonce        Replay protection nonce
    struct PaymentPolicy {
        address agent;
        address token;
        address spender;
        uint256 maxAmount;
        uint256 spent;
        uint256 perCallMax;
        uint64  validAfter;
        uint64  validBefore;
        uint256 nonce;
    }

    /// @notice An off-chain signed intent that accompanies a one-off payment
    struct PaymentIntent {
        address agent;
        address token;
        address spender;
        uint256 amount;
        bytes32 serviceId;   // e.g. keccak256("openai:gpt-4o-mini")
        bytes32 requestHash; // hash of the request payload for non-repudiation
        uint64  validAfter;
        uint64  validBefore;
        uint256 nonce;
    }

    // -----------------------------------------------------------------
    // EVENTS
    // -----------------------------------------------------------------

    event PolicyCreated(bytes32 indexed policyId, address indexed agent, address indexed spender, address token, uint256 maxAmount);
    event PolicyRevoked(bytes32 indexed policyId);
    event PaymentSettled(bytes32 indexed policyId, address indexed agent, address indexed spender, address token, uint256 amount, bytes32 serviceId, bytes32 requestHash);

    // -----------------------------------------------------------------
    // WRITE
    // -----------------------------------------------------------------

    /// @notice Register a reusable payment policy
    function setPolicy(PaymentPolicy calldata p) external returns (bytes32 policyId);

    /// @notice Revoke a previously set policy
    function revokePolicy(bytes32 policyId) external;

    /// @notice Called by a service provider to pull a payment under an existing policy
    function chargePolicy(bytes32 policyId, uint256 amount, bytes32 serviceId, bytes32 requestHash) external returns (bool);

    /// @notice Charge via a one-off signed PaymentIntent (meta-tx style)
    function chargeIntent(PaymentIntent calldata intent, bytes calldata signature) external returns (bool);

    // -----------------------------------------------------------------
    // READ
    // -----------------------------------------------------------------

    function getPolicy(bytes32 policyId) external view returns (PaymentPolicy memory);
    function nonceUsed(uint256 nonce) external view returns (bool);
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    // -----------------------------------------------------------------
    // HOOK
    // -----------------------------------------------------------------

    /// @notice Called on the agent's smart account (if it implements IERC8004Receiver)
    ///         after a successful settlement — agent can emit telemetry or reject.
    function onPaymentSettled(bytes32 policyId, address token, uint256 amount, bytes32 serviceId) external returns (bytes4);
}

interface IERC8004Receiver {
    function onPaymentSettled(bytes32 policyId, address token, uint256 amount, bytes32 serviceId) external returns (bytes4);
}
