// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStrategyAdapter} from "../../src/interfaces/IStrategyAdapter.sol";

/// @notice Test-only fully-liquid strategy adapter. Only its vault can move funds;
///         it always returns assets to that vault. `simulateYield` models gains.
contract MockStrategy is IStrategyAdapter {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable vault;
    uint256 public deployed;

    constructor(IERC20 token_, address vault_) {
        token = token_;
        vault = vault_;
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function totalAssets() external view returns (uint256) {
        return deployed;
    }

    function deposit(uint256 assets) external {
        require(msg.sender == vault, "only vault");
        deployed += assets; // tokens were already transferred in by the vault
    }

    function withdraw(uint256 assets) external {
        require(msg.sender == vault, "only vault");
        deployed -= assets;
        token.safeTransfer(vault, assets);
    }

    function withdrawAll() external returns (uint256) {
        require(msg.sender == vault, "only vault");
        uint256 amount = deployed;
        deployed = 0;
        token.safeTransfer(vault, amount);
        return amount;
    }

    /// @dev Test helper: caller must have minted matching tokens to this contract.
    function simulateYield(uint256 amount) external {
        deployed += amount;
    }
}
