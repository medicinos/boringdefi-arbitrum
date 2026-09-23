// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Compound III (Comet) surface used by CompoundV3Adapter.
interface IComet {
    function baseToken() external view returns (address);
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function withdrawTo(address to, address asset, uint256 amount) external;
    /// @notice Present value of the base-asset supply balance (accrues interest).
    function balanceOf(address account) external view returns (uint256);
    function isWithdrawPaused() external view returns (bool);
}
