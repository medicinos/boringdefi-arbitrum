// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AllocatorVault} from "../src/AllocatorVault.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {Mock4626} from "./mocks/Mock4626.sol";

contract AdaptersTest is Test {
    MockERC20 usdc;
    AllocatorVault vault;
    address admin;
    address keeper;
    address alice;

    uint256 constant CAP = 1_000_000e6;
    uint256 constant START = 1_000_000e6;

    function setUp() public {
        admin = makeAddr("admin");
        keeper = makeAddr("keeper");
        alice = makeAddr("alice");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new AllocatorVault(IERC20(address(usdc)), "SYA USDC Vault", "syaUSDC", admin, CAP);
        vm.startPrank(admin);
        vault.grantRole(vault.KEEPER_ROLE(), keeper);
        vm.stopPrank();

        usdc.mint(alice, START);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(100_000e6, alice);
    }

    // ── Aave v3 adapter (mirrors evm_aave_usdc_executor) ─────────────────

    function test_AaveAdapter_DeployRecallWithdraw() public {
        MockAavePool pool = new MockAavePool(IERC20(address(usdc)));
        AaveV3Adapter ad = new AaveV3Adapter(IERC20(address(usdc)), IERC20(address(pool.aToken())), pool, address(vault));
        vm.prank(admin);
        vault.setStrategy(address(ad), true);

        vm.prank(keeper);
        vault.deployToStrategy(address(ad), 60_000e6);
        assertEq(ad.totalAssets(), 60_000e6);
        assertEq(usdc.balanceOf(address(vault)), 40_000e6);
        assertEq(vault.totalAssets(), 100_000e6);

        vm.prank(keeper);
        vault.recallFromStrategy(address(ad), 20_000e6);
        assertEq(ad.totalAssets(), 40_000e6);
        assertEq(usdc.balanceOf(address(vault)), 60_000e6);

        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(sh, alice, alice); // auto-recalls remaining from Aave
        assertEq(usdc.balanceOf(alice), START);
        assertEq(ad.totalAssets(), 0);
    }

    function test_AaveAdapter_YieldFlowsToDepositor() public {
        MockAavePool pool = new MockAavePool(IERC20(address(usdc)));
        AaveV3Adapter ad = new AaveV3Adapter(IERC20(address(usdc)), IERC20(address(pool.aToken())), pool, address(vault));
        vm.prank(admin);
        vault.setStrategy(address(ad), true);
        vm.prank(keeper);
        vault.deployToStrategy(address(ad), 100_000e6);

        usdc.mint(address(pool), 5_000e6); // fund the pool to stay solvent
        pool.accrueInterest(address(ad), 5_000e6);
        assertEq(vault.totalAssets(), 105_000e6);

        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(sh, alice, alice);
        assertApproxEqAbs(usdc.balanceOf(alice), START + 5_000e6, 2);
    }

    // ── ERC-4626 adapter (mirrors Morpho/Yearn/Euler wiring) ─────────────

    function test_ERC4626Adapter_DeployRecallWithdraw() public {
        Mock4626 t = new Mock4626(IERC20(address(usdc)));
        ERC4626Adapter ad = new ERC4626Adapter(IERC4626(address(t)), address(vault));
        vm.prank(admin);
        vault.setStrategy(address(ad), true);

        vm.prank(keeper);
        vault.deployToStrategy(address(ad), 60_000e6);
        assertApproxEqAbs(ad.totalAssets(), 60_000e6, 2);
        assertEq(usdc.balanceOf(address(vault)), 40_000e6);

        vm.prank(keeper);
        vault.recallFromStrategy(address(ad), 20_000e6);
        assertApproxEqAbs(ad.totalAssets(), 40_000e6, 2);

        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(sh, alice, alice);
        assertApproxEqAbs(usdc.balanceOf(alice), START, 3);
    }

    function test_ERC4626Adapter_YieldFlowsToDepositor() public {
        Mock4626 t = new Mock4626(IERC20(address(usdc)));
        ERC4626Adapter ad = new ERC4626Adapter(IERC4626(address(t)), address(vault));
        vm.prank(admin);
        vault.setStrategy(address(ad), true);
        vm.prank(keeper);
        vault.deployToStrategy(address(ad), 100_000e6);

        usdc.mint(address(t), 5_000e6); // donate yield into the 4626 vault
        assertApproxEqAbs(vault.totalAssets(), 105_000e6, 2);

        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(sh, alice, alice);
        assertApproxEqAbs(usdc.balanceOf(alice), START + 5_000e6, 5);
    }
}
