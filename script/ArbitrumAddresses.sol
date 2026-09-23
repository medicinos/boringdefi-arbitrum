// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Arbitrum One (chainId 42161) venues for the BoringDeFi USDC vault.
///         Every address was checked on-chain on 2026-09-23 (block ~508.1M):
///         asset()/baseToken() == native USDC, and the Aave aToken is the one
///         returned by Pool.getReserveData(USDC). TVL figures are from the same day.
library ArbitrumAddresses {
    uint256 internal constant CHAIN_ID = 42161;

    /// Native USDC (Circle), 6 decimals.
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// Aave v3 Pool (revision 11) and aArbUSDCn.  ~22M USDC free liquidity.
    address internal constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address internal constant AAVE_AUSDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;

    /// Fluid fUSDC (ERC-4626 lending fToken).  ~64.7M USDC.
    address internal constant FLUID_FUSDC = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;

    /// Compound III cUSDCv3 (Comet, native USDC base).  ~14.7M USDC supplied.
    address internal constant COMET_USDC = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;

    /// Morpho vaults (ERC-4626, listed on morpho.org).
    address internal constant MORPHO_STEAKHOUSE_HY = 0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA; // bbqUSDC ~2.7M
    address internal constant MORPHO_GAUNTLET_CORE = 0x7e97fa6893871A2751B5fE961978DCCb2c201E65; // gtUSDCc ~0.8M
}
