# SwapRouter

BSC（BNB Smart Chain）兑换路由合约 —— **不可升级（non-upgradeable）、单合约、可在区块浏览器完整验证开源**。

- 合约地址：[`0x6a0D30be107BA8344ca52FC57eb1349fe9CceEC8`](https://bscscan.com/address/0x6a0D30be107BA8344ca52FC57eb1349fe9CceEC8#code)（BscScan 已验证，MIT）
- 形态：普通合约（无代理 / 无 initializer / 无存储间隙），`Ownable + ReentrancyGuard + constructor` 部署；逻辑一经部署不可更换，owner 仅能调整运行参数（费率、限额、路由地址等）
- 编译：solc `v0.8.24`，viaIR，optimizer 200 runs，evmVersion `cancun`
- 依赖：OpenZeppelin Contracts v5（Ownable / ReentrancyGuard / IERC20 / SafeERC20）

---

## 一、BTCA 兑换 BTCB（单向）

**入口**：`swapBTCAToBTCB(btcaIn)`（普通）；`swapBTCAToBTCBWithNfts(btcaIn, ringIds, fitIds)`（叠加 NFT 折扣）

兑换流程（BTCA 真销毁，BTCB 由 BTCBVault 金库支付）：

1. **定价**：按 oracle 报价折算 —— 可兑 BTCB = BTCA 数量 × BTCA 价格 ÷ BTC 价格（Chainlink BTC/USD）
2. **金库健康度**：若金库健康因子 HF < 1，产出按 HF 比例缩减，保护金库储备
3. **温度阶梯折扣**：接入 PowerRelease 温度源后按温度阶梯折价（当前部署未启用温度折扣）
4. **阶梯手续费**（按单笔 BTCA 金额）：

   | 单笔 BTCA | 手续费 |
   |---|---|
   | < 100 | 3% |
   | 100 ~ 1,000 | 6% |
   | 1,000 ~ 10,000 | 9% |
   | 10,000 ~ 100,000 | 12% |
   | ≥ 100,000 | 15% |

5. **NFT 折扣**：勾选 SwimRing / Fitness NFT 可对手续费打折（两类各取勾选之和、合计封顶 80%），被勾选的 NFT 在兑换成功后**销毁**；折扣省下的手续费记入 `lpFeePool`
6. **手续费用途**：用户实付手续费的一半买入 UNI、另一半经 UNI 买入 UNIX，组成 **UNI/UNIX LP**（配入流动性池，支撑双边市场）
7. **限额**（owner 可调）：单笔 ≥ 1 BTCA；每地址 24 小时滚动窗口内最多 3 笔、累计 10,000 BTCA

> BTCB 兑回 BTCA 的方向已永久关闭（`swapBTCBToBTCA` 恒 revert）。

## 二、USDT 兑换 UNIX（库存销售模式）

**入口**：`swapUSDTToUNIX(usdtIn)`（普通）；`swapUSDTToUNIXWithMin(usdtIn, minUnixOut)`（带到手下限，推荐）

1. **定价**：Pancake V2 `[USDT → WBNB → UNI]` × Uniswap V2 `[UNI → UNIX]` 双段实时池价，**0 手续费**
2. **出币**：UNIX 由平台库存（UnixVault 专门金库）按池价付出 —— **不向池子购买、不冲击池价**；库存不足直接 revert
3. **USDT 去向**：用户付出的 USDT 全额进入生息通道 ——
   `USDT →(Pancake V3 0.01%)→ WBNB →(Pancake V3 0.05%)→ BTCB → Aave V3 → aBTCB`，记入平台金库复利
4. **限额**：每地址每日 1,000 USDT（UTC 0 点重置，owner 可调）
5. **防夹击**：`WithMin` 版本传入最低到手 UNIX 数量，池价被操纵导致到手不足时直接 revert

## 安全与治理

- **不可升级**：合约代码部署后固定，任何人都无法更换逻辑（包括 owner）
- **owner 权限边界**：只能调参数（费率/限额/滑点/路由地址/暂停开关），碰不到用户资产路径之外的逻辑
- **紧急提取**：`rescue(token, amount)` 提取误转入合约的代币；`rescueLpFeePool(to)` 提取累计的折扣池
- **暂停开关**：`setBtcaToBtcbPaused(true)` 可紧急暂停 BTCA→BTCB 方向（不影响 USDT→UNIX）
- **重入保护**：所有兑换入口 `nonReentrant`

## English Summary

`SwapRouter` is a non-upgradeable swap router on BSC, verified on BscScan (MIT).

- **BTCA → BTCB** (one-way): oracle-priced, tiered fee 3%–15% by size, optional NFT fee discount (selected NFTs are burned, cap 80%), vault health-factor scaling, daily rolling limits (3 tx / 10,000 BTCA). Half of the paid fee buys UNI and the other half buys UNIX to form UNI/UNIX LP.
- **USDT → UNIX** (inventory sale): priced by live pool quotes (Pancake V2 USDT→WBNB→UNI × Uniswap V2 UNI→UNIX), zero fee; UNIX is paid from the platform vault (UnixVault) without touching the pool; the user's USDT is fully routed into Aave V3 as aBTCB (via Pancake V3: USDT→WBNB→BTCB). Daily cap: 1,000 USDT per address (UTC). Use `swapUSDTToUNIXWithMin` for slippage protection.

## License

MIT
