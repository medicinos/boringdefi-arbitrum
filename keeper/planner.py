"""Allocation planner for the BoringDeFi vault - pure functions, no chain access.

The planner never trusts itself with safety: the vault enforces caps, the idle
buffer and exit liquidity on-chain. The planner only decides *where yield is
boring and better* and produces moves the contract will accept.

Boring rules (all must hold for a venue to receive money):
  - base APY only (reward tokens are ignored - they are not yield, they are marketing)
  - venue TVL >= min_tvl_usd
  - APY not an outlier: <= outlier_mult x median APY of the eligible set
  - the venue can pay our current position back right now (withdrawable >= position)
Anti-churn: a move happens only if it lifts the vault's blended APY by at least
min_gain_bps and the amount is at least min_move.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from statistics import median

BPS = 10_000


@dataclass
class Venue:
    adapter: str
    name: str
    position: int          # USDC units (6 decimals) currently in the venue
    withdrawable: int      # what the venue could pay back right now
    cap_bps: int           # on-chain concentration cap
    apy: float | None      # base APY in percent (None = unknown -> ineligible)
    tvl_usd: float | None
    reasons: list[str] = field(default_factory=list)

    @property
    def eligible(self) -> bool:
        return not self.reasons


@dataclass
class Move:
    action: str            # "recall" | "deploy"
    adapter: str
    name: str
    amount: int


@dataclass
class Plan:
    total: int
    idle: int
    targets: dict[str, int]
    moves: list[Move]
    blended_apy_now: float
    blended_apy_target: float
    venues: list[Venue]
    note: str = ""


def screen(venues: list[Venue], min_tvl_usd: float, outlier_mult: float) -> list[Venue]:
    """Attach exclusion reasons to venues that break a boring rule."""
    for v in venues:
        if v.apy is None:
            v.reasons.append("no APY data")
        if v.tvl_usd is None or v.tvl_usd < min_tvl_usd:
            v.reasons.append(f"TVL below ${min_tvl_usd/1e6:.1f}M")
        if v.position > 0 and v.withdrawable < v.position:
            v.reasons.append("cannot pay our position back right now")
        if v.cap_bps == 0:
            v.reasons.append("no on-chain cap (closed)")
    apys = [v.apy for v in venues if v.apy is not None and not v.reasons]
    if apys:
        m = median(apys)
        for v in venues:
            if v.apy is not None and m > 0 and v.apy > outlier_mult * m and not v.reasons:
                v.reasons.append(f"APY {v.apy:.2f}% is > {outlier_mult:g}x median ({m:.2f}%) - too good to be boring")
    return venues


def blended_apy(alloc: dict[str, int], venues: dict[str, Venue], total: int) -> float:
    if total == 0:
        return 0.0
    return sum(amt * (venues[a].apy or 0.0) for a, amt in alloc.items()) / total


def plan(
    venues: list[Venue],
    idle: int,
    min_idle_bps: int,
    max_per_call: int,
    min_tvl_usd: float = 2_000_000,
    outlier_mult: float = 2.0,
    cap_margin_bps: int = 100,
    idle_margin_bps: int = 100,
    min_gain_bps: int = 10,
    min_move: int = 100_000_000,  # 100 USDC
) -> Plan:
    screen(venues, min_tvl_usd, outlier_mult)
    by = {v.adapter: v for v in venues}
    total = idle + sum(v.position for v in venues)
    now = {v.adapter: v.position for v in venues}

    # Water-fill: best base APY first, each venue up to (cap - margin) of total,
    # keeping (min idle + margin) as cash.
    keep_idle = -(-total * (min_idle_bps + idle_margin_bps) // BPS)
    budget = max(total - keep_idle, 0)
    target = {v.adapter: 0 for v in venues}
    for v in sorted((v for v in venues if v.eligible), key=lambda v: -(v.apy or 0)):
        room = total * max(v.cap_bps - cap_margin_bps, 0) // BPS
        take = min(room, budget)
        target[v.adapter] = take
        budget -= take
        if budget == 0:
            break

    apy_now = blended_apy(now, by, total)
    apy_target = blended_apy(target, by, total)
    moves: list[Move] = []
    note = ""
    if (apy_target - apy_now) * 100 < min_gain_bps and all(v.eligible or v.position == 0 for v in venues):
        note = f"hold: blended APY gain {(apy_target - apy_now) * 100:.1f} bps < {min_gain_bps} bps"
        return Plan(total, idle, target, [], apy_now, apy_target, venues, note)

    # Recalls first (they create the idle cash that deploys need), then deploys.
    for v in venues:
        diff = now[v.adapter] - target[v.adapter]
        diff = min(diff, v.withdrawable)  # never ask a venue for more than it can pay now
        if diff >= min_move or (not v.eligible and diff > 0):
            moves += _split("recall", v, diff, max_per_call)
    cash = idle + sum(m.amount for m in moves) - keep_idle  # what deploys may spend
    for v in sorted(venues, key=lambda v: -(v.apy or 0)):
        diff = min(target[v.adapter] - now[v.adapter], cash)
        if diff >= min_move:
            moves += _split("deploy", v, diff, max_per_call)
            cash -= diff
    return Plan(total, idle, target, moves, apy_now, apy_target, venues, note)


def _split(action: str, v: Venue, amount: int, max_per_call: int) -> list[Move]:
    out = []
    while amount > 0:
        step = min(amount, max_per_call)
        out.append(Move(action, v.adapter, v.name, step))
        amount -= step
    return out
