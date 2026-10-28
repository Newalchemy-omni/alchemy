// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC8004} from "../contracts/ERC8004.sol";
import {IERC8004} from "../contracts/interfaces/IERC8004.sol";
import {AgentWallet} from "../contracts/examples/AgentWallet.sol";

contract Tkn is ERC20 {
    constructor() ERC20("Test", "TST") { _mint(msg.sender, 1e6 * 1e18); }
}

contract ERC8004Test is Test {
    Tkn token;
    ERC8004 pay;
    AgentWallet agent;
    address provider = address(0xDEAD);
    uint256 agentOwnerKey = 0xBEEF;
    address agentOwner;

    function setUp() public {
        agentOwner = vm.addr(agentOwnerKey);
        token = new Tkn();
        pay = new ERC8004(address(this));
        agent = new AgentWallet(agentOwner);
        token.transfer(address(agent), 10_000e18);

        vm.prank(agentOwner);
        agent.approveToken(address(token), address(pay), type(uint256).max);
    }

    function testPolicyCharge() public {
        IERC8004.PaymentPolicy memory p = IERC8004.PaymentPolicy({
            agent: address(agent),
            token: address(token),
            spender: provider,
            maxAmount: 1000e18,
            spent: 0,
            perCallMax: 10e18,
            validAfter: uint64(block.timestamp - 1),
            validBefore: uint64(block.timestamp + 1 days),
            nonce: 1
        });
        // agent owner sets the policy via the registry owner (this contract)
        bytes32 pid = pay.setPolicy(p);
        assertTrue(pid != bytes32(0));

        uint256 balBefore = token.balanceOf(provider);
        vm.prank(provider);
        pay.chargePolicy(pid, 5e18, keccak256("openai:gpt-4o-mini"), bytes32(0));
        assertEq(token.balanceOf(provider), balBefore + 5e18);
    }
}
