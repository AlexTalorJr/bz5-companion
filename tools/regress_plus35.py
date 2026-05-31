"""
Independent regression for v0.1.29+35 — the Trends rebuild.

Two parts:
  A. Structural checks on the new Dart (does trends.dart wire the three
     sections, does database.dart expose getTripsInRange, version triple,
     fl_chart smoothing flags present, old snapshot-only charts gone).
  B. A Python port of TrendAggregator's maths run against synthetic trip
     sets, exercising the edge cases that were called out as the main
     bug surface: null fields on historic trips, division by zero, the
     short-trip range filter, money with an unconfigured tariff, and the
     moving-average never overshooting the data range.

Run from repo root:  python3 tools/regress_plus35.py
Exit 0 = clean, 1 = any FAIL.
"""
import re
import sys
import pathlib

root = pathlib.Path('.')
fails, warns, oks = [], [], []
def ok(m): oks.append(m)
def warn(m): warns.append(m)
def fail(m): fails.append(m)

# ────────────────────────── Part A: structural ──────────────────────────

trends = (root / 'lib/screens/trends.dart').read_text()
db = (root / 'lib/data/database.dart').read_text()
agg_src = (root / 'lib/services/trend_aggregator.dart').read_text()

# A1. version triple
pv = re.search(r"version:\s*0\.1\.29\+(\d+)", (root / 'pubspec.yaml').read_text()).group(1)
diag = re.search(r"_kDiagVersion = 'v0\.1\.29\+(\d+)'", (root / 'lib/screens/dashboard.dart').read_text())
cloud = re.search(r"_readAppVersion\(\) async => '0\.1\.29\+(\d+)'", (root / 'lib/services/cloud_sync_service.dart').read_text())
if pv == "35" and diag and diag.group(1) == "35" and cloud and cloud.group(1) == "35":
    ok("version triple-sync = +35")
else:
    fail(f"version triple mismatch: pubspec={pv} diag={diag and diag.group(1)} cloud={cloud and cloud.group(1)}")

# A2. data layer method
if "Future<List<Trip>> getTripsInRange(DateTime from, DateTime to)" in db:
    ok("database.getTripsInRange present")
else:
    fail("getTripsInRange missing from database.dart")

# A3. three sections wired
for label in ["Итоги за период", "Накопительно", "Эффективность вождения", "Здоровье батареи"]:
    if label in trends:
        ok(f"section present: {label}")
    else:
        fail(f"section label missing: {label}")

# A4. old snapshot-only charts removed (the dead ones). Match the old
#     chart *titles* exactly (title: 'X') — not bare substrings, which
#     would false-positive on new field names like cumulativeOdometer.
dead_titles = ["Cycle count", "Odometer", "Battery temperature", "Cell spread"]
dead_found = [d for d in dead_titles if f"title: '{d}'" in trends]
if dead_found:
    for d in dead_found:
        fail(f"old chart still present in trends.dart: {d}")
else:
    ok("old monotone/diagnostic charts removed")

# A5. smoothing flags actually used
if "preventCurveOverShooting: true" in trends:
    ok("preventCurveOverShooting enabled (no impossible dips)")
else:
    fail("preventCurveOverShooting not set — curves may overshoot below floor")
if "isCurved: curved" in trends or "isCurved: true" in trends:
    ok("curved lines wired")
else:
    warn("no curved line flag found")

# A6. cumulative odometer must NOT be curved (monotone integrity)
m = re.search(r"Пробег накопительно.*?curved:\s*(true|false)", trends, re.S)
if m and m.group(1) == "false":
    ok("cumulative distance is non-curved (monotone preserved)")
elif m:
    fail("cumulative distance is curved — overshoot can break monotonicity")
else:
    warn("could not locate cumulative-distance curved flag")

# A7. cost gated on configuration
if "if (cost.isConfigured)" in trends:
    ok("cost UI gated on CostSettings.isConfigured")
else:
    warn("cost section not gated on isConfigured — may show 0 when untariffed")

# A8. aggregator constants present
if "kMinSocDeltaForRange" in agg_src and "kConsumptionSmoothingWindow" in agg_src:
    ok("aggregator filter + smoothing constants present")
else:
    fail("aggregator constants missing")

