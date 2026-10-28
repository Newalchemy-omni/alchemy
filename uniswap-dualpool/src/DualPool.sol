// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {IDualPool} from "./interfaces/IDualPool.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";

/**
 * @title DualPool — Uniswap-style dual ERC4626 Vault AMM
 * @author Uniswap Labs (reference implementation, extended with ERC4626)
 *
 * @notice DualPool couples two ERC-4626 yield-bearing vaults into a single
 *         constant-product swap pool. LPs supply proportional amounts of the
 *         two underlying assets; the contract auto-deposits them into their
 *         respective ERC4626 vaults and issues LP tokens. Yield from both
 *         vaults accrues pro-rata to LPs. Swaps happen against the
 *         *underlying* assets using a concentrated-liquidity-style sqrt-price
 *         curve (subset of Uniswap V3), and the pool rebalances its vault
 *         holdings after each swap.
 *
 *         This repository is a reference / educational implementation
 *         inspired by Uniswap V3 + Spark Protocol's dual-pool discussion.
 */
contract DualPool is ERC20, IDualPool, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;      // ≈ 1/2^128
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    address public immutable override vault0;
    address public immutable override vault1;
    address public immutable override token0;
    address public immutable override token1;

    uint160 public override sqrtPriceX96;
    uint256 public liquidity; // active virtual liquidity in Q96

    /// @dev The LP "fee" in hundredths of a bip (1e-6). Default 0.3% = 3000.
    uint24 public immutable fee;

    constructor(
        address _vault0,
        address _vault1,
        uint24 _fee,
        uint160 _initialSqrtPriceX96,
        string memory _lpName,
        string memory _lpSymbol
    ) ERC20(_lpName, _lpSymbol) {
        require(_vault0 != address(0) && _vault1 != address(0), "ZERO_ADDR");
        require(_initialSqrtPriceX96 >= MIN_SQRT_RATIO && _initialSqrtPriceX96 < MAX_SQRT_RATIO, "BAD_PRICE");
        vault0 = _vault0;
        vault1 = _vault1;
        fee = _fee;
        sqrtPriceX96 = _initialSqrtPriceX96;
        token0 = IERC4626(_vault0).asset();
        token1 = IERC4626(_vault1).asset();
    }

    // ============================================================
    // LIQUIDITY
    // ============================================================

    /// @inheritdoc IDualPool
    function addLiquidity(
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external override nonReentrant returns (uint256 amount0Used, uint256 amount1Used, uint256 lpMinted) {
        require(amount0Max > 0 && amount1Max > 0, "ZERO_IN");

        // Compute proportional amounts from current price
        uint256 price = FixedPointMath.sqrtPriceX96ToPriceX96(sqrtPriceX96);
        // amount1 ≈ amount0 * price / Q96
        uint256 amount1Optimal = FixedPointMath.mulDiv(amount0Max, price, Q96);

        if (amount1Optimal <= amount1Max) {
            require(amount1Optimal >= amount1Min, "AMT1_MIN");
            amount0Used = amount0Max;
            amount1Used = amount1Optimal;
        } else {
            uint256 amount0Optimal = FixedPointMath.mulDiv(amount1Max, Q96, price);
            assert(amount0Optimal <= amount0Max);
            require(amount0Optimal >= amount0Min, "AMT0_MIN");
            amount0Used = amount0Optimal;
            amount1Used = amount1Max;
        }

        // Pull underlying tokens from sender, deposit into the two ERC4626 vaults
        IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0Used);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1Used);

        IERC20(token0).forceApprove(vault0, amount0Used);
        uint256 shares0 = IERC4626(vault0).deposit(amount0Used, address(this));
        IERC20(token1).forceApprove(vault1, amount1Used);
        uint256 shares1 = IERC4626(vault1).deposit(amount1Used, address(this));

        // LP minting: geometric mean of the two deposit values
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            lpMinted = FixedPointMath.mulDiv(amount0Used, amount1Used, 1);
            require(lpMinted > 0, "INSUFFICIENT_LIQ");
            // init liquidity
            liquidity = uint256(uint160(FixedPointMath.mulDiv(amount0Used, Q96, sqrtPriceX96)));
        } else {
            uint256 shares0Total = IERC4626(vault0).balanceOf(address(this));
            uint256 shares1Total = IERC4626(vault1).balanceOf(address(this));
            lpMinted = _min(
                (shares0 * _totalSupply) / (shares0Total - shares0),
                (shares1 * _totalSupply) / (shares1Total - shares1)
            );
            liquidity += lpMinted;
        }
        _mint(to, lpMinted);

        emit AddLiquidity(msg.sender, amount0Used, amount1Used, shares0, shares1, lpMinted);
    }

    /// @inheritdoc IDualPool
    function removeLiquidity(
        uint256 lpShares,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external override nonReentrant returns (uint256 amount0Out, uint256 amount1Out) {
        require(lpShares > 0, "ZERO_SHARES");
        uint256 _totalSupply = totalSupply();
        // Burn LP
        _burn(msg.sender, lpShares);
        liquidity = liquidity - _min(liquidity, lpShares);

        // Redeem proportional vault shares back to underlying
        uint256 shares0 = (IERC4626(vault0).balanceOf(address(this)) * lpShares) / _totalSupply;
        uint256 shares1 = (IERC4626(vault1).balanceOf(address(this)) * lpShares) / _totalSupply;

        amount0Out = IERC4626(vault0).redeem(shares0, to, address(this));
        amount1Out = IERC4626(vault1).redeem(shares1, to, address(this));

        require(amount0Out >= amount0Min && amount1Out >= amount1Min, "SLIPPAGE");
        emit RemoveLiquidity(msg.sender, shares0, shares1, amount0Out, amount1Out);
    }

    // ============================================================
    // SWAP
    // ============================================================

    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96After;
        int256 amount0;
        int256 amount1;
    }

    /// @inheritdoc IDualPool
    function swap(
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override nonReentrant returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, "ZERO_AMT");
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < sqrtPriceX96 && sqrtPriceLimitX96 > MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > sqrtPriceX96 && sqrtPriceLimitX96 < MAX_SQRT_RATIO,
            "BAD_LIMIT"
        );

        bool exactInput = amountSpecified > 0;
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: exactInput ? uint256(amountSpecified) : uint256(-amountSpecified),
            amountCalculated: 0,
            sqrtPriceX96After: sqrtPriceX96,
            amount0: 0,
            amount1: 0
        });

        // Single-step swap across current active liquidity (concentrated around current tick).
        // In a full V3 port this loop would cross ticks; we keep one tick for the reference impl.
        {
            uint160 sqrtPriceTargetX96 = zeroForOne ? sqrtPriceLimitX96 : MAX_SQRT_RATIO - 1;
            if (!zeroForOne) sqrtPriceTargetX96 = sqrtPriceLimitX96;

            // Compute how much the price moves given amountSpecified & L
            (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut) =
                _computeSwapStep(state.sqrtPriceX96After, sqrtPriceTargetX96, liquidity, state.amountSpecifiedRemaining, fee);

            state.sqrtPriceX96After = sqrtPriceNextX96;
            if (exactInput) {
                state.amountSpecifiedRemaining -= amountIn;
                state.amountCalculated += amountOut;
            } else {
                state.amountSpecifiedRemaining -= amountOut;
                state.amountCalculated += amountIn;
            }
        }

        sqrtPriceX96 = state.sqrtPriceX96After;

        if (zeroForOne) {
            if (exactInput) {
                state.amount0 = int256(uint256(amountSpecified));
                state.amount1 = -int256(state.amountCalculated);
            } else {
                state.amount0 = int256(state.amountCalculated);
                state.amount1 = int256(-uint256(amountSpecified));
            }
        } else {
            if (exactInput) {
                state.amount0 = -int256(state.amountCalculated);
                state.amount1 = int256(uint256(amountSpecified));
            } else {
                state.amount0 = -int256(-uint256(amountSpecified));
                state.amount1 = int256(state.amountCalculated);
            }
        }

        amount0 = state.amount0;
        amount1 = state.amount1;

        // Settle: pull input token, deposit into corresponding vault;
        // withdraw output asset from the other vault and send to recipient.
        _settleSwap(msg.sender, zeroForOne, amount0, amount1, data);

        emit Swap(msg.sender, msg.sender, zeroForOne,
            exactInput ? uint256(amountSpecified) : state.amountCalculated,
            exactInput ? state.amountCalculated : uint256(-amountSpecified),
            state.sqrtPriceX96After, liquidity);
    }

    function _settleSwap(
        address payer,
        bool zeroForOne,
        int256 amount0,
        int256 amount1,
        bytes calldata /*data*/
    ) internal {
        if (zeroForOne) {
            // exact in: token0 in, token1 out
            uint256 amtIn = amount0 > 0 ? uint256(amount0) : uint256(-amount1);
            uint256 amtOut = amount1 < 0 ? uint256(-amount1) : uint256(-amount0);
            IERC20(token0).safeTransferFrom(payer, address(this), amtIn);
            IERC20(token0).forceApprove(vault0, amtIn);
            IERC4626(vault0).deposit(amtIn, address(this));
            IERC4626(vault1).withdraw(amtOut, payer, address(this));
        } else {
            uint256 amtIn = amount1 > 0 ? uint256(amount1) : uint256(-amount0);
            uint256 amtOut = amount0 < 0 ? uint256(-amount0) : uint256(-amount1);
            IERC20(token1).safeTransferFrom(payer, address(this), amtIn);
            IERC20(token1).forceApprove(vault1, amtIn);
            IERC4626(vault1).deposit(amtIn, address(this));
            IERC4626(vault0).withdraw(amtOut, payer, address(this));
        }
    }

    // ============================================================
    // INTERNAL MATH
    // ============================================================

    function _computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint256 L,
        uint256 amountRemaining,
        uint24 _fee
    ) internal pure returns (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut) {
        bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;
        // First estimate amountIn to reach target
        uint256 amountInMax = zeroForOne
            ? FixedPointMath.mulDiv(L, (uint256(sqrtPriceCurrentX96) - sqrtPriceTargetX96) << 32,
                (uint256(sqrtPriceCurrentX96) * sqrtPriceTargetX96) >> 64) >> 32
            : FixedPointMath.mulDiv(L, uint256(sqrtPriceTargetX96) - sqrtPriceCurrentX96, Q96);

        // Simplified: apply fee on input and bound by target price
        uint256 feeAmount = (amountRemaining * _fee) / 1_000_000;
        uint256 amountInLessFee = amountRemaining - feeAmount;
        if (amountInLessFee >= amountInMax) {
            sqrtPriceNextX96 = sqrtPriceTargetX96;
            amountIn = amountInMax;
        } else {
            amountIn = amountInLessFee;
            // approximate new sqrt price by shifting proportionally
            uint256 delta = zeroForOne
                ? (amountIn * (uint256(sqrtPriceCurrentX96) * sqrtPriceCurrentX96 / Q96)) / L
                : (amountIn * Q96) / L;
            sqrtPriceNextX96 = zeroForOne
                ? uint160(uint256(sqrtPriceCurrentX96) - delta)
                : uint160(uint256(sqrtPriceCurrentX96) + delta);
        }
        amountOut = zeroForOne
            ? FixedPointMath.getAmount1(sqrtPriceNextX96 == sqrtPriceTargetX96 ? sqrtPriceCurrentX96 : sqrtPriceNextX96, amountIn)
            : FixedPointMath.getAmount0(sqrtPriceNextX96 == sqrtPriceTargetX96 ? sqrtPriceCurrentX96 : sqrtPriceNextX96, amountIn);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
