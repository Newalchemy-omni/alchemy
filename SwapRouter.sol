// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBucketToken {
    function mint(address to, uint256 amount) external;
    function burnToHole(uint256 amount) external;
}

interface IBTCBVault {
    function takeBtcb(address to, uint256 amount) external returns (uint256);
    function refillFromRouter(uint256 amount) external;
    function healthFactor() external view returns (uint256);
    function reserve() external view returns (uint256);
}

/// @dev Dedicated UNIX vault (payout leg of the swapUSDTToUNIX platform inventory)
interface IUnixVault {
    function takeUnix(address to, uint256 amount) external returns (uint256);
    function reserve() external view returns (uint256);
}

interface IPriceOracle {
    function getBTCAPrice() external view returns (uint256);
    function getBTCCPrice() external view returns (uint256);
    function getBTCSPrice() external view returns (uint256);
    function getBtcUsd() external view returns (uint256);
}

/// @dev PowerRelease V4: temperature source (temp x 1e8; 100 = 1e10)
interface IPowerRelease {
    function getTemperature() external view returns (uint256);
}

/// @dev Minimal SwimRingNFT v2 interface (discount read / swap-time burn)
interface ISwimRingNFTLite {
    function heldLevel(address user) external view returns (uint8);
    function lockTopNFT(address user) external;
    function discountBpsOfIds(uint256[] calldata tokenIds, address user) external view returns (uint256);
    function burnNFTs(uint256[] calldata tokenIds, address user) external;
}

/// @dev Minimal FitnessNFT interface
interface IFitnessNFTLite {
    function heldLevel(address user) external view returns (uint8);
    function lockTopNFT(address user) external;
    function discountBpsOfIds(uint256[] calldata tokenIds, address user) external view returns (uint256);
    function burnNFTs(uint256[] calldata tokenIds, address user) external;
}

/// @dev PancakeSwap V3 router (fee-leg deep-pool route BTCB->WBNB->UNI;
///      the unit-test MockPancakeV3Router implements the same interface)
interface IPancakeV3Route {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut);
}

/// @dev Aave V3 Pool (only `supply` is used: BTCB -> aBTCB receipt)
interface IAavePoolSupply {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

/// @dev PancakeSwap V2 router (BSC UniswapV2 standard). LP legs of the fee split go through here.
interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory amounts);
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

/**
 * @title SwapRouter - NFTv2 swap (non-upgradeable, open-source version)
 * @dev  Plain Ownable + ReentrancyGuard deployed through its constructor: no proxy,
 *       no initializer, no storage gaps - the single-contract source verifies
 *       as-is on block explorers (BscScan). Logic is immutable once deployed;
 *       runtime parameters remain owner-adjustable through setters.
 */
