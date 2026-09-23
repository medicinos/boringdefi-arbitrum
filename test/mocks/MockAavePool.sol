// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";

/// @notice Test-only aToken: minted/burned only by its pool, rebases 1:1.
contract MockAToken is ERC20 {
    address public immutable pool;

    constructor() ERC20("Mock aUSDC", "maUSDC") {
        pool = msg.sender;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == pool, "only pool");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == pool, "only pool");
        _burn(from, amount);
    }
}

/// @notice Test-only Aave v3 pool: supply pulls underlying and mints aTokens 1:1;
///         withdraw burns aTokens and returns underlying.
contract MockAavePool is IAaveV3Pool {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;
    MockAToken public immutable aToken;

    constructor(IERC20 underlying_) {
        underlying = underlying_;
        aToken = new MockAToken();
    }

    function supply(address asset_, uint256 amount, address onBehalfOf, uint16) external {
        require(asset_ == address(underlying), "bad asset");
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset_, uint256 amount, address to) external returns (uint256) {
        require(asset_ == address(underlying), "bad asset");
        // Mirror real Aave: type(uint256).max (or an over-amount) withdraws the full balance.
        uint256 bal = aToken.balanceOf(msg.sender);
        if (amount == type(uint256).max || amount > bal) amount = bal;
        aToken.burn(msg.sender, amount);
        underlying.safeTransfer(to, amount);
        return amount;
    }

    bool public paused;

    function setPaused(bool p) external {
        paused = p;
    }

    /// @dev Active bit (56) always set; paused bit (60) mirrors `paused`.
    function getConfiguration(address) external view returns (uint256) {
        return (uint256(1) << 56) | (paused ? (uint256(1) << 60) : 0);
    }

    function getVirtualUnderlyingBalance(address) external view returns (uint128) {
        return uint128(underlying.balanceOf(address(this)));
    }

    /// @dev Test helper: accrue interest to a holder. Caller must fund the pool
    ///      with matching underlying first so withdrawals stay solvent.
    function accrueInterest(address holder, uint256 amount) external {
        aToken.mint(holder, amount);
    }
}
