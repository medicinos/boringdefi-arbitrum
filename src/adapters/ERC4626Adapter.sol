// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IExitLiquidity} from "../interfaces/IExitLiquidity.sol";

/// @title ERC4626Adapter
/// @notice Routes vault USDC into any ERC-4626 vault (Morpho, Yearn, Euler, …)
///         and back. Mirrors the bot's existing ERC-4626 provider wiring
///         (`*_MORPHO_VAULT_ADDRESS`, `*_EXECUTOR_ERC4626_PROVIDERS_JSON`).
contract ERC4626Adapter is IStrategyAdapter, IExitLiquidity {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;
    IERC4626 public immutable targetVault; // the external ERC-4626 vault
    address public immutable vault;        // our AllocatorVault

    error OnlyVault();

    constructor(IERC4626 targetVault_, address vault_) {
        targetVault = targetVault_;
        underlying = IERC20(targetVault_.asset());
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    /// @notice Underlying value of the ERC-4626 shares this adapter holds.
    function totalAssets() external view returns (uint256) {
        return targetVault.convertToAssets(targetVault.balanceOf(address(this)));
    }

    /// @notice ERC-4626 `maxWithdraw` for this adapter. MetaMorpho and Fluid
    ///         fTokens bound it by the liquidity actually available in their
    ///         markets / withdrawal limits, so it drops when exits are constrained.
    function withdrawableNow() external view returns (uint256) {
        uint256 position = targetVault.convertToAssets(targetVault.balanceOf(address(this)));
        uint256 w = targetVault.maxWithdraw(address(this));
        return w < position ? w : position;
    }

    function deposit(uint256 assets) external onlyVault {
        // The vault has already transferred `assets` of underlying to this adapter.
        underlying.forceApprove(address(targetVault), assets);
        targetVault.deposit(assets, address(this));
    }

    function withdraw(uint256 assets) external onlyVault {
        // receiver = our vault, owner = this adapter (it holds the 4626 shares).
        targetVault.withdraw(assets, vault, address(this));
    }

    function withdrawAll() external onlyVault returns (uint256) {
        uint256 shares = targetVault.balanceOf(address(this));
        if (shares == 0) return 0;
        // redeem all shares — no exact-amount rounding revert on full exit.
        return targetVault.redeem(shares, vault, address(this));
    }
}
