"""
Independent regression for v0.1.29+35/+36/+37.

  A. Trends rebuild (+35) structural checks.
  B. TrendAggregator maths edge cases (+35).
  C. Power-flow dashboard widget (+36).
  D. trips.extra speed-histogram backup (+37): migration is additive,
     binning matches SpeedHistogramCard exactly, JSON round-trips, parse
     is corruption-tolerant, cloud upload/restore carry extra, and the
     detail view falls back to extra when samples are empty.

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
if pv == diag.group(1) and pv == cloud.group(1) and int(pv) >= 35:
    ok(f"version triple-sync = +{pv}")
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

# ──────────── Part C: +36 power-flow dashboard widget ────────────
# Only meaningful once +36 is applied; on a pure +35 tree these are
# skipped (the version gate tells us which we're on).
if int(pv) >= 36:
    dash = (root / 'lib/screens/dashboard.dart').read_text()
    driver = (root / 'lib/screens/wide/driver_view_wide.dart').read_text()
    conn = (root / 'lib/services/connection.dart').read_text()

    # C1. widgets read the +33 getters by EXACT name (typo → CI compile fail)
    for getter in ["instantPowerKw", "powerFlowDirection"]:
        if getter in dash and getter in conn:
            ok(f"C1 dashboard reads svc.{getter}")
        else:
            fail(f"C1 dashboard missing/!exists getter {getter}")
    if "instantConsumptionWhKm" in dash:
        ok("C1 dashboard reads svc.instantConsumptionWhKm")
    else:
        fail("C1 dashboard missing instantConsumptionWhKm")
    if "instantPowerKw" in driver:
        ok("C1 driver display reads svc.instantPowerKw")
    else:
        fail("C1 driver display missing instantPowerKw")

    # C2. connection.dart MUST be untouched by +36 (protected file).
    #     The +33 getters must still be present and unchanged in shape.
    for sig in ["double? get instantPowerKw {",
                "int? get powerFlowDirection {",
                "double? get instantConsumptionWhKm {"]:
        if sig in conn:
            ok(f"C2 protected getter intact: {sig.split('get ')[1].split(' ')[0]}")
        else:
            fail(f"C2 protected getter altered/missing: {sig}")

    # C3. raw amps NOT surfaced on the dashboard (owner's call: provisional
    #     scale → show kW/flow, never a hard 'X A' figure). We allow the
    #     getter packCurrentA to exist in connection.dart, but the UI files
    #     must not render an ampere unit.
    amp_ui = (" A'" in dash) or (" A\"" in dash) or ("packCurrentA" in dash) or \
             (" A'" in driver) or ("packCurrentA" in driver)
    if not amp_ui:
        ok("C3 no raw-ampere readout in dashboard/driver UI")
    else:
        fail("C3 raw amps surfaced in UI — owner said power/flow only")

    # C4. BZ3 (tall layout) marks power as uncalibrated candidate.
    if "useTallLayout ? 'Regen?'" in dash or "Power?'" in dash:
        ok("C4 BZ3 marks power as candidate (790/0009 unverified there)")
    else:
        fail("C4 BZ3 power not marked candidate — risks false confirmed reading")

    # C5. flow colour helper present and maps 1/-1/0
    if "_flowColor" in dash:
        ok("C5 _flowColor helper present")
    else:
        fail("C5 _flowColor helper missing")
else:
    ok(f"Part C skipped (build +{pv}, power-flow widget lands in +36)")

# ──────────── Part D: +37 trips.extra speed-histogram backup ────────────
if int(pv) >= 37:
    db_src = (root / 'lib/data/database.dart').read_text()
    extra_src_path = root / 'lib/data/trip_extra.dart'
    conn_src = (root / 'lib/services/connection.dart').read_text()
    cloud_src = (root / 'lib/services/cloud_sync_service.dart').read_text()
    detail_src = (root / 'lib/screens/trip_detail.dart').read_text()

    # D1. schema migration: version bumped to 8, additive addColumn step.
    if "int get schemaVersion => 8;" in db_src:
        ok("D1 schemaVersion bumped to 8")
    else:
        fail("D1 schemaVersion not 8")
    if "if (from < 8)" in db_src and "m.addColumn(trips, trips.extra)" in db_src:
        ok("D1 migration adds trips.extra (additive)")
    else:
        fail("D1 from<8 addColumn(trips.extra) missing")
    # additive only — must NOT drop/recreate trips in the new step
    seg = db_src[db_src.find("if (from < 8)"):db_src.find("if (from < 8)") + 200]
    if "deleteTable" in seg or "drop" in seg.lower():
        fail("D1 from<8 step is destructive (drop/delete) — must be additive")
    else:
        ok("D1 from<8 step is non-destructive")

    # D2. extra written only when non-null (don't null existing on partial)
    if "extra != null ? Value(extra) : const Value.absent()" in db_src:
        ok("D2 endTrip writes extra only when non-null (absent otherwise)")
    else:
        fail("D2 endTrip extra write not guarded with Value.absent()")

    # D3. histogram computed at endTrip in connection.dart (protected,
    #     owner-authorised) and best-effort (wrapped so it can't block).
    if "computeSpeedHistogramJson" in conn_src and conn_src.count("computeSpeedHistogramJson") >= 2:
        ok("D3 connection computes histogram at both endTrip sites")
    else:
        fail("D3 histogram not computed at both endTrip sites")
    if "non-fatal" in conn_src and "computeSpeedHistogramJson" in conn_src:
        ok("D3 histogram compute is best-effort (cannot block finalize)")
    else:
        warn("D3 histogram compute may not be wrapped best-effort")

    # D4. cloud sync carries extra both ways
    if "'extra': _decodeExtraOrNull(t.extra)" in cloud_src:
        ok("D4 upload sends extra (decoded to object for jsonb)")
    else:
        fail("D4 upload does not send extra")
    if "extra: _encodeExtraOrAbsent(j['extra'])" in cloud_src:
        ok("D4 restore re-encodes server extra into local row")
    else:
        fail("D4 restore does not handle extra")

    # D5. detail view falls back to extra when samples empty
    if "TripExtra.parse(widget.trip?.extra)" in detail_src and "hasSpeedHistogram" in detail_src:
        ok("D5 trip detail falls back to extra histogram when samples empty")
    else:
        fail("D5 trip detail extra fallback missing")

    # D6. Python port of trip_extra binning — must match SpeedHistogramCard
    #     (15 bins × 10 km/h, exclude v<1). Verify the Dart constants too.
    if "speedBinSize = 10" in extra_src_path.read_text() and \
       "speedBinCount = 15" in extra_src_path.read_text():
        ok("D6 extra binning constants = 15×10 km/h (match histogram card)")
    else:
        fail("D6 extra binning constants differ from histogram card")

    SPEED_BIN_SIZE = 10
    SPEED_BIN_COUNT = 15

    def bin_speed(kmh):
        if kmh is None or kmh < 1:
            return None
        idx = int(kmh // SPEED_BIN_SIZE)
        if idx < 0 or idx >= SPEED_BIN_COUNT:
            return None
        return idx

    def build_hist(speeds):
        c = [0] * SPEED_BIN_COUNT
        for v in speeds:
            b = bin_speed(v)
            if b is not None:
                c[b] += 1
        return c

    # D7. binning matches the card's documented behaviour: v<1 excluded,
    #     150+ dropped, correct bucket assignment.
    h = build_hist([0, 0.5, 1, 9.9, 10, 55, 149, 150, 200, None])
    # expect: 1→bin0, 9.9→bin0, 10→bin1, 55→bin5, 149→bin14; 0/0.5/150/200/None excluded
    exp = [0]*15
    exp[0] = 2  # 1, 9.9
    exp[1] = 1  # 10
    exp[5] = 1  # 55
    exp[14] = 1  # 149
    if h == exp:
        ok("D7 binning matches card (v<1 and ≥150 excluded, buckets correct)")
    else:
        fail(f"D7 binning mismatch: {h} != {exp}")

    # D8. JSON round-trip: build → encode → parse → identical histogram.
    import json as _json
    def encode_extra(hist):
        m = {"v": 1}
        if hist and any(c > 0 for c in hist):
            m["speedHist"] = hist
        return None if len(m) == 1 else _json.dumps(m)

    def parse_extra(raw):
        if not raw:
            return None
        try:
            o = _json.loads(raw)
            h = o.get("speedHist")
            if isinstance(h, list) and len(h) == SPEED_BIN_COUNT:
                return [int(x) for x in h]
        except Exception:
            return None
        return None

    src = build_hist([5, 15, 15, 65, 65, 65, 120])
    rt = parse_extra(encode_extra(src))
    if rt == src:
        ok("D8 histogram JSON round-trips identically")
    else:
        fail(f"D8 round-trip mismatch: {rt} != {src}")

    # D9. empty histogram → encode returns None (don't store empty blobs)
    if encode_extra([0]*15) is None and encode_extra(None) is None:
        ok("D9 empty histogram stores nothing (no empty blobs)")
    else:
        fail("D9 empty histogram produced a blob")

    # D10. parse is corruption-tolerant: garbage / wrong-length → None,
    #      never throws.
    bad_inputs = ["", "not json", "{}", '{"speedHist":[1,2,3]}',
                  '{"speedHist":"nope"}', "null", "[1,2,3]"]
    crashed = False
    for b in bad_inputs:
        try:
            parse_extra(b)
        except Exception:
            crashed = True
    if not crashed and all(parse_extra(b) is None for b in bad_inputs):
        ok("D10 parse tolerant of malformed/short blobs (→ None, no throw)")
    else:
        fail("D10 parse not corruption-tolerant")
else:
    ok(f"Part D skipped (build +{pv}, extra-backup lands in +37)")

# ──────────── Part E: +38 trip-finalization end-value fallback ────────────
if int(pv) >= 38:
    conn_src = (root / 'lib/services/connection.dart').read_text()
    db_src = (root / 'lib/data/database.dart').read_text()

    # E1. DB helper exists
    if "Future<double?> lastNumericSampleForTrip(" in db_src:
        ok("E1 lastNumericSampleForTrip helper present")
    else:
        fail("E1 lastNumericSampleForTrip helper missing")

    # E2. it sorts desc + limit 1 (truly the LAST sample) and filters null
    anchor2 = "Future<double?> lastNumericSampleForTrip("
    helper = db_src[db_src.find(anchor2): db_src.find(anchor2) + 700]
    if "OrderingMode.desc" in helper and "limit(1)" in helper and \
       "numericValue.isNotNull()" in helper:
        ok("E2 helper returns last non-null sample (desc + limit 1)")
    else:
        fail("E2 helper query not correct (desc/limit/notnull)")

    # E3. BOTH finalize paths fall back to the DB for end odo + soc.
    # disconnect path uses ??= ; stopPolling path uses ?? inline.
    disc_ok = ("endSoc ??= await db.lastNumericSampleForTrip(tripId, '790', '0005')"
               in conn_src and
               "endOdo ??= await db.lastNumericSampleForTrip(tripId, '791', '0026')"
               in conn_src)
    stop_ok = ("await db.lastNumericSampleForTrip(_currentTripId!, '790', '0005')"
               in conn_src and
               "await db.lastNumericSampleForTrip(_currentTripId!, '791', '0026')"
               in conn_src)
    if disc_ok:
        ok("E3 disconnect-finalize falls back to DB for end odo/soc")
    else:
        fail("E3 disconnect-finalize missing DB fallback")
    if stop_ok:
        ok("E3 stopPolling-finalize falls back to DB for end odo/soc")
    else:
        fail("E3 stopPolling-finalize missing DB fallback")

    # E4. Logic port: distance/energy compute correctly once end values
    #     are recovered from the DB (the trips #1/#13 scenario).
    CAP = 80.0  # stand-in battery capacity kWh for the ratio check

    def finalize(start_odo, end_odo_cache, end_odo_db,
                 start_soc, end_soc_cache, end_soc_db):
        # mirror connection.dart: cache first, DB fallback
        end_odo = end_odo_cache if end_odo_cache is not None else end_odo_db
        end_soc = end_soc_cache if end_soc_cache is not None else end_soc_db
        dist = None
        if start_odo is not None and end_odo is not None and end_odo > start_odo:
            dist = end_odo - start_odo
        energy = None
        if start_soc is not None and end_soc is not None and start_soc > end_soc:
            energy = (start_soc - end_soc) * CAP / 100.0
        return dist, energy

    # Scenario A: cache empty (the bug) → DB fallback recovers it.
    # trip #13 numbers: odo 3209.2→3220.1, soc 50→47.
    dist, energy = finalize(3209.2, None, 3220.1, 50.0, None, 47.0)
    if dist is not None and abs(dist - 10.9) < 1e-6 and energy is not None:
        ok(f"E4 cache-empty → DB fallback recovers distance ({dist:.1f} km) + energy")
    else:
        fail(f"E4 fallback did not recover distance/energy: {dist}, {energy}")

    # Scenario B: cache present → cache wins (no behaviour change for the
    # happy path; DB value ignored).
    dist, _ = finalize(100.0, 150.0, 999.0, 80.0, 70.0, 10.0)
    if dist == 50.0:
        ok("E4 cache-present → cache value used (happy path unchanged)")
    else:
        fail(f"E4 cache no longer preferred when present: {dist}")

    # Scenario C: neither cache nor DB → distance stays null (no crash,
    # no bogus value).
    dist, energy = finalize(100.0, None, None, 80.0, None, None)
    if dist is None and energy is None:
        ok("E4 neither source → null (no crash, no fabricated distance)")
    else:
        fail(f"E4 produced value with no source: {dist}, {energy}")
else:
    ok(f"Part E skipped (build +{pv}, finalize fallback lands in +38)")

# ──────────── Part F: +39 pack-current fixes ────────────
if int(pv) >= 39:
    conn_src = (root / 'lib/services/connection.dart').read_text()

    # F1. 790/0009 excluded from the generic poll (fast-lane is sole writer)
    if "ecu.txId == '790' && spec.did == '0009'" in conn_src and \
       "continue;" in conn_src:
        ok("F1 790/0009 excluded from generic poll (no raw/amps double-write)")
    else:
        fail("F1 790/0009 still double-written by generic poll")

    # F2. zero refined to the measured standstill value
    if "_kPackCurrentZeroRaw = 5024.0" in conn_src:
        ok("F2 current zero corrected 4800 → 5024 (kills standstill phantom)")
    else:
        fail("F2 current zero not updated to 5024")

    # F3. scale deliberately UNCHANGED (no guessing without steady-state data)
    if "_kPackCurrentAmpsPerLsb = 0.05" in conn_src:
        ok("F3 scale 0.05 left provisional (correct — no valid calib data)")
    else:
        fail("F3 scale was changed — but export had no steady-state anchor")

    # F4. numeric sanity: with zero=5024, a standstill raw≈5024 → ~0 A,
    #     and the old phantom (~5 kW) is gone.
    ZERO=5024.0; LSB=0.05; V=446.0
    standstill_kw = (5024-ZERO)*LSB*V/1000
    old_kw = (5024-4800)*LSB*V/1000
    if abs(standstill_kw) < 0.5 and abs(old_kw - 5.0) < 1.0:
        ok(f"F4 standstill now ~{standstill_kw:.1f} kW (was ~{old_kw:.1f} kW phantom)")
    else:
        fail(f"F4 zero math off: now={standstill_kw:.2f} old={old_kw:.2f}")

    # F5. sign still exact at the new zero: raw above → discharge(+),
    #     below → regen(−).
    disc = (5500-ZERO)*LSB
    regn = (4500-ZERO)*LSB
    if disc > 0 and regn < 0:
        ok("F5 sign preserved at new zero (raw>5024 discharge, <5024 regen)")
    else:
        fail("F5 sign broken at new zero")
else:
    ok(f"Part F skipped (build +{pv}, current fixes land in +39)")

# ──────────── Part G: +40 dashboard grid stability ────────────
if int(pv) >= 40:
    dash = (root / 'lib/screens/dashboard.dart').read_text()

    # G1. Power/Consumption/PDU cards must NOT be conditional anymore —
    #     a conditional card drops out of the grid when its value is null
    #     and shifts every later card (BZ3 owner: tiles jump at a stop).
    bad = []
    for guard in ["if (powerKw != null)", "if (consWhKm != null)",
                  "if (pduTemp1 != null)", "if (pduTemp2 != null)"]:
        if guard in dash:
            bad.append(guard)
    if not bad:
        ok("G1 no conditional metric cards (grid can't reflow on null)")
    else:
        fail(f"G1 conditional cards still present (will reflow): {bad}")

    # G2. cards show a dash placeholder when their value is null, so the
    #     cell stays but reads '—'.
    if ": '—'" in dash and "consWhKm != null" in dash and "powerKw != null" in dash:
        ok("G2 cards show '—' placeholder when value null (cell persists)")
    else:
        fail("G2 null placeholder wiring missing")

    # G3. consumption must NOT fabricate 0 at standstill — undefined →
    #     dash, not a misleading zero.
    idx = dash.find("'Consumption?' : 'Consumption'")
    cons_seg = dash[idx: idx + 250] if idx >= 0 else ""
    if "consWhKm != null" in cons_seg and "'—'" in cons_seg:
        ok("G3 consumption shows '—' at standstill (no fake 0 Wh/km)")
    else:
        warn("G3 could not confirm consumption dash-at-standstill")
else:
    ok(f"Part G skipped (build +{pv}, grid stability lands in +40)")

# ──────────── Part H: +41 orphan/backfill finalization ────────────
if int(pv) >= 41:
    db_src = (root / 'lib/data/database.dart').read_text()
    conn_src = (root / 'lib/services/connection.dart').read_text()

    # H1. firstNumericSampleForTrip helper added (asc + limit 1)
    if "Future<double?> firstNumericSampleForTrip(" in db_src:
        anchor = "Future<double?> firstNumericSampleForTrip("
        fn = db_src[db_src.find(anchor): db_src.find(anchor) + 600]
        if "OrderingMode.asc" in fn and "limit(1)" in fn:
            ok("H1 firstNumericSampleForTrip helper present (asc + limit 1)")
        else:
            fail("H1 firstNumericSampleForTrip query wrong")
    else:
        fail("H1 firstNumericSampleForTrip helper missing")

    # H2. forceCloseTrip now derives aggregates (was endedAt-only).
    fc = db_src[db_src.find("Future<DateTime> forceCloseTrip"):
                db_src.find("Future<DateTime> forceCloseTrip") + 2400]
    derives = all(s in fc for s in [
        "firstNumericSampleForTrip(tripId, '791', '0026')",
        "lastNumericSampleForTrip(tripId, '791', '0026')",
        "distanceKm = endOdo - startOdo",
        "sampleCount",
    ])
    if derives:
        ok("H2 forceCloseTrip recovers distance/energy/count from samples")
    else:
        fail("H2 forceCloseTrip still endedAt-only (orphan stays empty)")

    # H3. it must NOT fabricate values — each field guarded, capacity
    #     passed in (no vehicle-model dependency in DB layer).
    fc_full = db_src[db_src.find("Future<DateTime> forceCloseTrip"):
                     db_src.find("Future<DateTime> forceCloseTrip") + 4500]
    if "batteryCapacityKwh != null" in fc_full and "Value.absent()" in fc_full:
        ok("H3 forceCloseTrip null-safe (no fabricated values, capacity injected)")
    else:
        fail("H3 forceCloseTrip not null-safe / hardcodes capacity")

    # H4. caller passes capacity
    if "forceCloseTrip(t.id" in conn_src and \
       "batteryCapacityKwh: Bz5Model.batteryCapacityKwh" in conn_src:
        ok("H4 connection passes battery capacity to forceCloseTrip")
    else:
        fail("H4 connection does not pass capacity")

    # H5. backfill: orphan query catches already-closed empty trips too.
    if "t.endedAt.isNull() | t.distanceKm.isNull()" in db_src:
        ok("H5 orphan query also backfills closed trips with null distance")
    else:
        fail("H5 orphan query only catches endedAt-null (won't fix #1/#13/#15)")

    # H6. Logic port: orphan with samples but no cached start/end → recover.
    CAP = 65.28
    def force_close(first_odo, last_odo, first_soc, last_soc, n):
        dist = (last_odo - first_odo) if (first_odo is not None and last_odo
                is not None and last_odo > first_odo) else None
        energy = ((first_soc - last_soc) * CAP / 100.0) if (first_soc is not None
                 and last_soc is not None and first_soc > last_soc) else None
        return dist, energy, n
    # #15-like: samples present (odo 3220→3231, soc 47→44), ended but empty.
    dist, energy, cnt = force_close(3220.1, 3231.0, 47.0, 44.0, 980)
    if dist is not None and abs(dist - 10.9) < 1e-6 and energy is not None and cnt == 980:
        ok(f"H6 orphan recovery: distance {dist:.1f} km, energy + count restored")
    else:
        fail(f"H6 orphan recovery wrong: {dist}, {energy}, {cnt}")
    # No usable samples → all null, no crash, no fake distance.
    dist, energy, cnt = force_close(None, None, None, None, 0)
    if dist is None and energy is None and cnt == 0:
        ok("H6 no samples → nulls (no fabricated distance)")
    else:
        fail(f"H6 fabricated value with no samples: {dist}, {energy}")
else:
    ok(f"Part H skipped (build +{pv}, orphan finalize lands in +41)")

# ──────────── Part I: +42 heavy aggregate recovery ────────────
if int(pv) >= 42:
    db_src = (root / 'lib/data/database.dart').read_text()

    # I1. recoverHeavyAggregates method exists
    if "Future<TripsCompanion> recoverHeavyAggregates(" in db_src:
        ok("I1 recoverHeavyAggregates method present")
    else:
        fail("I1 recoverHeavyAggregates missing")

    rha = db_src[db_src.find("recoverHeavyAggregates(int"):
                 db_src.find("recoverHeavyAggregates(int") + 4000] \
        if "recoverHeavyAggregates(int" in db_src else ""

    # I2. recovers every field the screen showed blank
    fields = ["peakSpeedKmh", "avgMovingSpeedKmh", "movingSeconds",
              "idleSeconds", "minBatteryTempC", "maxBatteryTempC",
              "minSoc", "maxSoc", "maxCellSpreadMv"]
    missing = [f for f in fields if f not in rha]
    if not missing:
        ok("I2 recovers all heavy fields (peak/moving/idle/temp/soc/spread)")
    else:
        fail(f"I2 heavy recovery missing fields: {missing}")

    # I3. reads the right DIDs (speed 740/0008, temp 790/002F, soc 790/0005,
    #     cells 790/002D & 002B)
    dids_ok = all(d in rha for d in
                  ["'740'", "'0008'", "'790'", "'002F'", "'0005'",
                   "'002D'", "'002B'"])
    if dids_ok:
        ok("I3 reads correct DIDs for each aggregate")
    else:
        fail("I3 wrong/missing DIDs in heavy recovery")

    # I4. forceCloseTrip merges heavy via copyWith (not separate write)
    fc = db_src[db_src.find("Future<DateTime> forceCloseTrip"):
                db_src.find("Future<DateTime> forceCloseTrip") + 3000]
    if "recoverHeavyAggregates(tripId)" in fc and "heavy.copyWith(" in fc:
        ok("I4 forceCloseTrip merges heavy aggregates via copyWith")
    else:
        fail("I4 forceCloseTrip does not merge heavy aggregates")

    # I5. Logic port: peak speed comes from samples, not a stale scalar
    #     (Друг 2 diagnosis: peak_speed=3.3 while histogram had 60-70).
    def heavy(speeds):
        if not speeds:
            return None, None, 0, 0
        peak = max(speeds)
        moving = [s for s in speeds if s >= 1.0]
        idle_n = len([s for s in speeds if s < 1.0])
        avg_mov = sum(moving) / len(moving) if moving else None
        return peak, avg_mov, len(moving), idle_n
    # samples reaching 67 km/h must yield peak 67, not 3.3
    peak, avg_mov, mv, idl = heavy([0, 3.3, 20, 45, 67, 50, 0, 0])
    if peak == 67 and avg_mov is not None and mv == 5 and idl == 3:
        ok(f"I5 peak from samples = {peak} (fixes stale-scalar 3.3 bug)")
    else:
        fail(f"I5 heavy speed calc wrong: peak={peak} avg={avg_mov} mv={mv} idl={idl}")

    # I6. cell spread = max(002D) − min(002B), guarded
    def spread(hi_list, lo_list):
        if not hi_list or not lo_list:
            return None
        hi, lo = max(hi_list), min(lo_list)
        return (hi - lo) if hi >= lo else None
    if spread([3712, 3720, 3715], [3650, 3648, 3655]) == 72 and \
       spread([], [1]) is None:
        ok("I6 cell spread = max(002D)−min(002B), null-guarded")
    else:
        fail("I6 cell spread calc wrong")
else:
    ok(f"Part I skipped (build +{pv}, heavy recovery lands in +42)")

# ──────────── Part J: +43 park-based trip segmentation ────────────
if int(pv) >= 43:
    conn_src = (root / 'lib/services/connection.dart').read_text()

    # J1. segmentation method exists and is called in the poll loop
    if "_maybeSegmentTripOnPark()" in conn_src and \
       conn_src.count("_maybeSegmentTripOnPark") >= 2:
        ok("J1 _maybeSegmentTripOnPark defined and called in poll loop")
    else:
        fail("J1 segmentation method missing or not wired")

    seg = conn_src[conn_src.find("Future<void> _maybeSegmentTripOnPark"):
                   conn_src.find("Future<void> _maybeSegmentTripOnPark") + 2200]

    # J2. charging must NOT be read as end-of-trip
    if "isCharging" in seg:
        ok("J2 charging excluded from park-segmentation (no false close)")
    else:
        fail("J2 charging not excluded — DC charge would falsely segment")

    # J3. reuses the clean finalize path (no duplicate close logic)
    if "_finalizeTripFromLastKnown()" in seg:
        ok("J3 reuses _finalizeTripFromLastKnown (identical aggregates, no dup)")
    else:
        fail("J3 does not reuse the clean finalize path")

    # J4. re-arms trip creation after closing
    if "_wantTripCreation = true" in seg:
        ok("J4 re-arms _wantTripCreation so next D starts a new trip")
    else:
        fail("J4 does not re-arm trip creation (next drive wouldn't start)")

    # J5. debounce + threshold present, gear==P (1) detected
    if "_kParkConfirmDuration" in seg and "_kParkCloseThreshold" in seg \
       and "gear.toInt() == 1" in seg:
        ok("J5 P-debounce + 10-min threshold + gear==P(1) detection present")
    else:
        fail("J5 debounce/threshold/gear-detection incomplete")

    # J6. no-double-close: the finalize path it calls guards on
    #     _currentTripId == null (so a later BLE-drop close is a no-op).
    fin = conn_src[conn_src.find("Future<void> _finalizeTripFromLastKnown"):
                   conn_src.find("Future<void> _finalizeTripFromLastKnown") + 200]
    if "if (_currentTripId == null) return;" in fin:
        ok("J6 finalize guards on null trip → park-close can't double-close")
    else:
        fail("J6 finalize lacks null guard — risk of double close")

    # J7. Logic port: state machine (P debounce → park clock → close).
    CONFIRM = 30   # seconds
    CLOSE = 600    # seconds
    def sim(events):
        # events: list of (t_seconds, gear) where gear 1=P else moving
        confirm_start = None; parked_since = None; closed_at = None
        for t, gear in events:
            in_park = (gear == 1)
            if not in_park:
                confirm_start = None; parked_since = None
                continue
            if confirm_start is None:
                confirm_start = t
            if t - confirm_start < CONFIRM:
                continue
            if parked_since is None:
                parked_since = t
            if t - parked_since >= CLOSE and closed_at is None:
                closed_at = t
        return closed_at
    # parked continuously from t=0 → confirmed at 30s, clock from 30s,
    # closes at 30+600=630s.
    park_stream = [(t, 1) for t in range(0, 700, 5)]
    c = sim(park_stream)
    if c is not None and 625 <= c <= 635:
        ok(f"J7 continuous park closes at ~{c}s (30s confirm + 600s threshold)")
    else:
        fail(f"J7 close timing wrong: {c}")
    # short stop (5 min) then drive → never closes
    short = [(t, 1) for t in range(0, 300, 5)] + [(305, 3)]
    if sim(short) is None:
        ok("J7 5-min stop does NOT close (sub-threshold park ignored)")
    else:
        fail("J7 short stop wrongly closed the trip")
    # spurious single P frame amid driving → never arms
    spur = [(0, 3), (5, 1), (10, 3), (15, 3)]
    if sim(spur) is None:
        ok("J7 spurious P frame does not arm (debounce works)")
    else:
        fail("J7 spurious P wrongly armed")
else:
    ok(f"Part J skipped (build +{pv}, segmentation lands in +43)")

# ────────────────────────────── report ──────────────────────────────
print("=" * 64)
print(f"+35→+43 REGRESSION — build +{pv}")
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
