// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDualPool {
    /// @notice Emitted on a swap between the two ERC4626 vaults
    event Swap(
        address indexed sender,
        address indexed recipient,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        uint160 sqrtPriceX96After,
        uint256 liquidityAfter
    );

    /// @notice Emitted when liquidity is added proportionally across both pools
    event AddLiquidity(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        uint256 shares0,
        uint256 shares1,
        uint256 lpTokensMinted
    );

    /// @notice Emitted when liquidity is removed
    event RemoveLiquidity(
        address indexed sender,
        uint256 shares0Burned,
        uint256 shares1Burned,
        uint256 amount0Out,
        uint256 amount1Out
    );

    /// @notice The two underlying ERC4626 vaults that form the dual pool
    function vault0() external view returns (address);
    function vault1() external view returns (address);

    /// @notice Underlying assets of vault0 / vault1
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice Current sqrt price in Q64.96 format
    function sqrtPriceX96() external view returns (uint160);

    /// @notice Total LP shares
    function totalSupply() external view returns (uint256);

    function addLiquidity(uint256 amount0Max, uint256 amount1Max, uint256 amount0Min, uint256 amount1Min, address to)
        external
        returns (uint256 amount0Used, uint256 amount1Used, uint256 lpMinted);

    function removeLiquidity(uint256 lpShares, uint256 amount0Min, uint256 amount1Min, address to)
        external
        returns (uint256 amount0Out, uint256 amount1Out);

    function swap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}
