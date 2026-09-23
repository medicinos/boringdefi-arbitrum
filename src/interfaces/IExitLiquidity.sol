// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IExitLiquidity
/// @notice Optional adapter extension: how much of the adapter's position could
///         be withdrawn from the venue RIGHT NOW. A lending venue at 100%
///         utilization, a paused market or an ERC-4626 vault whose markets are
///         illiquid all report less than `totalAssets()` here.
///
///         BoringVault reads this after every keeper deploy and refuses to leave
///         depositors' money in a venue they could not exit from today.
interface IExitLiquidity {
    /// @return assets Underlying withdrawable immediately (always <= totalAssets()).
    function withdrawableNow() external view returns (uint256 assets);
}
