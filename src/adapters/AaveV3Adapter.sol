// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IAaveV3Pool} from "../interfaces/IAaveV3Pool.sol";
import {IExitLiquidity} from "../interfaces/IExitLiquidity.sol";

/// @title AaveV3Adapter
/// @notice Routes vault USDC into Aave v3 (supply) and back (withdraw). Mirrors
///         the bot's existing `evm_aave_usdc_executor`. Only its vault can move
///         funds, and withdrawals always return USDC to the vault.
contract AaveV3Adapter is IStrategyAdapter, IExitLiquidity {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying; // e.g. USDC
    IERC20 public immutable aToken;     // aUSDC, rebases ~1:1 with underlying
    IAaveV3Pool public immutable pool;
    address public immutable vault;

    error OnlyVault();

    constructor(IERC20 underlying_, IERC20 aToken_, IAaveV3Pool pool_, address vault_) {
        underlying = underlying_;
        aToken = aToken_;
        pool = pool_;
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    /// @notice Underlying claimable from Aave (aToken balance includes accrued interest).
    function totalAssets() external view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /// @notice Part of our aToken position Aave could pay out right now: zero if
    ///         the reserve is paused or inactive, otherwise capped by the reserve's
    ///         free cash (virtual balance on Aave >= 3.1, raw aToken cash before).
    function withdrawableNow() external view returns (uint256) {
        uint256 position = aToken.balanceOf(address(this));
        if (position == 0) return 0;
        uint256 cfg = pool.getConfiguration(address(underlying));
        bool active = (cfg >> 56) & 1 == 1;
        bool paused = (cfg >> 60) & 1 == 1;
        if (!active || paused) return 0;
        uint256 cash;
        try pool.getVirtualUnderlyingBalance(address(underlying)) returns (uint128 v) {
            cash = v;
        } catch {
            cash = underlying.balanceOf(address(aToken));
        }
        return position < cash ? position : cash;
    }

    function deposit(uint256 assets) external onlyVault {
        // The vault has already transferred `assets` of underlying to this adapter.
        underlying.forceApprove(address(pool), assets);
        pool.supply(address(underlying), assets, address(this), 0);
    }

    function withdraw(uint256 assets) external onlyVault {
        // Aave sends the underlying straight to the vault.
        pool.withdraw(address(underlying), assets, vault);
    }

    function withdrawAll() external onlyVault returns (uint256) {
        if (aToken.balanceOf(address(this)) == 0) return 0;
        // type(uint256).max tells Aave to withdraw the full balance.
        return pool.withdraw(address(underlying), type(uint256).max, vault);
    }
}
