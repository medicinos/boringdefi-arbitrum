# Build log - Arbitrum Open House Singapore buildathon

## Prior work (before the buildathon)

BoringDeFi (boringdefi.com): stablecoin yield allocator with an off-chain engine (private) and on-chain vaults on Ethereum. From that code base this repo imports, unchanged in the first commit: `AllocatorVault`, `AllocatorVaultV2`, `AaveV3Adapter`, `ERC4626Adapter`, their mocks and unit tests.

## Built during the buildathon (from 2026-09-23)

- `BoringVault`: concentration cap per venue, idle buffer, exit-liquidity guard enforced after every keeper deploy; resilient withdrawal path (a frozen venue no longer reverts a user's withdrawal).
- Two small hooks in the imported base so the guards can be added without touching the rest: `_afterDeploy` (called at the end of `deployToStrategy`) and `virtual` on `_ensureLiquidity`.
- `IExitLiquidity.withdrawableNow()` and implementations in the Aave (paused/inactive reserve = 0, capped by virtual balance), ERC-4626 (`maxWithdraw`) and new Compound III adapter (withdraw pause honoured, capped by market cash).
- `CompoundV3Adapter` for Comet.
- Arbitrum One venue research: every address checked on-chain (asset == native USDC, aToken from `getReserveData`), Morpho vaults taken from the Morpho API listed set; vaults showing absurd APYs excluded.
- `DeployArbitrum.s.sol` (keystore-based, no private key in env), `ArbitrumAddresses.sol`.
- Tests: `BoringVault.t.sol` (guards, resilient exits, fuzz), `ArbitrumFork.t.sol` (real venues on a fork: deposits, exit liquidity, 30-day yield with profit-only fee, full exit from every venue, drained Aave pool, paused Comet, frozen venue during withdrawal).
- Keeper for Arbitrum: pure planner with tests + CLI (`status`, `plan`, `execute` with pre-simulation).
- `app/index.html`: deposit/withdraw page with the live exit-liquidity table.
