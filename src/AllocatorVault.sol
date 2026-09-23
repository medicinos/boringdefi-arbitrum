// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IStrategyAdapter} from "./interfaces/IStrategyAdapter.sol";

/// @title AllocatorVault
/// @notice Non-custodial, single-asset (e.g. USDC) yield vault for the Stable
///         Yield Allocator.
///
/// Custody model:
///   - Depositors hold ERC-4626 SHARES. Only a share owner (or an approved
///     spender) can withdraw/redeem their assets — the keeper cannot.
///   - The keeper (KEEPER_ROLE) can ONLY move idle assets into, or back out of,
///     strategy adapters that the admin has put on an ON-CHAIN ALLOWLIST, and
///     never more than `maxRebalanceAssets` per call. There is NO function that
///     lets the keeper send assets to an arbitrary address.
///   => A compromised keeper key cannot steal funds. The worst it can do is
///      shuffle assets among already-approved strategies, within the cap.
///   - A guardian can pause keeper actions in an emergency; user withdrawals
///     remain open even while paused.
///
/// The admin/allowlist is the trust root (it decides which strategies exist).
/// For shared/multi-tenant use, give DEFAULT_ADMIN_ROLE to a timelock/multisig
/// and only allowlist audited adapters.
contract AllocatorVault is ERC4626, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Strategy adapters the keeper is allowed to route into.
    mapping(address => bool) public isStrategy;
    address[] public strategies;

    /// @notice Max assets the keeper may deploy/recall in a single call.
    uint256 public maxRebalanceAssets;

    event StrategySet(address indexed strategy, bool allowed);
    event MaxRebalanceSet(uint256 maxAssets);
    event Deployed(address indexed strategy, uint256 assets);
    event Recalled(address indexed strategy, uint256 assets);

    error NotStrategy(address strategy);
    error OverCap(uint256 assets, uint256 cap);
    error WrongAsset();

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin,
        uint256 maxRebalanceAssets_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        require(admin != address(0), "admin=0");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
        maxRebalanceAssets = maxRebalanceAssets_;
        emit MaxRebalanceSet(maxRebalanceAssets_);
    }

    // ───────────────────────────── accounting ─────────────────────────────

    /// @dev AUDIT A6 (first-depositor / inflation griefing): use OZ ERC4626
    ///      virtual shares with a 1e6 offset. This makes it economically
    ///      infeasible to grief the first real depositor to zero shares via a
    ///      donation (attacker must over-donate ~1e6x and still loses it).
    ///      Deploy SHOULD additionally seed a tiny dead-share deposit (see the
    ///      deploy runbook) for belt-and-suspenders.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice Idle assets in the vault plus everything deployed in allowlisted
    ///         strategies. This is what backs the shares.
    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            total += IStrategyAdapter(strategies[i]).totalAssets();
        }
        return total;
    }

    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    // ───────────────────────────── admin ──────────────────────────────────

    /// @notice Add/remove a strategy adapter from the keeper allowlist.
    function setStrategy(address strategy, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (allowed) {
            if (IStrategyAdapter(strategy).asset() != asset()) revert WrongAsset();
            if (!isStrategy[strategy]) {
                isStrategy[strategy] = true;
                strategies.push(strategy);
            }
        } else if (isStrategy[strategy]) {
            isStrategy[strategy] = false;
            uint256 n = strategies.length;
            for (uint256 i = 0; i < n; i++) {
                if (strategies[i] == strategy) {
                    strategies[i] = strategies[n - 1];
                    strategies.pop();
                    break;
                }
            }
        }
        emit StrategySet(strategy, allowed);
    }

    function setMaxRebalanceAssets(uint256 maxAssets) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxRebalanceAssets = maxAssets;
        emit MaxRebalanceSet(maxAssets);
    }

    // ───────────────────────── keeper (constrained) ───────────────────────

    /// @notice Move idle vault assets into an allowlisted strategy. Keeper only.
    function deployToStrategy(address strategy, uint256 assets)
        external
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (!isStrategy[strategy]) revert NotStrategy(strategy);
        if (assets > maxRebalanceAssets) revert OverCap(assets, maxRebalanceAssets);
        IERC20(asset()).safeTransfer(strategy, assets);
        IStrategyAdapter(strategy).deposit(assets);
        emit Deployed(strategy, assets);
        _afterDeploy(strategy, assets);
    }

    /// @dev Post-deploy hook (no-op here). BoringVault uses it to enforce the
    ///      concentration, idle-buffer and exit-liquidity guards on-chain.
    function _afterDeploy(address strategy, uint256 assets) internal virtual {}

    /// @notice Pull assets back from an allowlisted strategy into the vault. Keeper only.
    function recallFromStrategy(address strategy, uint256 assets)
        external
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (!isStrategy[strategy]) revert NotStrategy(strategy);
        if (assets > maxRebalanceAssets) revert OverCap(assets, maxRebalanceAssets);
        IStrategyAdapter(strategy).withdraw(assets);
        emit Recalled(strategy, assets);
    }

    // ───────────────────────────── guardian ───────────────────────────────

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ─────────────────── user withdrawals (always honored) ─────────────────

    /// @dev If idle assets are insufficient, fully exit strategies (one at a
    ///      time) until the withdrawal is covered. Using `withdrawAll` avoids
    ///      exact-amount rounding reverts on real ERC-4626 / rebasing venues.
    ///      Works even while keeper actions are paused.
    function _ensureLiquidity(uint256 assets) internal virtual {
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            if (IERC20(asset()).balanceOf(address(this)) >= assets) return;
            IStrategyAdapter s = IStrategyAdapter(strategies[i]);
            if (s.totalAssets() == 0) continue;
            s.withdrawAll();
        }
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        _ensureLiquidity(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev AUDIT (pause hardening): when paused, block NEW deposits too — not
    ///      just keeper actions. A vault paused because something is wrong should
    ///      not keep taking inflows. Withdrawals stay open (no guard on _withdraw).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        virtual
        override
        whenNotPaused
    {
        super._deposit(caller, receiver, assets, shares);
    }
}
