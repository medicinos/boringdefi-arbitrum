// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStrategyAdapter} from "../../src/interfaces/IStrategyAdapter.sol";
import {IExitLiquidity} from "../../src/interfaces/IExitLiquidity.sol";

/// @notice Test-only venue whose exit liquidity can be squeezed, like a lending
///         pool at high utilization. `liquid` = how much could be withdrawn now.
///         withdrawAll() reverts unless the whole position is liquid.
contract MockVenue is IStrategyAdapter, IExitLiquidity {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable vault;
    uint256 public deployed;
    uint256 public liquidBps = 10_000; // share of the position withdrawable now

    constructor(IERC20 token_, address vault_) {
        token = token_;
        vault = vault_;
    }

    function setLiquidBps(uint256 bps) external {
        liquidBps = bps;
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function totalAssets() external view returns (uint256) {
        return deployed;
    }

    function withdrawableNow() public view returns (uint256) {
        return (deployed * liquidBps) / 10_000;
    }

    function deposit(uint256 assets) external {
        require(msg.sender == vault, "only vault");
        deployed += assets;
    }

    function withdraw(uint256 assets) external {
        require(msg.sender == vault, "only vault");
        require(assets <= withdrawableNow(), "venue illiquid");
        deployed -= assets;
        token.safeTransfer(vault, assets);
    }

    function withdrawAll() external returns (uint256 amount) {
        require(msg.sender == vault, "only vault");
        require(liquidBps >= 10_000, "venue illiquid");
        amount = deployed;
        deployed = 0;
        token.safeTransfer(vault, amount);
    }
}
