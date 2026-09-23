#!/usr/bin/env python3
"""BoringDeFi keeper for Arbitrum One.

    python keeper/boring_keeper.py status  --vault 0x...          # read-only
    python keeper/boring_keeper.py plan    --vault 0x...          # read-only, prints moves
    python keeper/boring_keeper.py execute --vault 0x...          # sends the moves

`status` and `plan` need no key. `execute` reads KEEPER_PRIVATE_KEY from the
environment; that key holds only KEEPER_ROLE, so even if it leaks it can only
shuffle money between venues the admin allowlisted, within the on-chain caps -
it can never withdraw user funds.

APY/TVL come from DefiLlama (base APY only). Positions, exit liquidity, caps and
the idle buffer come from the vault itself (BoringVault.allocationReport).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from planner import Venue, plan  # noqa: E402

DEFAULT_RPC = "https://arb1.arbitrum.io/rpc"
LLAMA = "https://yields.llama.fi/pools"
CONFIG = Path(__file__).resolve().parent / "venues.arbitrum.json"

VAULT_ABI = [
    {"type": "function", "name": "allocationReport", "stateMutability": "view", "inputs": [],
     "outputs": [{"name": "venues", "type": "address[]"}, {"name": "assets", "type": "uint256[]"},
                 {"name": "withdrawable", "type": "uint256[]"}, {"name": "capBps", "type": "uint256[]"},
                 {"name": "idle", "type": "uint256"}, {"name": "total", "type": "uint256"}]},
    {"type": "function", "name": "minIdleBps", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "minExitBps", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "maxRebalanceAssets", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "totalSupply", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "paused", "stateMutability": "view", "inputs": [], "outputs": [{"type": "bool"}]},
    {"type": "function", "name": "deployToStrategy", "stateMutability": "nonpayable",
     "inputs": [{"name": "strategy", "type": "address"}, {"name": "assets", "type": "uint256"}], "outputs": []},
    {"type": "function", "name": "recallFromStrategy", "stateMutability": "nonpayable",
     "inputs": [{"name": "strategy", "type": "address"}, {"name": "assets", "type": "uint256"}], "outputs": []},
]
# Each adapter type exposes the venue it wraps under a different getter.
PROBES = [("targetVault", "ERC-4626"), ("pool", "Aave v3"), ("comet", "Compound III")]


def _addr_getter(name: str) -> list[dict]:
    return [{"type": "function", "name": name, "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]}]


def venue_of(w3, adapter: str) -> str | None:
    for getter, _ in PROBES:
        try:
            return w3.eth.contract(address=adapter, abi=_addr_getter(getter)).functions[getter]().call()
        except Exception:
            continue
    return None


def llama_pools() -> dict[str, dict]:
    req = urllib.request.Request(LLAMA, headers={"User-Agent": "boringdefi-keeper"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return {p["pool"]: p for p in json.load(r)["data"]}


def read_vault(w3, vault_addr: str, cfg: dict) -> tuple[list[Venue], dict]:
    from web3 import Web3

    vault = w3.eth.contract(address=Web3.to_checksum_address(vault_addr), abi=VAULT_ABI)
    venues, assets, withdrawable, caps, idle, total = vault.functions.allocationReport().call()
    meta = {
        "idle": idle, "total": total,
        "min_idle_bps": vault.functions.minIdleBps().call(),
        "min_exit_bps": vault.functions.minExitBps().call(),
        "max_per_call": vault.functions.maxRebalanceAssets().call(),
        "paused": vault.functions.paused().call(),
    }
    pools = llama_pools()
    known = {k.lower(): v for k, v in cfg["venues"].items()}
    out = []
    for adapter, pos, w, cap in zip(venues, assets, withdrawable, caps):
        target = venue_of(w3, adapter)
        info = known.get((target or "").lower(), {})
        p = pools.get(info.get("llama_pool", ""), {})
        out.append(Venue(adapter=adapter, name=info.get("name", target or adapter), position=pos, withdrawable=w,
                         cap_bps=cap, apy=p.get("apyBase"), tvl_usd=p.get("tvlUsd")))
    return out, meta


def usd(x: int) -> str:
    return f"{x / 1e6:,.2f}"


def print_status(venues: list[Venue], meta: dict) -> None:
    print(f"total {usd(meta['total'])} USDC | idle {usd(meta['idle'])} | min idle {meta['min_idle_bps']/100:.1f}% "
          f"| exit guard {meta['min_exit_bps']/100:.0f}% | per-call cap {usd(meta['max_per_call'])} "
          f"| {'PAUSED' if meta['paused'] else 'live'}")
    print(f"{'venue':30} {'position':>14} {'exit now':>14} {'share':>7} {'cap':>6} {'base APY':>9} {'TVL':>9}")
    for v in venues:
        share = v.position / meta["total"] * 100 if meta["total"] else 0
        apy = f"{v.apy:.2f}%" if v.apy is not None else "n/a"
        tvl = f"${v.tvl_usd/1e6:.1f}M" if v.tvl_usd else "n/a"
        print(f"{v.name[:30]:30} {usd(v.position):>14} {usd(v.withdrawable):>14} {share:6.1f}% {v.cap_bps/100:5.0f}% {apy:>9} {tvl:>9}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["status", "plan", "execute"])
    ap.add_argument("--vault", required=True)
    ap.add_argument("--rpc", default=os.environ.get("ARB_RPC_URL", DEFAULT_RPC))
    ap.add_argument("--config", default=str(CONFIG))
    args = ap.parse_args()

    from web3 import Web3

    w3 = Web3(Web3.HTTPProvider(args.rpc))
    if w3.eth.chain_id != 42161:
        raise SystemExit(f"refuse: chain id {w3.eth.chain_id} is not Arbitrum One")
    cfg = json.loads(Path(args.config).read_text())
    venues, meta = read_vault(w3, args.vault, cfg)
    print_status(venues, meta)
    if args.cmd == "status":
        return

    r = cfg.get("rules", {})
    p = plan(venues, meta["idle"], meta["min_idle_bps"], meta["max_per_call"], **r)
    for v in p.venues:
        if v.reasons:
            print(f"  excluded {v.name}: {'; '.join(v.reasons)}")
    print(f"blended base APY now {p.blended_apy_now:.2f}% -> target {p.blended_apy_target:.2f}%")
    if p.note:
        print(p.note)
    for m in p.moves:
        print(f"  {m.action:6} {usd(m.amount):>14} USDC  {m.name}")
    if args.cmd == "plan" or not p.moves:
        return
    if meta["paused"]:
        raise SystemExit("refuse: vault is paused")

    key = os.environ.get("KEEPER_PRIVATE_KEY")
    if not key:
        raise SystemExit("execute needs KEEPER_PRIVATE_KEY (a key holding only KEEPER_ROLE)")
    acct = w3.eth.account.from_key(key)
    vault = w3.eth.contract(address=Web3.to_checksum_address(args.vault), abi=VAULT_ABI)
    for m in p.moves:
        fn = vault.functions.deployToStrategy if m.action == "deploy" else vault.functions.recallFromStrategy
        call = fn(Web3.to_checksum_address(m.adapter), m.amount)
        call.call({"from": acct.address})  # simulate first: the vault's guards reject bad moves before gas is spent
        # Headroom on top of the estimate: the vault reads venue liquidity inside try/catch, and a
        # sub-call starved by the 63/64 rule would turn a valid move into an out-of-gas revert.
        gas = int(call.estimate_gas({"from": acct.address}) * 1.3) + 50_000
        tx = call.build_transaction({"from": acct.address, "nonce": w3.eth.get_transaction_count(acct.address),
                                     "chainId": 42161, "gas": gas})
        signed = acct.sign_transaction(tx)
        h = w3.eth.send_raw_transaction(signed.raw_transaction)
        rcpt = w3.eth.wait_for_transaction_receipt(h, timeout=120)
        print(f"  {m.action} {usd(m.amount)} -> {m.name}: https://arbiscan.io/tx/{h.hex() if h.hex().startswith('0x') else '0x' + h.hex()} "
              f"{'ok' if rcpt.status == 1 else 'FAILED'}")
        if rcpt.status != 1:
            raise SystemExit("stopping after failed transaction")


if __name__ == "__main__":
    main()
