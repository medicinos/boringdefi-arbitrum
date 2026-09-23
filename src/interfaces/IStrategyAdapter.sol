// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStrategyAdapter
/// @notice Minimal interface the vault uses to route capital into an allowlisted
///         venue (e.g. an Aave/Morpho/ERC-4626 wrapper). The vault PUSHES assets
///         to the adapter then calls `deposit`, and `withdraw` pulls them back to
///         the vault. An adapter must only ever return funds to its vault.
interface IStrategyAdapter {
    /// @notice The underlying asset (must equal the vault asset, e.g. USDC).
    function asset() external view returns (address);

    /// @notice Assets this adapter currently holds on behalf of the vault.
    function totalAssets() external view returns (uint256);

    /// @notice Account for `assets` already transferred into the adapter by the vault.
    function deposit(uint256 assets) external;

    /// @notice Return `assets` back to the calling vault.
    function withdraw(uint256 assets) external;

    /// @notice Return the adapter's ENTIRE position to the vault. Avoids
    ///         exact-amount rounding reverts on full exits from rebasing/share
    ///         based venues. Returns the underlying amount sent back.
    function withdrawAll() external returns (uint256 withdrawn);
}
