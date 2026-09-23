// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {BoringVault} from "../src/BoringVault.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";

/// @notice The three on-chain guards (concentration, idle buffer, exit liquidity)
///         and the resilient withdrawal path of BoringVault.
contract BoringVaultTest is Test {
    MockERC20 usdc;
    BoringVault vault;
    MockVenue a;
    MockVenue b;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");

    uint256 constant CAP_PER_CALL = 1_000_000e6;
    uint256 constant IDLE_BPS = 500; // 5 %
    uint256 constant EXIT_BPS = 10_000; // venue must be 100 % exitable after a deploy

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new BoringVault(
            IERC20(address(usdc)), "BoringDeFi USDC (Arbitrum)", "boringUSDC", admin, CAP_PER_CALL, treasury, 100, IDLE_BPS, EXIT_BPS
        );
        a = new MockVenue(IERC20(address(usdc)), address(vault));
        b = new MockVenue(IERC20(address(usdc)), address(vault));

        vm.startPrank(admin);
        vault.grantRole(vault.KEEPER_ROLE(), keeper);
        vault.setStrategy(address(a), true);
        vault.setStrategy(address(b), true);
        vault.setAllocationCap(address(a), 6_000); // 60 %
        vault.setAllocationCap(address(b), 4_000); // 40 %
        vm.stopPrank();

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(100_000e6, alice);
    }

    function _deploy(address s, uint256 amt) internal {
        vm.prank(keeper);
        vault.deployToStrategy(s, amt);
    }

    // ── guard 1: concentration ─────────────────────────────────────────────

    function test_DeployWithinAllGuards() public {
        _deploy(address(a), 60_000e6);
        _deploy(address(b), 35_000e6);
        assertEq(a.totalAssets(), 60_000e6);
        assertEq(b.totalAssets(), 35_000e6);
        assertEq(usdc.balanceOf(address(vault)), 5_000e6);
        assertEq(vault.totalAssets(), 100_000e6);
    }

    function test_VenueWithoutCapIsClosed() public {
        MockVenue c = new MockVenue(IERC20(address(usdc)), address(vault));
        vm.prank(admin);
        vault.setStrategy(address(c), true);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BoringVault.CapNotSet.selector, address(c)));
        vault.deployToStrategy(address(c), 1e6);
    }

    function test_ConcentrationCapReverts() public {
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(BoringVault.OverAllocation.selector, address(b), 40_000e6 + 1, 40_000e6)
        );
        vault.deployToStrategy(address(b), 40_000e6 + 1);
    }

    function test_ConcentrationIsCumulative() public {
        _deploy(address(a), 50_000e6);
        vm.prank(keeper);
        vm.expectRevert(); // 50k + 10.001k > 60 % of 100k
        vault.deployToStrategy(address(a), 10_001e6);
    }

    // ── guard 2: idle buffer ───────────────────────────────────────────────

    function test_IdleBufferReverts() public {
        _deploy(address(a), 60_000e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BoringVault.IdleBelowBuffer.selector, 4_000e6, 5_000e6));
        vault.deployToStrategy(address(b), 36_000e6);
    }

    // ── guard 3: exit liquidity ────────────────────────────────────────────

    function test_IlliquidVenueCannotReceiveFunds() public {
        _deploy(address(a), 10_000e6);
        a.setLiquidBps(9_000); // venue now pays back only 90 % on demand (e.g. utilization spike)
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(BoringVault.ExitLiquidityTooLow.selector, address(a), 18_000e6, 20_000e6)
        );
        vault.deployToStrategy(address(a), 10_000e6);
    }

    function test_AdapterWithoutExitReportCountsAsIlliquid() public {
        MockStrategy legacy = new MockStrategy(IERC20(address(usdc)), address(vault));
        vm.startPrank(admin);
        vault.setStrategy(address(legacy), true);
        vault.setAllocationCap(address(legacy), 5_000);
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(BoringVault.ExitLiquidityTooLow.selector, address(legacy), 0, 1_000e6)
        );
        vault.deployToStrategy(address(legacy), 1_000e6);
    }

    function test_ExitGuardCanBeRelaxedByAdminOnly() public {
        a.setLiquidBps(9_000);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, bytes32(0))
        );
        vault.setGuards(IDLE_BPS, 8_000);
        vm.prank(admin);
        vault.setGuards(IDLE_BPS, 8_000);
        _deploy(address(a), 10_000e6); // 90 % >= 80 %
        assertEq(a.totalAssets(), 10_000e6);
    }

    // ── recalls and withdrawals are never blocked by the guards ────────────

    function test_RecallAllowedEvenWhenVenueOverCap() public {
        _deploy(address(a), 60_000e6);
        vm.prank(admin);
        vault.setAllocationCap(address(a), 1_000); // admin tightens the cap to 10 %
        vm.prank(keeper);
        vault.recallFromStrategy(address(a), 50_000e6); // de-risking still works
        assertEq(a.totalAssets(), 10_000e6);
    }

    function test_WithdrawSkipsFrozenVenue() public {
        _deploy(address(a), 60_000e6);
        _deploy(address(b), 35_000e6);
        a.setLiquidBps(0); // venue A frozen: withdrawAll and withdraw both revert

        uint256 shares = vault.previewWithdraw(30_000e6);
        vm.prank(alice);
        vault.redeem(shares, alice, alice); // 5k idle + 35k from B covers it

        assertEq(a.totalAssets(), 60_000e6); // untouched
        assertEq(b.totalAssets(), 0);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6 - 100_000e6 + 30_000e6, 1);
    }

    function test_WithdrawTakesPartialFromConstrainedVenue() public {
        _deploy(address(a), 60_000e6);
        _deploy(address(b), 35_000e6);
        b.setLiquidBps(5_000); // B can pay back 17.5k now
        a.setLiquidBps(5_000); // A can pay back 30k now

        uint256 shares = vault.previewWithdraw(50_000e6);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        // 5k idle + 30k from A (partial) + 15k from B (partial) = 50k
        assertApproxEqAbs(usdc.balanceOf(alice), 950_000e6, 1);
        assertEq(a.totalAssets(), 30_000e6);
        assertApproxEqAbs(b.totalAssets(), 20_000e6, 1);
    }

    function test_WithdrawRevertsWhenVenuesCannotCover() public {
        _deploy(address(a), 60_000e6);
        _deploy(address(b), 35_000e6);
        a.setLiquidBps(0);
        b.setLiquidBps(0);
        uint256 shares = vault.previewWithdraw(10_000e6);
        vm.prank(alice);
        vm.expectRevert(); // only 5k idle; nobody is paid with someone else's money
        vault.redeem(shares, alice, alice);
    }

    // ── report ─────────────────────────────────────────────────────────────

    function test_AllocationReport() public {
        _deploy(address(a), 60_000e6);
        _deploy(address(b), 20_000e6);
        b.setLiquidBps(5_000);
        (
            address[] memory venues,
            uint256[] memory assets,
            uint256[] memory withdrawable,
            uint256[] memory caps,
            uint256 idle,
            uint256 total
        ) = vault.allocationReport();
        assertEq(venues.length, 2);
        assertEq(venues[0], address(a));
        assertEq(assets[0], 60_000e6);
        assertEq(withdrawable[1], 10_000e6);
        assertEq(caps[0], 6_000);
        assertEq(idle, 20_000e6);
        assertEq(total, 100_000e6);
    }

    function test_BadBpsRejected() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(BoringVault.BadBps.selector, 10_001));
        vault.setAllocationCap(address(a), 10_001);
        vm.expectRevert(abi.encodeWithSelector(BoringVault.BadBps.selector, 10_001));
        vault.setGuards(10_001, 0);
        vm.stopPrank();
    }

    // ── fuzz: a deploy either reverts or leaves every guard satisfied ──────

    function testFuzz_DeployNeverBreaksGuards(uint256 amtA, uint256 amtB, uint16 liqA) public {
        amtA = bound(amtA, 1, 100_000e6);
        amtB = bound(amtB, 1, 100_000e6);
        a.setLiquidBps(bound(liqA, 0, 10_000));
        vm.startPrank(keeper);
        try vault.deployToStrategy(address(a), amtA) {} catch {}
        try vault.deployToStrategy(address(b), amtB) {} catch {}
        vm.stopPrank();

        uint256 total = vault.totalAssets();
        assertEq(total, 100_000e6); // nothing lost
        assertLe(a.totalAssets() * 10_000, total * 6_000);
        assertLe(b.totalAssets() * 10_000, total * 4_000);
        assertGe(usdc.balanceOf(address(vault)) * 10_000, total * IDLE_BPS);
        if (a.totalAssets() > 0) assertGe(a.withdrawableNow(), a.totalAssets());
    }

    // ── real adapter against the mock Aave pool ────────────────────────────

    function test_AaveAdapterReportsPausedReserveAsIlliquid() public {
        MockAavePool pool = new MockAavePool(IERC20(address(usdc)));
        AaveV3Adapter aave =
            new AaveV3Adapter(IERC20(address(usdc)), IERC20(address(pool.aToken())), IAaveV3Pool(address(pool)), address(vault));
        vm.startPrank(admin);
        vault.setStrategy(address(aave), true);
        vault.setAllocationCap(address(aave), 5_000);
        vm.stopPrank();

        _deploy(address(aave), 10_000e6);
        assertEq(aave.withdrawableNow(), 10_000e6);

        pool.setPaused(true);
        assertEq(aave.withdrawableNow(), 0);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(BoringVault.ExitLiquidityTooLow.selector, address(aave), 0, 11_000e6)
        );
        vault.deployToStrategy(address(aave), 1_000e6);
    }
}
