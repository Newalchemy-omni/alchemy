// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {DualPool} from "./DualPool.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";

/**
 * @title DualPoolFactory
 * @notice Creates DualPool pairs deterministically from (vaultA, vaultB, fee)
 * @dev Mirrors Uniswap V3's UniswapV3Factory pattern for developer familiarity
 */
contract DualPoolFactory {
    /// @dev fee tier → tick spacing (simplified: single tick spacing per fee)
    mapping(uint24 => int24) public feeTickSpacing;

    /// @dev (vault0, vault1, fee) → pool
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    address[] public allPools;

    event PoolCreated(
        address indexed vault0, address indexed vault1, uint24 fee, address pool, uint256 poolIndex
    );

    constructor() {
        feeTickSpacing[500]   = 10;  // 0.05%
        feeTickSpacing[3000]  = 60;  // 0.30%
        feeTickSpacing[10000] = 200; // 1.00%
    }

    function createPool(address vaultA, address vaultB, uint24 fee, uint160 initialSqrtPriceX96)
        external
        returns (address pool)
    {
        require(vaultA != vaultB, "SAME_VAULT");
        require(feeTickSpacing[fee] != 0, "FEE_NOT_ENABLED");
        (address v0, address v1) = vaultA < vaultB ? (vaultA, vaultB) : (vaultB, vaultA);
        require(getPool[v0][v1][fee] == address(0), "POOL_EXISTS");

        // Preflight: make sure vaults are ERC4626 by probing .asset()
        address a0 = IERC4626(v0).asset();
        address a1 = IERC4626(v1).asset();
        require(a0 != address(0) && a1 != address(0), "BAD_VAULT");

        string memory name = string(abi.encodePacked("DualPool-LP"));
        string memory sym  = string(abi.encodePacked("DP-", _sym(v0), "-", _sym(v1)));

        pool = address(new DualPool(v0, v1, fee, initialSqrtPriceX96, name, sym));
        getPool[v0][v1][fee] = pool;
        getPool[v1][v0][fee] = pool;
        allPools.push(pool);
        emit PoolCreated(v0, v1, fee, pool, allPools.length - 1);
    }

    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    function _sym(address v) internal view returns (string memory) {
        try IERC4626(v).symbol() returns (string memory s) { return s; } catch { return "?"; }
    }
}
