// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AllocatorVaultV2} from "../src/AllocatorVaultV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Proves the on-chain performance fee charges ONLY on profit, never
///         on principal, and that cost basis is tracked correctly.
contract AllocatorVaultV2Test is Test {
    MockERC20 usdc;
    AllocatorVaultV2 vault;

    address admin = address(0xA11CE);
    address treasury = address(0x7EE);
    address alice = address(0xA1);
    address bob = address(0xB0B);
    uint256 constant FEE = 100; // 1%

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new AllocatorVaultV2(
            IERC20(address(usdc)), "boringdefi USDC", "bdUSDC", admin, 5_000e6, treasury, FEE
        );
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev Simulate yield: mint USDC straight into the vault, raising PPS.
    function _yield(uint256 amt) internal {
        usdc.mint(address(vault), amt);
    }

    /// @dev Simulate a loss: move USDC out of the vault, lowering PPS.
    function _loss(uint256 amt) internal {
        vm.prank(address(vault));
        usdc.transfer(address(0xdead), amt);
    }

    function test_DeploysWithFeeAndCap() public view {
        assertEq(vault.performanceFeeBps(), FEE);
        assertEq(vault.treasury(), treasury);
        assertEq(vault.MAX_FEE_BPS(), 2_000);
    }

    function test_RejectsFeeAboveCap() public {
        vm.expectRevert(bytes("fee>max"));
        new AllocatorVaultV2(IERC20(address(usdc)), "x", "x", admin, 0, treasury, 2_001);
    }

    function test_NoFeeOnPrincipalOnly() public {
        _deposit(alice, 1_000e6);
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(sh, alice, alice);
        assertEq(usdc.balanceOf(alice), 10_000e6); // full principal back
        assertEq(usdc.balanceOf(treasury), 0); // no fee on principal
    }

    function test_FeeOnProfitOnly() public {
        _deposit(alice, 1_000e6); // alice now holds 9_000e6 USDC
        _yield(1_000e6); // her shares are now worth ~2_000e6

        uint256 sh = vault.balanceOf(alice);
        (uint256 gross, uint256 profit, uint256 fee) = vault.quoteFee(alice, sh);

        assertApproxEqAbs(profit, 1_000e6, 1e4); // ~1000 profit
        assertApproxEqAbs(fee, 10e6, 1e4); // 1% of profit ~ 10

        vm.prank(alice);
        vault.redeem(sh, alice, alice);

        assertApproxEqAbs(usdc.balanceOf(treasury), 10e6, 1e4); // treasury got the fee
        assertApproxEqAbs(usdc.balanceOf(alice), 9_000e6 + gross - fee, 2); // user got principal + profit - fee
    }

    function test_NoFeeOnLoss() public {
        _deposit(alice, 1_000e6);
        _loss(200e6); // position now worth ~800 < 1000 basis

        uint256 sh = vault.balanceOf(alice);
        (, uint256 profit, uint256 fee) = vault.quoteFee(alice, sh);
        assertEq(profit, 0);
        assertEq(fee, 0);

        vm.prank(alice);
        vault.redeem(sh, alice, alice);
        assertEq(usdc.balanceOf(treasury), 0); // no fee when underwater
    }

    function test_TransferMovesCostBasis() public {
        _deposit(alice, 1_000e6);
        uint256 sh = vault.balanceOf(alice);

        vm.prank(alice);
        vault.transfer(bob, sh); // hand all shares to bob

        assertEq(vault.costBasisAssets(alice), 0);
        assertApproxEqAbs(vault.costBasisAssets(bob), 1_000e6, 1);

        _yield(1_000e6);
        (, , uint256 fee) = vault.quoteFee(bob, sh);
        assertGt(fee, 0); // bob now bears the profit and the fee
    }

    function test_PartialWithdrawScalesBasis() public {
        _deposit(alice, 1_000e6);
        _yield(1_000e6); // worth ~2000
        uint256 half = vault.balanceOf(alice) / 2;

        vm.prank(alice);
        vault.redeem(half, alice, alice);

        // ~half the basis consumed, ~half remains
        assertApproxEqAbs(vault.costBasisAssets(alice), 500e6, 1e6);
        // treasury earned ~1% of the ~500 profit realized on this half
        assertApproxEqAbs(usdc.balanceOf(treasury), 5e6, 1e5);
    }

    function test_SecondDepositWeightedBasis() public {
        _deposit(alice, 1_000e6);
        _deposit(alice, 1_000e6); // total basis 2000, no reset
        assertApproxEqAbs(vault.costBasisAssets(alice), 2_000e6, 1);
    }

    function test_OnlyAdminSetsTreasury() public {
        vm.prank(bob);
        vm.expectRevert();
        vault.setTreasury(bob);

        vm.prank(admin);
        vault.setTreasury(bob);
        assertEq(vault.treasury(), bob);
    }

    // ───────────────────────── AUDIT Round 1 fixes ─────────────────────────

    /// AUDIT (pause): a paused vault must refuse NEW deposits...
    function test_PauseBlocksDeposit() public {
        vm.prank(admin);
        vault.pause();
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(); // OZ Pausable: EnforcedPause()
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
    }

    /// ...but withdrawals/redeems must STAY OPEN while paused (non-custodial).
    function test_WithdrawalsOpenWhilePaused() public {
        _deposit(alice, 1_000e6);
        vm.prank(admin);
        vault.pause();
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(sh, alice, alice); // must not revert
        assertEq(usdc.balanceOf(alice), 10_000e6);
    }

    function test_UnpauseRestoresDeposit() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(admin);
        vault.unpause();
        _deposit(alice, 1_000e6); // works again
        assertGt(vault.balanceOf(alice), 0);
    }

    /// AUDIT B2: maxWithdraw must report NET of the profit fee (was gross → over-reported).
    function test_MaxWithdrawIsNetOfFee() public {
        _deposit(alice, 1_000e6);
        _yield(1_000e6); // ~1000 profit, 1% fee ~ 10
        uint256 sh = vault.balanceOf(alice);
        (uint256 gross,, uint256 fee) = vault.quoteFee(alice, sh);
        assertEq(vault.maxWithdraw(alice), gross - fee);
        assertLt(vault.maxWithdraw(alice), gross); // strictly less than gross when in profit
    }

    /// AUDIT B2: previewRedeemNet must equal what redeem actually delivers.
    function test_PreviewRedeemNetMatchesActual() public {
        _deposit(alice, 1_000e6);
        _yield(1_000e6);
        uint256 sh = vault.balanceOf(alice);
        uint256 predicted = vault.previewRedeemNet(alice, sh);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(sh, alice, alice);
        assertApproxEqAbs(usdc.balanceOf(alice) - before, predicted, 2);
    }

    /// AUDIT A6: first-depositor / donation inflation griefing is resisted.
    /// Without the 1e6 virtual-share offset the victim's deposit would round to
    /// ZERO shares (total loss); with it they keep meaningful, redeemable shares.
    function test_FirstDepositorInflationResisted() public {
        address attacker = address(0xBAD);
        address victim = address(0xBEEF);
        usdc.mint(attacker, 20_000e6);
        usdc.mint(victim, 1_000e6);

        // attacker seeds 1 wei then donates a large amount to inflate PPS
        vm.startPrank(attacker);
        usdc.approve(address(vault), 1);
        vault.deposit(1, attacker);
        usdc.transfer(address(vault), 10_000e6); // donation
        vm.stopPrank();

        // victim deposits AFTER the donation
        vm.startPrank(victim);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, victim);
        vm.stopPrank();

        assertGt(vault.balanceOf(victim), 0, "victim griefed to zero shares");
        // victim can redeem a meaningful amount back (not ~0)
        uint256 sh = vault.balanceOf(victim);
        vm.prank(victim);
        vault.redeem(sh, victim, victim);
        assertGt(usdc.balanceOf(victim), 500e6, "victim lost most of deposit");
    }
}
