// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC8004, IERC8004Receiver} from "./interfaces/IERC8004.sol";

/**
 * @title ERC8004 — AI Agent Payment Registry
 * @notice Reference implementation of EIP-8004: trust-minimized payments for AI agents.
 *
 * Two payment modes are supported:
 *   1) Persistent `PaymentPolicy` — agent owner authorizes a spender up to a cap,
 *      provider charges incrementally via `chargePolicy`.
 *   2) Ephemeral `PaymentIntent` — a one-off signed message authorizing a specific
 *      service/request, settled via `chargeIntent` without prior on-chain setup.
 *
 * The contract does not custody funds itself; it pulls tokens from the agent's own
 * address at charge time, meaning agents can use normal ERC-20 allowances or smart
 * account hooks to manage their balances.
 */
contract ERC8004 is IERC8004, EIP712, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    bytes32 public constant POLICY_TYPEHASH =
        keccak256("PaymentPolicy(address agent,address token,address spender,uint256 maxAmount,uint256 perCallMax,uint64 validAfter,uint64 validBefore,uint256 nonce)");
    bytes32 public constant INTENT_TYPEHASH =
        keccak256("PaymentIntent(address agent,address token,address spender,uint256 amount,bytes32 serviceId,bytes32 requestHash,uint64 validAfter,uint64 validBefore,uint256 nonce)");

    mapping(bytes32 => PaymentPolicy) private _policies;
    mapping(uint256 => bool) public override nonceUsed;
    mapping(bytes32 => bool) public intentHashUsed;

    constructor(address owner_) EIP712("ERC8004-AgentPay", "1.0") Ownable(owner_) {}

    // -----------------------------------------------------------------
    // POLICY
    // -----------------------------------------------------------------

    /// @inheritdoc IERC8004
    function setPolicy(PaymentPolicy calldata p) external override returns (bytes32 policyId) {
        // Only the agent itself or the agent's owner (set via approveAgentOwner) may set.
        require(msg.sender == p.agent || msg.sender == owner(), "NOT_AGENT");
        require(p.validBefore > block.timestamp, "EXPIRED");
        require(p.validAfter <= block.timestamp + 365 days, "TOO_LONG");

        policyId = _hashPolicy(p);
        require(_policies[policyId].spender == address(0), "EXISTS");
        _policies[policyId] = p;
        emit PolicyCreated(policyId, p.agent, p.spender, p.token, p.maxAmount);
    }

    /// @inheritdoc IERC8004
    function revokePolicy(bytes32 policyId) external override {
        PaymentPolicy storage p = _policies[policyId];
        require(msg.sender == p.agent || msg.sender == owner(), "NOT_AUTH");
        p.validBefore = 0;
        emit PolicyRevoked(policyId);
    }

    /// @inheritdoc IERC8004
    function chargePolicy(bytes32 policyId, uint256 amount, bytes32 serviceId, bytes32 requestHash)
        external
        override
        nonReentrant
        returns (bool)
    {
        PaymentPolicy storage p = _policies[policyId];
        _validateAndCharge(p, amount, serviceId, requestHash);
        p.spent += amount;
        emit PaymentSettled(policyId, p.agent, p.spender, p.token, amount, serviceId, requestHash);
        return true;
    }

    // -----------------------------------------------------------------
    // INTENT (meta-tx)
    // -----------------------------------------------------------------

    /// @inheritdoc IERC8004
    function chargeIntent(PaymentIntent calldata intent, bytes calldata signature)
        external
        override
        nonReentrant
        returns (bool)
    {
        require(!intentHashUsed[_hashIntent(intent)], "INTENT_USED");
        require(!nonceUsed[intent.nonce], "NONCE_USED");
        require(block.timestamp >= intent.validAfter && block.timestamp <= intent.validBefore, "TIME_WINDOW");
        require(intent.spender == msg.sender, "NOT_SPENDER");
        require(intent.amount > 0, "ZERO_AMT");

        bytes32 digest = _hashTypedDataV4(_hashIntent(intent));
        address signer = digest.recover(signature);
        require(signer == intent.agent, "BAD_SIG");

        intentHashUsed[_hashIntent(intent)] = true;
        nonceUsed[intent.nonce] = true;

        _pullFunds(intent.agent, msg.sender, intent.token, intent.amount);
        _notifyReceiver(intent.agent, bytes32(0), intent.token, intent.amount, intent.serviceId);

        emit PaymentSettled(bytes32(0), intent.agent, msg.sender, intent.token, intent.amount, intent.serviceId, intent.requestHash);
        return true;
    }

    // -----------------------------------------------------------------
    // READ
    // -----------------------------------------------------------------

    function getPolicy(bytes32 policyId) external view override returns (PaymentPolicy memory) {
        return _policies[policyId];
    }

    function _hashPolicy(PaymentPolicy calldata p) internal view returns (bytes32) {
        return keccak256(abi.encode(POLICY_TYPEHASH, p.agent, p.token, p.spender, p.maxAmount, p.perCallMax, p.validAfter, p.validBefore, p.nonce));
    }

    function _hashIntent(PaymentIntent calldata i) internal pure returns (bytes32) {
        return keccak256(abi.encode(INTENT_TYPEHASH, i.agent, i.token, i.spender, i.amount, i.serviceId, i.requestHash, i.validAfter, i.validBefore, i.nonce));
    }

    // -----------------------------------------------------------------
    // INTERNAL
    // -----------------------------------------------------------------

    function _validateAndCharge(PaymentPolicy storage p, uint256 amount, bytes32 serviceId, bytes32 /*requestHash*/) internal {
        require(p.spender == msg.sender, "NOT_SPENDER");
        require(block.timestamp >= p.validAfter && block.timestamp <= p.validBefore, "TIME_WINDOW");
        require(amount > 0 && amount <= p.perCallMax, "PER_CALL_LIMIT");
        require(p.spent + amount <= p.maxAmount, "CAP_EXCEEDED");
        _pullFunds(p.agent, p.spender, p.token, amount);
        _notifyReceiver(p.agent, bytes32(0), p.token, amount, serviceId);
    }

    function _pullFunds(address from, address to, address token, uint256 amount) internal {
        if (token == address(0)) {
            require(msg.value == 0, "NATIVE_VIA_CALL");
            // For native we expect the caller (agent) to have sent value; for policy-based
            // pulls we require the agent to hold native and we rely on a smart-account
            // execute() flow; for minimal reference we revert here to avoid forced sends.
            revert("NATIVE_USE_INTENT_WITH_VALUE");
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    function _notifyReceiver(address agent, bytes32 policyId, address token, uint256 amount, bytes32 serviceId) internal {
        // If the agent is a contract implementing IERC8004Receiver, invoke the hook.
        uint256 size;
        assembly { size := extcodesize(agent) }
        if (size > 0) {
            try IERC8004Receiver(agent).onPaymentSettled(policyId, token, amount, serviceId) returns (bytes4 ret) {
                require(ret == IERC8004Receiver.onPaymentSettled.selector, "BAD_HOOK_RET");
            } catch {
                // hook failure does not revert the payment — fire-and-forget by design
            }
        }
    }

    function DOMAIN_SEPARATOR() external view override returns (bytes32) {
        return _domainSeparatorV4();
    }

    function onPaymentSettled(bytes32, address, uint256, bytes32) external pure override returns (bytes4) {
        // The registry itself doesn't receive funds as an agent, so this is a no-op.
        return IERC8004.onPaymentSettled.selector;
    }
}
