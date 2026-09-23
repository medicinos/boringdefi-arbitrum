// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IExitLiquidity} from "../interfaces/IExitLiquidity.sol";
import {IComet} from "../interfaces/IComet.sol";

/// @title CompoundV3Adapter
/// @notice Routes vault USDC into a Compound III (Comet) market as a pure base
///         supplier - no collateral, no borrowing - and back. Only its vault can
///         move funds; withdrawals always go straight to the vault.
///
///         Written for BoringDeFi on Arbitrum (cUSDCv3, native USDC), works for
///         any Comet whose base token equals the vault asset.
contract CompoundV3Adapter is IStrategyAdapter, IExitLiquidity {
    using SafeERC20 for IERC20;

    IComet public immutable comet;
    IERC20 public immutable underlying;
    address public immutable vault;

    error OnlyVault();

    constructor(IComet comet_, address vault_) {
        comet = comet_;
        underlying = IERC20(comet_.baseToken());
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    /// @notice Base-asset supply balance including accrued interest.
    function totalAssets() external view returns (uint256) {
        return comet.balanceOf(address(this));
    }

    /// @notice Zero while Comet withdrawals are paused, otherwise the position
    ///         capped by the base-token cash sitting in the market.
    function withdrawableNow() external view returns (uint256) {
        uint256 position = comet.balanceOf(address(this));
        if (position == 0 || comet.isWithdrawPaused()) return 0;
        uint256 cash = underlying.balanceOf(address(comet));
        return position < cash ? position : cash;
    }

    function deposit(uint256 assets) external onlyVault {
        // The vault has already transferred `assets` of underlying to this adapter.
        underlying.forceApprove(address(comet), assets);
        comet.supply(address(underlying), assets);
    }

    function withdraw(uint256 assets) external onlyVault {
        comet.withdrawTo(vault, address(underlying), assets);
    }

    function withdrawAll() external onlyVault returns (uint256 withdrawn) {
        if (comet.balanceOf(address(this)) == 0) return 0;
        uint256 before = underlying.balanceOf(vault);
        // type(uint256).max withdraws the full supply balance (Comet convention).
        comet.withdrawTo(vault, address(underlying), type(uint256).max);
        withdrawn = underlying.balanceOf(vault) - before;
    }
}
