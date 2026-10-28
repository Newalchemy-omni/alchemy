// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FixedPointMath – minimal sqrt/price math for DualPool
/// @notice Implements 512-bit multiplication and Q64.96 fixed-point sqrt price math
///         (subset of Uniswap V3's SqrtPriceMath / FullMath / FixedPoint96)
library FixedPointMath {
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2^96

    /// @dev Returns floor(a*b / denominator), reverting if denominator == 0 or overflow.
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        require(denominator > 0, "div by 0");
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (prod1 == 0) {
            require(prod0 < type(uint256).max, "overflow");
            return prod0 / denominator;
        }
        require(prod1 < denominator, "overflow");
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }
        uint256 twos = denominator & (~denominator + 1);
        assembly {
            denominator := div(denominator, twos)
            prod0 := div(prod0, twos)
            twos := add(div(sub(0, twos), twos), 1)
        }
        prod0 |= prod1 * twos;
        uint256 inv = (3 * denominator) ^ 2;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        result = prod0 * inv;
    }

    /// @notice priceX96 = sqrtPriceX96^2 / 2^96
    function sqrtPriceX96ToPriceX96(uint160 sqrtPriceX96) internal pure returns (uint256 priceX96) {
        priceX96 = mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q96);
    }

    /// @notice Given reserves of asset1 and sqrtPrice, compute reserve of asset0
    function getAmount0(uint160 sqrtPriceX96, uint256 amount1, bool roundUp) internal pure returns (uint256 amount0) {
        // amount0 = amount1 * Q96 / sqrtPrice^2  → using mulDiv
        uint256 price = sqrtPriceX96ToPriceX96(sqrtPriceX96);
        if (roundUp) {
            amount0 = mulDiv(amount1, Q96, price) + (mulmod(amount1, Q96, price) == 0 ? 0 : 1);
        } else {
            amount0 = mulDiv(amount1, Q96, price);
        }
    }

    /// @notice Given reserves of asset0 and sqrtPrice, compute reserve of asset1
    function getAmount1(uint160 sqrtPriceX96, uint256 amount0) internal pure returns (uint256 amount1) {
        // amount1 = amount0 * sqrtPrice^2 / Q96
        uint256 price = sqrtPriceX96ToPriceX96(sqrtPriceX96);
        amount1 = mulDiv(amount0, price, Q96);
    }
}
