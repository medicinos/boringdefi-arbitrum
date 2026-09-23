# Deployment - Arbitrum One (chainId 42161)

Deployed 2026-09-23 with `script/DeployArbitrum.s.sol` (block 508177489). Source verified on Sourcify (full match).

| Contract | Address | Cap |
|---|---|---|
| BoringVault (boringUSDC) | [`0x3cA6Ee7A5d64BCF3f23955c1ed9A66E332e60672`](https://arbiscan.io/address/0x3cA6Ee7A5d64BCF3f23955c1ed9A66E332e60672) | - |
| AaveV3Adapter | [`0xD07819c4502DD01ADaE7a2e3e1ca5d7c4D204417`](https://arbiscan.io/address/0xD07819c4502DD01ADaE7a2e3e1ca5d7c4D204417) | 40 % |
| ERC4626Adapter - Fluid fUSDC | [`0x1ea2Fe759f07E581e56c01563fd1EB964177baB0`](https://arbiscan.io/address/0x1ea2Fe759f07E581e56c01563fd1EB964177baB0) | 40 % |
| CompoundV3Adapter - cUSDCv3 | [`0x1bdF77b5501fA0F34F3783C4E6790217a9bFfF5f`](https://arbiscan.io/address/0x1bdF77b5501fA0F34F3783C4E6790217a9bFfF5f) | 25 % |
| ERC4626Adapter - Morpho Steakhouse bbqUSDC | [`0x5e7226E8b1995E1B58A66aa61968D307bD86B0eF`](https://arbiscan.io/address/0x5e7226E8b1995E1B58A66aa61968D307bD86B0eF) | 20 % |
| ERC4626Adapter - Morpho Gauntlet gtUSDCc | [`0xBD0Eae748b42dF16C88C9EC18AFfdEf3e21EF72f`](https://arbiscan.io/address/0xBD0Eae748b42dF16C88C9EC18AFfdEf3e21EF72f) | 15 % |

Parameters (read on-chain after deploy): asset native USDC `0xaf88…5831`, performance fee 100 bps on profit only, `maxRebalanceAssets` 10,000 USDC, `minIdleBps` 200, `minExitBps` 10000, not paused.

Roles: admin, guardian, keeper and treasury are the operator address `0x415715ed87Cb9213b2546a78053b48F2eD2631Ce` (single-operator canary). Before real TVL: admin to a timelock + multisig.

First activity: 1 USDC dead-share seed to `0x…dEaD`, first deposit by the operator, keeper deploys into Morpho Steakhouse and Fluid (Aave next). Check the live state with

```bash
python keeper/boring_keeper.py status --vault 0x3cA6Ee7A5d64BCF3f23955c1ed9A66E332e60672
```