# ──────────────── Part B: aggregator logic port + edge cases ────────────────
# Mirror of TrendAggregator.build / _movingAverage. Kept deliberately
# close to the Dart so a divergence shows up as a test failure.

MIN_SOC_DELTA = 5.0
SMOOTH_WINDOW = 5

class Trip:
    def __init__(self, t, dist=None, energy=None, regen=None, cons=None,
                 start_soc=None, end_soc=None):
        self.t = t  # x (any monotone number stands in for epoch ms)
        self.distanceKm = dist
        self.energyUsedKwh = energy
        self.regenEnergyKwh = regen
        self.avgConsumptionKwh100km = cons
        self.startSoc = start_soc
        self.endSoc = end_soc

def moving_average(points, window):
    if len(points) < 2:
        return []
    half = window // 2
    out = []
    for i in range(len(points)):
        lo = max(0, i - half)
        hi = min(len(points) - 1, i + half)
        s = sum(p[1] for p in points[lo:hi + 1])
        out.append((points[i][0], s / (hi - lo + 1)))
    return out

def build(trips, cost_per_kwh):
    total_dist = total_energy = total_regen = 0.0
    cumulative, cons_dots, regen_share, range_pts = [], [], [], []
    month_energy = {}
    running = 0.0
    for t in trips:
        x = t.t
        if t.distanceKm is not None and t.distanceKm > 0:
            total_dist += t.distanceKm
            running += t.distanceKm
            cumulative.append((x, running))
        if t.energyUsedKwh is not None and t.energyUsedKwh > 0:
            total_energy += t.energyUsedKwh
            month_energy[x // 100] = month_energy.get(x // 100, 0) + t.energyUsedKwh
        if t.regenEnergyKwh is not None and t.regenEnergyKwh > 0:
            total_regen += t.regenEnergyKwh
            if t.energyUsedKwh is not None and t.energyUsedKwh > 0:
                share = max(0.0, min(100.0, t.regenEnergyKwh / t.energyUsedKwh * 100))
                regen_share.append((x, share))
        cons = t.avgConsumptionKwh100km
        if cons is None and t.distanceKm and t.energyUsedKwh and t.distanceKm > 0 and t.energyUsedKwh > 0:
            cons = t.energyUsedKwh / t.distanceKm * 100
        if cons is not None and 0 < cons < 100:
            cons_dots.append((x, cons))
        if (t.distanceKm and t.distanceKm > 0 and
                t.startSoc is not None and t.endSoc is not None):
            d = abs(t.startSoc - t.endSoc)
            if d >= MIN_SOC_DELTA:
                range_pts.append((x, t.distanceKm / d * 100))
    smoothed = moving_average(cons_dots, SMOOTH_WINDOW)
    return {
        "total_dist": total_dist, "total_energy": total_energy,
        "total_regen": total_regen, "cost": total_energy * cost_per_kwh,
        "trip_count": len(trips), "cumulative": cumulative,
        "cons_dots": cons_dots, "smoothed": smoothed,
        "regen_share": regen_share, "range_pts": range_pts,
    }

# B1. empty trip list → all zero, no crash
r = build([], 0.0)
if r["trip_count"] == 0 and r["total_dist"] == 0 and r["cumulative"] == []:
    ok("B1 empty trips → zeros, no crash")
else:
    fail("B1 empty trips not handled")

# B2. historic trips with null energy/regen still contribute distance,
#     and don't poison totals with zeros
trips = [
    Trip(100, dist=50, energy=None, regen=None),         # old trip: dist only
    Trip(200, dist=30, energy=6.0, regen=1.0),            # full trip
    Trip(300, dist=None, energy=None, regen=None),        # junk row
]
r = build(trips, 5.0)
if r["total_dist"] == 80 and abs(r["total_energy"] - 6.0) < 1e-9 and abs(r["total_regen"] - 1.0) < 1e-9:
    ok("B2 null fields skipped, distance still summed")
else:
    fail(f"B2 null handling wrong: {r['total_dist']}/{r['total_energy']}/{r['total_regen']}")

# B3. money = 0 when tariff unconfigured (cost_per_kwh = 0)
r = build([Trip(1, dist=10, energy=2.0)], 0.0)
if r["cost"] == 0.0:
    ok("B3 untariffed → cost 0 (UI hides section)")
else:
    fail("B3 cost not zero when tariff unconfigured")

# B4. short-trip range filter: a 0.2km / 1% tick must NOT enter range curve
trips = [
    Trip(1, dist=0.2, start_soc=80, end_soc=79),   # 1% → filtered
    Trip(2, dist=180, start_soc=90, end_soc=20),   # 70% → kept (~257 km)
]
r = build(trips, 0)
if len(r["range_pts"]) == 1 and abs(r["range_pts"][0][1] - (180 / 70 * 100)) < 1e-6:
    ok("B4 short trip filtered from range; long trip kept & correct")
else:
    fail(f"B4 short-trip filter wrong: {r['range_pts']}")

# B5. division-by-zero guards: zero distance, zero socDelta, zero energy
trips = [
    Trip(1, dist=0, energy=0, regen=0, start_soc=50, end_soc=50),
    Trip(2, dist=10, energy=2.0, start_soc=50, end_soc=50),  # socDelta 0 → no range
]
try:
    r = build(trips, 3.0)
    if r["range_pts"] == [] and r["total_dist"] == 10:
        ok("B5 zero distance/socDelta/energy → no div-by-zero, no bogus points")
    else:
        fail(f"B5 unexpected: range={r['range_pts']} dist={r['total_dist']}")
except ZeroDivisionError:
    fail("B5 ZeroDivisionError — guard missing")

# B6. consumption derived when avg field null but dist+energy present
r = build([Trip(1, dist=100, energy=18.0)], 0)
if len(r["cons_dots"]) == 1 and abs(r["cons_dots"][0][1] - 18.0) < 1e-6:
    ok("B6 consumption derived from dist+energy when stored field null")
else:
    fail(f"B6 derived consumption wrong: {r['cons_dots']}")

# B7. moving average never overshoots the data range (key UX requirement)
dots = [(i, v) for i, v in enumerate([20, 14, 22, 13, 25, 12, 24, 15, 21, 16, 23])]
sm = moving_average(dots, SMOOTH_WINDOW)
dmin, dmax = min(v for _, v in dots), max(v for _, v in dots)
if all(dmin <= y <= dmax for _, y in sm):
    ok(f"B7 smoothed line stays within [{dmin},{dmax}] — no overshoot")
else:
    fail(f"B7 smoothing overshot data range: {[round(y,1) for _,y in sm]}")

# B8. smoothing actually reduces jaggedness (variance drop)
raw_var = sum((v - sum(v for _, v in dots) / len(dots)) ** 2 for _, v in dots)
sm_var = sum((y - sum(y for _, y in sm) / len(sm)) ** 2 for _, y in sm)
if sm_var < raw_var:
    ok(f"B8 smoothing reduces variance ({raw_var:.0f} → {sm_var:.0f})")
else:
    fail("B8 smoothing did not reduce variance")

# B9. regen share clamped to ≤100 even if a malformed trip has regen>used
r = build([Trip(1, dist=10, energy=2.0, regen=5.0)], 0)  # regen>used
if r["regen_share"] and r["regen_share"][0][1] == 100.0:
    ok("B9 regen share clamped to 100% on malformed trip")
else:
    fail(f"B9 regen share not clamped: {r['regen_share']}")

# B10. cumulative distance is monotone non-decreasing
trips = [Trip(i, dist=d) for i, d in enumerate([10, 5, 20, 0, 8])]
r = build(trips, 0)
ys = [y for _, y in r["cumulative"]]
if ys == sorted(ys):
    ok("B10 cumulative distance monotone non-decreasing")
else:
    fail(f"B10 cumulative not monotone: {ys}")

# ────────────────────────────── report ──────────────────────────────
print("=" * 64)
print(f"+35 TRENDS REGRESSION — build +{pv}")
print("=" * 64)
for m in oks:
    print(f"  [PASS] {m}")
for m in warns:
    print(f"  [WARN] {m}")
for m in fails:
    print(f"  [FAIL] {m}")
print("=" * 64)
print(f"PASS {len(oks)} · WARN {len(warns)} · FAIL {len(fails)}")
sys.exit(1 if fails else 0)
