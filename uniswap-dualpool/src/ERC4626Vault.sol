// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";

/**
 * @title ERC4626Vault
 * @notice Minimal ERC-4626 Tokenized Vault for use as vault0 / vault1 in DualPool
 * @dev 1:1 share:asset ratio by default — acts as a pass-through vault so tests / integrations
 *      can verify deposit/mint/withdraw/redeem semantics without a live yield source.
 *      Override `totalAssets()` and add yield-harvesting hooks to connect a live strategy.
 */
contract ERC4626Vault is ERC20, IERC4626 {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;

    constructor(IERC20 _asset, string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        underlying = _asset;
    }

    function asset() external view override returns (address) { return address(underlying); }

    function totalAssets() public view virtual override returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view virtual override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view virtual override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }

    function maxDeposit(address) external pure override returns (uint256) { return type(uint256).max; }
    function maxMint(address) external pure override returns (uint256) { return type(uint256).max; }
    function maxWithdraw(address owner) external view override returns (uint256) { return convertToAssets(balanceOf(owner)); }
    function maxRedeem(address owner) external view override returns (uint256) { return balanceOf(owner); }

    function previewDeposit(uint256 assets) public view override returns (uint256) { return convertToShares(assets); }
    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : (shares * totalAssets() + supply - 1) / supply;
    }
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply + totalAssets() - 1) / totalAssets();
    }
    function previewRedeem(uint256 shares) public view override returns (uint256) { return convertToAssets(shares); }

    function deposit(uint256 assets, address receiver) external virtual override returns (uint256 shares) {
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");
        underlying.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external virtual override returns (uint256 assets) {
        assets = previewMint(shares);
        underlying.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external virtual override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        underlying.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external virtual override returns (uint256 assets) {
        require(shares <= balanceOf(owner), "INSUFFICIENT");
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        assets = previewRedeem(shares);
        _burn(owner, shares);
        underlying.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _spendAllowance(address owner, address spender, uint256 needed) internal {
        uint256 a = allowance(owner, spender);
        if (a != type(uint256).max) {
            require(a >= needed, "ALLOWANCE");
            _approve(owner, spender, a - needed);
        }
    }
}
