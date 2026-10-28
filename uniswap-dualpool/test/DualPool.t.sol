// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626Vault} from "../src/ERC4626Vault.sol";
import {DualPoolFactory} from "../src/DualPoolFactory.sol";
import {DualPool} from "../src/DualPool.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract DualPoolTest is Test {
    MockERC20 tokenA;
    MockERC20 tokenB;
    ERC4626Vault vaultA;
    ERC4626Vault vaultB;
    DualPoolFactory factory;
    DualPool pool;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    function setUp() public {
        tokenA = new MockERC20("USD Coin", "USDC");
        tokenB = new MockERC20("Wrapped Ether", "WETH");
        vaultA = new ERC4626Vault(tokenA, "vUSDC", "vUSDC");
        vaultB = new ERC4626Vault(tokenB, "vWETH", "vWETH");

        factory = new DualPoolFactory();

        // initial price: 1 WETH = 2000 USDC → sqrtPriceX96 ≈ sqrt(2000 * 2^96) ≈ 1254421006516994040646927079777
        uint160 initSqrt = uint160(FixedPointSqrt.sqrt(2000e6 * 1e12) * (1 << 48)); // rough for test
        // Simpler: pick a well-known value — 1:2000 ratio in 6-decimal vs 18-decimal
        // We'll just use 1:1 for testing addLiquidity/remove sanity
        initSqrt = 79228162514264337593543950336; // = 2^96 → price = 1.0 in Q96

        pool = DualPool(factory.createPool(address(vaultA), address(vaultB), 3000, initSqrt));

        tokenA.mint(alice, 1_000_000e6);
        tokenB.mint(alice, 1_000_000e18);
        tokenA.mint(bob,   100_000e6);
        tokenB.mint(bob,   100_000e18);

        vm.startPrank(alice);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(100_000e6, 100_000e18, 0, 0, alice);
        vm.stopPrank();
    }

    function testInitialLiquidity() public view {
        assertTrue(pool.totalSupply() > 0, "LP minted");
        assertEq(pool.vault0(), address(vaultA));
        assertEq(pool.vault1(), address(vaultB));
    }

    function testRemoveLiquidity() public {
        vm.startPrank(alice);
        uint256 lpBal = pool.balanceOf(alice);
        uint256 beforeA = tokenA.balanceOf(alice);
        uint256 beforeB = tokenB.balanceOf(alice);
        pool.removeLiquidity(lpBal / 2, 0, 0, alice);
        assertTrue(tokenA.balanceOf(alice) > beforeA, "got back A");
        assertTrue(tokenB.balanceOf(alice) > beforeB, "got back B");
        vm.stopPrank();
    }
}

library FixedPointSqrt {
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = x / 2 + 1;
        while (y < z) { z = y; y = (x / y + y) / 2; }
    }
}
