// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AllocatorVault} from "./AllocatorVault.sol";

/// @title AllocatorVaultV2
/// @notice AllocatorVault + an on-chain PERFORMANCE FEE charged ONLY on profit.
///
/// Fee model (per-user cost-basis high-water-mark):
///   - Every depositor has a `costBasisAssets` = the asset value they paid in for
///     the shares they currently hold (weighted-average; top-ups don't reset it).
///   - On withdraw/redeem we value the shares being removed, subtract the matching
///     slice of cost basis, and charge `performanceFeeBps` ONLY on the positive
///     difference (profit). If the position is flat or down, the fee is ZERO — it
///     is mathematically impossible to charge on principal.
///   - The fee is taken in the vault asset (e.g. USDC) and sent to `treasury`.
///   - Because the vault is single-asset, profit is measured in that same asset —
///     no oracle is ever in the fee path.
///
/// Trust properties preserved from V1: non-custodial (only a share owner can
/// withdraw), keeper is allowlist+cap bounded and cannot move funds out. The fee
/// rate is IMMUTABLE and hard-capped; only `treasury` (the payout address) is
/// admin-updatable, so it can later point at a multisig.
contract AllocatorVaultV2 is AllocatorVault {
    using SafeERC20 for IERC20;

    /// @notice Hard ceiling on the performance fee (20%), enforced at construction.
    uint256 public constant MAX_FEE_BPS = 2_000;

    /// @notice Performance fee in basis points (e.g. 100 = 1%). Immutable.
    uint256 public immutable performanceFeeBps;

    /// @notice Where performance fees are sent (set a multisig in production).
    address public treasury;

    /// @notice Per-user weighted-average cost basis, denominated in the vault asset.
    mapping(address => uint256) public costBasisAssets;

    event TreasurySet(address indexed treasury);
    event PerformanceFeeCharged(address indexed owner, uint256 feeAssets);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin,
        uint256 maxRebalanceAssets_,
        address treasury_,
        uint256 feeBps_
    ) AllocatorVault(asset_, name_, symbol_, admin, maxRebalanceAssets_) {
        require(treasury_ != address(0), "treasury=0");
        require(feeBps_ <= MAX_FEE_BPS, "fee>max");
        treasury = treasury_;
        performanceFeeBps = feeBps_;
        emit TreasurySet(treasury_);
    }

    /// @notice Move the fee payout address (e.g. to a multisig). Rate stays fixed.
    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Preview the fee for redeeming `shares` of `owner` right now.
    /// @return grossAssets value of the shares, profit above cost basis, fee charged.
    function quoteFee(address owner, uint256 shares)
        public
        view
        returns (uint256 grossAssets, uint256 profit, uint256 fee)
    {
        grossAssets = convertToAssets(shares);
        uint256 bal = balanceOf(owner);
        uint256 basisPortion = bal == 0 ? 0 : Math.mulDiv(costBasisAssets[owner], shares, bal);
        profit = grossAssets > basisPortion ? grossAssets - basisPortion : 0;
        fee = Math.mulDiv(profit, performanceFeeBps, 10_000);
    }

    // ───────────────────── ERC-4626 fee-aware views (AUDIT B2) ─────────────────────
    //
    // INTENTIONAL, DOCUMENTED ERC-4626 DEVIATION: this vault charges a per-USER,
    // cost-basis performance fee on the way out. `previewWithdraw`/`previewRedeem`
    // are owner-agnostic by the ERC-4626 spec, so they CANNOT reflect a per-user
    // fee and continue to report GROSS (pre-fee) values. `withdraw`/`redeem`
    // therefore deliver assets NET of the profit fee. Integrators must size exits
    // with the owner-aware helpers below (or `quoteFee`), NOT the gross previews.
    // `redeem` is the canonical exit. Auditors: this trade-off is unavoidable with
    // per-user basis; the alternative (fee-shares dilution) was rejected to keep
    // "fee strictly on the depositor's own profit".

    /// @notice Max assets `owner` can actually receive via withdraw, i.e. the NET
    ///         value of all their shares after the profit fee. AUDIT B2: the
    ///         inherited (gross) maxWithdraw over-reported by the fee.
    function maxWithdraw(address owner) public view override returns (uint256) {
        (uint256 grossAssets,, uint256 fee) = quoteFee(owner, balanceOf(owner));
        return grossAssets - fee;
    }

    /// @notice Exact assets `owner` would receive for redeeming `shares` (net of fee).
    function previewRedeemNet(address owner, uint256 shares) external view returns (uint256 net) {
        (uint256 grossAssets,, uint256 fee) = quoteFee(owner, shares);
        return grossAssets - fee;
    }

    /// @notice Shares `owner` must redeem to receive ~`netAssets` after fee (ceil).
    function sharesForNetWithdraw(address owner, uint256 netAssets) external view returns (uint256 shares) {
        uint256 maxNet = maxWithdraw(owner);
        if (netAssets >= maxNet) return balanceOf(owner);
        // net is monotonic in shares; linear-interpolate then this is exact enough
        // for UI sizing (final settlement is on-chain via redeem → quoteFee).
        uint256 bal = balanceOf(owner);
        return maxNet == 0 ? 0 : Math.mulDiv(bal, netAssets, maxNet);
    }

    // ───────────────────────── cost-basis accounting ──────────────────────────

    /// @dev Track cost basis on the way in (knows the exact assets paid).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
    {
        super._deposit(caller, receiver, assets, shares);
        costBasisAssets[receiver] += assets;
    }

    /// @dev Charge the fee on the way out. Mirrors OZ ERC4626._withdraw but splits
    ///      the payout into (assets - fee) to the user and `fee` to the treasury.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _ensureLiquidity(assets); // fully exit strategies if idle is short (from V1)

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        uint256 bal = balanceOf(owner);
        uint256 basisPortion = bal == 0 ? 0 : Math.mulDiv(costBasisAssets[owner], shares, bal);
        uint256 profit = assets > basisPortion ? assets - basisPortion : 0;
        uint256 fee = Math.mulDiv(profit, performanceFeeBps, 10_000);

        // EFFECTS first (checks-effects-interactions)
        costBasisAssets[owner] = costBasisAssets[owner] > basisPortion
            ? costBasisAssets[owner] - basisPortion
            : 0;
        _burn(owner, shares);

        // INTERACTIONS
        IERC20 a = IERC20(asset());
        a.safeTransfer(receiver, assets - fee);
        if (fee > 0) {
            a.safeTransfer(treasury, fee);
            emit PerformanceFeeCharged(owner, fee);
        }
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev On a plain share transfer, move the matching slice of cost basis with
    ///      the shares so profit can't be laundered to a fresh address. Skips
    ///      mint (handled in _deposit) and burn (handled in _withdraw).
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 0) {
            uint256 bal = balanceOf(from); // before balances change
            uint256 moved = bal == 0 ? 0 : Math.mulDiv(costBasisAssets[from], value, bal);
            costBasisAssets[from] -= moved;
            costBasisAssets[to] += moved;
        }
        super._update(from, to, value);
    }
}
