// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AllocatorVaultV2} from "../src/AllocatorVaultV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice AUDIT Round 5 — stateful invariants for the fee vault. A handler drives
///         random deposit / redeem / yield / loss across 3 actors; after every
///         sequence we assert the safety properties an external auditor cares about:
///           INV1 (solvency): the vault never claims more share value than it holds.
///           INV2 (fee never on principal): cumulative treasury payouts can never
///                 exceed the total profit (yield) ever injected — i.e. the fee is
///                 mathematically incapable of touching principal.
contract Handler is Test {
    AllocatorVaultV2 public vault;
    MockERC20 public usdc;
    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];
    uint256 public totalYieldInjected;

    constructor(AllocatorVaultV2 v, MockERC20 u) {
        vault = v;
        usdc = u;
        for (uint256 i; i < actors.length; i++) usdc.mint(actors[i], 1_000_000e6);
    }

    function deposit(uint256 actorSeed, uint256 amt) external {
        address a = actors[actorSeed % actors.length];
        amt = bound(amt, 1e6, 100_000e6);
        if (usdc.balanceOf(a) < amt) return;
        vm.startPrank(a);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, a);
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 sharesSeed) external {
        address a = actors[actorSeed % actors.length];
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 sh = bound(sharesSeed, 1, bal);
        vm.prank(a);
        vault.redeem(sh, a, a);
    }

    function injectYield(uint256 amt) external {
        amt = bound(amt, 0, 50_000e6);
        if (amt == 0) return;
        usdc.mint(address(vault), amt);
        totalYieldInjected += amt;
    }

    function injectLoss(uint256 amt) external {
        uint256 vb = usdc.balanceOf(address(vault));
        amt = bound(amt, 0, vb);
        if (amt == 0) return;
        vm.prank(address(vault));
        usdc.transfer(address(0xdead), amt);
    }
}

contract AllocatorVaultV2InvariantTest is Test {
    AllocatorVaultV2 vault;
    MockERC20 usdc;
    Handler handler;
    address treasury = address(0x7EE);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new AllocatorVaultV2(
            IERC20(address(usdc)), "bd", "bd", address(this), 5_000e6, treasury, 500 // 5% fee
        );
        handler = new Handler(vault, usdc);
        targetContract(address(handler));
    }

    /// INV1: share value never exceeds backing (no phantom assets / offset drift).
    function invariant_Solvency() public view {
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets() + 1);
    }

    /// INV2: the treasury (fees) can never receive more than the total profit ever
    /// created → the performance fee can never be charged on principal.
    function invariant_FeeNeverOnPrincipal() public view {
        assertLe(usdc.balanceOf(treasury), handler.totalYieldInjected());
    }
}