contract SwapRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev WBNB (BSC; intermediate hop of the SC-group UNIX spot quote [UNI,WBNB,BTCB])
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    IBucketToken public btca;
    IBucketToken public btcc;
    IERC20 public btcs;
    IERC20 public btcb;
    IBTCBVault public vault;
    IPriceOracle public oracle;

    uint256 public swapFeeBps;
    uint256 public constant BPS = 10_000;

    // ── Tiered fee (only swapBTCAToBTCB) ──────────────────────────────────
    // 5 thresholds: upper bounds for tiers 0-3; sentinel (max) makes the
    // 5th iteration always hit (tier 4 = catch-all for ≥100k BTCA).
    uint256[5] public tierThresholds;     // [100e18, 1e21, 1e22, 1e23, type(uint256).max]
    uint256[5] public tierFeesBps;        // [300, 600, 900, 1200, 1500]  (3%-15%)

    // ── Withdrawal limits (owner-configurable rolling window) ──────────────
    uint256 public withdrawWindowSec;     // default 86400 (1 day)
    uint256 public withdrawMaxCount;      // default 3
    uint256 public withdrawMaxAmount;     // default 10000e18

    // Per-user rolling window state. Three mappings, each 1 slot.
    mapping(address => uint256) public userWindowStart;   // window-start ts (0 = never)
    mapping(address => uint256) public userWindowCount;   // swaps in current window
    mapping(address => uint256) public userWindowAmount;  // BTCA spent in current window

    // ── Pause (only swapBTCAToBTCB) ────────────────────────────────────────
    bool public btcaToBtcbPaused;

    // ── Min swap amount (only swapBTCAToBTCB) ─────────────────────────────
    uint256 public minBtcaSwap;

    // ── BTCA->BTCB fee split (1/2 buys BTCA, 1/2 pairs with it into the PancakeSwap BTCB/BTCA LP) ──
    IUniswapV2Router02 public pancakeRouter;   // wired by owner after deployment via setPancakeRouter
    uint256 public lpSlippageBps;              // addLiquidity tolerance in bps: amountMin = intended * (BPS-bps)/BPS; 0 = strictest full floor, 10000 = effectively uncapped (amountMin = 0)
    address public lpReceiver;                 // LP recipient (0 = LP tokens stay in this contract, legacy behavior)

    // ── Temperature-ladder discount + frozen balance (swapBTCAToBTCB; ladder payout in _tempDiscountBps) ──
    IPowerRelease public powerRelease;       // wired by owner (0 = discount off)
    uint256 public maxDiscountBps;           // deprecated (unused by the ladder version); slot kept for ABI compatibility
    mapping(address => uint256) public frozenBTCB;  // per-user cumulative frozen BTCB (shortfall from discounts; bookkeeping only, never paid out)
    uint256 public totalFrozenBTCB;          // global cumulative frozen BTCB (statistics only)

    // ── NFT discount stacking ──────────────────────────────────────────────────
    /// @notice SwimRingNFT v2 contract address (0 = SwimRing discount off)
    ISwimRingNFTLite public swimRingV2;
    /// @notice FitnessNFT contract address (0 = Fitness discount off)
    IFitnessNFTLite public fitnessNft;
    /// @notice NFT discount cap (bps; 8000 = 80%); owner-adjustable
    uint256 public maxNftDiscountBps;
    /// @notice BTCB saved by NFT discounts so far (neither burned nor distributed in this version; owner emergency-withdrawable)
    uint256 public lpFeePool;

    event Swapped(address indexed user, string kind, uint256 inAmount, uint256 outAmount);
    event FeeSet(uint256 bps);
    event TierConfigSet(uint256[5] thresholds, uint256[5] feesBps);
    event WithdrawLimitsSet(uint256 windowSec, uint256 maxCount, uint256 maxAmount);
    event BtcaToBtcbPausedSet(bool paused);
    event TierUsed(address indexed user, uint256 tierIdx, uint256 feeBps);
    event MinBtcaSwapSet(uint256 min);
    event FeeSplitToLP(uint256 feeBtcb, uint256 btcaMinted, uint256 liquidity);
    event LpFeeSplitToUniUnix(uint256 feeBtcb, uint256 uniOut, uint256 unixOut, uint256 liquidity);
    event LpV3RouteSet(address v3Router, address wbnb, uint24 feeBtcbWbnb, uint24 feeWbnbUni);
    event LpPairTokensSet(address uni, address unix_);
    event LpReceiverSet(address receiver);
    event PowerReleaseSet(address powerRelease);
    event MaxDiscountBpsDeprecated(uint256 previous);   // maxDiscountBps is deprecated; setMaxDiscountBps emits this instead
    event FrozenRecorded(address indexed user, uint256 btcbFrozen, uint256 tempBp);

    // ── NFT discount events ────────────────────────────────────────────────────
    event SwapRouterNftSet(address swimRingV2, address fitnessNft);
    event MaxNftDiscountBpsSet(uint256 bps);
    event NftDiscountUsed(address indexed user, uint256 nftBps, uint256 savedFee);
    event LpFeePoolRescued(address indexed to, uint256 amount);

    constructor(
        address initialOwner,
        address _btca,
        address _btcc,
        address _btcs,
        address _btcb,
        address _vault,
        address _oracle
    ) Ownable(initialOwner) {
        btca = IBucketToken(_btca);
        btcc = IBucketToken(_btcc);
        btcs = IERC20(_btcs);
        btcb = IERC20(_btcb);
        vault = IBTCBVault(_vault);
        oracle = IPriceOracle(_oracle);
        swapFeeBps = 30;

        // Tier defaults: 10-100 BTCA -> 3% ... 100k+ -> 15%.
        // Lower bound stored in minBtcaSwap (default 1 BTCA, owner-adjustable).
        tierThresholds = [
            uint256(100)   * 1e18,
            uint256(1_000) * 1e18,
            uint256(10_000)* 1e18,
            uint256(100_000)* 1e18,
            type(uint256).max
        ];
        tierFeesBps = [uint256(300), uint256(600), uint256(900), uint256(1200), uint256(1500)];

        // Default withdrawal limits: 1 day / 3 swaps / 10k BTCA
        withdrawWindowSec = 86400;
        withdrawMaxCount = 3;
        withdrawMaxAmount = uint256(10_000) * 1e18;

        btcaToBtcbPaused = false;
        minBtcaSwap = 1 ether;

        // NFT discount cap defaults to 80% (owner-adjustable)
        maxNftDiscountBps = 8000;
    }

    function _btcaErc() internal view returns (IERC20) { return IERC20(address(btca)); }
    function _btccErc() internal view returns (IERC20) { return IERC20(address(btcc)); }

    function _btcaToBtcb(uint256 btcaIn) internal view returns (uint256) {
        uint256 pA = oracle.getBTCAPrice();
        uint256 pB = oracle.getBtcUsd();
        require(pB > 0, "Bad BTC price");
        return btcaIn * pA / pB;
    }

    function _btcbToBtca(uint256 btcbIn) internal view returns (uint256) {
        uint256 pA = oracle.getBTCAPrice();
        uint256 pB = oracle.getBtcUsd();
        require(pA > 0, "Bad BTCA price");
        return btcbIn * pB / pA;
    }

    function _tierIndex(uint256 amount) internal view returns (uint256) {
        // tierThresholds has exactly 5 elements; the last is uint256.max so
        // the loop always returns within bounds. amount=0 lands on tier 0.
        for (uint256 i = 0; i < 5; i++) {
            if (amount < tierThresholds[i]) return i;
        }
        return 4; // unreachable; loop above covers all uint256
    }

    function _tierFeeBps(uint256 amount) internal view returns (uint256) {
        return tierFeesBps[_tierIndex(amount)];
    }

    /// @notice Temperature-ladder discount (only below 50 degrees)
    /// @dev  Returns 0 when powerRelease is not wired (discount off, legacy behavior).
    ///       Ladder (temperature -> payout rate bps):
    ///         > 50        -> 10000 (no loss; "lossless at 51 and above")
    ///         [50, 51)    -> 9500
    ///         [45, 50)    -> 9000
    ///         [40, 45)    -> 8000
    ///         [35, 40)    -> 7000
    ///         [30, 35)    -> 6000
    ///         [25, 30)    -> 5000
    ///         [20, 25)    -> 4000
    ///         [15, 20)    -> 3000
    ///         [10, 15)    -> 2000
    ///         [9, 10)     -> 1000
    ///         [5, 9)      ->  500
    ///         [4, 5)      ->  400
    ///         [3, 4)      ->  300
    ///         [2, 3)      ->  200
    ///         [1, 2)      ->  100
    ///         (0, 1)      ->   30  (0.3%)
    ///         == 0        ->   30  (same as above)
    ///         < 0         ->    3  (0.03%; getTemperature returns uint256 so this is
    ///                                theoretically unreachable, kept as a fallback)
    ///       Return value = BPS - payoutBps = the discount bps applied for the user.
    function _tempDiscountBps() internal view returns (uint256) {
        if (address(powerRelease) == address(0)) return 0;
        uint256 tempBp = powerRelease.getTemperature();               // temp x 1e8 (100 = 1e10)
        if (tempBp > 50 * 1e8) return 0;                              // >= 51: lossless

        uint256 payoutBps;
        if      (tempBp >= 50 * 1e8) payoutBps = 9500;                // [50, 51)
        else if (tempBp >= 45 * 1e8) payoutBps = 9000;                // [45, 50)
        else if (tempBp >= 40 * 1e8) payoutBps = 8000;                // [40, 45)
        else if (tempBp >= 35 * 1e8) payoutBps = 7000;                // [35, 40)
        else if (tempBp >= 30 * 1e8) payoutBps = 6000;                // [30, 35)
        else if (tempBp >= 25 * 1e8) payoutBps = 5000;                // [25, 30)
        else if (tempBp >= 20 * 1e8) payoutBps = 4000;                // [20, 25)
        else if (tempBp >= 15 * 1e8) payoutBps = 3000;                // [15, 20)
        else if (tempBp >= 10 * 1e8) payoutBps = 2000;                // [10, 15)
        else if (tempBp >=  9 * 1e8) payoutBps = 1000;                // [9, 10)
        else if (tempBp >=  5 * 1e8) payoutBps =  500;                // [5, 9)
        else if (tempBp >=  4 * 1e8) payoutBps =  400;                // [4, 5)
        else if (tempBp >=  3 * 1e8) payoutBps =  300;                // [3, 4)
        else if (tempBp >=  2 * 1e8) payoutBps =  200;                // [2, 3)
        else if (tempBp >=  1 * 1e8) payoutBps =  100;                // [1, 2)
        else if (tempBp > 0)         payoutBps =   30;                // (0, 1)
        else if (tempBp == 0)        payoutBps =   30;                // == 0: 0.3%
        else                         payoutBps =    3;                // < 0 (fallback): 0.03%

        return BPS - payoutBps;
    }

    /// @notice NFT discount stacking (swapBTCAToBTCB only): take the highest held
    ///         tier of each NFT class and sum them, capped at maxNftDiscountBps
    /// @dev    SwimRingNFT has 5 tiers (5%/10%/15%/20%/25%); FitnessNFT has 3 tiers (10%/20%/30%).
    ///         Classes are naturally separated by contract address; a user holding
    ///         both classes still only counts the max tier within each class.
    ///         Return unit is bps (500 = 5%); 0 = no NFT or discount source not wired.
    function _nftDiscountBps(address user) internal view returns (uint256) {
        uint256 ringBps = address(swimRingV2) != address(0) ? uint256(swimRingV2.heldLevel(user)) * 100 : 0;
        uint256 fitBps  = address(fitnessNft)  != address(0) ? uint256(fitnessNft.heldLevel(user))  * 100 : 0;
        uint256 total = ringBps + fitBps;
        return total > maxNftDiscountBps ? maxNftDiscountBps : total;
    }

    /// @notice NFT discount view (auto mode: highest tier of each class; used by the frontend "potential" display)
    function nftDiscountBps(address user) external view returns (uint256) { return _nftDiscountBps(user); }

    /// @notice Multi-select mode: sum the discounts of user-selected tokenIds (bps; capped at maxNftDiscountBps)
    /// @dev    The NFT contracts validate ownership + not locked (invalid ids revert with "Not owner"/"Locked")
    function _nftDiscountBpsOfIds(
        address user,
        uint256[] memory ringIds,
        uint256[] memory fitIds
    ) internal view returns (uint256) {
        uint256 ringBps = ringIds.length > 0 && address(swimRingV2) != address(0)
            ? swimRingV2.discountBpsOfIds(ringIds, user) : 0;
        uint256 fitBps = fitIds.length > 0 && address(fitnessNft) != address(0)
            ? fitnessNft.discountBpsOfIds(fitIds, user) : 0;
        uint256 total = ringBps + fitBps;
        return total > maxNftDiscountBps ? maxNftDiscountBps : total;
    }

    /// @notice Multi-select discount view (frontend popup preview; same formula as swapBTCAToBTCBWithNfts)
    function nftDiscountBpsOfIds(
        address user,
        uint256[] calldata ringIds,
        uint256[] calldata fitIds
    ) external view returns (uint256) { return _nftDiscountBpsOfIds(user, ringIds, fitIds); }

    /// @notice v1-compatible entry: no NFT selection (no NFT discount, identical to pre-upgrade behavior)
    function swapBTCAToBTCB(uint256 btcaIn) external nonReentrant returns (uint256) {
        uint256[] memory empty = new uint256[](0);
        return _swapBTCAtoBTCBCore(btcaIn, empty, empty);
    }

    /// @notice v2 multi-select entry: with NFT selection (selected NFT discounts sum, capped at maxNftDiscountBps; all burned)
    function swapBTCAToBTCBWithNfts(
        uint256 btcaIn,
        uint256[] calldata ringIds,
        uint256[] calldata fitIds
    ) external nonReentrant returns (uint256) {
        return _swapBTCAtoBTCBCore(btcaIn, ringIds, fitIds);
    }

    function _swapBTCAtoBTCBCore(
        uint256 btcaIn,
        uint256[] memory ringIds,
        uint256[] memory fitIds
    ) private returns (uint256) {
        require(!btcaToBtcbPaused, "BTCA->BTCB paused");
        require(btcaIn >= minBtcaSwap, "Below min");

        // ── Rolling-window accounting (CEI: effects first) ──
        // Lazy reset: if window has expired OR never started, (re)initialise it.
        uint256 winStart = userWindowStart[msg.sender];
        if (winStart == 0 || block.timestamp > winStart + withdrawWindowSec) {
            userWindowStart[msg.sender] = block.timestamp;
            userWindowCount[msg.sender] = 0;
            userWindowAmount[msg.sender] = 0;
        }

        require(userWindowCount[msg.sender] < withdrawMaxCount, "Daily count exceeded");
        require(
            userWindowAmount[msg.sender] + btcaIn <= withdrawMaxAmount,
            "Daily amount exceeded"
        );
        userWindowCount[msg.sender] += 1;
        userWindowAmount[msg.sender] += btcaIn;

        // ── Price + health factor (compute the full value first, then apply fee) ──
        uint256 hf = vault.healthFactor();
        uint256 fullOut = _btcaToBtcb(btcaIn);
        if (hf < 1e18) fullOut = fullOut * hf / 1e18;

        // ── Temperature discount (ladder when temp < 100; shortfall recorded as frozen, bookkeeping only) ──
        uint256 discountBps = _tempDiscountBps();
        uint256 discountedOut = fullOut;
        uint256 frozen = 0;
        if (discountBps > 0) {
            discountedOut = fullOut * (BPS - discountBps) / BPS;
            frozen = fullOut - discountedOut;
        }

        // ── Tiered fee replaces flat swapFeeBps for this direction ──
        // Fee is taken on the discounted amount (discount and fee don't stack;
        // userOut = discounted - fee from the user's perspective)
        uint256 tierBps = _tierFeeBps(btcaIn);
        uint256 feeBtcb = discountedOut * tierBps / BPS;

        // ── v2.1 multi-select NFT discount stacking (selected discounts sum, capped at maxNftDiscountBps) ──
        // Empty arrays = no discount (v1-compatible path); all selected NFTs are
        // burned once the swap has succeeded (see burn section below)
        uint256 nftBps = _nftDiscountBpsOfIds(msg.sender, ringIds, fitIds);
        uint256 nftSaved = 0;
        if (nftBps > 0) {
            nftSaved = discountedOut * nftBps / BPS;
            // Guard against nftBps > tierBps making userFee negative; floor at 0
            if (nftSaved > feeBtcb) nftSaved = feeBtcb;
            lpFeePool += nftSaved;
            emit NftDiscountUsed(msg.sender, nftBps, nftSaved);
        }
        uint256 userFee = feeBtcb - nftSaved;
        uint256 userOut = discountedOut - userFee;
        require(userOut > 0, "Zero user out");

        // ── Upfront vault reserve check (2026-09-03 fix) ──
        // Production incident: with an empty vault, takeBtcb silently returned 0
        // while BTCA had already been burned - users got no BTCB (block 119694348).
        // Precheck: vault reserve must cover userOut + the fee split (when pancakeRouter is wired).
        // Double safety: (1) upfront revert here; (2) BTCBVault.takeBtcb also reverts when aBal < amount.
        uint256 totalDemand = userOut;
        if (feeBtcb > 0 && address(pancakeRouter) != address(0)) {
            totalDemand += feeBtcb;
        }
        require(vault.reserve() >= totalDemand, "Vault reserve insufficient");

        _btcaErc().safeTransferFrom(msg.sender, address(this), btcaIn);
        btca.burnToHole(btcaIn);
        uint256 userActual = vault.takeBtcb(msg.sender, userOut);

        // ── Cumulative frozen balance: BTCB not received due to the discount (recording only, never paid out) ──
        if (frozen > 0) {
            frozenBTCB[msg.sender] += frozen;
            totalFrozenBTCB += frozen;
            emit FrozenRecorded(msg.sender, frozen, powerRelease.getTemperature());
        }

        // ── Fee split: 1/2 BTCB buys BTCA (at oracle price), the other 1/2 pairs with it
        //    into the PancakeSwap BTCB/BTCA LP ──
        // Without a router wired, fee BTCB stays in the contract (owner can rescue);
        // the main swap flow is never blocked. The NFT-discount savings (nftSaved)
        // do not enter the LP; they accrue in lpFeePool for a future pro-rata LP
        // distribution. The vault pays out feeBtcb (userFee + nftSaved); the LP leg
        // only uses half of userFee, the nftSaved remainder goes to lpFeePool.
        uint256 btcaMinted = 0;
        uint256 liquidity = 0;
        if (feeBtcb > 0 && address(pancakeRouter) != address(0)) {
            uint256 feeActual = vault.takeBtcb(address(this), feeBtcb);
            uint256 lpFee = userFee / 2;     // what the LP leg actually uses
            // ── UNIX/UNI LP path (2026-10-23; preferred when lpUniToken/lpUnixToken are both wired) ──
            // 1/2 BTCB buys UNI + 1/2 BTCB buys UNIX via UNI -> Pancake V2 UNIX/UNI LP
            if (lpFee > 0 && lpUniToken != address(0) && lpUnixToken != address(0)) {
                // Leg 1: 1/2 BTCB -> UNI (see _swapBtcbToLpUni for the routed path)
                uint256 halfFee = lpFee / 2;
                uint256 uniOut = _swapBtcbToLpUni(halfFee);
                // Leg 2: 1/2 BTCB -> UNI -> UNIX (UNIX/UNI pool lives on Uniswap V2)
                uint256 uniMid = _swapBtcbToLpUni(lpFee - halfFee);
                uint256 unixOut = _swapUniToUnix(uniMid);
                if (uniOut > 0 && unixOut > 0) {
                    address lpRouter = uniV2LpRouter != address(0) ? uniV2LpRouter : address(pancakeRouter);
                    IERC20(lpUniToken).forceApprove(lpRouter, uniOut);
                    IERC20(lpUnixToken).forceApprove(lpRouter, unixOut);
                    uint256 slipMul = BPS - lpSlippageBps;
                    try IUniswapV2Router02(lpRouter).addLiquidity(
                        lpUnixToken, lpUniToken,
                        unixOut, uniOut,
                        unixOut * slipMul / BPS, uniOut * slipMul / BPS,
                        _lpTo(), block.timestamp + 300
                    ) returns (uint256, uint256, uint256 lpOut) {
                        liquidity = lpOut;
                        emit LpFeeSplitToUniUnix(lpFee, uniOut, unixOut, lpOut);
                    } catch {}
                }
                // Any leg or LP failure: fee BTCB stays in this contract (equivalent
                // to lpFeePool bookkeeping; owner rescue handles it)
            } else if (lpFee > 0) {
                uint256 pA = oracle.getBTCAPrice();
                uint256 pB = oracle.getBtcUsd();
                require(pA > 0 && pB > 0, "Bad price");
                btcaMinted = lpFee * pB / pA; // anchored to the oracle price to avoid first-LP price arbitrage
                if (btcaMinted > 0) {
                    btca.mint(address(this), btcaMinted);
                    // Approve both legs: half the BTCB + the freshly minted BTCA
                    btcb.forceApprove(address(pancakeRouter), lpFee);
                    _btcaErc().forceApprove(address(pancakeRouter), btcaMinted);
                    uint256 slipMul = BPS - lpSlippageBps;
                    (uint256 usedA, uint256 usedB, uint256 lpOut) = pancakeRouter.addLiquidity(
                        address(btcb), address(btca),
                        lpFee, btcaMinted,
                        lpFee * slipMul / BPS, btcaMinted * slipMul / BPS,
                        _lpTo(),
                        block.timestamp + 300
                    );
                    liquidity = lpOut;
                    if (usedA < lpFee) {
                        btcb.forceApprove(address(pancakeRouter), 0);
                    }
                    if (usedB < btcaMinted) {
                        _btcaErc().forceApprove(address(pancakeRouter), 0);
                    }
                }
            }
            // Residue of feeActual = feeActual - lpFee (approx. nftSaved); stays in
            // this contract like lpFeePool bookkeeping. The vault already paid out
            // feeActual but only lpFee was used; the dust is handled by owner rescue()
        }

        // ── Burn the selected NFTs to the dead address (the main swap already
        //    succeeded; burning is the consumption) ──
        if (ringIds.length > 0 && address(swimRingV2) != address(0)) {
            swimRingV2.burnNFTs(ringIds, msg.sender);
        }
        if (fitIds.length > 0 && address(fitnessNft) != address(0)) {
            fitnessNft.burnNFTs(fitIds, msg.sender);
        }

        emit Swapped(msg.sender, "BTCA->BTCB", btcaIn, userActual);
        emit TierUsed(msg.sender, _tierIndex(btcaIn), tierBps);
        if (btcaMinted > 0 && liquidity > 0) emit FeeSplitToLP(feeBtcb, btcaMinted, liquidity);  // legacy BTCB/BTCA path only
        return userActual;
    }

    /// @dev UNI -> UNIX (Uniswap V2 [UNI,UNIX] - the UNIX/UNI pool lives on Uniswap V2). Returns 0 on failure.
    function _swapUniToUnix(uint256 uniAmt) internal returns (uint256) {
        if (uniAmt == 0 || lpUnixToken == address(0)) return 0;
        address r = uniV2LpRouter != address(0) ? uniV2LpRouter : address(pancakeRouter);
        address[] memory path = new address[](2);
        path[0] = lpUniToken;
        path[1] = lpUnixToken;
        try IUniswapV2Router02(r).getAmountsOut(uniAmt, path) returns (uint256[] memory ref) {
            uint256 outMin = ref[ref.length - 1] * (BPS - lpSlippageBps) / BPS;
            IERC20(lpUniToken).forceApprove(r, uniAmt);
            try IUniswapV2Router02(r).swapExactTokensForTokens(
                uniAmt, outMin, path, address(this), block.timestamp + 300
            ) returns (uint256[] memory amounts) {
                return amounts[amounts.length - 1];
            } catch { return 0; }
        } catch { return 0; }
    }

    /// @dev Fee LP leg: BTCB -> target token.
    ///      When lpV3Router is wired the swap routes through the V3 deep pools
    ///      BTCB->WBNB->UNI (the direct V2 BTCB/UNI pair is a dead pool); the
    ///      reference price is the Pancake V2 3-hop quote [BTCB,WBNB,UNI] x
    ///      (1 - lpSlippageBps). Without a V3 router it falls back to the V2
    ///      [BTCB, target] direct pair. On failure returns 0 and the caller
    ///      silently skips the LP split.
    function _swapBtcbToLpUni(uint256 amountIn) internal returns (uint256) {
        if (amountIn == 0) return 0;
        if (lpV3Router == address(0) || lpWbnb == address(0)) return _swapBtcbViaV2(amountIn, lpUniToken);
        address[] memory refPath = new address[](3);
        refPath[0] = address(btcb);
        refPath[1] = lpWbnb;
        refPath[2] = lpUniToken;
        try pancakeRouter.getAmountsOut(amountIn, refPath) returns (uint256[] memory ref) {
            uint256 outMin = ref[ref.length - 1] * (BPS - lpSlippageBps) / BPS;
            bytes memory path = abi.encodePacked(address(btcb), lpFeeBtcbWbnb, lpWbnb, lpFeeWbnbUni, lpUniToken);
            btcb.forceApprove(lpV3Router, amountIn);
            try IPancakeV3Route(lpV3Router).exactInput(
                IPancakeV3Route.ExactInputParams({
                    path: path,
                    recipient: address(this),
                    deadline: block.timestamp + 300,
                    amountIn: amountIn,
                    amountOutMinimum: outMin
                })
            ) returns (uint256 out) {
                return out;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    function _swapBtcbViaV2(uint256 amountIn, address tokenOut) internal returns (uint256) {
        if (amountIn == 0) return 0;
        address[] memory path;
        path = new address[](2);
        path[0] = address(btcb);
        path[1] = tokenOut;
        try pancakeRouter.getAmountsOut(amountIn, path) returns (uint256[] memory ref) {
            uint256 outMin = ref[ref.length - 1] * (BPS - lpSlippageBps) / BPS;
            btcb.forceApprove(address(pancakeRouter), amountIn);
            try pancakeRouter.swapExactTokensForTokens(
                amountIn, outMin, path, address(this), block.timestamp + 300
            ) returns (uint256[] memory amounts) {
                return amounts[amounts.length - 1];
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    /// @dev 2026-08-25 decision: BTCA->BTCB is one-way; BTCB no longer converts back to BTCA.
    ///      Signature kept as a placeholder (frontend ABI compatibility); calls always revert.
    ///      The original V2 logic (receive BTCB -> vault.refill -> mint BTCA) is offline.
    function swapBTCBToBTCA(uint256) external pure returns (uint256) {
        revert("BTCB->BTCA disabled");
    }

    /// @dev BTCS->BTCC is priced by the oracle ratio (no longer fixed 1:1 since V2):
    ///      BTCC is anchored to BTC (oracle.getBTCCPrice = BTC/USD), BTCS is the
    ///      BTCS/BTCB pool price (oracle.getBTCSPrice).
    ///      Since 2026-08-31 the SC group only allows BTCS->BTCC one-way;
    ///      BTCC->BTCS permanently reverts.
    ///      Since 2026-08-31 incoming BTCS is sent straight to 0xdEaD (equivalent
    ///      to a burn; it no longer accrues in router reserves).
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev 2026-10-23: SC-group token BTCS -> UNIX (UniswapX). When lpUnixToken is
    ///      wired this entry takes UNIX instead:
    ///      pricing = Pancake V2 spot 1 UNIX -> [UNIX,UNI,BTCB] in BTCB x Chainlink BTC/USD;
    ///      the input UNIX is sent straight to the dead address. When not wired
    ///      (lpUnixToken = 0) the legacy BTCS behavior applies (oracle.getBTCSPrice).
    function swapBTCSToBTCC(uint256 btcsIn) external nonReentrant returns (uint256) {
        return _swapScTokenToBTCC(btcsIn);
    }

    /// @notice UNIX->BTCC entry (same logic as swapBTCSToBTCC, clearer semantics)
    function swapUNIXToBTCC(uint256 unixIn) external nonReentrant returns (uint256) {
        return _swapScTokenToBTCC(unixIn);
    }

    function _swapScTokenToBTCC(uint256 amountIn) internal returns (uint256) {
        require(amountIn > 0, "Zero in");
        uint256 pC = oracle.getBTCCPrice();
        require(pC > 0, "Bad price");

        address inToken;
        uint256 pIn;
        string memory kind;
        if (lpUnixToken != address(0) && address(pancakeRouter) != address(0)) {
            inToken = lpUnixToken;
            // Dual-router spot price: 1 UNIX --Uniswap[UNIX,UNI]--> UNI --Pancake[UNI,WBNB,BTCB]--> BTCB x BTC/USD
            // (2026-10-24 fix: the old UNI->BTCB leg via the V2 direct pair was a dust
            // pool (reserves ~ 0); it now routes through the deep WBNB pools in 3 hops)
            address rU = uniV2LpRouter != address(0) ? uniV2LpRouter : address(pancakeRouter);
            address[] memory legU = new address[](2);
            legU[0] = lpUnixToken;
            legU[1] = lpUniToken;
            uint256[] memory refU = IUniswapV2Router02(rU).getAmountsOut(1e18, legU);
            uint256 uniPerUnix = refU[refU.length - 1];
            require(uniPerUnix > 0, "Bad UNIX price");
            address[] memory legP = new address[](3);
            legP[0] = lpUniToken;
            legP[1] = WBNB;
            legP[2] = address(btcb);
            uint256[] memory refP = pancakeRouter.getAmountsOut(uniPerUnix, legP);
            pIn = refP[refP.length - 1] * oracle.getBtcUsd() / 1e18;
            kind = "UNIX->BTCC";
        } else {
            inToken = address(btcs);
            pIn = oracle.getBTCSPrice();
            kind = "BTCS->BTCC";
        }
        require(pIn > 0, "Bad price");
        // out = in * pIn / pC * (1 - fee), rounded down
        uint256 out = amountIn * pIn / pC;
        out = out * (BPS - swapFeeBps) / BPS;
        require(out > 0, "Out too small");

        IERC20(inToken).safeTransferFrom(msg.sender, DEAD_ADDRESS, amountIn);
        btcc.mint(msg.sender, out);
        emit Swapped(msg.sender, kind, amountIn, out);
        return out;
    }

    /// @dev 2026-08-31 decision: BTCC->BTCS is permanently offline.
    ///      Signature kept as a placeholder (frontend ABI compatibility); calls always revert.
    ///      The original V2 logic (receive BTCC -> burn -> send BTCS) is offline.
    function swapBTCCToBTCS(uint256) external pure returns (uint256) {
        revert("BTCC->BTCS disabled");
    }

    function setFeeBps(uint256 bps) external onlyOwner {
        require(bps <= 1000, "Max 10%");
        swapFeeBps = bps;
        emit FeeSet(bps);
    }

    /// @notice Set tier config (onlyOwner). Owner can override defaults but
    ///         tierFeesBps[4] (the 15% top tier) cannot be raised above 2000 bps.
    function setTierConfig(uint256[5] calldata thresholds, uint256[5] calldata feesBps) external onlyOwner {
        // Thresholds must be strictly ascending, with last = uint256.max
        // (sentinel keeps the tier lookup loop well-defined).
        require(thresholds[4] == type(uint256).max, "Last threshold must be max");
        for (uint256 i = 1; i < 5; i++) {
            require(thresholds[i] > thresholds[i - 1], "Thresholds must ascend");
        }
        // Cap fees so the top tier can't be set to something egregious
        // (e.g., admin fat-fingering). 2000 bps = 20%.
        for (uint256 i = 0; i < 5; i++) {
            require(feesBps[i] <= 2000, "Fee too high");
        }
        tierThresholds = thresholds;
        tierFeesBps = feesBps;
        emit TierConfigSet(thresholds, feesBps);
    }

    function setWithdrawLimits(uint256 windowSec, uint256 maxCount, uint256 maxAmount) external onlyOwner {
        require(windowSec > 0, "Window must be > 0");
        require(maxCount > 0, "Max count must be > 0");
        require(maxAmount > 0, "Max amount must be > 0");
        withdrawWindowSec = windowSec;
        withdrawMaxCount = maxCount;
        withdrawMaxAmount = maxAmount;
        emit WithdrawLimitsSet(windowSec, maxCount, maxAmount);
    }

    function setBtcaToBtcbPaused(bool paused) external onlyOwner {
        btcaToBtcbPaused = paused;
        emit BtcaToBtcbPausedSet(paused);
    }

    /// @notice Minimum single swap size for BTCA->BTCB (default 1 BTCA; 0 would allow dust trades, so it is rejected)
    function setMinBtcaSwap(uint256 min) external onlyOwner {
        require(min > 0, "Min must be > 0");
        minBtcaSwap = min;
        emit MinBtcaSwapSet(min);
    }

    /// @notice Wire the PowerRelease (temperature source). address(0) = discount off (legacy behavior).
    function setPowerRelease(address _pr) external onlyOwner {
        powerRelease = IPowerRelease(_pr);
        emit PowerReleaseSet(_pr);
    }

    /// @notice Deprecated: the temperature discount uses the hardcoded ladder in
    ///         _tempDiscountBps; the single maxDiscountBps knob is no longer used.
    /// @dev  The function and its storage slot are kept only so the public ABI
    ///       stays stable. Calling it rewrites the stored value but has no effect
    ///       on discount behavior: _tempDiscountBps fully ignores maxDiscountBps.
    ///       An accidental owner call is harmless and merely records the value
    ///       (for post-hoc audits: a non-zero value = old code may have read it).
    function setMaxDiscountBps(uint256 _bps) external onlyOwner {
        require(_bps <= 9000, "Max 90%");
        uint256 prev = maxDiscountBps;
        maxDiscountBps = _bps;
        emit MaxDiscountBpsDeprecated(prev);
    }

    /// @notice Returns (windowStart, count, amount). windowStart=0 means user has never swapped.
    function getUserWindowInfo(address user) external view returns (uint256 windowStart, uint256 count, uint256 amount) {
        windowStart = userWindowStart[user];
        count = userWindowCount[user];
        amount = userWindowAmount[user];
    }

    function previewTier(uint256 amount) external view returns (uint256 tierIdx, uint256 feeBps) {
        tierIdx = _tierIndex(amount);
        feeBps = tierFeesBps[tierIdx];
    }

    /// @notice Full-field BTCA->BTCB preview (same formula as the swapBTCAToBTCB main flow; used by the frontend)
    /// @return fullOut       theoretical BTCB out before discounts (HF-scaled)
    /// @return discountBps   current temperature discount rate (bps; ladder lookup)
    /// @return discountedOut BTCB out after the temperature discount
    /// @return tierBps       tiered fee (bps; 100 = 1%)
    /// @return feeBtcb       fee amount (based on discountedOut)
    /// @return userOut       BTCB actually received by the user (discountedOut - fee)
    /// @return frozen        BTCB frozen by the discount in this swap (fullOut - discountedOut)
    /// @return tempBp        temperature (x 1e8)
    /// @return vaultOk       added 2026-09-03: whether vault reserve covers userOut + fee split; for frontend disabling / hints
    function previewSwapBTCAToBTCB(uint256 btcaIn) external view returns (
        uint256 fullOut, uint256 discountBps, uint256 discountedOut,
        uint256 tierBps, uint256 feeBtcb, uint256 userOut, uint256 frozen, uint256 tempBp,
        bool vaultOk
    ) {
        uint256 hf = vault.healthFactor();
        fullOut = _btcaToBtcb(btcaIn);
        if (hf < 1e18) fullOut = fullOut * hf / 1e18;

        discountBps = _tempDiscountBps();
        discountedOut = discountBps > 0 ? fullOut * (BPS - discountBps) / BPS : fullOut;
        frozen = fullOut - discountedOut;

        tierBps = _tierFeeBps(btcaIn);
        feeBtcb = discountedOut * tierBps / BPS;
        userOut = discountedOut - feeBtcb;

        tempBp = address(powerRelease) == address(0) ? 0 : powerRelease.getTemperature();

        // vaultOk: whether the vault reserve covers userOut + fee split
        uint256 totalDemand = userOut;
        if (feeBtcb > 0 && address(pancakeRouter) != address(0)) {
            totalDemand += feeBtcb;
        }
        vaultOk = userOut > 0 && vault.reserve() >= totalDemand;
    }

    function depositBtcs(uint256 amount) external onlyOwner {
        btcs.safeTransferFrom(msg.sender, address(this), amount);
    }

    function setOracle(address _oracle) external onlyOwner { oracle = IPriceOracle(_oracle); }
    function setVault(address _vault) external onlyOwner { vault = IBTCBVault(_vault); }

    /// @notice Swap the BTCA token address (used for the BTCA98 migration: point the
    ///         btca reference at the newly deployed token). Pure pointer rewrite.
    ///         Before calling, this contract must be granted setMinter(true) on the new token.
    event BtcaSet(address indexed btca);
    function setBtca(address _b) external onlyOwner {
        require(_b != address(0), "Zero");
        btca = IBucketToken(_b);
        emit BtcaSet(_b);
    }

    /// @notice Swap the BTCC token address (used for the BTCC98 migration; same precondition as setBtca).
    event BtccSet(address indexed btcc);
    function setBtcc(address _b) external onlyOwner {
        require(_b != address(0), "Zero");
        btcc = IBucketToken(_b);
        emit BtccSet(_b);
    }

    /// @notice Set the PancakeSwap V2 router (LP entry point of the fee split). Must be called once after deployment.
    function setPancakeRouter(address _r) external onlyOwner {
        require(_r != address(0), "Zero");
        pancakeRouter = IUniswapV2Router02(_r);
    }

    /// @notice Set the addLiquidity slippage tolerance (slipMul = BPS - bps; amountMin = intended * slipMul / BPS).
    ///         0 = strictest (pool ratio must exactly match the oracle-minted ratio);
    ///         10000 = effectively uncapped (amountMin = 0; the LP leg fills at pool price).
    ///         2026-09-21 decision: the LP leg is a market action independent of the
    ///         contract-internal oracle price, so the hard cap was raised from 2000 to BPS.
    ///         Leftover dust from ratio drift stays in this contract for owner rescue().
    function setLpSlippageBps(uint256 bps) external onlyOwner {
        require(bps <= BPS, "Max 100%");
        lpSlippageBps = bps;
    }

    /// @dev LP recipient: send to lpReceiver when configured, otherwise keep in this contract (legacy behavior)
    function _lpTo() internal view returns (address) {
        return lpReceiver != address(0) ? lpReceiver : address(this);
    }

    /// @notice Set the LP recipient of the fee split (0 = LP stays in this contract)
    function setLpReceiver(address _r) external onlyOwner {
        lpReceiver = _r;
        emit LpReceiverSet(_r);
    }

    /// @notice Uniswap V2 Router02 (UNIX legs + UNIX/UNI LP; 0 = everything via pancakeRouter, legacy behavior)
    function setUniV2LpRouter(address _r) external onlyOwner { require(_r != address(0)); uniV2LpRouter = _r; }

    /// @notice Fee-leg deep-pool V3 route (BTCB->WBNB->UNI). Router 0 = fall back to V2 [BTCB,UNI] direct (legacy).
    /// @param _v3        Pancake V3 SwapRouter
    /// @param _wbnb      WBNB (intermediate hop)
    /// @param _fBtcWbnb  BTCB/WBNB fee tier (deepest pool = 500)
    /// @param _fWbnbUni  WBNB/UNI fee tier (deepest pool = 2500)
    function setLpV3Route(address _v3, address _wbnb, uint24 _fBtcWbnb, uint24 _fWbnbUni) external onlyOwner {
        require(_v3 != address(0) && _wbnb != address(0), "Zero");
        require(_fBtcWbnb > 0 && _fWbnbUni > 0, "Bad fee");
        lpV3Router = _v3;
        lpWbnb = _wbnb;
        lpFeeBtcbWbnb = _fBtcWbnb;
        lpFeeWbnbUni = _fWbnbUni;
        emit LpV3RouteSet(_v3, _wbnb, _fBtcWbnb, _fWbnbUni);
    }

    /// @notice Configure the fee-LP pair (UNI + UNIX; both non-zero enables the new path, both zero falls back to the legacy BTCB/BTCA path)
    function setLpPairTokens(address _uni, address _unix) external onlyOwner {
        require(_uni != address(0) && _unix != address(0), "Zero");
        lpUniToken = _uni;
        lpUnixToken = _unix;
        emit LpPairTokensSet(_uni, _unix);
    }

    function rescue(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    /// @notice Wire the SwimRingNFT v2 contract (NFT discount source; 0 = SwimRing discount off)
    function setSwimRingV2(address r) external onlyOwner {
        swimRingV2 = ISwimRingNFTLite(r);
        emit SwapRouterNftSet(address(swimRingV2), address(fitnessNft));
    }

    /// @notice Wire the FitnessNFT contract (NFT discount source; 0 = Fitness discount off)
    function setFitnessNft(address r) external onlyOwner {
        fitnessNft = IFitnessNFTLite(r);
        emit SwapRouterNftSet(address(swimRingV2), address(fitnessNft));
    }

    /// @notice Set the NFT discount cap (bps; 8000 = 80%); owner-adjustable
    function setMaxNftDiscountBps(uint256 bps) external onlyOwner {
        require(bps <= 9000, "Max 90%");
        maxNftDiscountBps = bps;
        emit MaxNftDiscountBpsSet(bps);
    }

    /// @notice Emergency withdrawal: the owner extracts the BTCB accrued in lpFeePool
    ///         (no LP-holder distribution in this version; owner uses rescue)
    function rescueLpFeePool(address to) external onlyOwner {
        require(to != address(0), "Zero");
        uint256 amt = lpFeePool;
        lpFeePool = 0;
        btcb.safeTransfer(to, amt);
        emit LpFeePoolRescued(to, amt);
    }

    /// @notice v2 preview (with NFT discount; for the frontend popup). The v1
    ///         previewSwapBTCAToBTCB is kept unchanged for ABI compatibility
    /// @return fullOut       theoretical BTCB out before discounts (HF-scaled)
    /// @return discountBps   temperature discount rate (bps)
    /// @return discountedOut BTCB out after the temperature discount
    /// @return nftBps        NFT discount rate (bps; 0 = no NFT)
    /// @return tierBps       tiered fee (bps)
    /// @return feeBtcb       gross fee (discountedOut x tierBps)
    /// @return nftSaved      fee saved by the NFT discount (discountedOut x nftBps; goes to lpFeePool)
    /// @return userFee       fee actually paid by the user (feeBtcb - nftSaved)
    /// @return userOut       BTCB actually received by the user (discountedOut - userFee)
    /// @return frozen        BTCB frozen by the temperature discount in this swap (fullOut - discountedOut)
    /// @return tempBp        temperature (x 1e8)
    /// @return vaultOk       whether the vault reserve covers userOut + the LP fee part
    function previewSwapBTCAToBTCBv2(
        uint256 btcaIn,
        uint256[] calldata ringIds,
        uint256[] calldata fitIds
    ) external view returns (
        uint256 fullOut, uint256 discountBps, uint256 discountedOut,
        uint256 nftBps, uint256 tierBps, uint256 feeBtcb,
        uint256 nftSaved, uint256 userFee, uint256 userOut,
        uint256 frozen, uint256 tempBp, bool vaultOk
    ) {
        uint256 hf = vault.healthFactor();
        fullOut = _btcaToBtcb(btcaIn);
        if (hf < 1e18) fullOut = fullOut * hf / 1e18;

        discountBps = _tempDiscountBps();
        discountedOut = discountBps > 0 ? fullOut * (BPS - discountBps) / BPS : fullOut;
        frozen = fullOut - discountedOut;

        // v2.1: discount from the user-selected tokenIds (same formula as swapBTCAToBTCBWithNfts)
        nftBps = _nftDiscountBpsOfIds(msg.sender, ringIds, fitIds);
        tierBps = _tierFeeBps(btcaIn);
        feeBtcb = discountedOut * tierBps / BPS;
        nftSaved = nftBps > 0 ? discountedOut * nftBps / BPS : 0;
        if (nftSaved > feeBtcb) nftSaved = feeBtcb;
        userFee = feeBtcb - nftSaved;
        userOut = discountedOut - userFee;

        tempBp = address(powerRelease) == address(0) ? 0 : powerRelease.getTemperature();

        // vaultOk: whether the vault reserve covers userOut + the actual LP part (lpFee = userFee / 2)
        uint256 totalDemand = userOut + (lpFeeOf(userFee) > 0 ? lpFeeOf(userFee) : 0);
        vaultOk = userOut > 0 && vault.reserve() >= totalDemand;
    }

    function lpFeeOf(uint256 userFee) internal pure returns (uint256) { return userFee / 2; }

    // ── Fee LP via UNIX/UNI (2026-10-23 addition) ───────────────────────────────
    /// @notice LP-side UNI. When both this and lpUnixToken are non-zero, the
    ///         swapBTCAToBTCB fee split becomes:
    ///         1/2 BTCB buys UNI + 1/2 BTCB buys UNIX via UNI -> Pancake V2 UNIX/UNI LP (to lpReceiver).
    ///         If any leg fails (e.g. pool missing) that LP split is skipped
    ///         silently, fee BTCB stays in the contract (owner rescue); the main
    ///         swap is unaffected.
    address public lpUniToken;
    /// @notice LP-side UNIX (UniswapX)
    address public lpUnixToken;

    /// @notice Uniswap V2 Router02 (the UNIX/UNI pool lives on Uniswap V2: the
    ///         UNI->UNIX leg and the UNIX/UNI addLiquidity go through here).
    ///         0 = everything via pancakeRouter
    address public uniV2LpRouter;

    // ── Fee-leg deep-pool routing (2026-10-24 addition) ─────────────────────────
    // The direct Pancake V2 BTCB/UNI pair is a dead pool (reserves < $0.1), so the
    // UNI fee leg routes through WBNB using the deepest measured V3 pools
    // (BTCB/WBNB = tier 500, WBNB/UNI = tier 2500).
    /// @notice Pancake V3 router (fee leg BTCB->WBNB->UNI; 0 = fall back to the V2 [BTCB,UNI] direct pair)
    address public lpV3Router;
    /// @notice WBNB (fee-leg intermediate hop)
    address public lpWbnb;
    /// @notice BTCB/WBNB fee tier (deepest pool = 500 / 0.05%)
    uint24 public lpFeeBtcbWbnb;
    /// @notice WBNB/UNI fee tier (deepest pool = 2500 / 0.25%)
    uint24 public lpFeeWbnbUni;

    // ── USDT->UNIX swap (2026-10-24: "add a USDT -> UNIX column at LP price, 1000 USD per address per day") ──
    /// @notice USDT token (input of swapUSDTToUNIX)
    address public usdtToken;
    /// @notice USDT->UNIX per-address daily limit (USDT wei / UTC day; default 1000 USD; 0 = unlimited)
    uint256 public usdtUnixDailyLimit;
    /// @notice USDT->UNIX hop1 (USDT->WBNB->UNI) slippage bps (default 300; hop2 uses lpSlippageBps)
    uint256 public usdtUnixSlippageBps;
    /// @notice USDT->UNIX per-address daily spend (user => UTC day => USDT wei)
    mapping(address => mapping(uint256 => uint256)) public usdtUnixDailySpent;

    // ── aBTCB leg of USDT->UNIX (2026-10-25: "the USDT must also be converted to
    //    aBTCB, like the last leg of deposits"; UNIX is paid out from platform
    //    inventory at the live Uniswap UNIX/UNI pool price) ──────────────────────
    /// @notice Aave V3 Pool (aBTCB supply; same address as the deposit router's aavePool)
    address public aavePool;
    /// @notice USDT->WBNB V3 fee tier (100 = 0.01%; matches deposit payTokens[USDT].feeToWbnb)
    uint24 public usdtFeeToWbnb;
    /// @notice aBTCB receipt holder (supply onBehalfOf; same address as the deposit abtcbReceiver = platform treasury)
    address public abtcbReceiver;
    /// @notice WBNB->BTCB V3 fee tier (500 = 0.05%; matches the deposit WBNB_TO_BTCB_FEE)
    uint24 public wbnbFeeToBtcb;
    /// @notice USDT->BTCB->aBTCB leg slippage bps (default 500 = 5%; matches the deposit slippageBps).
    ///         outMin = Pancake V2 quote [USDT,WBNB,BTCB] x (1 - slip)
    uint256 public usdtAbtcbSlippageBps;

    // ── Dedicated UNIX vault (2026-10-26: "UNIX also needs to be stored in a dedicated vault") ──
    /// @notice UNIX inventory vault (0 = the payout leg falls back to this contract's own balance)
    address public unixVault;

    // ── USDT->UNIX swap events ──────────────────────────────────────────────────
    event UsdtUnixSwapped(address indexed user, uint256 usdtIn, uint256 unixOut);
    event UsdtUnixConfigSet(address usdt, uint256 limit, uint256 slippageBps);
    /// @notice USDT fully converted to aBTCB credited to the platform treasury (aBTCB leg done)
    event UsdtRoutedToAbtcb(address indexed receiver, uint256 usdtIn, uint256 btcbOut);
    event UsdtAbtcbRouteSet(address indexed aavePool, address indexed receiver, uint24 feeToWbnb, uint24 feeToBtcb, uint256 slippageBps);
    /// @notice Dedicated UNIX vault wiring
    event UnixVaultSet(address indexed unixVault);

    /// @notice USDT->UNIX swap (2026-10-25 revision: "the USDT must also be converted
    ///         to aBTCB, like the last deposit leg"):
    ///         (1) the user's USDT in full goes through the same route as deposits,
    ///             credited to the platform treasury as aBTCB:
    ///             USDT --(Pancake V3 0.01%)--> WBNB --(Pancake V3 0.05%)--> BTCB -> Aave V3 -> aBTCB;
    ///         (2) UNIX is paid out from platform inventory at the live Uniswap
    ///             UNIX/UNI pool price (never bought from the pool, so the pool
    ///             price is not pushed down):
    ///             pricing = Pancake V2 [USDT->WBNB->UNI] x Uniswap V2 [UNI->UNIX];
    ///             the inventory sits in the dedicated unixVault (takeUnix payout;
    ///             unixVault = 0 falls back to this contract's own balance);
    ///         (3) per-address daily limit usdtUnixDailyLimit (UTC-day reset);
    ///             insufficient inventory reverts.
    function swapUSDTToUNIX(uint256 usdtIn) external nonReentrant returns (uint256 unixOut) {
        return _swapUsdtToUnix(usdtIn, 0);
    }

    /// @notice USDT->UNIX swap with a receive floor (the frontend passes "quote x (1 - usdtUnixSlippageBps)")
    /// @dev  Inventory pays at the pool price = a fixed-price fill, so there is no
    ///       on-chain outMin protection; the frontend supplies the floor instead,
    ///       and if a pool sandwich attack shrinks the outcome it reverts "Slippage".
    function swapUSDTToUNIXWithMin(uint256 usdtIn, uint256 minUnixOut) external nonReentrant returns (uint256 unixOut) {
        return _swapUsdtToUnix(usdtIn, minUnixOut);
    }

    function _swapUsdtToUnix(uint256 usdtIn, uint256 minUnixOut) internal returns (uint256 unixOut) {
        require(usdtIn > 0, "Zero in");
        require(usdtToken != address(0) && lpUnixToken != address(0) && lpUniToken != address(0), "Not wired");
        require(address(pancakeRouter) != address(0) && uniV2LpRouter != address(0), "No router");
        require(address(aavePool) != address(0) && abtcbReceiver != address(0), "No aave");

        // Per-address daily limit (UTC day; 0 = unlimited)
        uint256 day = block.timestamp / 1 days;
        uint256 spent = usdtUnixDailySpent[msg.sender][day];
        require(usdtUnixDailyLimit == 0 || spent + usdtIn <= usdtUnixDailyLimit, "Daily limit");

        // Take the USDT
        IERC20(usdtToken).safeTransferFrom(msg.sender, address(this), usdtIn);

        // Pricing leg 1: Pancake V2 [USDT -> WBNB -> UNI] (USD leg, quote only, no fill)
        address[] memory pUsd = new address[](3);
        pUsd[0] = usdtToken;
        pUsd[1] = WBNB;
        pUsd[2] = lpUniToken;
        uint256[] memory refUsd = IUniswapV2Router02(pancakeRouter).getAmountsOut(usdtIn, pUsd);
        uint256 uniOut = refUsd[2];
        require(uniOut > 0, "Bad USDT quote");

        // Pricing leg 2: Uniswap V2 [UNI -> UNIX] (live UNIX/UNI pool price)
        address[] memory pUnix = new address[](2);
        pUnix[0] = lpUniToken;
        pUnix[1] = lpUnixToken;
        uint256[] memory refUnix = IUniswapV2Router02(uniV2LpRouter).getAmountsOut(uniOut, pUnix);
        unixOut = refUnix[1];
        require(unixOut > 0, "Bad UNIX quote");
        require(minUnixOut == 0 || unixOut >= minUnixOut, "Slippage");

        // Pay UNIX from platform inventory (filled at the pool price; the Uniswap
        // pool itself is untouched). The inventory sits in the dedicated unixVault
        // and is paid out through takeUnix (an empty vault reverts with
        // "Insufficient vault reserve"); unixVault = 0 keeps the legacy behavior of
        // reading this contract's own balance
        if (address(unixVault) != address(0)) {
            IUnixVault(unixVault).takeUnix(msg.sender, unixOut);
        } else {
            require(IERC20(lpUnixToken).balanceOf(address(this)) >= unixOut, "Insufficient UNIX");
            IERC20(lpUnixToken).safeTransfer(msg.sender, unixOut);
        }

        // The user's USDT -> BTCB -> Aave -> aBTCB (credited to the platform treasury;
        // same route as the last deposit leg)
        uint256 btcbOut = _routeUsdtToAbtcb(usdtIn);

        usdtUnixDailySpent[msg.sender][day] = spent + usdtIn;
        emit UsdtUnixSwapped(msg.sender, usdtIn, unixOut);
        emit UsdtRoutedToAbtcb(abtcbReceiver, usdtIn, btcbOut);
    }

    /// @dev USDT ->(Pancake V3)-> BTCB -> Aave V3 -> aBTCB (credited to abtcbReceiver)
    ///      Same route as deposits (GoldDepositRouter swap-to-BTCB + supply):
    ///      USDT --(usdtFeeToWbnb 0.01%)--> WBNB --(wbnbFeeToBtcb 0.05%)--> BTCB;
    ///      outMin from the Pancake V2 quote [USDT,WBNB,BTCB] x (1 - usdtAbtcbSlippageBps)
    ///      (same convention as deposits).
    function _routeUsdtToAbtcb(uint256 usdtAmt) internal returns (uint256 btcbOut) {
        bytes memory path = abi.encodePacked(
            usdtToken, usdtFeeToWbnb,
            WBNB, wbnbFeeToBtcb,
            address(btcb)
        );
        // Reference price: Pancake V2 [USDT, WBNB, BTCB]
        address[] memory p2 = new address[](3);
        p2[0] = usdtToken;
        p2[1] = WBNB;
        p2[2] = address(btcb);
        uint256[] memory ref = IUniswapV2Router02(pancakeRouter).getAmountsOut(usdtAmt, p2);
        require(ref[2] > 0, "No BTCB quote");
        uint256 outMin = ref[2] * (BPS - usdtAbtcbSlippageBps) / BPS;

        IERC20(usdtToken).forceApprove(address(lpV3Router), usdtAmt);
        btcbOut = IPancakeV3Route(lpV3Router).exactInput(
            IPancakeV3Route.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp + 300,
                amountIn: usdtAmt,
                amountOutMinimum: outMin
            })
        );
        require(btcbOut > 0, "No BTCB out");
        btcb.forceApprove(address(aavePool), btcbOut);
        IAavePoolSupply(aavePool).supply(address(btcb), btcbOut, abtcbReceiver, 0);
    }

    /// @notice Configure the USDT->aBTCB channel (Aave V3 pool + aBTCB receipt holder + V3 fee tiers + slippage)
    function setUsdtAbtcbRoute(
        address _aavePool,
        address _receiver,
        uint24 _usdtFeeToWbnb,
        uint24 _wbnbFeeToBtcb,
        uint256 _slippageBps
    ) external onlyOwner {
        require(_aavePool != address(0) && _receiver != address(0), "Zero");
        require(_usdtFeeToWbnb > 0 && _wbnbFeeToBtcb > 0, "Bad fee");
        require(_slippageBps <= 2000, "Max 20%");
        aavePool = _aavePool;
        abtcbReceiver = _receiver;
        usdtFeeToWbnb = _usdtFeeToWbnb;
        wbnbFeeToBtcb = _wbnbFeeToBtcb;
        usdtAbtcbSlippageBps = _slippageBps;
        emit UsdtAbtcbRouteSet(_aavePool, _receiver, _usdtFeeToWbnb, _wbnbFeeToBtcb, _slippageBps);
    }

    /// @notice USDT->UNIX swap config (limit = USDT wei/day, 0 = unlimited; slippage bps)
    function setUsdtUnixConfig(address _usdt, uint256 _limit, uint256 _slip) external onlyOwner {
        require(_usdt != address(0), "Zero");
        require(_slip <= 2000, "Max 20%");
        usdtToken = _usdt;
        usdtUnixDailyLimit = _limit;
        usdtUnixSlippageBps = _slip;
        emit UsdtUnixConfigSet(_usdt, _limit, _slip);
    }

    /// @notice Wire the dedicated UNIX vault (0 = fall back to this contract's own inventory, legacy behavior)
    function setUnixVault(address _v) external onlyOwner {
        unixVault = _v;
        emit UnixVaultSet(_v);
    }
}
