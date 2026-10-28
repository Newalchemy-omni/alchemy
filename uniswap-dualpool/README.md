# DualPool

> Uniswap-style AMM over two ERC-4626 yield-bearing vaults

[![License: GPL v2](https://img.shields.io/badge/License-GPLv2-blue.svg)](https://www.gnu.org/licenses/gpl-2.0)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-363636?logo=solidity)](https://docs.soliditylang.org/)
[![Built by Uniswap](https://img.shields.io/badge/Built%20by-Uniswap-FF007A?logo=uniswap)](https://uniswap.org/)

## Overview

DualPool is a reference implementation that pairs two [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626)
tokenized vaults into a single Uniswap-style AMM. When LPs deposit assets they are
automatically routed into the respective vaults, so liquidity earns yield *while* it
sits in the pool. Swaps happen against the underlying assets using a concentrated
sqrt-price curve derived from Uniswap V3.

The repo is designed as a developer-friendly minimal core:

- `src/ERC4626Vault.sol`       — canonical ERC-4626 vault used for testing/integration
- `src/DualPool.sol`           — core pool (LP token + swap + add/remove liquidity)
- `src/DualPoolFactory.sol`    — deterministic pool creation by `(vaultA, vaultB, fee)`
- `src/interfaces/IERC4626.sol`
- `src/interfaces/IDualPool.sol`
- `src/libraries/FixedPointMath.sol` — Q64.96 fixed-point math (subset of Uniswap V3)

## Quickstart (Foundry)

```bash
git clone https://github.com/uniswap/dualpool.git
cd dualpool
forge install
forge build
forge test -vvv
```

## Key Concepts

1. **Tokenized Vaults.** Both sides of the pair are ERC-4626 vaults rather than bare ERC-20s.
   Each side earns yield (e.g. from Aave, Spark, Compound, Lido).
2. **Proportional liquidity.** LPs deposit assets in the ratio dictated by the current
   `sqrtPriceX96`; excess on one side is rejected with a slippage check.
3. **Auto-compounding.** Vault shares are held by the pool contract; yield accrues to
   all LPs pro-rata because LP tokens represent a claim on the pool's vault shares.
4. **Swaps use the underlying.** During a swap the pool pulls the input asset, deposits
   it into the incoming vault, then withdraws the output asset from the other vault and
   forwards it to the caller.

## Deploying a pool

```solidity
DualPoolFactory f = DualPoolFactory(DEPLOYED_FACTORY);
address pool = f.createPool(
    address(vaultUSDC),   // vaultA
    address(vaultWETH),   // vaultB
    3000,                 // fee tier (0.30%)
    79228162514264337593543950336  // initial sqrtPriceX96 → price = 1.0 in Q96
);
```

## Tags / Metadata

- `uniswap`
- `erc4626`
- `amm`
- `yield`
- `spark`
- `concentrated-liquidity`

## License

GPL-2.0-or-later — same as Uniswap V3.
