// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AllocatorVaultV2} from "./AllocatorVaultV2.sol";
import {IStrategyAdapter} from "./interfaces/IStrategyAdapter.sol";
import {IExitLiquidity} from "./interfaces/IExitLiquidity.sol";

/// @title BoringVault
/// @notice AllocatorVaultV2 (non-custodial ERC-4626, allowlisted keeper, profit-only
///         fee) plus three guards that are enforced ON-CHAIN after every keeper
///         deploy, so "boring" is a property of the contract, not a promise:
///
///   1. Concentration cap - no venue may hold more than `allocationCapBps` of the
///      vault. A venue without a cap cannot receive funds at all.
///   2. Idle buffer - at least `minIdleBps` of the vault stays as idle USDC, so
///      small withdrawals never touch a venue.
///   3. Exit liquidity - after the deploy, the venue must be able to pay back at
///      least `minExitBps` of our whole position immediately (adapter reports it
///      via IExitLiquidity). A 100%-utilized lending pool or a paused market
///      therefore cannot receive depositors' money.
///
///   Withdrawals are hardened too: if one venue cannot pay out (paused, fully
///   utilized), the vault takes what that venue can pay and moves on to the next
///   venue instead of reverting the user's withdrawal.
///
///   Guards only restrict the keeper's deploys. Recalls (risk-reducing) and user
///   withdrawals are never blocked by them.
contract BoringVault is AllocatorVaultV2 {
    uint256 public constant BPS = 10_000;

    /// @notice Max share of totalAssets() a venue may hold after a deploy (0 = closed).
    mapping(address => uint256) public allocationCapBps;
    /// @notice Minimum idle share of totalAssets() that must remain after a deploy.
    uint256 public minIdleBps;
    /// @notice Minimum share of a venue position that must be withdrawable right now.
    uint256 public minExitBps;

    event AllocationCapSet(address indexed strategy, uint256 capBps);
    event GuardsSet(uint256 minIdleBps, uint256 minExitBps);
    event ExitShortfall(address indexed strategy, uint256 requested, uint256 paid);

    error CapNotSet(address strategy);
    error OverAllocation(address strategy, uint256 strategyAssets, uint256 limit);
    error IdleBelowBuffer(uint256 idle, uint256 required);
    error ExitLiquidityTooLow(address strategy, uint256 withdrawable, uint256 required);
    error BadBps(uint256 bps);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin,
        uint256 maxRebalanceAssets_,
        address treasury_,
        uint256 feeBps_,
        uint256 minIdleBps_,
        uint256 minExitBps_
    ) AllocatorVaultV2(asset_, name_, symbol_, admin, maxRebalanceAssets_, treasury_, feeBps_) {
        _setGuards(minIdleBps_, minExitBps_);
    }

    // ───────────────────────────── admin ──────────────────────────────────

    function setAllocationCap(address strategy, uint256 capBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (capBps > BPS) revert BadBps(capBps);
        allocationCapBps[strategy] = capBps;
        emit AllocationCapSet(strategy, capBps);
    }

    function setGuards(uint256 minIdleBps_, uint256 minExitBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setGuards(minIdleBps_, minExitBps_);
    }

    function _setGuards(uint256 minIdleBps_, uint256 minExitBps_) internal {
        if (minIdleBps_ > BPS) revert BadBps(minIdleBps_);
        if (minExitBps_ > BPS) revert BadBps(minExitBps_);
        minIdleBps = minIdleBps_;
        minExitBps = minExitBps_;
        emit GuardsSet(minIdleBps_, minExitBps_);
    }

    // ───────────────────────────── views ──────────────────────────────────

    /// @notice Withdrawable-now for a strategy (0 if the adapter cannot tell).
    function withdrawableNow(address strategy) public view returns (uint256) {
        try IExitLiquidity(strategy).withdrawableNow() returns (uint256 w) {
            return w;
        } catch {
            return 0;
        }
    }

    /// @notice One call for dashboards and the keeper: every venue's position,
    ///         what it could pay back right now, and its cap.
    function allocationReport()
        external
        view
        returns (
            address[] memory venues,
            uint256[] memory assets,
            uint256[] memory withdrawable,
            uint256[] memory capBps,
            uint256 idle,
            uint256 total
        )
    {
        uint256 n = strategies.length;
        venues = new address[](n);
        assets = new uint256[](n);
        withdrawable = new uint256[](n);
        capBps = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            address s = strategies[i];
            venues[i] = s;
            assets[i] = IStrategyAdapter(s).totalAssets();
            withdrawable[i] = withdrawableNow(s);
            capBps[i] = allocationCapBps[s];
        }
        idle = IERC20(asset()).balanceOf(address(this));
        total = totalAssets();
    }

    // ───────────────────────────── guards ─────────────────────────────────

    /// @dev Runs at the end of every keeper deployToStrategy (see AllocatorVault).
    function _afterDeploy(address strategy, uint256) internal view override {
        uint256 cap = allocationCapBps[strategy];
        if (cap == 0) revert CapNotSet(strategy);

        uint256 total = totalAssets();
        uint256 position = IStrategyAdapter(strategy).totalAssets();

        uint256 limit = (total * cap) / BPS;
        if (position > limit) revert OverAllocation(strategy, position, limit);

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 required = (total * minIdleBps + BPS - 1) / BPS; // round up
        if (idle < required) revert IdleBelowBuffer(idle, required);

        uint256 needExit = (position * minExitBps + BPS - 1) / BPS; // round up
        uint256 w = withdrawableNow(strategy);
        if (w < needExit) revert ExitLiquidityTooLow(strategy, w, needExit);
    }

    // ─────────────────────── resilient withdrawals ────────────────────────

    /// @dev Like AllocatorVault._ensureLiquidity, but one venue that cannot pay
    ///      out (paused / fully utilized) no longer reverts the withdrawal: we
    ///      take what it can pay now and continue with the next venue. If all
    ///      venues together still cannot cover it, the ERC-4626 transfer reverts
    ///      as before - no one is ever paid with someone else's money.
    function _ensureLiquidity(uint256 assets) internal override {
        IERC20 a = IERC20(asset());
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 idle = a.balanceOf(address(this));
            if (idle >= assets) return;
            IStrategyAdapter s = IStrategyAdapter(strategies[i]);
            if (s.totalAssets() == 0) continue;
            try s.withdrawAll() {
                // full exit succeeded
            } catch {
                uint256 need = assets - idle;
                uint256 can = withdrawableNow(address(s));
                uint256 amt = can < need ? can : need;
                if (amt > 0) {
                    try s.withdraw(amt) {} catch {
                        amt = 0;
                    }
                }
                emit ExitShortfall(address(s), need, amt);
            }
        }
    }
}
