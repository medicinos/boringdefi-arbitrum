// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BoringVault} from "../../src/BoringVault.sol";
import {AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {CompoundV3Adapter} from "../../src/adapters/CompoundV3Adapter.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IComet} from "../../src/interfaces/IComet.sol";
import {ArbitrumAddresses as A} from "../../script/ArbitrumAddresses.sol";

/// @notice Forks Arbitrum One and routes vault USDC through the REAL Aave v3,
///         Fluid, Compound III and two Morpho vaults. No real funds involved.
///
///   forge test --match-path "test/fork/*" -vv
///   (ARB_RPC_URL overrides the public RPC; ARB_FORK_BLOCK pins a block)
contract ArbitrumForkTest is Test {
    BoringVault vault;
    AaveV3Adapter aave;
    ERC4626Adapter fluid;
    CompoundV3Adapter compound;
    ERC4626Adapter steakhouse;
    ERC4626Adapter gauntlet;

    IERC20 usdc = IERC20(A.USDC);
    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");

    uint256 constant DEPOSIT = 100_000e6;

    function setUp() public {
        string memory rpc = vm.envOr("ARB_RPC_URL", string("https://arb1.arbitrum.io/rpc"));
        uint256 blockNo = vm.envOr("ARB_FORK_BLOCK", uint256(0));
        if (blockNo == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNo);
        assertEq(block.chainid, A.CHAIN_ID);

        vault = new BoringVault(usdc, "BoringDeFi USDC (Arbitrum)", "boringUSDC", admin, 1_000_000e6, treasury, 100, 200, 10_000);
        aave = new AaveV3Adapter(usdc, IERC20(A.AAVE_AUSDC), IAaveV3Pool(A.AAVE_POOL), address(vault));
        fluid = new ERC4626Adapter(IERC4626(A.FLUID_FUSDC), address(vault));
        compound = new CompoundV3Adapter(IComet(A.COMET_USDC), address(vault));
        steakhouse = new ERC4626Adapter(IERC4626(A.MORPHO_STEAKHOUSE_HY), address(vault));
        gauntlet = new ERC4626Adapter(IERC4626(A.MORPHO_GAUNTLET_CORE), address(vault));

        vm.startPrank(admin);
        vault.grantRole(vault.KEEPER_ROLE(), keeper);
        _allow(address(aave), 4_000);
        _allow(address(fluid), 4_000);
        _allow(address(compound), 2_500);
        _allow(address(steakhouse), 2_000);
        _allow(address(gauntlet), 1_500);
        vm.stopPrank();

        deal(A.USDC, alice, DEPOSIT);
        assertEq(usdc.balanceOf(alice), DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();
    }

    function _allow(address s, uint256 cap) internal {
        vault.setStrategy(s, true);
        vault.setAllocationCap(s, cap);
    }

    function _spreadAcrossAllVenues() internal {
        vm.startPrank(keeper);
        vault.deployToStrategy(address(aave), 30_000e6);
        vault.deployToStrategy(address(fluid), 30_000e6);
        vault.deployToStrategy(address(compound), 20_000e6);
        vault.deployToStrategy(address(steakhouse), 10_000e6);
        vault.deployToStrategy(address(gauntlet), 5_000e6);
        vm.stopPrank();
    }

    function test_Fork_EveryVenueAcceptsFundsAndReportsExitLiquidity() public {
        _spreadAcrossAllVenues();

        assertApproxEqAbs(aave.totalAssets(), 30_000e6, 2);
        assertApproxEqAbs(fluid.totalAssets(), 30_000e6, 2);
        assertApproxEqAbs(compound.totalAssets(), 20_000e6, 2);
        assertApproxEqAbs(steakhouse.totalAssets(), 10_000e6, 2);
        assertApproxEqAbs(gauntlet.totalAssets(), 5_000e6, 2);
        assertEq(usdc.balanceOf(address(vault)), 5_000e6);
        assertApproxEqAbs(vault.totalAssets(), DEPOSIT, 10);

        // Every real venue can pay our whole position back right now.
        assertApproxEqAbs(aave.withdrawableNow(), aave.totalAssets(), 1);
        assertApproxEqAbs(fluid.withdrawableNow(), fluid.totalAssets(), 1);
        assertApproxEqAbs(compound.withdrawableNow(), compound.totalAssets(), 1);
        assertApproxEqAbs(steakhouse.withdrawableNow(), steakhouse.totalAssets(), 1);
        assertApproxEqAbs(gauntlet.withdrawableNow(), gauntlet.totalAssets(), 1);
    }

    function test_Fork_ConcentrationCapOnRealVenue() public {
        vm.prank(keeper);
        vm.expectPartialRevert(BoringVault.OverAllocation.selector); // 41 % into Aave > 40 % cap
        vault.deployToStrategy(address(aave), 41_000e6);
    }

    function test_Fork_YieldAccruesAndFeeIsOnlyOnProfit() public {
        _spreadAcrossAllVenues();
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        uint256 total = vault.totalAssets();
        assertGt(total, DEPOSIT, "no yield after 30 days");

        uint256 shares = vault.balanceOf(alice);
        (uint256 gross, uint256 profit, uint256 fee) = vault.quoteFee(alice, shares);
        assertGt(profit, 0);
        assertEq(fee, (profit * 100) / 10_000);

        vm.prank(alice);
        vault.redeem(shares, alice, alice); // returns GROSS assets (documented ERC-4626 deviation B2)
        uint256 got = usdc.balanceOf(alice);
        assertApproxEqAbs(got, gross - fee, 5);
        assertGt(got, DEPOSIT, "depositor lost principal");
        assertApproxEqAbs(usdc.balanceOf(treasury), fee, 5);
        emit log_named_decimal_uint("30-day profit (USDC)", profit, 6);
        emit log_named_decimal_uint("fee to treasury (USDC)", fee, 6);
    }

    function test_Fork_FullExitPullsFromEveryVenue() public {
        _spreadAcrossAllVenues();
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(got, DEPOSIT, 10);
        assertLe(aave.totalAssets(), 1);
        assertLe(fluid.totalAssets(), 1);
        assertLe(compound.totalAssets(), 1);
        assertLe(steakhouse.totalAssets(), 1);
        assertLe(gauntlet.totalAssets(), 1);
    }

    function test_Fork_ExitGuardBlocksDrainedAavePool() public {
        // Simulate Aave USDC at ~100 % utilization: almost no free cash left.
        vm.mockCall(
            A.AAVE_POOL,
            abi.encodeWithSelector(IAaveV3Pool.getVirtualUnderlyingBalance.selector, A.USDC),
            abi.encode(uint128(1_000e6))
        );
        vm.prank(keeper);
        // (position may be 1 wei below 20k after Aave's ray rounding -> match the error, not the numbers)
        vm.expectPartialRevert(BoringVault.ExitLiquidityTooLow.selector);
        vault.deployToStrategy(address(aave), 20_000e6);
    }

    function test_Fork_ExitGuardBlocksPausedComet() public {
        vm.mockCall(A.COMET_USDC, abi.encodeWithSelector(IComet.isWithdrawPaused.selector), abi.encode(true));
        vm.prank(keeper);
        vm.expectPartialRevert(BoringVault.ExitLiquidityTooLow.selector);
        vault.deployToStrategy(address(compound), 10_000e6);
    }

    function test_Fork_FrozenVenueDoesNotBlockWithdrawals() public {
        vm.startPrank(keeper);
        vault.deployToStrategy(address(aave), 40_000e6);
        vault.deployToStrategy(address(fluid), 40_000e6);
        vm.stopPrank();

        // Aave refuses every withdrawal (e.g. reserve paused by governance).
        vm.mockCallRevert(A.AAVE_POOL, abi.encodeWithSelector(IAaveV3Pool.withdraw.selector), "paused");

        // 20k idle + Fluid covers 50k although Aave is frozen.
        vm.prank(alice);
        vault.withdraw(50_000e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 50_000e6);
        assertApproxEqAbs(aave.totalAssets(), 40_000e6, 2);
    }
}
