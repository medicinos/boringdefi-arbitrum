from planner import Venue, plan

M = 1_000_000  # 1 USDC


def v(name, pos=0, apy=4.0, tvl=50e6, cap=4000, withdrawable=None):
    return Venue(adapter=name, name=name, position=pos, withdrawable=pos if withdrawable is None else withdrawable,
                 cap_bps=cap, apy=apy, tvl_usd=tvl)


def test_fills_best_venue_up_to_cap_and_keeps_idle():
    p = plan([v("fluid", apy=4.2), v("aave", apy=3.1), v("comet", apy=3.0, cap=2500)],
             idle=100_000 * M, min_idle_bps=200, max_per_call=10_000 * M)
    assert p.targets["fluid"] == 39_000 * M          # 40 % cap - 1 % margin
    assert p.targets["aave"] == 39_000 * M
    assert p.targets["comet"] == 19_000 * M          # rest after 3 % idle
    deployed = sum(m.amount for m in p.moves if m.action == "deploy")
    assert deployed == 97_000 * M
    assert all(m.amount <= 10_000 * M for m in p.moves)  # split to the per-call cap


def test_reward_only_or_tiny_or_outlier_venues_get_nothing():
    p = plan([v("fluid", apy=4.2), v("aave", apy=3.1), v("tiny", apy=4.5, tvl=0.8e6), v("degen", apy=40.0)],
             idle=100_000 * M, min_idle_bps=200, max_per_call=10**12)
    assert p.targets["tiny"] == 0 and p.targets["degen"] == 0
    reasons = {x.name: x.reasons for x in p.venues}
    assert any("TVL" in r for r in reasons["tiny"])
    assert any("too good to be boring" in r for r in reasons["degen"])


def test_illiquid_venue_is_drained_only_by_what_it_can_pay():
    p = plan([v("fluid", pos=30_000 * M, apy=4.2), v("aave", pos=30_000 * M, apy=3.1, withdrawable=5_000 * M)],
             idle=40_000 * M, min_idle_bps=200, max_per_call=10**12)
    recalls = [m for m in p.moves if m.action == "recall" and m.adapter == "aave"]
    assert sum(m.amount for m in recalls) == 5_000 * M


def test_holds_when_gain_is_below_threshold():
    p = plan([v("a", pos=48_000 * M, apy=4.00, cap=5000), v("b", pos=49_000 * M, apy=3.99, cap=5000)],
             idle=3_000 * M, min_idle_bps=200, max_per_call=10**12, min_gain_bps=10)
    assert p.moves == [] and p.note.startswith("hold")


def test_deploys_never_exceed_available_cash():
    p = plan([v("fluid", apy=4.2), v("aave", pos=50_000 * M, apy=3.1, withdrawable=1_000 * M, cap=4000)],
             idle=50_000 * M, min_idle_bps=200, max_per_call=10**12)
    spent = sum(m.amount for m in p.moves if m.action == "deploy")
    got = sum(m.amount for m in p.moves if m.action == "recall")
    assert spent <= 50_000 * M + got - 3_000 * M
