// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Aave v3 Pool surface used by the adapter (supply/withdraw USDC).
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Reserve configuration bitmap (bit 56 active, 57 frozen, 60 paused).
    function getConfiguration(address asset) external view returns (uint256);

    /// @notice Aave >= 3.1 virtual accounting: underlying cash the reserve can pay out.
    function getVirtualUnderlyingBalance(address asset) external view returns (uint128);
}
