// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test-only ERC-4626 vault (stands in for Morpho/Yearn/etc.). Donate
///         underlying to it to simulate yield (raises convertToAssets).
contract Mock4626 is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock 4626", "m4626") ERC4626(asset_) {}
}
