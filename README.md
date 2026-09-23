# BoringDeFi on Arbitrum

**A non-custodial USDC vault on Arbitrum One that refuses, on-chain, to leave depositors' money anywhere it couldn't get back today.**

BoringDeFi splits USDC across Aave v3, Fluid, Compound III and two Morpho vaults. A keeper rebalances toward the best *base* yield (reward tokens ignored). What makes it boring is what the contract will not allow:

| Rule (checked after every keeper deploy) | What it prevents |
|---|---|
| **Concentration cap** per venue (`allocationCapBps`, venue without a cap is closed) | One protocol failure taking most of the vault |
| **Idle buffer** (`minIdleBps`, default 2 %) | Small withdrawals touching a venue at all |
| **Exit liquidity** (`minExitBps`, default 100 %): after the deploy the venue must be able to pay our *whole* position back immediately | Parking money in a lending pool at 100 % utilization, a paused market, or an ERC-4626 vault whose markets are illiquid |

And withdrawals got harder to break: if one venue cannot pay out (paused, fully borrowed), the vault takes what that venue can pay and continues with the next one instead of reverting the user's withdrawal.

The keeper holds only `KEEPER_ROLE`: it can move USDC between allowlisted venues within those rules and a per-call cap. It has no function that sends funds anywhere else. Only share owners withdraw.

## Venues (Arbitrum One, verified on-chain 2026-09-23)

| Venue | Contract | Adapter |
|---|---|---|
| Aave v3 USDC | Pool `0x794a…14aD`, aToken `0x724d…C637` | `AaveV3Adapter` |
| Fluid fUSDC | `0x1A99…6096` | `ERC4626Adapter` |
| Compound III cUSDCv3 | `0x9c4e…58bf` | `CompoundV3Adapter` (new) |
| Morpho Steakhouse High Yield USDC | `0x5c0C…63BA` | `ERC4626Adapter` |
| Morpho Gauntlet USDC Core | `0x7e97…1E65` | `ERC4626Adapter` |

Full addresses: [`script/ArbitrumAddresses.sol`](script/ArbitrumAddresses.sol).

## Layout

```
src/
  AllocatorVault.sol        ERC-4626 core: allowlisted keeper, per-call cap, guardian pause   (prior work)
  AllocatorVaultV2.sol      + performance fee charged only on each depositor's profit          (prior work)
  BoringVault.sol           + concentration / idle / exit-liquidity guards, resilient exits    (new)
  adapters/AaveV3Adapter    + withdrawableNow(): paused reserve = 0, capped by free cash        (extended)
  adapters/ERC4626Adapter   + withdrawableNow(): ERC-4626 maxWithdraw                          (extended)
  adapters/CompoundV3Adapter  Comet base supplier, withdrawableNow() honours withdraw pause     (new)
  interfaces/IExitLiquidity   withdrawableNow() - what the venue could pay back right now      (new)
script/DeployArbitrum.s.sol   one-shot deploy: vault + 5 adapters + caps + keeper + seed        (new)
test/BoringVault.t.sol        guard + resilient-withdrawal unit tests, fuzz                     (new)
test/fork/ArbitrumFork.t.sol  real Aave / Fluid / Compound / Morpho on an Arbitrum fork         (new)
keeper/                       planner (pure, tested) + CLI: status / plan / execute             (new)
app/index.html                deposit / withdraw page with the live exit-liquidity table        (new)
```

## Build and test

```bash
forge install foundry-rs/forge-std@v1.9.7 OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git
forge test --no-match-path "test/fork/*"          # unit + fuzz + invariants
forge test --match-path "test/fork/*" -vv          # Arbitrum One fork (public RPC; ARB_RPC_URL to override)
python -m pytest keeper -q                         # planner tests
```

## Deploy (Arbitrum One)

Never put a private key in an env var or shell history. Import it once into Foundry's encrypted keystore:

```bash
cast wallet import boring --interactive
forge script script/DeployArbitrum.s.sol:DeployArbitrum \
  --rpc-url https://arb1.arbitrum.io/rpc --account boring --broadcast --verify
```

The deployer needs ~0.001 ETH for gas and 1 USDC for the dead-share seed (`SEED_USDC=0` to skip). Optional: `KEEPER`, `TREASURY`, `FINAL_ADMIN` (multisig), `FEE_BPS`, `MAX_REBALANCE`, `MIN_IDLE_BPS`, `MIN_EXIT_BPS`.

## Keeper

```bash
pip install web3
python keeper/boring_keeper.py status --vault <VAULT>    # read-only
python keeper/boring_keeper.py plan   --vault <VAULT>    # read-only, prints the moves
KEEPER_PRIVATE_KEY=... python keeper/boring_keeper.py execute --vault <VAULT>
```

Boring rules in the planner: base APY only, venue TVL ≥ $2M, APY no more than 2× the median of eligible venues ("too good to be boring"), a venue that cannot pay our position back is drained by what it can pay, and nothing moves for less than 10 bps of blended APY. Every move is simulated against the vault before it is sent, so the on-chain guards reject bad moves before gas is spent.

## Status and honesty

- **Not audited.** The core (`AllocatorVault`, `AllocatorVaultV2`) comes from the BoringDeFi Ethereum stack (first vault live on mainnet since 2026-05-30 as a capped single-operator canary) and went through an internal pre-audit round (53 unit + 2 invariant tests in the original repo). `BoringVault`, `CompoundV3Adapter` and the exit-liquidity reporting are new and have not been reviewed externally.
- Admin (allowlist, caps, guards) is the trust root. Production plan: `DEFAULT_ADMIN_ROLE` to a timelock + multisig; keeper stays a hot key with `KEEPER_ROLE` only.
- `withdrawableNow()` for ERC-4626 venues is only as good as the venue's `maxWithdraw`. MetaMorpho and Fluid bound it by market liquidity; other 4626 vaults may not.

MIT licence.
