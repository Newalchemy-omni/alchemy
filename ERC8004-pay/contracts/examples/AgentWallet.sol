// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC8004Receiver} from "../interfaces/IERC8004.sol";

/**
 * @title AgentWallet — minimal smart account for an AI agent that can:
 *        - hold ERC-20 and native balances
 *        - execute arbitrary calls on behalf of the owner
 *        - auto-approve tokens to ERC8004
 *        - emit telemetry on every payment via IERC8004Receiver hook
 */
contract AgentWallet is Ownable, IERC8004Receiver {
    using SafeERC20 for IERC20;

    event Telemetry(bytes32 indexed policyId, address token, uint256 amount, bytes32 serviceId);

    constructor(address owner_) Ownable(owner_) {}

    receive() external payable {}

    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (bytes memory ret)
    {
        (bool ok, bytes memory r) = target.call{value: value}(data);
        require(ok, "CALL_FAIL");
        return r;
    }

    function approveToken(address token, address spender, uint256 amount) external onlyOwner {
        IERC20(token).forceApprove(spender, amount);
    }

    function onPaymentSettled(bytes32 policyId, address token, uint256 amount, bytes32 serviceId)
        external
        override
        returns (bytes4)
    {
        // emit telemetry — in production this could stream to an agent's observability stack
        emit Telemetry(policyId, token, amount, serviceId);
        return IERC8004Receiver.onPaymentSettled.selector;
    }
}
