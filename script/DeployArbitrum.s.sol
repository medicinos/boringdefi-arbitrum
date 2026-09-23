// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BoringVault} from "../src/BoringVault.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {CompoundV3Adapter} from "../src/adapters/CompoundV3Adapter.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";
import {IComet} from "../src/interfaces/IComet.sol";
import {ArbitrumAddresses as A} from "./ArbitrumAddresses.sol";

/// @notice Deploys the BoringDeFi USDC vault on Arbitrum One with five venues:
///         Aave v3, Fluid fUSDC, Compound III, Morpho Steakhouse, Morpho Gauntlet.
///
///   No private key in env or shell history - use an encrypted keystore:
///     cast wallet import boring --interactive
///     forge script script/DeployArbitrum.s.sol:DeployArbitrum \
///       --rpc-url https://arb1.arbitrum.io/rpc --account boring --broadcast
///
///   Optional env:
///     KEEPER=0x...        keeper hot key (default: deployer)
///     TREASURY=0x...      fee receiver (default: deployer)
///     FINAL_ADMIN=0x...   multisig/timelock that owns the vault (default: deployer)
///     FEE_BPS=100         performance fee on profit only (1 %), hard cap 2000
///     MAX_REBALANCE=10000000000   per-call keeper cap (10,000 USDC)
///     MIN_IDLE_BPS=200    idle buffer (2 %)
///     MIN_EXIT_BPS=10000  venue must be 100 % exitable after each deploy
///     SEED_USDC=1000000   dead-share seed deposit in USDC units (default 1 USDC, 0 = skip)
contract DeployArbitrum is Script {
    struct Stack {
        BoringVault vault;
        AaveV3Adapter aave;
        ERC4626Adapter fluid;
        CompoundV3Adapter compound;
        ERC4626Adapter morphoSteakhouse;
        ERC4626Adapter morphoGauntlet;
    }

    function run() external returns (Stack memory s) {
        require(block.chainid == A.CHAIN_ID, "not Arbitrum One");
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        s = _deployVault(deployer);
        _wire(s, deployer);
        _seed(s.vault);
        _handoff(s.vault, deployer);

        vm.stopBroadcast();
        _log(s);
    }

    function _deployVault(address deployer) internal returns (Stack memory s) {
        s.vault = new BoringVault(
            IERC20(A.USDC),
            "BoringDeFi USDC (Arbitrum)",
            "boringUSDC",
            deployer,
            vm.envOr("MAX_REBALANCE", uint256(10_000e6)),
            vm.envOr("TREASURY", deployer),
            vm.envOr("FEE_BPS", uint256(100)),
            vm.envOr("MIN_IDLE_BPS", uint256(200)),
            vm.envOr("MIN_EXIT_BPS", uint256(10_000))
        );
        address v = address(s.vault);
        s.aave = new AaveV3Adapter(IERC20(A.USDC), IERC20(A.AAVE_AUSDC), IAaveV3Pool(A.AAVE_POOL), v);
        s.fluid = new ERC4626Adapter(IERC4626(A.FLUID_FUSDC), v);
        s.compound = new CompoundV3Adapter(IComet(A.COMET_USDC), v);
        s.morphoSteakhouse = new ERC4626Adapter(IERC4626(A.MORPHO_STEAKHOUSE_HY), v);
        s.morphoGauntlet = new ERC4626Adapter(IERC4626(A.MORPHO_GAUNTLET_CORE), v);
    }

    /// @dev Allowlist every adapter with its concentration cap; grant the keeper.
    function _wire(Stack memory s, address deployer) internal {
        BoringVault v = s.vault;
        _allow(v, address(s.aave), 4_000); // 40 %
        _allow(v, address(s.fluid), 4_000); // 40 %
        _allow(v, address(s.compound), 2_500); // 25 %
        _allow(v, address(s.morphoSteakhouse), 2_000); // 20 %
        _allow(v, address(s.morphoGauntlet), 1_500); // 15 %
        v.grantRole(v.KEEPER_ROLE(), vm.envOr("KEEPER", deployer));
    }

    function _allow(BoringVault v, address adapter, uint256 capBps) internal {
        v.setStrategy(adapter, true);
        v.setAllocationCap(adapter, capBps);
    }

    /// @dev Belt-and-braces against first-depositor inflation (the vault already
    ///      uses a 1e6 virtual-share offset): a tiny deposit owned by 0xdEaD.
    function _seed(BoringVault v) internal {
        uint256 seed = vm.envOr("SEED_USDC", uint256(1e6));
        if (seed == 0) return;
        IERC20(A.USDC).approve(address(v), seed);
        v.deposit(seed, address(0x000000000000000000000000000000000000dEaD));
    }

    function _handoff(BoringVault v, address deployer) internal {
        address finalAdmin = vm.envOr("FINAL_ADMIN", deployer);
        if (finalAdmin == deployer) return;
        v.grantRole(v.DEFAULT_ADMIN_ROLE(), finalAdmin);
        v.grantRole(v.GUARDIAN_ROLE(), finalAdmin);
        v.renounceRole(v.GUARDIAN_ROLE(), deployer);
        v.renounceRole(v.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _log(Stack memory s) internal view {
        console2.log("BoringVault          ", address(s.vault));
        console2.log("AaveV3Adapter        ", address(s.aave));
        console2.log("Fluid fUSDC adapter  ", address(s.fluid));
        console2.log("CompoundV3Adapter    ", address(s.compound));
        console2.log("Morpho Steakhouse    ", address(s.morphoSteakhouse));
        console2.log("Morpho Gauntlet Core ", address(s.morphoGauntlet));
        console2.log("strategies           ", s.vault.strategiesLength());
        console2.log("maxRebalanceAssets   ", s.vault.maxRebalanceAssets());
        console2.log("minIdleBps / minExit ", s.vault.minIdleBps(), s.vault.minExitBps());
    }
}
