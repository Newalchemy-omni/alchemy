# SwapRouter

- Contract: [`0x6a0D30be107BA8344ca52FC57eb1349fe9CceEC8`](https://bscscan.com/address/0x6a0D30be107BA8344ca52FC57eb1349fe9CceEC8#code) (verified on BscScan, MIT)
- Form: plain single contract (no proxy / no initializer / no storage gaps), `Ownable + ReentrancyGuard + constructor` deployment; logic is fixed once deployed — the owner can only adjust runtime parameters (fees, limits, router addresses)
- Compiler: solc `v0.8.24`, viaIR, optimizer 200 runs, evmVersion `cancun`
- Dependencies: OpenZeppelin Contracts v5 (Ownable / ReentrancyGuard / IERC20 / SafeERC20)

---

## BTCA → BTCB (one-way)

**Entry points**: `swapBTCAToBTCB(btcaIn)`; `swapBTCAToBTCBWithNfts(btcaIn, ringIds, fitIds)` (with NFT fee discount)

Flow — BTCA is truly burned, BTCB is paid out from the BTCBVault:

1. **Pricing**: oracle-quoted — BTCB out = BTCA amount × BTCA price ÷ BTC price (Chainlink BTC/USD)
2. **Vault health**: if the vault health factor (HF) < 1, the output is scaled down by HF to protect reserves
3. **Temperature ladder discount**: applies when the PowerRelease temperature source is wired (not enabled in the current deployment)
4. **Tiered fee** (by per-swap BTCA amount):

   | Per swap (BTCA) | Fee |
   |---|---|
   | < 100 | 3% |
   | 100 – 1,000 | 6% |
   | 1,000 – 10,000 | 9% |
   | 10,000 – 100,000 | 12% |
   | ≥ 100,000 | 15% |

5. **NFT discount**: selected SwimRing / Fitness NFTs discount the fee (sum of the selected ids per class, total capped at 80%); the selected NFTs are burned once the swap succeeds; the saved fee accrues to `lpFeePool`
6. **Fee usage**: half of the user-paid fee buys UNI, the other half buys UNIX via UNI, forming **UNI/UNIX LP** to support both markets
7. **Limits** (owner-adjustable): per swap ≥ 1 BTCA; per address within a rolling 24h window at most 3 swaps and 10,000 BTCA cumulative

> The reverse direction (BTCB → BTCA) is permanently disabled (`swapBTCBToBTCA` always reverts).

## Security & Governance

- **Non-upgradeable**: the code is fixed after deployment; nobody — including the owner — can replace the logic
- **Owner boundary**: parameter-only setters (fees / limits / slippage / router addresses / pause switch); user-asset paths cannot be altered
- **Emergency withdrawal**: `rescue(token, amount)` recovers mistakenly sent tokens; `rescueLpFeePool(to)` extracts the accrued discount pool
- **Pause switch**: `setBtcaToBtcbPaused(true)` halts the BTCA→BTCB direction in an emergency
- **Reentrancy**: all swap entry points are `nonReentrant`

## License

MIT
