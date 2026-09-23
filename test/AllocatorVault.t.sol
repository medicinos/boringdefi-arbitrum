// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {AllocatorVault} from "../src/AllocatorVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

contract AllocatorVaultTest is Test {
    MockERC20 usdc;
    AllocatorVault vault;
    MockStrategy strat;
    MockStrategy stratB;

    address admin;
    address keeper;
    address alice;
    address attacker;

    uint256 constant CAP = 100_000e6;
    uint256 constant START = 1_000_000e6;

    function setUp() public {
        admin = makeAddr("admin");
        keeper = makeAddr("keeper");
        alice = makeAddr("alice");
        attacker = makeAddr("attacker");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new AllocatorVault(IERC20(address(usdc)), "SYA USDC Vault", "syaUSDC", admin, CAP);
        strat = new MockStrategy(IERC20(address(usdc)), address(vault));
        stratB = new MockStrategy(IERC20(address(usdc)), address(vault));

        vm.startPrank(admin);
        vault.grantRole(vault.KEEPER_ROLE(), keeper);
        vault.setStrategy(address(strat), true);
        vm.stopPrank();

        usdc.mint(alice, START);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _deposit(uint256 amt) internal {
        vm.prank(alice);
        vault.deposit(amt, alice);
    }

    // ── core ERC-4626 ownership ──────────────────────────────────────────

    function test_DepositMintsShares_RedeemReturnsAssets() public {
        _deposit(1000e6);
        // AUDIT A6: _decimalsOffset()==6 → first deposit mints assets * 10**6 shares
        // (OZ virtual-shares anti-inflation). Round-trip value is unchanged.
        assertEq(vault.balanceOf(alice), 1000e6 * 1e6);
        assertEq(vault.totalAssets(), 1000e6);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(usdc.balanceOf(alice), START);
        assertEq(vault.totalAssets(), 0);
    }

    // ── keeper is constrained to the allowlist + cap ─────────────────────

    function test_KeeperDeploysToAllowlistedStrategy() public {
        _deposit(1000e6);
        vm.prank(keeper);
        vault.deployToStrategy(address(strat), 600e6);
        assertEq(usdc.balanceOf(address(vault)), 400e6);
        assertEq(strat.totalAssets(), 600e6);
        assertEq(vault.totalAssets(), 1000e6);
    }

    function test_KeeperCannotDeployToNonAllowlisted() public {
        _deposit(1000e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AllocatorVault.NotStrategy.selector, address(stratB)));
        vault.deployToStrategy(address(stratB), 100e6);
    }

    function test_KeeperCannotExceedCap() public {
        _deposit(START);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AllocatorVault.OverCap.selector, CAP + 1, CAP));
        vault.deployToStrategy(address(strat), CAP + 1);
    }

    function test_NonKeeperCannotDeploy() public {
        _deposit(1000e6);
        vm.prank(attacker);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        vault.deployToStrategy(address(strat), 100e6);
    }

    function test_OnlyAdminManagesAllowlist() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setStrategy(address(stratB), true);
    }

    // ── the core non-custodial guarantees ────────────────────────────────

    function test_KeeperCannotDrain_UserValuePreserved() public {
        _deposit(1000e6);
        vm.startPrank(keeper);
        vault.deployToStrategy(address(strat), 100e6);
        vault.recallFromStrategy(address(strat), 50e6);
        vault.deployToStrategy(address(strat), 100e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(keeper), 0); // keeper never receives funds

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(usdc.balanceOf(alice), START); // depositor keeps full value
    }

    function test_UserWithdrawAutoRecallsFromStrategy() public {
        _deposit(1000e6);
        vm.prank(keeper);
        vault.deployToStrategy(address(strat), 800e6); // idle 200, strat 800

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice); // must auto-recall to honor withdrawal
        assertEq(usdc.balanceOf(alice), START);
        assertEq(strat.totalAssets(), 0);
    }

    function test_PauseStopsKeeperButNotWithdrawals() public {
        _deposit(1000e6);
        vm.prank(keeper);
        vault.deployToStrategy(address(strat), 500e6);

        vm.prank(admin);
        vault.pause();

        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deployToStrategy(address(strat), 100e6);

        // depositor can still exit while paused
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(usdc.balanceOf(alice), START);
    }

    function test_YieldAccruesToDepositor() public {
        _deposit(1000e6);
        vm.prank(keeper);
        vault.deployToStrategy(address(strat), 1000e6);

        usdc.mint(address(strat), 50e6); // +50 USDC of "yield"
        strat.simulateYield(50e6);
        assertEq(vault.totalAssets(), 1050e6);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        // ERC-4626 rounds in the vault's favor (anti-inflation), so the depositor
        // may be short by up to a couple of wei of dust — never gains at others' expense.
        assertApproxEqAbs(usdc.balanceOf(alice), START + 50e6, 2);
        assertLe(usdc.balanceOf(alice), START + 50e6);
    }
}
