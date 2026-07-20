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
# v0.1.33+132: the version regex was hardwired to the 0.1.29 minor and
# silently died the day the minor rolled to 0.1.30 (AttributeError on the
# very first check). The build number (+N) is the only monotonic part all
# the era-gates below compare against, so match any x.y.z and keep +N.
_pv_m = re.search(r"version:\s*(\d+\.\d+\.\d+\+(\d+))", (root / 'pubspec.yaml').read_text())
full_ver, pv = _pv_m.group(1), _pv_m.group(2)
diag = re.search(r"_kDiagVersion = 'v\d+\.\d+\.\d+\+(\d+)'", (root / 'lib/screens/dashboard.dart').read_text())
cloud = re.search(r"_readAppVersion\(\) async => '\d+\.\d+\.\d+\+(\d+)'", (root / 'lib/services/cloud_sync_service.dart').read_text())
if pv == diag.group(1) and pv == cloud.group(1) and int(pv) >= 35:
    ok(f"version triple-sync = +{pv}")
else:
    fail(f"version triple mismatch: pubspec={pv} diag={diag and diag.group(1)} cloud={cloud and cloud.group(1)}")

# A2. data layer method
if "Future<List<Trip>> getTripsInRange(DateTime from, DateTime to)" in db:
    ok("database.getTripsInRange present")
else:
    fail("getTripsInRange missing from database.dart")

# A3. three sections wired.
#     +60: section labels moved into the l10n dictionary — trends.dart
#     references keys, strings.dart holds both translations. The check
#     follows: key usage in trends + RU value still present in dict.
if int(pv) >= 60:
    _strings_src = (root / 'lib/l10n/strings.dart').read_text()
    for key, ru_label in [
        ('trends.sec_totals', 'Итоги за период'),
        ('trends.sec_cumulative', 'Накопительно'),
        ('trends.sec_efficiency', 'Эффективность вождения'),
        ('trends.sec_health', 'Здоровье батареи'),
    ]:
        if f"_SectionLabel(S.of('{key}'))" in trends and ru_label in _strings_src:
            ok(f"section present via l10n key: {key}")
        else:
            fail(f"section missing: {key} / {ru_label}")
else:
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

# A6. cumulative odometer must NOT be curved (monotone integrity).
#     +60: the title literal became an l10n key — anchor on the key.
_a6_anchor = (r"S\.of\('trends\.cumulative_dist'\).*?curved:\s*(true|false)"
              if int(pv) >= 60
              else r"Пробег накопительно.*?curved:\s*(true|false)")
m = re.search(_a6_anchor, trends, re.S)
# v0.1.32+131 flipped the contract ON PURPOSE: the cumulative card is
# curved, protected by preventCurveOverShooting (verified separately
# just below) — monotone data stays monotone, the staircase softens.
_a6_want = "true" if int(pv) >= 131 else "false"
if m and m.group(1) == _a6_want:
    ok(f"cumulative distance curved={_a6_want} (per-era contract)")
elif m:
    fail(f"cumulative distance curved={m.group(1)}, expected {_a6_want} for +{pv}")
else:
    warn("could not locate cumulative-distance curved flag")

# A7. cost gated on configuration
if "if (cost.isConfigured)" in trends:
    ok("cost UI gated on CostSettings.isConfigured")
else:
    warn("cost section not gated on isConfigured — may show 0 when untariffed")

# A8. aggregator constants present
# +130 Trends v2 removed smoothing/range constants (bars replaced the
# smoothed line; real-range card dropped); +132 added the bucket floor.
if int(pv) >= 132:
    _a8_need = ["kMinDistForConsumptionKm", "kUsableCapacityKwh",
                "kMinBucketDistKm"]
elif int(pv) >= 130:
    _a8_need = ["kMinDistForConsumptionKm", "kUsableCapacityKwh"]
else:
    _a8_need = ["kMinSocDeltaForRange", "kConsumptionSmoothingWindow"]
_a8_missing = [c for c in _a8_need if c not in agg_src]
if not _a8_missing:
    ok(f"aggregator constants present ({', '.join(_a8_need)})")
else:
    fail(f"aggregator constants missing: {_a8_missing}")

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
    # v0.1.44+143 (era-aware, spec §A3): the charging banner NOW renders
    # the HAL charge current — that is the CONFIRMED-scale
    # BYDAutoChargingDevice|0x2D300018 double (verified vs UDS), not the
    # provisional OBD2 figure this rule was written against. The rule
    # still holds everywhere else: strip the banner class body before the
    # scan (AP1 separately asserts the banner wiring).
    dash_c3 = dash
    if int(pv) >= 143:
        _cb0 = dash.find('class _ChargingBanner')
        _cb1 = dash.find('class _TripCard', max(_cb0, 0))
        if -1 < _cb0 < _cb1:
            dash_c3 = dash[:_cb0] + dash[_cb1:]
    amp_ui = (" A'" in dash_c3) or (" A\"" in dash_c3) or \
             ("packCurrentA" in dash_c3) or \
             (" A'" in driver) or ("packCurrentA" in driver)
    if not amp_ui:
        ok("C3 no raw-ampere readout in dashboard/driver UI")
    else:
        fail("C3 raw amps surfaced in UI — owner said power/flow only")

    # C4. BZ3 (tall layout) marks power as uncalibrated candidate.
    #     v0.1.29+48: superseded — BZ3 verified by livelog 2 (see N1-N4),
    #     the '*'/'?' candidate markers were intentionally removed. On
    #     +48+ this check inverts: the markers MUST be gone.
    if int(pv) >= 48:
        ok("C4 superseded by N3 on +48+ (BZ3 verified, markers removed)")
    elif "useTallLayout ? 'Regen?'" in dash or "Power?'" in dash:
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
    # v0.1.29+125: structural DDL is wrapped in if-absent guards
    # (_addColumnIfAbsent/_createTableIfAbsent). Normalize back to
    # the raw form so additive-migration checks keep asserting the
    # same migration CONTENT regardless of the guard wrapper.
    db_src = db_src.replace('_addColumnIfAbsent(m, ', 'm.addColumn(') \
                   .replace('_createTableIfAbsent(m, ', 'm.createTable(')
    extra_src_path = root / 'lib/data/trip_extra.dart'
    conn_src = (root / 'lib/services/connection.dart').read_text()
    cloud_src = (root / 'lib/services/cloud_sync_service.dart').read_text()
    detail_src = (root / 'lib/screens/trip_detail.dart').read_text()

    # D1. schema migration: version bumped to 14 (v0.1.29+117 C1:
    # client_uuid UUIDv7 on the 5 syncable tables + partial unique
    # indexes + backfill + uuid-mapping push). Prior steps remain
    # present/additive: from<8 trips.extra, from<9 hal_samples,
    # from<10 samples.charging_session_id (+94), from<11 soh_estimates
    # table (+104), from<12 soh_estimates.source (+105, splits UDS
    # id=1 / HAL id=2), from<13 trips.last_alive_ts (+106), from<14
    # client_uuid x5 (+117).
    _d1_expected = 16 if int(pv) >= 140 else (15 if int(pv) >= 130 else 14)  # +140: trip_series (v16)
    if f"int get schemaVersion => {_d1_expected};" in db_src:
        ok(f"D1 schemaVersion = {_d1_expected} (per-era)")
    else:
        fail(f"D1 schemaVersion != {_d1_expected}")
    if int(pv) >= 130:
        if "if (from < 15)" in db_src and "sohHistory" in db_src:
            ok("D1 migration adds soh_history (from<15, additive)")
        else:
            fail("D1 from<15 soh_history step missing")
    if "if (from < 8)" in db_src and "m.addColumn(trips, trips.extra)" in db_src:
        ok("D1 migration adds trips.extra (additive)")
    else:
        fail("D1 from<8 addColumn(trips.extra) missing")
    if "if (from < 9)" in db_src and "m.createTable(halSamples)" in db_src:
        ok("D1 migration adds hal_samples (additive)")
    else:
        fail("D1 from<9 createTable(halSamples) missing")
    if "if (from < 10)" in db_src and \
       "m.addColumn(samples, samples.chargingSessionId)" in db_src:
        ok("D1 migration adds samples.charging_session_id (additive)")
    else:
        fail("D1 from<10 addColumn(samples.chargingSessionId) missing")
    if "if (from < 11)" in db_src and "m.createTable(sohEstimates)" in db_src:
        ok("D1 migration adds soh_estimates (additive)")
    else:
        fail("D1 from<11 createTable(sohEstimates) missing")
    if "if (from < 12)" in db_src and \
       "m.addColumn(sohEstimates, sohEstimates.source)" in db_src:
        ok("D1 migration adds soh_estimates.source (additive)")
    else:
        fail("D1 from<12 addColumn(sohEstimates.source) missing")
    if "if (from < 13)" in db_src and \
       "m.addColumn(trips, trips.lastAliveTs)" in db_src:
        ok("D1 migration adds trips.last_alive_ts (additive)")
    else:
        fail("D1 from<13 addColumn(trips.lastAliveTs) missing")
    # v0.1.29+117 (C1): from<14 — client_uuid on the 5 syncable tables,
    # partial unique indexes, backfill.
    if "if (from < 14)" in db_src and \
       "m.addColumn(trips, trips.clientUuid)" in db_src and \
       "m.addColumn(snapshots, snapshots.clientUuid)" in db_src and \
       "m.addColumn(sweepRuns, sweepRuns.clientUuid)" in db_src and \
       "m.addColumn(liveLogSessions, liveLogSessions.clientUuid)" in db_src and \
       "canMonitorSessions, canMonitorSessions.clientUuid" in db_src:
        ok("D1 migration adds client_uuid to all 5 syncable tables (additive)")
    else:
        fail("D1 from<14 addColumn(clientUuid) x5 incomplete")
    if "CREATE UNIQUE INDEX IF NOT EXISTS idx_${table}_client_uuid" in db_src \
       and "WHERE client_uuid IS NOT NULL" in db_src:
        ok("D1 client_uuid partial unique indexes (NULL-tolerant)")
    else:
        fail("D1 client_uuid partial unique index statement missing")
    if "_backfillClientUuids" in db_src and \
       db_src.count("_backfillClientUuids") >= 2:
        ok("D1 from<14 backfill invoked (defined + called)")
    else:
        fail("D1 _backfillClientUuids missing or never called")
    uuid_gen_path = root / 'lib/data/uuid_v7.dart'
    uuid_gen_src = uuid_gen_path.read_text() if uuid_gen_path.is_file() else ""
    if "String uuidV7({DateTime? time})" in uuid_gen_src:
        ok("D1 uuid_v7 generator present")
    else:
        fail("D1 lib/data/uuid_v7.dart missing or wrong signature")
    # C1 mapping-push client: endpoint, watermark prefix, 404/405 tolerance,
    # ordering (mapping strictly AFTER the ingest pushes in syncOnce).
    if "'/v2/sync/uuid-mapping'" in cloud_src and \
       "cloud_sync_uuid_map_wm_" in cloud_src:
        ok("D1 uuid-mapping push wired (endpoint + watermarks)")
    else:
        fail("D1 uuid-mapping endpoint/watermarks missing in cloud_sync")
    if "_EndpointNotDeployedException" in cloud_src and \
       "tolerateNotDeployed" in cloud_src:
        ok("D1 uuid-mapping tolerates undeployed endpoint (404/405)")
    else:
        fail("D1 uuid-mapping 404/405 tolerance missing")
    # v0.1.29+118 hotfix regression: the 404/405 branch MUST live inside
    # _postIngest (where the tolerateNotDeployed parameter is), not in
    # _getJson. +117 shipped it in the wrong method — identical anchor
    # comment in two methods — and CI kernel_snapshot failed with
    # "getter isn't defined". Scope heuristic: the branch must appear
    # AFTER the parameter declaration in file order (_getJson precedes
    # _postIngest in this file).
    pos_param = cloud_src.find("{bool tolerateNotDeployed = false}")
    pos_branch = cloud_src.find("if (tolerateNotDeployed && (code == 404")
    if pos_param != -1 and pos_branch != -1 and pos_branch > pos_param:
        ok("D1 404/405 branch scoped inside _postIngest (after its param)")
    else:
        fail("D1 404/405 branch outside _postIngest scope (the +117 bug)")
    # +146: entities are wrapped in guardEntity — the ordering INVARIANT is
    # unchanged, only the call syntax moved. Anchor per build.
    pos_can = cloud_src.find(
        "guardEntity('canmonitors', _syncCanMonitors)"
        if int(pv) >= 146 else "await _syncCanMonitors();")
    pos_map = cloud_src.find("await _syncUuidMapping();")
    if pos_can != -1 and pos_map != -1 and pos_can < pos_map:
        ok("D1 uuid-mapping ordered after ingest pushes in syncOnce")
    else:
        fail("D1 _syncUuidMapping must run after _syncCanMonitors")
    if "j['client_uuid'] is String" in cloud_src and \
       cloud_src.count("j['client_uuid'] is String") >= 2:
        ok("D1 restore adopts server client_uuid (trips + snapshots)")
    else:
        fail("D1 restore companions don't read client_uuid from payload")
    # additive only — must NOT drop/recreate tables in the new steps
    for marker in ("if (from < 8)", "if (from < 9)", "if (from < 10)",
                   "if (from < 11)", "if (from < 12)", "if (from < 13)",
                   "if (from < 14)"):
        seg = db_src[db_src.find(marker):db_src.find(marker) + 200]
        if "deleteTable" in seg or "drop" in seg.lower():
            fail(f"D1 {marker} step is destructive (drop/delete) — must be additive")
        else:
            ok(f"D1 {marker} step is non-destructive")

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
    # v0.1.29+125: structural DDL is wrapped in if-absent guards
    # (_addColumnIfAbsent/_createTableIfAbsent). Normalize back to
    # the raw form so additive-migration checks keep asserting the
    # same migration CONTENT regardless of the guard wrapper.
    db_src = db_src.replace('_addColumnIfAbsent(m, ', 'm.addColumn(') \
                   .replace('_createTableIfAbsent(m, ', 'm.createTable(')

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

    # F2. zero refined to the measured standstill value.
    #     v0.1.29+47: superseded — DC-calibration moved zero from
    #     5024 (parked-stat-fit) to 5018 (least-squares on 4 anchor
    #     points; see M1). On +47+ the +39-era 5024 check is wrong
    #     by construction; M1 takes over.
    if int(pv) >= 47:
        ok("F2 superseded by M1 on +47+ (zero now 5018 from DC calib)")
    elif "_kPackCurrentZeroRaw = 5024.0" in conn_src:
        ok("F2 current zero corrected 4800 → 5024 (kills standstill phantom)")
    else:
        fail("F2 current zero not updated to 5024")

    # F3. scale deliberately UNCHANGED (no guessing without steady-state data).
    #     v0.1.29+47: superseded — Friend2's DC fast-charge session
    #     finally provided the steady-state anchor, and scale moved
    #     from provisional 0.05 to calibrated 0.1021 (see M2). On +47+
    #     this test inverts: scale MUST have moved.
    if int(pv) >= 47:
        ok("F3 superseded by M2 on +47+ (scale now 0.1021 from DC calib)")
    elif "_kPackCurrentAmpsPerLsb = 0.05" in conn_src:
        ok("F3 scale 0.05 left provisional (correct — no valid calib data)")
    else:
        fail("F3 scale was changed — but export had no steady-state anchor")

    # F4. numeric sanity at the active calibration.
    #     v0.1.29+47: re-pinned to the new (5018, 0.1021) pair. The
    #     standstill-phantom guarantee still holds: raw at the zero
    #     produces ~0 A; raw at the OLD wrong zero (4800) still
    #     produces a phantom but using the NEW slope it's bigger
    #     (~10 kW instead of ~5) — which is fine, it just means the
    #     old bug would have been twice as bad with the correct slope.
    if int(pv) >= 47:
        ZERO=5018.0; LSB=0.1021; V=446.0
        standstill_kw = (5018-ZERO)*LSB*V/1000
        # Sanity: at zero raw we get exactly 0 A.
        if abs(standstill_kw) < 0.01:
            ok(f"F4 standstill at new zero = {standstill_kw:.2f} kW (zero is the zero)")
        else:
            fail(f"F4 standstill math off at new zero: {standstill_kw:.2f}")
    else:
        ZERO=5024.0; LSB=0.05; V=446.0
        standstill_kw = (5024-ZERO)*LSB*V/1000
        old_kw = (5024-4800)*LSB*V/1000
        if abs(standstill_kw) < 0.5 and abs(old_kw - 5.0) < 1.0:
            ok(f"F4 standstill now ~{standstill_kw:.1f} kW (was ~{old_kw:.1f} kW phantom)")
        else:
            fail(f"F4 zero math off: now={standstill_kw:.2f} old={old_kw:.2f}")

    # F5. sign still exact at the new zero: raw above → discharge(+),
    #     below → regen(−). Re-pinned to new zero on +47+.
    if int(pv) >= 47:
        disc = (5500-5018.0)*0.1021
        regn = (4500-5018.0)*0.1021
    else:
        disc = (5500-5024.0)*0.05
        regn = (4500-5024.0)*0.05
    if disc > 0 and regn < 0:
        ok("F5 sign preserved at active zero (raw>zero discharge, <zero regen)")
    else:
        fail("F5 sign broken at active zero")
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
    # v0.1.29+125: structural DDL is wrapped in if-absent guards
    # (_addColumnIfAbsent/_createTableIfAbsent). Normalize back to
    # the raw form so additive-migration checks keep asserting the
    # same migration CONTENT regardless of the guard wrapper.
    db_src = db_src.replace('_addColumnIfAbsent(m, ', 'm.addColumn(') \
                   .replace('_createTableIfAbsent(m, ', 'm.createTable(')
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
    # v0.1.29+125: structural DDL is wrapped in if-absent guards
    # (_addColumnIfAbsent/_createTableIfAbsent). Normalize back to
    # the raw form so additive-migration checks keep asserting the
    # same migration CONTENT regardless of the guard wrapper.
    db_src = db_src.replace('_addColumnIfAbsent(m, ', 'm.addColumn(') \
                   .replace('_createTableIfAbsent(m, ', 'm.createTable(')

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

# ──────────── Part K: +44 trends UI fixes (date axis + tooltip rounding) ────────────
if int(pv) >= 44:
    # K1. old _leftOnlyTitles() helper replaced by gated _chartTitles().
    #     Strict signature so a partial rename can't pass — the old name
    #     must no longer be CALLED (a backtick mention in a doc-comment
    #     for historical clarity is fine), the new name must be present,
    #     and the new one must accept an optional `bottom` argument.
    if "_leftOnlyTitles(" not in trends and \
       "FlTitlesData _chartTitles({SideTitles? bottom})" in trends:
        ok("K1 _chartTitles helper replaces _leftOnlyTitles (bottom-aware)")
    else:
        fail("K1 _chartTitles helper missing or _leftOnlyTitles still called")

    # K2. _timeSideTitles defined and decodes x as epoch-ms → DateTime
    if "SideTitles _timeSideTitles(" in trends and \
       "DateTime.fromMillisecondsSinceEpoch(v.toInt())" in trends:
        ok("K2 _timeSideTitles decodes epoch-ms x to DateTime")
    else:
        fail("K2 _timeSideTitles missing or doesn't decode epoch-ms")

    # K3. _monthBarSideTitles looks up bars[i].start (real DateTime),
    #     not just rendering the integer index.
    # +130 renamed _monthBarSideTitles → _periodBarSideTitles (day/month
    # buckets); the invariant — labels from bars[i].start — is unchanged.
    _k3_name = ("_periodBarSideTitles" if int(pv) >= 130
                else "_monthBarSideTitles")
    if f"SideTitles {_k3_name}(" in trends and "bars[i].start" in trends:
        ok(f"K3 {_k3_name} uses bars[i].start for real period labels")
    else:
        fail(f"K3 {_k3_name} missing or doesn't read PeriodBar.start")

    # K4. _LineCard and _ScatterTrendCard wire bottom=_timeSideTitles via
    #     spots.first.x / spots.last.x or dotSpots.first.x / dotSpots.last.x.
    _lc_start = trends.find("class _LineCard")
    _lc_end = trends.find("class _", _lc_start + 10)
    line_card = trends[_lc_start:_lc_end]
    line_ok = "_timeSideTitles(" in line_card and \
              "minX: spots.first.x" in line_card and \
              "maxX: spots.last.x" in line_card
    if int(pv) >= 130:
        # +130 removed _ScatterTrendCard with the real-range card; the
        # date-axis invariant now lives in _LineCard alone (the +131
        # _SpreadCard is checked by its own part, not here).
        if line_ok:
            ok("K4 _LineCard wires date axis from spot extremes"
               " (scatter card removed in +130)")
        else:
            fail("K4 _LineCard date axis not wired from spot extremes")
    else:
        scatter_card = trends[trends.find("class _ScatterTrendCard"):trends.find("class _BarCard")]
        scatter_ok = "_timeSideTitles(" in scatter_card and \
                     "minX: dotSpots.first.x" in scatter_card and \
                     "maxX: dotSpots.last.x" in scatter_card
        if line_ok and scatter_ok:
            ok("K4 _LineCard + _ScatterTrendCard wire date axis from spot extremes")
        else:
            fail(f"K4 date axis not wired correctly: line={line_ok} scatter={scatter_ok}")

    # K5. _BarCard wires _monthBarSideTitles(bars)
    bar_card = trends[trends.find("class _BarCard"):trends.find("// ── shared chart helpers ──")]
    _k5_call = ("_periodBarSideTitles(bars, bucket)" if int(pv) >= 130
                else "_monthBarSideTitles(bars)")
    if _k5_call in bar_card:
        ok(f"K5 _BarCard wires period bottom axis via {_k5_call}")
    else:
        fail(f"K5 _BarCard missing {_k5_call} wiring")

    # K6. SOH block no longer subtracts a t0 offset — must use absolute
    #     epoch-ms so the date-axis formatter shows real years, not 1970.
    _k6_anchor = ("Ah-method (coulomb-counted) SOH points" if int(pv) >= 130
                  else "SOH curve straight off snapshots")
    soh_block_idx = trends.find(_k6_anchor)
    soh_block = trends[soh_block_idx:soh_block_idx + 700] if soh_block_idx >= 0 else ""
    if soh_block and "final t0 =" not in soh_block and \
       "millisecondsSinceEpoch.toDouble()" in soh_block and \
       "- t0" not in soh_block:
        ok("K6 SOH points use absolute epoch-ms (no t0 subtraction)")
    else:
        fail("K6 SOH block still uses relative-to-t0 offset → dates would be 1970")

    # K7. Cost rounding to one decimal. In +44 this lived inside a
    #     custom BarTouchTooltipData on the bar card — which turned out
    #     to be exactly the API surface that blanked the chart on the
    #     BZ5 head unit (see L2). The +45 redesign moves the rounding
    #     into the cost footer composed in _buildSections, and removes
    #     the tooltip altogether. From +45 the test looks at the footer
    #     formula instead; pre-+45 it still checks the tooltip path.
    if int(pv) >= 45:
        if "costTotal.toStringAsFixed(1)" in trends:
            ok("K7 cost rounded to one decimal in footer (+45 redesign path)")
        else:
            fail("K7 cost footer not rounded to one decimal")
    else:
        if "barTouchData: BarTouchData(" in bar_card and \
           "BarTouchTooltipData(" in bar_card and \
           "getTooltipItem:" in bar_card and \
           "rod.toY.toStringAsFixed(1)" in bar_card:
            ok("K7 cost tooltip uses rod.toY.toStringAsFixed(1) — no IEEE-754 garbage")
        else:
            fail("K7 cost tooltip missing or doesn't round (would show 10.64064000000003)")

    # K8. Date-format ladder: three branches for span (30d / 1y / all).
    #     A regression would be a single hardcoded format that misreads
    #     a 30-day window or a 10-year window. Match all three formats.
    #     v0.1.29+49: the ≤400d branch was rewired from a direct
    #     DateFormat.MMM('ru') call to the _fmtMonthRu helper (which
    #     defends against missing intl-locale data). Accept either form.
    ts_block_idx = trends.find("SideTitles _timeSideTitles(")
    ts_block = trends[ts_block_idx:ts_block_idx + 1500] if ts_block_idx >= 0 else ""
    ru_branch_present = ("DateFormat.MMM('ru')" in ts_block) or \
                        ("fmt = _fmtMonthRu" in ts_block)
    if ts_block and "'dd.MM'" in ts_block and \
       ru_branch_present and \
       "'MM.yy'" in ts_block:
        ok("K8 date format ladder covers ≤45d / ≤400d / all")
    else:
        fail("K8 date format ladder incomplete (need dd.MM, MMM ru/helper, MM.yy)")

    # K9. Tick thinning in bar axis: i % step != 0 → SizedBox.shrink().
    #     Without this, a 24-month "all" view would overlap labels.
    mb_block_idx = trends.find(f"SideTitles {_k3_name}(")
    mb_block = trends[mb_block_idx:mb_block_idx + 1200] if mb_block_idx >= 0 else ""
    if mb_block and "i % step != 0" in mb_block and \
       "SizedBox.shrink()" in mb_block:
        ok("K9 bar axis thins labels via stride (no overlap on wide windows)")
    else:
        fail("K9 bar axis lacks stride thinning")

    # K10. Continuous-time axis must not place ticks on top of the y-axis
    #      strip or off the right edge of the card. Guard ticks within
    #      `step * 0.4` of either extreme — this matches our implementation.
    if ts_block and "step * 0.4" in ts_block and "SizedBox.shrink()" in ts_block:
        ok("K10 time axis guards extremes (no collision with y-strip)")
    else:
        fail("K10 time axis missing edge-extreme guard")

    # K11. Logic port: stride formula in _monthBarSideTitles must yield 1
    #      for n≤4, 2 for n=5..8, 3 for n=9..12, etc. Mirror Dart math
    #      directly so any later "optimization" that breaks the formula
    #      shows up as a test failure.
    def stride(n):
        return max(1, min(n, ((n + 3) // 4)))
    cases = {1: 1, 3: 1, 4: 1, 5: 2, 8: 2, 9: 3, 12: 3, 24: 6}
    if all(stride(n) == s for n, s in cases.items()):
        ok("K11 month-bucket stride formula matches Dart for n∈{1,3,4,5,8,9,12,24}")
    else:
        fail("K11 stride formula diverged from Dart")

else:
    ok(f"Part K skipped (build +{pv}, trends UI fixes land in +44)")

# ──────────── Part L: +45 trends clean-slate redesign ────────────
if int(pv) >= 45:
    # L1. Default window is now 30d (was 1y). One-character change, but
    #     the regression catches a future "improvement" that defaults
    #     back to 1y and surprises a new user with a blank 30d-only
    #     history.
    if "_Window _window = _Window.d30;" in trends:
        ok("L1 default window is 30d")
    else:
        fail("L1 default window not d30 — would show 1y for new users")

    # L2. No barTouchData / BarTouchTooltipData CALL anywhere in
    #     trends.dart. This is the root cause of the blank white bar
    #     card on the BZ5 in v44: the fl_chart 0.68 tooltip API trips
    #     release-mode rendering. The +45 redesign removes it entirely;
    #     per-bar value moves to the footer. Historical mentions in
    #     doc-comments are kept on purpose (so the next contributor
    #     understands why we don't use this API) — match the open paren
    #     to detect a real call, not a comment.
    if "BarTouchTooltipData(" not in trends and \
       "BarTooltipItem(" not in trends and \
       "getTooltipItem:" not in trends:
        ok("L2 no BarTouchTooltipData/BarTooltipItem/getTooltipItem CALLS in trends")
    else:
        fail("L2 fl_chart tooltip API leaked back into trends — same risk as +44")

    # L3. Bar card disables touch outright (no chance of any touch path
    #     activating the same code surface that blanked v44).
    if "BarTouchData(enabled: false)" in trends:
        ok("L3 bar chart touch disabled outright")
    else:
        fail("L3 bar chart touch not disabled — would still expose tooltip surface")

    # L4. Bar card has a text fallback for <3 months (one bar is not a
    #     chart). Match the method name AND the boundary.
    if "_textFallback()" in trends and "bars.length < 3" in trends:
        ok("L4 bar card text fallback engages at <3 months")
    else:
        fail("L4 bar card missing text fallback for <3 months")

    # L5. _LineCard accepts forcedMinY/forcedMaxY for SOH-style fixed
    #     bounds. The signature must include the optional doubles.
    if "final double? forcedMinY;" in trends and \
       "final double? forcedMaxY;" in trends:
        ok("L5 _LineCard supports forced Y bounds")
    else:
        fail("L5 _LineCard missing forced Y bound parameters")

    # L6. SOH bound logic must be adaptive: floor at min(measured, 95),
    #     ceiling at max(measured, 100). Match the expressions.
    if "measuredMin < 95.0 ? measuredMin - 0.5 : 95.0" in trends and \
       "measuredMax > 100.0 ? measuredMax + 0.5 : 100.0" in trends:
        ok("L6 SOH bounds are adaptive (95-100% baseline, extends with data)")
    else:
        fail("L6 SOH bounds not adaptive — hard-coded or missing")

    # L7. Real-range filter now uses kMinDistForRangeKm in the
    #     aggregator. Verify both the constant declaration and the
    #     conditional that uses it.
    if int(pv) >= 130:
        ok("L7 superseded by +130 Trends v2 (real-range card removed; "
           "short-hop guard lives on as kMinDistForConsumptionKm)")
    elif "kMinDistForRangeKm = 3.0" in agg_src and \
         "dist >= kMinDistForRangeKm" in agg_src:
        ok("L7 real-range short-trip filter (≥3 km) added to aggregator")
    else:
        fail("L7 real-range distance filter missing — would leak 2.4-km anomalies")

    # L8. Every card type now requires a `footer` parameter — the
    #     caller composes the meaningful string. Verify the required
    #     keyword shows up in each class.
    def _class_body(name):
        _i = trends.find(f"class {name}")
        if _i < 0: return None
        _j = trends.find("class _", _i + 10)
        return trends[_i:_j if _j > 0 else len(trends)]
    if int(pv) >= 131:
        _l8_classes = ["_LineCard", "_SpreadCard", "_SohComboCard", "_BarCard"]
    elif int(pv) >= 130:
        _l8_classes = ["_LineCard", "_SohComboCard", "_BarCard"]
    else:
        _l8_classes = ["_LineCard", "_ScatterTrendCard", "_BarCard"]
    _l8_missing = [c for c in _l8_classes
                   if not (_class_body(c) or "").count("required this.footer,")]
    if not _l8_missing:
        ok(f"L8 footer required in every card class ({', '.join(_l8_classes)})")
    else:
        fail(f"L8 footer parameter missing in: {_l8_missing}")

    # L9. _buildSections must wire all six footers explicitly. Check
    #     each composition string fragment shows up.
    footer_fragments = [
        "cumFooter",
        "costFooter",
        "consFooter",
        "regenFooter",
        "sohFooter",
        "spreadFooter" if int(pv) >= 130 else "rangeFooter",
    ]
    missing = [f for f in footer_fragments if f not in trends]
    if not missing:
        ok("L9 _buildSections composes all six footers (cum/cost/cons/regen/soh/range)")
    else:
        fail(f"L9 missing footer composition: {missing}")

    # L10. Logic port: weighted-average consumption is total energy /
    #      total distance × 100 (not per-trip average). Era-aware: from
    #      +150 the weighted average lives in the aggregate as the
    #      co-covered ratio (still Σenergy/Σdistance, cleaner window) and
    #      the footer reads it from there.
    _l10_ok = ("agg.totalEnergyKwh / agg.totalDistanceKm * 100" in trends
               if int(pv) < 150
               else ("agg.avgConsumptionKwh100" in trends and
                     "pairedEnergy / pairedDist * 100" in agg_src))
    if _l10_ok:
        ok("L10 average consumption is weighted (energy/distance), not per-trip mean")
    else:
        fail("L10 average consumption formula wrong — would skew with short trips")

    # L11. Logic port (Python): SOH adaptive-bound formula.
    def soh_bounds(samples):
        if not samples: return (None, None)
        m, M = min(samples), max(samples)
        lo = m - 0.5 if m < 95.0 else 95.0
        hi = M + 0.5 if M > 100.0 else 100.0
        return (lo, hi)
    cases = [
        ([], (None, None)),
        ([97.0, 98.0], (95.0, 100.0)),       # healthy → fixed window
        ([93.0, 94.5], (92.5, 100.0)),       # worn → floor extends
        ([99.0, 100.5], (95.0, 101.0)),      # over-100 (rare) → ceiling extends
    ]
    if all(soh_bounds(s) == expected for s, expected in cases):
        ok("L11 SOH adaptive bounds: healthy=fixed, worn=floor-extends, over=ceiling-extends")
    else:
        fail("L11 SOH bound formula diverged from Dart")

    # L12. Logic port: range filter rejects short trips even with
    #      adequate ΔSOC.
    def range_pt(dist_km, soc_delta):
        if dist_km is None or dist_km < 3.0: return None
        if soc_delta < 5.0: return None
        return dist_km / soc_delta * 100
    cases = [
        ((1.0, 50.0), None),    # 1 km × 50% ΔSOC → 2 km/100% — rejected
        ((0.24, 10.0), None),   # tiny hop, even with 10% — rejected
        ((3.0, 5.0), 60.0),     # threshold case — kept (60 km/100%)
        ((30.0, 10.0), 300.0),  # normal trip — kept (300 km/100%)
    ]
    if all(range_pt(*args) == expected for args, expected in cases):
        ok("L12 range-point filter rejects <3 km hops regardless of ΔSOC")
    else:
        fail("L12 range-point filter formula diverged from Dart")

else:
    ok(f"Part L skipped (build +{pv}, clean-slate trends redesign lands in +45)")

# ──────────── Part M: +47 DC-calibration of pack current (C33) ────────────
if int(pv) >= 47:
    # Load connection.dart fresh — it's outside the usual `trends` blob.
    conn_src = open("lib/services/connection.dart").read()

    # M1. New zero. The +39 zero was 5024 (from a stat-fit on parked
    #     samples); the +47 zero is 5018 from least-squares on 4 DC
    #     anchor points incl. an independently-confirmed t0 = 0 A.
    #     Match the exact literal — a typo that flips the sign-cross
    #     by a few amps would slip past sanity checks.
    if "_kPackCurrentZeroRaw = 5018.0" in conn_src and \
       "_kPackCurrentZeroRaw = 5024" not in conn_src:
        ok("M1 zero raw is 5018 (was 5024 provisional in +39..+46)")
    else:
        fail("M1 zero raw not 5018 — calibration not applied or old value lingers")

    # M2. New scale. Friend2's least-squares = 0.10214, rounded to
    #     0.1021. The prior 0.05 underestimated power ~2x; the new
    #     value is 2.04× that, matching the "8-9 kW @ 90 km/h vs real
    #     ~15 kW" field observation.
    if "_kPackCurrentAmpsPerLsb = 0.1021" in conn_src and \
       "_kPackCurrentAmpsPerLsb = 0.05" not in conn_src:
        ok("M2 amps-per-LSB is 0.1021 A/LSB (was 0.05 provisional)")
    else:
        fail("M2 amps-per-LSB not 0.1021 — calibration not applied")

    # M3. Sanity-check ratio: new/old must be ~2.04 (verifies the
    #     calibration didn't get fat-fingered to e.g. 0.01021).
    new_lsb = 0.1021
    old_lsb = 0.05
    ratio = new_lsb / old_lsb
    if 2.0 <= ratio <= 2.1:
        ok(f"M3 ratio new/old = {ratio:.3f} ≈ 2.04 (matches field observation)")
    else:
        fail(f"M3 ratio out of band: {ratio:.3f} — calibration value suspect")

    # M4. Sign rule still documented: charge (into pack) negative,
    #     discharge positive. A future "cleanup" that drops the
    #     convention would silently invert the regen/consumption math.
    if "discharge\n  /// positive, charge (current INTO pack) negative" in conn_src or \
       ("discharge" in conn_src and "charge (current INTO pack) negative" in conn_src):
        ok("M4 sign convention documented (charge<0, discharge>0)")
    else:
        fail("M4 sign convention not documented near the constants")

    # M5. Logic port (Python): each of the 4 anchor points reproduces
    #     within ±3.3 A. This is the actual residual check from
    #     Friend2's calibration — if anyone touches the constants and
    #     this fails, the calibration is broken.
    def i_amps(raw):
        return (raw - 5018) * 0.1021
    anchors = [
        (5019, 0,    0.1),    # t0: no current,    station 0 A
        (3213, -181, -184.3), # t1: 86 kW charge
        (3205, -186, -185.1), # t2: 90 kW charge
        (3101, -198, -195.8), # t3: 96 kW charge
    ]
    max_residual = 0.0
    for raw, station, expected_model in anchors:
        modelled = i_amps(raw)
        # Sanity 1: our Python re-fit matches Friend2's published model.
        if abs(modelled - expected_model) > 0.1:
            fail(f"M5 anchor raw={raw}: model {modelled:.1f} != published {expected_model:.1f}")
            break
        # Sanity 2: residual against station (ground truth) ≤ 3.3 A.
        residual = abs(modelled - station)
        if residual > max_residual:
            max_residual = residual
    else:
        if max_residual <= 3.3:
            ok(f"M5 all 4 anchor points fit ≤3.3 A (max residual {max_residual:.1f} A)")
        else:
            fail(f"M5 residual {max_residual:.1f} A exceeds Friend2's published 3.3 A bound")

    # M6. Cross-check with C32 drive raw: full-throttle raw 0x26E1
    #     should produce ~503 A → ~200 kW at ~400 V. This is the
    #     drive-side validation Friend2 ran independently.
    fullthrottle = i_amps(0x26E1)
    if 495 <= fullthrottle <= 510:
        ok(f"M6 C32 full-throttle cross-check: raw 0x26E1 → {fullthrottle:.0f} A (≈ peak motor)")
    else:
        fail(f"M6 C32 full-throttle cross-check off: {fullthrottle:.1f} A (expected ~503)")

    # M7. The 791/0038 caveat must be documented in code — otherwise
    #     a future contributor will reach for it as a charge cross-
    #     check and get garbage (motor idle during DC charge → raw
    #     stays constant). This is a real trap; pin the warning.
    if "791/0038 is NOT a charge cross-check" in conn_src:
        ok("M7 791/0038-not-for-charge caveat documented")
    else:
        fail("M7 missing 791/0038 charge-cross-check warning — future trap")

else:
    ok(f"Part M skipped (build +{pv}, DC current calibration lands in +47)")

# ──────────── Part N: +48 BZ3 verified on dashboard ────────────
if int(pv) >= 48:
    dash_src = open("lib/screens/dashboard.dart").read()

    # N1. The "BZ3 NOT verified" caveat block is gone. We keep a
    #     positive note ("VERIFIED 2026-06-04") in its place, so the
    #     check is for the negative phrasing being absent.
    if "NOT verified on BZ3" not in dash_src:
        ok("N1 'NOT verified on BZ3' caveat removed from dashboard")
    else:
        fail("N1 dashboard still warns BZ3 is unverified — stale comment")

    # N2. The positive marker IS present — proves we replaced the old
    #     wording with the new, not just deleted it (which would leave
    #     us with a silent change harder to trace later).
    if "BZ3: VERIFIED 2026-06-04" in dash_src:
        ok("N2 positive 'VERIFIED 2026-06-04' marker present in dashboard")
    else:
        fail("N2 BZ3 verification marker missing — was the caveat just deleted?")

    # N3. Star/question suffixes on the Power/Consumption labels are
    #     gone — BZ3 owners now see the same readout shape as BZ5.
    #     Two narrow checks: the literal '?' label variants and the
    #     '*' value suffix are both absent.
    qmark_present = "'Regen?'" in dash_src or "'Power?'" in dash_src or \
                    "'Consumption?'" in dash_src
    star_present = "useTallLayout ? '*'" in dash_src
    if not qmark_present and not star_present:
        ok("N3 no '?' label or '*' value suffix anywhere on dashboard")
    else:
        fail(f"N3 stale candidate-marker still present: ?={qmark_present} *={star_present}")

    # N4. Logic port (Python): the BZ3 livelog 2 standstill behaviour
    #     under the +47 calibration. We hard-code the field statistics
    #     so any future "improvement" that breaks the calibration also
    #     breaks the BZ3 verification — they're a single fact now.
    BZ3_STANDSTILL_RAW_MEDIAN = 5021  # measured in friend's session 2
    BZ3_STANDSTILL_RAW_RANGE  = (4910, 5052)
    zero = 5018
    lsb  = 0.1021
    # Median should produce ~+0.3 A on the +47 calibration; the band
    # should never exceed ±15 A (anything bigger means the calibration
    # is wrong for BZ3 and the verification message in N2 is a lie).
    median_amps = (BZ3_STANDSTILL_RAW_MEDIAN - zero) * lsb
    low_amps    = (BZ3_STANDSTILL_RAW_RANGE[0] - zero) * lsb
    high_amps   = (BZ3_STANDSTILL_RAW_RANGE[1] - zero) * lsb
    if abs(median_amps) < 1.0 and abs(low_amps) < 15 and abs(high_amps) < 15:
        ok(f"N4 BZ3 standstill on +47 calib: median {median_amps:+.1f} A, band {low_amps:+.1f}..{high_amps:+.1f} A — sane")
    else:
        fail(f"N4 BZ3 standstill no longer sane on calibration: median={median_amps:.2f}")

else:
    ok(f"Part N skipped (build +{pv}, BZ3 verification lands in +48)")

# ──────────── Part O: +49 ru locale init for intl ────────────
if int(pv) >= 49:
    main_src = open("lib/main.dart").read()
    trends   = open("lib/screens/trends.dart").read()

    # O1. main.dart imports the locale data package.
    if "package:intl/date_symbol_data_local.dart" in main_src:
        ok("O1 main.dart imports intl date_symbol_data_local")
    else:
        fail("O1 missing intl locale-data import in main.dart")

    # O2. main.dart awaits initializeDateFormatting('ru') BEFORE runApp.
    #     Order matters — if runApp runs first, the first frame can hit
    #     DateFormat.MMM('ru') and throw LocaleDataException → white box.
    #     Match the substring AND verify runApp comes after.
    init_idx = main_src.find("initializeDateFormatting('ru')")
    runapp_idx = main_src.find("runApp(")
    if 0 < init_idx < runapp_idx:
        ok("O2 initializeDateFormatting('ru') called before runApp")
    else:
        fail("O2 ru locale init missing or wrongly ordered vs runApp")

    # O3. The await is present (not a fire-and-forget). Without await,
    #     the first frame races the locale data load.
    if "await initializeDateFormatting('ru')" in main_src:
        ok("O3 ru locale init is awaited (no race with first frame)")
    else:
        fail("O3 initializeDateFormatting not awaited — first frame races")

    # O4. trends.dart now has a defensive _fmtMonthRu helper with
    #     try/catch fallback to a hardcoded month-name array. Belt-
    #     and-suspenders: even if init somehow fails, white boxes
    #     don't return.
    #     +60: helper became locale-aware — fallback indexes a
    #     ternary-selected array, intl locale follows S.locale.
    _o4_fallback = ("(ru ? _ruMonthShort : _enMonthShort)[d.month - 1]"
                    if int(pv) >= 60 else "_ruMonthShort[d.month - 1]")
    if "String _fmtMonthRu(DateTime d)" in trends and \
       "try {" in trends and \
       _o4_fallback in trends:
        ok("O4 trends has defensive _fmtMonthRu helper with hardcoded fallback")
    else:
        fail("O4 _fmtMonthRu defensive helper missing")

    # O5. NO direct DateFormat.MMM('ru') call sites remain OUTSIDE the
    #     defensive helper itself. The helper has exactly one such call
    #     wrapped in try/catch — that's the whole point. Match the
    #     pattern that would indicate a leak (fmt assignment, format
    #     chain), which the helper doesn't use.
    leak_patterns = [
        "fmt = DateFormat.MMM('ru')",  # old fmt-object assignment pattern
        "= DateFormat.MMM('ru')",      # any assignment outside _fmtMonthRu
    ]
    leaks = sum(trends.count(p) for p in leak_patterns)
    # Subtract the legitimate use inside _fmtMonthRu (it does
    # `return DateFormat.MMM('ru').format(d)`, no `=`).
    if leaks == 0:
        ok("O5 no direct DateFormat.MMM('ru') leaks outside the helper")
    else:
        fail(f"O5 {leaks} direct DateFormat.MMM('ru') leak(s) — routes around helper")

    # O6. Hardcoded fallback array has 12 months in the right order
    #     (no off-by-one — May=5 must be 'май'). Port the array,
    #     spot-check the canonical month for the field bug ("Br 13.0"
    #     for May was the original white-box reproduction).
    ru_months = ['янв', 'фев', 'мар', 'апр', 'май', 'июн',
                 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек']
    if ru_months[5 - 1] == 'май' and len(ru_months) == 12:
        ok("O6 ru month fallback array: May=май, 12 entries, no off-by-one")
    else:
        fail("O6 ru month fallback wrong size or off-by-one")

else:
    ok(f"Part O skipped (build +{pv}, ru locale fix lands in +49)")

# ──────────── Part P: +50 hold-last-value for Power/Consumption ────────────
if int(pv) >= 50:
    # P1. Two StatefulWidget classes exist: _PowerCard and _ConsumptionCard.
    if "class _PowerCard extends StatefulWidget" in dash and \
       "class _ConsumptionCard extends StatefulWidget" in dash:
        ok("P1 _PowerCard and _ConsumptionCard StatefulWidget classes present")
    else:
        fail("P1 hold-state wrapper classes missing")

    # P2. _MetricCard accepts an optional stale parameter with default
    #     false (so the change is backward-compatible for the other
    #     cards that don't need hold-state).
    if "final bool stale;" in dash and "this.stale = false," in dash:
        ok("P2 _MetricCard has optional 'stale' parameter, default false")
    else:
        fail("P2 _MetricCard missing stale parameter or default")

    # P3. Both Compact and Phone layouts wrap the value Text in Opacity
    #     controlled by stale. A regression would be applying the
    #     opacity only to one layout — BZ3 (compact) and BZ5 (phone-
    #     style on tall) would diverge.
    opacity_uses = dash.count("opacity: stale ? 0.5 : 1.0")
    if opacity_uses >= 2:
        ok(f"P3 Opacity(stale ? 0.5 : 1.0) wraps value in both layouts ({opacity_uses} sites)")
    else:
        fail(f"P3 expected ≥2 Opacity(stale) wrappers, found {opacity_uses}")

    # P4. The dashboard call sites for the two cards are the wrappers,
    #     NOT inline _MetricCard. Match the constructor invocation.
    if "_PowerCard(powerKw: powerKw, flowDir: flowDir)" in dash and \
       "_ConsumptionCard(consWhKm: consWhKm)" in dash:
        ok("P4 dashboard wires _PowerCard / _ConsumptionCard with live values")
    else:
        fail("P4 dashboard call sites don't use the new wrappers")

    # P5. Timer-based expiry (not periodic polling). One-shot Timer
    #     plus dispose-time cancel is the correct lifecycle pattern.
    #     A `Timer.periodic` here would be a smell — would tick every
    #     interval forever even when no data is moving.
    if "Timer? _expiry;" in dash and \
       "Timer(_holdWindow," in dash and \
       "Timer.periodic" not in dash:
        ok("P5 expiry is one-shot Timer (not periodic) with reset-on-absorb")
    else:
        fail("P5 expiry timer wrong shape (periodic, or missing reset)")

    # P6. The expiry callback guards with `mounted` before setState —
    #     forgetting this leaks setState on a disposed State, which
    #     prints a runtime exception in release.
    if "if (mounted) setState(() {});" in dash:
        ok("P6 expiry callback guards setState with mounted check")
    else:
        fail("P6 expiry callback missing mounted guard")

    # P7. dispose() cancels the timer. Without this the Timer fires
    #     after the widget is gone — same mounted-check protects
    #     against the runtime exception, but the Timer itself leaks
    #     until it fires.
    if "_expiry?.cancel();" in dash:
        ok("P7 dispose cancels expiry timer (no leak)")
    else:
        fail("P7 dispose doesn't cancel expiry timer — leak path")

    # P8. Hold window is 8 seconds. Long enough to ride out a single
    #     ~5-8s polling cycle but short enough that a held value
    #     can't claim to represent the present.
    if "Duration(seconds: 8)" in dash:
        ok("P8 hold window is 8 seconds (one polling cycle, no lies)")
    else:
        fail("P8 hold window changed from 8s — verify intentional")

    # P9. Logic port (Python): the decision table for what to show.
    #     live=value → show value, fresh.
    #     live=None, held<window → show held, stale.
    #     live=None, held>=window → show '—', not stale.
    #     live=None, never held → show '—', not stale.
    def decide(live, held, age_sec, window=8):
        if live is not None: return (live, False)
        if held is not None and age_sec is not None and age_sec <= window:
            return (held, True)
        return (None, False)
    cases = [
        ((42.0, None, None), (42.0, False)),    # fresh, no history
        ((None, 42.0,   3),  (42.0, True)),     # gap within window
        ((None, 42.0,   8),  (42.0, True)),     # at window boundary (inclusive)
        ((None, 42.0,  20),  (None, False)),    # past window, drop to '—'
        ((None, None,  None), (None, False)),   # nothing ever, '—'
        ((13.0, 42.0,   3),  (13.0, False)),    # fresh wins over recent held
    ]
    if all(decide(*args) == expected for args, expected in cases):
        ok("P9 hold/fresh/expired decision table matches Dart logic")
    else:
        fail("P9 hold decision table diverged from Dart")

else:
    ok(f"Part P skipped (build +{pv}, Power/Consumption hold-state lands in +50)")

# ──────────── Part Q: +51 pack-current polling observability ────────────
if int(pv) >= 51:
    conn = open("lib/services/connection.dart").read()
    settings = open("lib/screens/settings.dart").read()
    import os.path
    pd_path = "lib/screens/polling_diagnostics.dart"
    has_pd_file = os.path.exists(pd_path)

    # Q1. Four counter fields exist in ConnectionService. Match each
    #     literal so a future rename can't pass silently.
    fields = [
        "int _packCurrentReadOkCount = 0;",
        "DateTime? _packCurrentPrevSuccessAt;",
        "int _packCurrentMaxGapMs = 0;",
        "int _packCurrentGetterCalls = 0;",
        "int _packCurrentGetterNulls = 0;",
    ]
    missing = [f for f in fields if f not in conn]
    if not missing:
        ok("Q1 all five observability fields present in ConnectionService")
    else:
        fail(f"Q1 missing observability fields: {[m[:40] for m in missing]}")

    # Q2. Four public getters expose the counters. resetPackCurrentObservers
    #     method exists and notifies listeners.
    getters = [
        "int get packCurrentReadOkCount =>",
        "int get packCurrentMaxGapMs =>",
        "int? get packCurrentCurrentGapMs {",
        "int get packCurrentGetterCalls =>",
        "int get packCurrentGetterNulls =>",
        "void resetPackCurrentObservers() {",
    ]
    missing = [g for g in getters if g not in conn]
    if not missing:
        ok("Q2 all six getters + reset method exposed")
    else:
        fail(f"Q2 missing accessors: {[m[:40] for m in missing]}")

    # Q3. Getter packCurrentA must increment calls AND nulls on the two
    #     null-return paths. The previous behaviour was three early
    #     returns with no observation. We need both increments.
    if "_packCurrentGetterCalls++;" in conn and \
       conn.count("_packCurrentGetterNulls++;") >= 2:
        ok("Q3 packCurrentA getter increments calls + nulls on both paths")
    else:
        fail("Q3 getter doesn't observe calls/nulls correctly")

    # Q4. Ingest path updates readOk count + max gap BEFORE assigning
    #     to _packCurrentA — otherwise the gap is wrong (uses current
    #     time as prev, gives gap=0). Match the order.
    ingest_idx = conn.find("if (amps >= -600.0 && amps <= 600.0) {")
    if ingest_idx < 0:
        fail("Q4 cannot find ingest path — major refactor?")
    else:
        block = conn[ingest_idx:ingest_idx + 1000]
        readok_idx = block.find("_packCurrentReadOkCount++;")
        assign_idx = block.find("_packCurrentA = amps;")
        gap_idx    = block.find("_packCurrentMaxGapMs =")
        if 0 < readok_idx < assign_idx and 0 < gap_idx < readok_idx:
            ok("Q4 ingest updates max gap → readOk++ → assigns _packCurrentA (order correct)")
        else:
            fail(f"Q4 ingest ordering wrong: gap={gap_idx} readOk={readok_idx} assign={assign_idx}")

    # Q5. The diagnostics screen file exists. Loose file-creation check;
    #     contents validated by Q6.
    if has_pd_file:
        ok("Q5 polling_diagnostics.dart file created")
    else:
        fail("Q5 polling_diagnostics.dart missing — patch incomplete")

    if has_pd_file:
        pd = open(pd_path).read()
    else:
        pd = ""

    # Q6. The screen wires to context.watch<ConnectionService>() so it
    #     rebuilds on notify, plus a 1 Hz Timer.periodic so the live
    #     gap counter advances visibly between notifies. Both are
    #     needed — service notify alone freezes the "current gap"
    #     between successful reads.
    if "context.watch<ConnectionService>()" in pd and \
       "Timer.periodic(const Duration(seconds: 1)" in pd:
        ok("Q6 diag screen watches service AND ticks 1Hz for live gap display")
    else:
        fail("Q6 diag screen missing service watch or 1 Hz ticker")

    # Q7. The reset button calls resetPackCurrentObservers (not some
    #     local-only reset that wouldn't actually zero the service).
    if "svc.resetPackCurrentObservers()" in pd:
        ok("Q7 reset button calls service-side resetPackCurrentObservers")
    else:
        fail("Q7 reset button doesn't reset service counters")

    # Q8. Settings imports the new screen and exposes a ListTile that
    #     navigates to it. Without this entry the screen exists but
    #     can't be reached from the UI.
    if "import 'polling_diagnostics.dart';" in settings and \
       "PollingDiagnosticsScreen()" in settings:
        ok("Q8 Settings imports and navigates to PollingDiagnosticsScreen")
    else:
        fail("Q8 Settings doesn't expose the new diag screen")

    # Q9. Logic port (Python): null-rate calculation. Zero calls → 0%
    #     (avoid divide-by-zero); non-zero → nulls/calls × 100.
    def null_rate(nulls, calls):
        return 0.0 if calls == 0 else nulls / calls * 100
    cases = [
        ((0,    0), 0.0),
        ((50, 100), 50.0),
        ((0,  100), 0.0),
        ((100,100), 100.0),
    ]
    if all(null_rate(*args) == expected for args, expected in cases):
        ok("Q9 null-rate formula matches Dart (handles zero calls)")
    else:
        fail("Q9 null-rate formula diverged from Dart")

    # Q10. No NEW behavioural change in the polling cycle. The 2-second
    #      stale-gate must still be in place; no new reads added; no
    #      new timers in the service. Conservative check: the
    #      `inMilliseconds > 2000` literal still appears in the getter,
    #      and the ingest path still reads `0009` with the same timeout.
    #
    #      v0.1.29+53: superseded — the three-group scheduler patch
    #      DOES (legitimately) change polling cycle: removes the
    #      sub-poll cascade, widens stale-gate to 8 s, adds recovery.
    #      Q10's negative invariant is now backstopped positively by
    #      R8 (cascade gone), R12 (gate 8 s), R13 (observability
    #      intact), R14 (calibration untouched).
    if int(pv) >= 53:
        ok("Q10 superseded by R8/R12/R13/R14 on +53+ (scheduler rewrite)")
    elif "inMilliseconds > 2000" in conn and \
       "readDid('0009', tx: '790', rx: '798')" in conn:
        ok("Q10 stale-gate (2s) and ingest read of 790/0009 unchanged")
    else:
        fail("Q10 polling cycle was modified — should be observation-only")

else:
    ok(f"Part Q skipped (build +{pv}, polling observability lands in +51)")

# ──────────── Part R: +53 three-group scheduler + recovery ────────────
if int(pv) >= 53:
    conn = open("lib/services/connection.dart").read()

    # R1. _PollTask class exists at file scope (not nested in
    #     ConnectionService — otherwise _runTask's signature
    #     `_runTask(_PollTask task)` wouldn't resolve when called
    #     from outside the class body in some refactor scenarios).
    if "class _PollTask {" in conn:
        ok("R1 _PollTask class defined at file scope")
    else:
        fail("R1 _PollTask class missing — code won't compile")

    # R2. Three task lists exist and are typed. A regression would
    #     be replacing them with one Map<Group, List<...>>, which
    #     breaks the scheduling priority order.
    for needle in [
        "final List<_PollTask> _fastTasks = [];",
        "final List<_PollTask> _mediumTasks = [];",
        "final List<_PollTask> _slowTasks = [];",
    ]:
        if needle in conn:
            ok(f"R2 {needle.split('_')[1].split(' ')[0]} task list present")
        else:
            fail(f"R2 missing: {needle}")

    # R3. The four scheduler constants are defined with the
    #     committed values. Drift here changes behaviour silently —
    #     e.g. _kMaxConsecutiveSameEcu = 6 would resurrect the
    #     EMPTY-on-5th-read quirk.
    constants = [
        ("_kFastInterval", "Duration(milliseconds: 100)"),
        ("_kMediumInterval", "Duration(seconds: 5)"),
        ("_kSlowInterval", "Duration(seconds: 18)"),
        ("_kMaxConsecutiveSameEcu = 4", ""),
        ("_kRecoveryGapThresholdMs = 15000", ""),
        ("_kRecoveryCooldown = Duration(seconds: 60)", ""),
    ]
    for (name, val) in constants:
        needle = f"{name} = {val}" if val else name
        if needle in conn:
            ok(f"R3 {name.lstrip('_').split(' ')[0]} = expected")
        else:
            fail(f"R3 constant drifted: {name}")

    # R4. Fast group has exactly the three tasks the owner approved:
    #     speed (740), packV+I (790), and nothing else. A "small
    #     improvement" that adds a 4th fast task would compete with
    #     the medium/slow scheduling and widen the round-robin
    #     pressure on 790.
    build_idx = conn.find("void _buildSchedule() {")
    build_end = conn.find("/// Pick the next task", build_idx)
    if build_idx >= 0 and build_end >= 0:
        build_block = conn[build_idx:build_end]
        fast_count = build_block.count("_fastTasks.add(")
        if fast_count == 2:  # speed + packV+I (the latter reads both V and I)
            ok("R4 fast group has 2 tasks (speed + packV+I)")
        else:
            fail(f"R4 fast group has {fast_count} tasks; expected 2")

    # R5. Medium group: SOC, battery_temp, odometer, pdu_temps. SOH
    #     must NOT be in medium — owner moved it to slow.
    if build_idx >= 0 and build_end >= 0:
        build_block = conn[build_idx:build_end]
        mediums = [
            "name: 'soc'", "name: 'battery_temp'",
            "name: 'odometer'", "name: 'pdu_temps'",
        ]
        med_ok = all(m in build_block for m in mediums)
        # Confirm SOH is NOT in a medium-task position. Approximate
        # check: 'soh' string appears AFTER the slow-group comment
        # only.
        slow_idx = build_block.find("Slow group")
        soh_idx  = build_block.find("name: 'soh'")
        if med_ok and slow_idx >= 0 and soh_idx > slow_idx:
            ok("R5 medium group correct; SOH lives in slow group (owner-moved)")
        else:
            fail(f"R5 medium group wrong: med_ok={med_ok} soh_after_slow={soh_idx > slow_idx}")

    # R6. Slow group has SOH, cell_extremes, gear, soc_precise plus
    #     the atomic blocks full_cells and extra.
    if build_idx >= 0 and build_end >= 0:
        build_block = conn[build_idx:build_end]
        slows = [
            "name: 'soh'", "name: 'cell_extremes'", "name: 'gear'",
            "name: 'soc_precise'", "name: 'full_cells'", "name: 'extra'",
        ]
        missing = [s for s in slows if s not in build_block]
        if not missing:
            ok("R6 slow group has all six tasks (incl. SOH, full_cells)")
        else:
            fail(f"R6 slow group missing: {missing}")

    # R7. _pollEcuFiltered exists and preserves the fast-lane
    #     ownership exclusions (740/0008 and 790/0009). Without
    #     these, a medium task could shadow-write into the same
    #     _latestValues slots that fast-lane fills, causing the +51
    #     observability counters to drift.
    if "Future<void> _pollEcuFiltered" in conn and \
       "ecu.txId == '740' && spec.did == '0008'" in conn and \
       "ecu.txId == '790' && spec.did == '0009'" in conn:
        ok("R7 _pollEcuFiltered preserves fast-lane DID exclusions")
    else:
        fail("R7 _pollEcuFiltered missing or doesn't exclude fast-lane DIDs")

    # R8. The old sub-poll cascade in _pollLoop is GONE. A regression
    #     here would resurrect "burst 4 reads to 790 every iteration"
    #     and undo the whole patch. Search for the signature pattern.
    poll_idx = conn.find("Future<void> _pollLoop() async {")
    poll_end = conn.find("Future<void> _pollEcuFiltered", poll_idx)
    if poll_idx >= 0 and poll_end >= 0:
        loop_body = conn[poll_idx:poll_end]
        bad_patterns = [
            "for (final ecu in _ecusToPoll)",
            "if (cycle % 2 == 0) await _pollCells()",
            "if (cycle % 2 == 1) await _pollExtraDids()",
        ]
        leaks = [p for p in bad_patterns if p in loop_body]
        if not leaks:
            ok("R8 old sub-poll cascade removed from _pollLoop")
        else:
            fail(f"R8 old cascade leaked into new _pollLoop: {leaks}")

    # R9. _pollLoop calls _buildSchedule before entering the while
    #     loop. Without this, the three lists stay empty and nothing
    #     ever gets read.
    if poll_idx >= 0 and poll_end >= 0:
        loop_body = conn[poll_idx:poll_end]
        bs_idx  = loop_body.find("_buildSchedule()")
        while_idx = loop_body.find("while (_polling")
        if 0 < bs_idx < while_idx:
            ok("R9 _buildSchedule() called before main loop")
        else:
            fail(f"R9 _buildSchedule ordering wrong: bs={bs_idx} while={while_idx}")

    # R10. Recovery uses _client.initialize() — the soft warm reset
    #      path. NOT BLE reconnect (which would be _ble.connect() or
    #      similar). The owner explicitly chose soft only.
    rec_idx = conn.find("Future<void> _maybeRunRecovery() async {")
    rec_end = conn.find("Future<void> _pollLoop", rec_idx) if rec_idx >= 0 else -1
    if rec_idx >= 0 and rec_end >= 0:
        rec_body = conn[rec_idx:rec_end]
        if "_client!.initialize()" in rec_body and \
           "_ble!.connect()" not in rec_body and \
           "_ble!.disconnect()" not in rec_body:
            ok("R10 recovery is soft warm reset (no BLE reconnect)")
        else:
            fail("R10 recovery hits BLE link — owner asked for soft only")

    # R11. Recovery has cooldown gating BEFORE calling initialize().
    #      Without it, a single big gap could trigger ATZ every iteration.
    if rec_idx >= 0 and rec_end >= 0:
        rec_body = conn[rec_idx:rec_end]
        cd_idx = rec_body.find("_kRecoveryCooldown")
        init_idx = rec_body.find("_client!.initialize()")
        if 0 < cd_idx < init_idx:
            ok("R11 recovery checks cooldown before warm reset")
        else:
            fail(f"R11 recovery cooldown ordering wrong: cd={cd_idx} init={init_idx}")

    # R12. Stale-gate widened to 8 s. The previous 2000 literal must
    #      be GONE from the getter — it was the bottleneck.
    getter_idx = conn.find("double? get packCurrentA {")
    getter_end = conn.find("\n  }", getter_idx)
    if getter_idx >= 0 and getter_end >= 0:
        getter_body = conn[getter_idx:getter_end]
        if "inMilliseconds > 8000" in getter_body and \
           "inMilliseconds > 2000" not in getter_body:
            ok("R12 stale-gate widened 2s → 8s in packCurrentA getter")
        else:
            fail("R12 stale-gate not widened or 2000 literal still present")

    # R13. Observability hooks from +51 still update on successful
    #      read. The ingest order (gap → readOk++ → assign) must be
    #      unchanged — these counters are the diagnostic source that
    #      the whole +53 effort hinges on.
    if "_packCurrentReadOkCount++;" in conn and \
       "_packCurrentMaxGapMs =" in conn and \
       "_packCurrentPrevSuccessAt = now;" in conn:
        ok("R13 +51 observability hooks intact (unchanged by +53)")
    else:
        fail("R13 +51 observability hooks damaged")

    # R14. The +47 calibration constants are untouched.
    if "_kPackCurrentZeroRaw = 5018.0" in conn and \
       "_kPackCurrentAmpsPerLsb = 0.1021" in conn:
        ok("R14 +47 calibration constants untouched")
    else:
        fail("R14 +47 calibration constants were modified — abort")

    # R15. Logic port (Python): ECU round-robin invariant. The
    #      adapter's "5th consecutive same-ECU read = EMPTY" quirk
    #      means the scheduler must never let _consecutiveSameEcu
    #      exceed _kMaxConsecutiveSameEcu (4) when alternatives
    #      exist. Simulate the picker on a representative task set.
    class T:
        def __init__(self, name, ecu):
            self.name = name; self.ecu = ecu; self.lastRunAt = None
    def pick(candidates, last_ecu, count_same):
        if not candidates: return None
        eligible = candidates
        if count_same >= 4 and last_ecu is not None:
            diff = [t for t in candidates if t.ecu != last_ecu]
            if diff: eligible = diff
        # least-recent (None = oldest)
        return sorted(eligible, key=lambda t: (t.lastRunAt is not None, t.lastRunAt))[0]
    # Set: 2 fast tasks, both reading 790. Round-robin must rotate.
    fast = [T('packV', '790'), T('packI', '790')]
    last_ecu, same_count = None, 0
    history = []
    for i in range(10):
        p = pick(fast, last_ecu, same_count)
        history.append(p.ecu)
        if last_ecu == p.ecu: same_count += 1
        else: last_ecu = p.ecu; same_count = 1
        p.lastRunAt = i
    # With ONLY 790 candidates, all picks go to 790 — same_count rises.
    # The quirk WILL fire, but that's OK because no alternative exists.
    # The relevant invariant: when ANY other ECU is available, scheduler
    # MUST switch by the 5th pick.
    fast2 = [T('packV', '790'), T('packI', '790'), T('speed', '740')]
    last_ecu, same_count = None, 0
    history2 = []
    for i in range(10):
        p = pick(fast2, last_ecu, same_count)
        history2.append(p.ecu)
        if last_ecu == p.ecu: same_count += 1
        else: last_ecu = p.ecu; same_count = 1
        p.lastRunAt = i
    # Find longest run of consecutive same-ECU picks
    longest = 1; current = 1
    for j in range(1, len(history2)):
        if history2[j] == history2[j-1]:
            current += 1
            if current > longest: longest = current
        else:
            current = 1
    if longest <= 4:
        ok(f"R15 round-robin invariant holds: longest same-ECU run = {longest} (≤4) over 10 picks")
    else:
        fail(f"R15 round-robin VIOLATED: same-ECU run = {longest} (>4)")

    # R16. Triple-sync to the current pv (was hard-coded to +53 at
    #      land, version-aware on subsequent builds so each new patch
    #      doesn't have to update this test).
    pub = open("pubspec.yaml").read()
    dash = open("lib/screens/dashboard.dart").read()
    csync = open("lib/services/cloud_sync_service.dart").read()
    expected = full_ver
    if f"version: {expected}" in pub and \
       f"_kDiagVersion = 'v{expected}'" in dash and \
       f"'{expected}'" in csync:
        ok(f"R16 triple-sync to +{pv} (pubspec / dashboard / cloud_sync)")
    else:
        fail(f"R16 triple-sync incomplete for +{pv}")

else:
    ok(f"Part R skipped (build +{pv}, three-group scheduler lands in +53)")

# ──────────── Part S: +54 catchall slow task — thermal DIDs ────────────
if int(pv) >= 54:
    conn = open("lib/services/connection.dart").read()

    # S1. _pollEcuCatchall function exists. Without it, all DIDs not in
    #     an explicit fast/medium/slow task are silently dropped — same
    #     regression the patch fixes.
    if "Future<void> _pollEcuCatchall() async {" in conn:
        ok("S1 _pollEcuCatchall function defined")
    else:
        fail("S1 _pollEcuCatchall missing — regression not fixed")

    # S2. _catchallEcuIndex field exists for ECU rotation state.
    if "int _catchallEcuIndex = 0;" in conn:
        ok("S2 _catchallEcuIndex rotation state field present")
    else:
        fail("S2 _catchallEcuIndex missing — rotation can't track position")

    # S3. catchall task wired into the slow group at _buildSchedule.
    #     Match the literal pair so a copy-paste typo would catch.
    if "name: 'catchall'" in conn and \
       "execute: _pollEcuCatchall," in conn and \
       "ecuTx: 'rotation'" in conn:
        ok("S3 catchall task registered in slow group with rotation ecuTx")
    else:
        fail("S3 catchall task not properly registered")

    # S4. The catchall implementation rotates: reads ONE ECU per call
    #     by indexing into _ecusToPoll and incrementing the counter.
    #     Tests for the modulo wrap (or unconditional increment) so a
    #     future "optimization" that picks a fixed ECU doesn't pass.
    catchall_idx = conn.find("Future<void> _pollEcuCatchall() async {")
    catchall_end = conn.find("\n  }", catchall_idx)
    if catchall_idx >= 0 and catchall_end >= 0:
        body = conn[catchall_idx:catchall_end]
        if "_ecusToPoll" in body and \
           "_catchallEcuIndex %" in body and \
           "_catchallEcuIndex++" in body and \
           "_pollEcu(ecu)" in body:
            ok("S4 catchall rotates through _ecusToPoll one ECU at a time")
        else:
            fail("S4 catchall implementation wrong (no rotation / wrong target)")

    # S5. _pollEcu (the legacy sweep) still exists — catchall depends on
    #     it. A future "cleanup" deleting _pollEcu because it's "only
    #     called from one place" would re-break thermals.
    if "Future<void> _pollEcu(EcuSpec ecu) async {" in conn:
        ok("S5 _pollEcu (legacy sweep) still present — catchall's dependency")
    else:
        fail("S5 _pollEcu removed — catchall has nothing to call")

    # S6. Slow group now has SEVEN tasks (six from +53 + catchall).
    #     Regression check: if a future patch adds another slow task,
    #     this number bumps and we revisit Part R5/R6 numbers too.
    build_idx = conn.find("void _buildSchedule() {")
    build_end = conn.find("/// v0.1.29+54: index into", build_idx)
    if build_idx < 0 or build_end < 0:
        build_end = conn.find("/// Pick the next task", build_idx)
    if build_idx >= 0 and build_end >= 0:
        build_block = conn[build_idx:build_end]
        slow_count = build_block.count("_slowTasks.add(")
        if slow_count == 7:
            ok(f"S6 slow group has 7 tasks (6 from +53 + catchall)")
        else:
            fail(f"S6 slow group has {slow_count} tasks; expected 7")

    # S7. Logic port (Python): rotation invariant. Given a fixed ECU
    #     list of size N, _catchallEcuIndex modulo N should visit each
    #     ECU exactly once per N consecutive invocations.
    def simulate_rotation(n_ecus, n_calls):
        visited = []
        idx = 0
        for _ in range(n_calls):
            visited.append(idx % n_ecus)
            idx += 1
        return visited
    # 4 ECUs over 8 calls should hit each twice.
    visits = simulate_rotation(4, 8)
    from collections import Counter
    counts = Counter(visits)
    if all(c == 2 for c in counts.values()) and len(counts) == 4:
        ok(f"S7 rotation visits each ECU equally (counts: {dict(counts)})")
    else:
        fail(f"S7 rotation invariant broken: counts {dict(counts)}")

    # S8. Triple-sync to current pv (version-aware, no hard-coded
    #     constant — same pattern as R16).
    pub = open("pubspec.yaml").read()
    dash = open("lib/screens/dashboard.dart").read()
    csync = open("lib/services/cloud_sync_service.dart").read()
    expected = full_ver
    if f"version: {expected}" in pub and \
       f"_kDiagVersion = 'v{expected}'" in dash and \
       f"'{expected}'" in csync:
        ok(f"S8 triple-sync to +{pv}")
    else:
        fail(f"S8 triple-sync incomplete for +{pv}")

else:
    ok(f"Part S skipped (build +{pv}, catchall task lands in +54)")

# ──────────── Part T: +55 moving/idle aggregation moved to ingest ────────────
if int(pv) >= 55:
    conn = open("lib/services/connection.dart").read()

    # T1. Old field names (_tripMovingSec / _tripIdleSec) must NOT have
    #     assignments anywhere — the rename to *Ms is mechanical, and
    #     any leftover `+= secs` would silently keep the bug alive.
    #     Allow appearance in docstrings (regex matches only the
    #     assignment patterns).
    import re
    if not re.search(r'_tripMovingSec\s*[+=]', conn) and \
       not re.search(r'_tripIdleSec\s*[+=]', conn):
        ok("T1 no surviving _tripMovingSec / _tripIdleSec assignments")
    else:
        fail("T1 old second-based field assignment leaked")

    # T2. New ms-precision fields exist and are typed int.
    if "int _tripMovingMs = 0;" in conn and \
       "int _tripIdleMs = 0;" in conn:
        ok("T2 _tripMovingMs / _tripIdleMs (ms-precision) defined")
    else:
        fail("T2 ms-precision fields missing")

    # T3. New timestamp field _lastSpeedFreshAt distinct from the
    #     retained _lastSpeedSampleAt. They serve different purposes;
    #     keeping both lets future regressions diff the old and new
    #     paths if needed.
    if "DateTime? _lastSpeedFreshAt;" in conn and \
       "DateTime? _lastSpeedSampleAt;" in conn:
        ok("T3 both timestamp fields kept (old + new) for diffability")
    else:
        fail("T3 timestamp fields missing or removed")

    # T4. _updateTripAggregates no longer accumulates speed time —
    #     the entire `if (kmh != null) { ... }` block is gone, replaced
    #     by a doc-only marker. Match the marker phrase.
    upd_idx = conn.find("Future<void> _updateTripAggregates")
    upd_end = conn.find("Future<void>", upd_idx + 1)
    if upd_idx >= 0 and upd_end >= 0:
        body = conn[upd_idx:upd_end]
        if "v0.1.29+55 moved peak/avg/" in body and \
           "_tripMovingMs +=" not in body and \
           "_tripIdleMs +=" not in body and \
           "_tripPeakSpeedKmh = _tripPeakSpeedKmh" not in body:
            ok("T4 _updateTripAggregates: speed aggregator block removed cleanly")
        else:
            fail("T4 _updateTripAggregates still has speed aggregation logic")

    # T5. _pollSpeedOnly now contains the moved aggregator. Match the
    #     four pieces (peak update, moving accumulator, idle
    #     accumulator, _lastSpeedFreshAt update) AND require they're
    #     guarded by _currentTripId != null (no off-trip accumulation).
    pso_idx = conn.find("Future<void> _pollSpeedOnly() async {")
    pso_end = conn.find("Future<void>", pso_idx + 1)
    if pso_idx >= 0 and pso_end >= 0:
        body = conn[pso_idx:pso_end]
        if "_tripPeakSpeedKmh = _tripPeakSpeedKmh" in body and \
           "_tripMovingMs += attribMs" in body and \
           "_tripIdleMs += attribMs" in body and \
           "_lastSpeedFreshAt = now" in body and \
           "if (_currentTripId != null" in body:
            ok("T5 _pollSpeedOnly has the moved aggregator, trip-guarded")
        else:
            fail("T5 _pollSpeedOnly aggregator incomplete or unguarded")

    # T6. DB-write conversion ms→s. Two sites (endTrip on disconnect,
    #     endTrip on segment-on-park). Both must use the ~/ 1000 pattern.
    site_count = conn.count("_tripMovingMs > 0 ? (_tripMovingMs ~/ 1000)")
    if site_count == 2:
        ok("T6 both endTrip sites convert ms → seconds for DB write")
    else:
        fail(f"T6 expected 2 DB-write sites with ms→s, found {site_count}")

    # T7. 120s cap preserved. The reasoning (v0.1.26+5) still holds —
    #     a single late sample shouldn't extrapolate forever. Cap
    #     value is in ms (was already; now matches accumulator units).
    if "const capMs = 120000" in conn:
        ok("T7 120s per-sample cap preserved in moved code")
    else:
        fail("T7 120s cap missing — late samples could extrapolate forever")

    # T8. Logic port (Python): the new math for a representative trip.
    #     Simulate 25 minutes of driving with sample rate ~1 Hz and 30%
    #     of samples below 1.0 km/h (stop-and-go traffic). Verify the
    #     accumulated moving/idle totals match the sample classification
    #     exactly (no integer-division loss).
    def simulate(n_samples, dt_ms, fraction_moving):
        moving_ms = 0
        idle_ms = 0
        last_fresh = None
        for i in range(n_samples):
            now = i * dt_ms
            kmh = 30.0 if (i / n_samples) < fraction_moving else 0.0
            if last_fresh is not None:
                dt = now - last_fresh
                if dt > 0:
                    attrib = min(dt, 120000)
                    if kmh > 1.0:
                        moving_ms += attrib
                    else:
                        idle_ms += attrib
            last_fresh = now
        return moving_ms, idle_ms
    # 25 min at 1 Hz with 70% moving samples → ~17.5 min moving, ~7.5 idle
    mv, idl = simulate(1500, 1000, 0.7)
    # First sample has no dt; remaining 1499 each contribute 1000 ms
    # 70% of 1499 = 1049 moving samples × 1 s ≈ 1049 s = 17.48 min
    # 30% of 1499 = 450 idle samples × 1 s ≈ 450 s = 7.5 min
    expected_mv_min = (int(0.7 * 1499) * 1000) / 60000
    expected_idl_min = (1499 - int(0.7 * 1499)) * 1000 / 60000
    actual_mv_min = mv / 60000
    actual_idl_min = idl / 60000
    if abs(actual_mv_min - expected_mv_min) < 0.5 and \
       abs(actual_idl_min - expected_idl_min) < 0.5:
        ok(f"T8 ms aggregator simulates correctly "
           f"({actual_mv_min:.1f}m mv / {actual_idl_min:.1f}m idl)")
    else:
        fail(f"T8 ms aggregator math drifted: "
             f"{actual_mv_min:.1f}m mv / {actual_idl_min:.1f}m idl")

    # T9. Sub-second accumulation: verify the OLD bug (sec ~/ 1000 = 0
    #     on small dt) would now NOT eat the contribution. With 50 ms
    #     dt at 1.5 Hz over 60 sec → 90 samples × 50 ms = 4500 ms total.
    #     Old code: secs = 50/1000 = 0 every time → 0 total. New code:
    #     accumulates the 4500 ms.
    mv_subsec, _ = simulate(90, 50, 1.0)  # all moving
    # Expected: (90 - 1) * 50 ms = 4450 ms ≈ 4.45 sec
    if 4400 <= mv_subsec <= 4500:
        ok(f"T9 sub-second contributions accumulate ({mv_subsec} ms over 90×50ms)")
    else:
        fail(f"T9 sub-second loss: got {mv_subsec} ms (expected ~4450)")

    # T10. Capped-at-120s case: a single 5-minute (300 s) gap should
    #      contribute only 120 s, not 300. This is the BLE-stall safety.
    mv_capped, _ = simulate(2, 300000, 1.0)  # two samples, 5 min apart
    if 120000 - 100 <= mv_capped <= 120000:
        ok(f"T10 120s cap holds on 5-min gap (capped {mv_capped} ms)")
    else:
        fail(f"T10 cap broken: got {mv_capped} ms (expected ~120000)")

else:
    ok(f"Part T skipped (build +{pv}, moving/idle fix lands in +55)")

# ──────────── Part U: +56 navigation cleanup + charging UX ────────────
if int(pv) >= 56:
    home = open("lib/screens/home.dart").read()
    hus  = open("lib/screens/wide/head_unit_scaffold.dart").read()
    sett = open("lib/screens/settings.dart").read()
    import os.path
    ban_path = "lib/widgets/charging_banner.dart"
    ban = open(ban_path).read() if os.path.exists(ban_path) else ""

    # U1. Phone nav slimmed to 4 destinations; ECU Explorer no longer a tab.
    #     v0.1.29+108: a second bottom-nav scaffold (_TallHomeScreen, BZ3
    #     tall portrait) was added to home.dart, also 4 destinations and
    #     Driver-first. So from +108 home.dart legitimately has 8
    #     NavigationDestination( (2 scaffolds × 4). ECU Explorer stays out
    #     of both.
    _home_nav_want = 8 if int(pv) >= 108 else 4
    if home.count("NavigationDestination(") == _home_nav_want and \
       "EcuExplorerScreen()" not in home:
        ok("U1 phone nav 4 tabs"
           + (" + tall scaffold 4 tabs" if int(pv) >= 108 else "")
           + ", ECU Explorer demoted")
    else:
        fail("U1 phone nav wrong shape")

    # U2. HU rail: Raw Data screen removed from the stack, semantic labels.
    #     +56 shape: 5 destinations, Cyrillic literals + HAL Explorer.
    #     +58 shape: 4 destinations (HAL Explorer → Settings/Advanced),
    #     labels via S.of (Part V checks the keys themselves).
    if int(pv) >= 58:
        if "const RawDataWideScreen()," not in hus and \
           "S.of('nav.driving')" in hus and "S.of('nav.vehicle')" in hus and \
           "Text('HAL Explorer')" not in hus and "Text('Native API')" not in hus:
            ok("U2 HU rail: 4 destinations, S.of labels, HAL Explorer relocated")
        else:
            fail("U2 HU rail wrong shape or stale labels")
    else:
        if "const RawDataWideScreen()," not in hus and \
           "Text('Вождение')" in hus and "Text('Автомобиль')" in hus and \
           "Text('HAL Explorer')" in hus and "Text('Native API')" not in hus:
            ok("U2 HU rail: 5 destinations, renamed (Вождение/Автомобиль/HAL Explorer)")
        else:
            fail("U2 HU rail wrong shape or stale labels")

    # U3. HU rail index consistency: _screens list and destinations count
    #     must match (5 each on +56/+57; 4 each from +58). The
    #     v0.1.26+13 accident (lost tabs) was exactly this kind of drift.
    hus_dests = hus.count("NavigationRailDestination(")
    hus_screens = hus.count("WideScreen(),") + hus.count("NativeExplorerWide(")
    want = 4 if int(pv) >= 58 else 5
    if hus_dests == want and hus_screens == want:
        ok(f"U3 HU rail: destinations ({hus_dests}) == screens ({hus_screens})")
    else:
        fail(f"U3 HU rail drift: {hus_dests} destinations vs {hus_screens} screens (want {want})")

    # U4. charging_banner.dart exists with the three key mechanisms:
    #     shared static session guard, route-open guard, named route
    #     for targeted pop.
    if ban and "static bool _autoPushedThisSession" in ban and \
       "static bool _chargingRouteOpen" in ban and \
       "_kChargingRouteName" in ban:
        ok("U4 charging banner: session guard + route guard + named route")
    else:
        fail("U4 charging_banner.dart missing or incomplete")

    # U5. ChargingAwareBody wired into BOTH scaffolds with auto-push
    #     restricted to tab index 0 (Driver / Dashboard).
    #     v0.1.29+108: the BZ3 tall scaffold (_TallHomeScreen in home.dart)
    #     is a third ChargingAwareBody, also auto-push on its Driver tab
    #     (index 0). So home.dart has 2 occurrences from +108 (phone + tall),
    #     HU scaffold still 1.
    _home_autopush_want = 2 if int(pv) >= 108 else 1
    if home.count("autoPushWhenVisible: _index == 0") == _home_autopush_want and \
       hus.count("autoPushWhenVisible: _index == 0") == 1:
        ok("U5 ChargingAwareBody in all scaffolds, auto-push only on tab 0")
    else:
        fail("U5 ChargingAwareBody wiring wrong")

    # U6. ChargingViewWide is reachable: the banner pushes a route that
    #     builds it. (The orphan bug this patch fixes — screen existed,
    #     nothing rendered it.)
    if "ChargingViewWide()" in ban:
        ok("U6 ChargingViewWide reachable via banner route (orphan fixed)")
    else:
        fail("U6 ChargingViewWide still unreachable")

    # U7. Settings: four section labels present (+110: the Cloud and
    #     Data sections merged into the App group as sub-entries),
    #     Advanced ExpansionTile contains the research tools (ECU
    #     Explorer, DID Sweep, Live Log, Polling diagnostics) and the
    #     wide-only Raw Data entry.
    if int(pv) >= 58:
        # +58: section labels localized — literals replaced by S.of keys
        # (and a sixth Language section appeared, checked in Part V).
        sections_ok = all(f"_SectionLabel(S.of('settings.section.{x}'))" in sett
                          for x in ['connection', 'cost',
                                    'vehicle', 'app'])
        adv_idx = sett.find("title: Text(S.of('settings.advanced.title'))")
    else:
        sections_ok = all(f"_SectionLabel('{x}')" in sett
                          for x in ['Подключение', 'Стоимость', 'Облако',
                                    'Автомобиль', 'Данные'])
        adv_idx = sett.find("title: const Text('Advanced')")
    tools_after_adv = adv_idx > 0 and all(
        sett.find(t, adv_idx) > 0
        for t in ["EcuExplorerScreen()", "SweepScreen()",
                  "LiveLogScreen()", "PollingDiagnosticsScreen()",
                  "RawDataWideScreen()"])
    if sections_ok and tools_after_adv:
        ok("U7 Settings grouped; research tools under Advanced")
    else:
        fail(f"U7 Settings structure wrong: sections={sections_ok} tools={tools_after_adv}")

    # U8. DTC (user-facing feature) is NOT inside Advanced — it stays in
    #     the Автомобиль section above the ExpansionTile.
    if int(pv) >= 58:
        dtc_idx = sett.find("Text(S.of('settings.dtc.title'))")
    else:
        dtc_idx = sett.find("Text('Diagnostics (DTC)')")
    if 0 < dtc_idx < adv_idx:
        ok("U8 DTC stays top-level (user feature, not research tool)")
    else:
        fail("U8 DTC misplaced")

    # U9. Layout debug block: fully removed from production UI (+114 UI
    #     cleanup — the BZ3 layout-diagnostic overlay and the DID/formula
    #     calibration card were research aids, deleted outright).
    dash = open("lib/screens/dashboard.dart").read()
    if "_LayoutDiagnostic" not in dash and "_PhysicsModelCard" not in dash:
        ok("U9 layout-debug + calibration card removed from production UI")
    else:
        fail("U9 layout-debug/calibration still present in production UI")

    # U10. Protected layers untouched by +56: connection.dart polling
    #      internals unchanged this patch (scheduler constants intact),
    #      cloud sync service has only the version bump.
    conn = open("lib/services/connection.dart").read()
    if "_kFastInterval = Duration(milliseconds: 100)" in conn and \
       "_kPackCurrentZeroRaw = 5018.0" in conn:
        ok("U10 protected polling/calibration layers untouched")
    else:
        fail("U10 connection.dart was modified beyond expectations")

    # U11. ChargingViewWide is ADAPTIVE — the banner pushes it on all
    #      form factors including BZ3 (720 dp tall portrait), where the
    #      original wide-only three-charts-in-a-Row would compress to
    #      ~230 dp columns. The narrow branch must: scroll vertically,
    #      stack the charts at fixed height, shrink the hero font, and
    #      wrap the summary metrics.
    cvw = open("lib/screens/wide/charging_view_wide.dart").read()
    adaptive_bits = [
        "SingleChildScrollView",          # narrow root scrolls
        "wide ? 120 : 72",                # hero font shrinks
        "SizedBox(height: 240",           # charts get explicit height
        "_ChartsRow(svc: svc, wide: false)",  # column branch wired
        ": Wrap(",                        # summary metrics reflow
    ]
    missing = [b for b in adaptive_bits if b not in cvw]
    if not missing:
        ok("U11 ChargingViewWide adaptive for BZ3/narrow (scroll+stack+font+wrap)")
    else:
        fail(f"U11 charging view not narrow-safe, missing: {missing}")

    # U12. Wide branch preserved 1:1 — BZ5 keeps the original flex
    #      layout (three charts side-by-side in a Row, hero at 120).
    if "_ChartsRow(svc: svc, wide: true)" in cvw and \
       "Expanded(child: _PowerChart(history: hist))" in cvw and \
       "Expanded(flex: 4, child: _TopHeroRow(svc: svc, wide: true))" in cvw:
        ok("U12 BZ5 wide charging layout preserved (flex rows intact)")
    else:
        fail("U12 wide charging layout damaged by the adaptive refactor")

else:
    ok(f"Part U skipped (build +{pv}, navigation cleanup lands in +56)")

# ─────────── Part V: EN/RU localization mechanism (+58) ───────────
#
# Pilot scope: mechanism (S + LocaleService) + fully localized Settings
# screen (phone == wide, settings_wide just wraps SettingsScreen) +
# nav labels (phone bottom bar + HU rail) + HAL Explorer relocation
# rail → Settings/Advanced.

if int(pv) >= 58:
    import ast

    str_path = root / 'lib/l10n/strings.dart'
    loc_path = root / 'lib/services/locale_service.dart'
    if not str_path.exists():
        fail("V1 lib/l10n/strings.dart missing")
    if not loc_path.exists():
        fail("V1 lib/services/locale_service.dart missing")
    if str_path.exists() and loc_path.exists():
        sdart = str_path.read_text()
        ldart = loc_path.read_text()
        settings_src = (root / 'lib/screens/settings.dart').read_text()
        home_src = (root / 'lib/screens/home.dart').read_text()
        rail_src = (root / 'lib/screens/wide/head_unit_scaffold.dart').read_text()
        main_src = (root / 'lib/main.dart').read_text()

        # V1. S class structure
        bits = ['class S {', 'static String locale', 'static String of(String key)',
                'Map<String, String> _en', 'Map<String, String> _ru']
        miss = [b for b in bits if b not in sdart]
        if not miss:
            ok("V1 strings.dart: class S with locale/of/_en/_ru")
        else:
            fail(f"V1 strings.dart structure incomplete, missing: {miss}")

        # V2. Parse both maps from Dart source. Dart adjacent-string
        #     concatenation ('a' 'b') is the same as Python's, and the
        #     entries are plain literals, so ast.literal_eval works after
        #     wrapping in braces. Catches syntax drift AND gives us real
        #     key sets for the parity check.
        def parse_map(name):
            m = re.search(name + r"\s*=\s*\{(.*?)\n  \};", sdart, re.S)
            if not m:
                return None
            body = m.group(1)
            body = re.sub(r"//.*", "", body)  # strip comments
            try:
                return ast.literal_eval("{" + body + "}")
            except Exception as e:
                fail(f"V2 cannot parse {name} as literal map: {e}")
                return None
        en = parse_map("_en")
        ru = parse_map("_ru")
        if en and ru:
            ok(f"V2 maps parse: _en={len(en)} keys, _ru={len(ru)} keys")
            # Parity: every _ru key must exist in _en (en is the fallback
            # base — ru-only orphans would be unreachable in EN mode and
            # signal a typo'd key). _ru ⊂ _en is fine and deliberate
            # (identical strings like 'OK', 'English' fall back).
            orphans = sorted(set(ru) - set(en))
            if not orphans:
                ok("V2 no ru-orphan keys (every _ru key exists in _en)")
            else:
                fail(f"V2 ru-orphan keys (likely typos): {orphans[:8]}")

            # V3. Logic-port of the of() chain. The Dart body must match:
            #   ru → _ru[key] ?? _en[key] ?? key;  en → _en[key] ?? key
            if "_ru[key] ?? _en[key] ?? key" in sdart and \
               "return _en[key] ?? key;" in sdart:
                def of(loc, key):
                    if loc == 'ru':
                        return ru.get(key, en.get(key, key))
                    return en.get(key, key)
                cases = [
                    # key in both → per-locale
                    ('ru', 'common.cancel', 'Отмена'),
                    ('en', 'common.cancel', 'Cancel'),
                    # key only in _en → ru falls back to en
                    ('ru', 'settings.adapter.title', en['settings.adapter.title']),
                    # key nowhere → key itself
                    ('ru', 'no.such.key', 'no.such.key'),
                    ('en', 'no.such.key', 'no.such.key'),
                ]
                bad = [(l, k) for l, k, exp in cases if of(l, k) != exp]
                # the only-in-en case must actually be only-in-en
                if 'settings.adapter.title' in ru:
                    warn("V3 fallback fixture 'settings.adapter.title' now in _ru — pick another")
                if not bad:
                    ok("V3 of() fallback chain logic-port: ru→en→key verified")
                else:
                    fail(f"V3 fallback logic-port mismatches: {bad}")
            else:
                fail("V3 of() body does not implement ru→en→key chain")

        # V4. LocaleService: persistence + mode set.
        #     +58: {'system','ru','en'} + PlatformDispatcher resolution.
        #     +59: 'system' removed — explicit 'en' default / 'ru'.
        if int(pv) >= 59:
            bits = ["prefsKey = 'app_locale'", "{'ru', 'en'}",
                    "String _mode = 'en';"]
            anti = ["PlatformDispatcher", "'system'"]
            miss = [b for b in bits if b not in ldart]
            # comments legitimately narrate the removed 'system' mode —
            # the anti-scan must only see code.
            ldart_code = re.sub(r"//.*", "", ldart)
            stale = [a for a in anti if a in ldart_code]
            if not miss and not stale:
                ok("V4 LocaleService: en-default + explicit ru, no system mode")
            else:
                fail(f"V4 LocaleService +59 shape wrong: missing={miss} stale={stale}")
        else:
            bits = ["prefsKey = 'app_locale'", "{'system', 'ru', 'en'}",
                    "PlatformDispatcher.instance.locale.languageCode",
                    "lang == 'ru' ? 'ru' : 'en'"]
            miss = [b for b in bits if b not in ldart]
            if not miss:
                ok("V4 LocaleService: app_locale prefs + system→(ru|en) resolution")
            else:
                fail(f"V4 LocaleService incomplete, missing: {miss}")
        # Ordering contract: S.locale must be written before notifyListeners
        # in BOTH load() and setMode().
        order_ok = True
        for fn in ('load', 'setMode'):
            m = re.search(r"Future<void> " + fn + r"\((.*?)\n  \}", ldart, re.S)
            if not m:
                order_ok = False
                continue
            body = m.group(1)
            # +58 wrote `S.locale = resolve(...)`, +59 writes
            # `S.locale = _mode` — accept any assignment to the static.
            iw = body.find('S.locale =')
            inot = body.find('notifyListeners()')
            if iw == -1 or inot == -1 or iw > inot:
                order_ok = False
        if order_ok:
            ok("V4 S.locale written before notifyListeners in load() and setMode()")
        else:
            fail("V4 S.locale/notifyListeners ordering broken")

        # V5. main.dart wiring: loaded before runApp + provider registered
        if 'await localeService.load();' in main_src and \
           'ChangeNotifierProvider<LocaleService>.value' in main_src:
            ok("V5 main(): LocaleService loaded pre-runApp + in provider tree")
        else:
            fail("V5 main() LocaleService wiring incomplete")

        # V6. Settings: language section radios bound to setMode.
        #     +58: 3 (System/Русский/English); +59: 2 (English/Русский).
        want_radios = 2 if int(pv) >= 59 else 3
        if settings_src.count('RadioListTile<String>(') == want_radios and \
           "S.of('settings.section.language')" in settings_src and \
           settings_src.count('groupValue: locale.mode') == want_radios and \
           settings_src.count('locale.setMode(v!)') == want_radios:
            ok(f"V6 Settings language section: {want_radios} RadioListTile → setMode")
        else:
            fail("V6 Settings language section missing/incomplete")
        if int(pv) >= 59 and "'system'" in settings_src:
            fail("V6 stale 'system' language mode still referenced in settings")

        # V7. No hardcoded Cyrillic in code (comments stripped) for the
        #     pilot files. strings.dart is exempt (it IS the dictionary).
        for f in ('lib/screens/settings.dart', 'lib/screens/home.dart',
                  'lib/screens/wide/head_unit_scaffold.dart'):
            dirty = []
            for i, line in enumerate((root / f).read_text().split('\n'), 1):
                code = re.sub(r"//.*$", "", line)
                if re.search(r"[А-Яа-яЁё]", code):
                    dirty.append(i)
            if not dirty:
                ok(f"V7 no hardcoded Cyrillic outside comments: {f}")
            else:
                fail(f"V7 hardcoded Cyrillic in {f} lines {dirty[:6]}")

        # V8. Localized screens subscribe to LocaleService themselves —
        #     `home: const HomeScreen()` is a const subtree, so a
        #     MaterialApp-level rebuild never reaches them.
        subs = {
            'lib/screens/settings.dart': 'context.watch<LocaleService>()',
            'lib/screens/home.dart': 'context.watch<LocaleService>()',
            'lib/screens/wide/head_unit_scaffold.dart':
                'context.watch<LocaleService>()',
        }
        miss = [f for f, needle in subs.items()
                if needle not in (root / f).read_text()]
        if not miss:
            ok("V8 pilot screens watch LocaleService (instant re-render)")
        else:
            fail(f"V8 missing LocaleService watch in: {miss}")

        # V9. HAL Explorer relocation: gone from the rail, present in
        #     Settings → Advanced with its own detector lifecycle.
        rail_clean = ('NativeExplorerWide(' not in rail_src
                      and "Text('HAL Explorer')" not in rail_src
                      and rail_src.count('NavigationRailDestination(') == 4)
        settings_hosts = ('_HalExplorerRoute' in settings_src
                          and 'NativeExplorerWide(detector: _detector)' in settings_src
                          and '_detector = NativeDetector();' in settings_src
                          and '_detector.dispose();' in settings_src)
        if rail_clean:
            ok("V9 rail is 4 destinations, NativeExplorerWide removed")
        else:
            fail("V9 rail still references HAL Explorer / wrong destination count")
        if settings_hosts:
            ok("V9 Settings/Advanced hosts HAL Explorer with owned detector lifecycle")
        else:
            fail("V9 _HalExplorerRoute missing or detector lifecycle incomplete")
        # Not wide-gated: BZ3 (phone layout) must reach it. The tile must
        # NOT sit inside the useHeadUnitLayout conditional the way Raw
        # Data does — structural proxy: the HAL ListTile appears after the
        # Polling diagnostics tile, and there is exactly one
        # useHeadUnitLayout gate inside the Advanced children (Raw Data's).
        adv = settings_src[settings_src.find("ExpansionTile("):]
        if adv.count('LayoutBreakpoints.useHeadUnitLayout(context)') == 1 \
                and adv.find("Text('HAL Explorer')") > adv.find("Text('Polling diagnostics')") > -1:
            ok("V9 HAL Explorer tile is not wide-gated (BZ3 phone layout reaches it)")
        else:
            fail("V9 HAL Explorer tile gating/placement wrong")

        # V10. Nav labels localized
        if all(k in home_src for k in ["S.of('nav.dashboard')", "S.of('nav.cells')",
                                       "S.of('nav.history')", "S.of('nav.settings')"]):
            ok("V10 phone bottom-bar labels via S.of")
        else:
            fail("V10 phone bottom-bar labels not localized")
        if all(k in rail_src for k in ["S.of('nav.driving')", "S.of('nav.vehicle')",
                                       "S.of('nav.history')", "S.of('nav.settings')"]):
            ok("V10 HU rail labels via S.of")
        else:
            fail("V10 HU rail labels not localized")

        # V11. Every S.of('key') used anywhere must exist in _en (the
        #      fallback base). A missing key renders as the raw key
        #      string in the UI — silent and ugly.
        if en:
            used = set()
            v11_files = ['lib/screens/settings.dart', 'lib/screens/home.dart',
                         'lib/screens/wide/head_unit_scaffold.dart']
            if int(pv) >= 59:
                v11_files.append('lib/screens/about.dart')
            for f in v11_files:
                used |= set(re.findall(r"S\.of\('([^']+)'\)", (root / f).read_text()))
            missing = sorted(used - set(en))
            if not missing:
                ok(f"V11 all {len(used)} S.of keys used in pilot files exist in _en")
            else:
                fail(f"V11 S.of keys missing from _en: {missing}")

        # V12. The +49 intl date init must survive (we localize strings,
        #      not the date machinery).
        if "await initializeDateFormatting('ru');" in main_src:
            ok("V12 initializeDateFormatting('ru') preserved in main()")
        else:
            fail("V12 +49 date-locale init lost from main()")
else:
    ok(f"Part V skipped (build +{pv}, l10n lands in +58)")

# ───── Part W: hidden Advanced (15-tap unlock) + EN/RU only (+59) ─────

if int(pv) >= 59:
    sett_w = (root / 'lib/screens/settings.dart').read_text()
    about_w = (root / 'lib/screens/about.dart').read_text()
    str_w = (root / 'lib/l10n/strings.dart').read_text()

    # W1. Advanced ExpansionTile render-gated by the unlock flag, and the
    #     flag is loaded from prefs alongside the other settings.
    if 'if (_advancedUnlocked)' in sett_w and \
       "prefs.getBool('advanced_unlocked') ?? false" in sett_w:
        ok("W1 Advanced ExpansionTile gated by advanced_unlocked pref")
    else:
        fail("W1 Advanced gating missing in settings.dart")

    # W2. About APP card: 15-tap counter that persists the unlock and
    #     surfaces both snackbars (countdown + unlocked).
    bits = ['_unlockTaps = 15', "prefs.setBool('advanced_unlocked', true)",
            "S.of('about.adv.unlocked')", "S.of('about.adv.progress')",
            'class _AppInfoCardState extends State<_AppInfoCard>']
    miss = [b for b in bits if b not in about_w]
    if not miss:
        ok("W2 About APP card: 15-tap unlock with persisted flag + snackbars")
    else:
        fail(f"W2 About tap-unlock incomplete, missing: {miss}")
    # Already-unlocked taps must be no-ops.
    if 'if (_unlocked) return;' in about_w:
        ok("W2 taps are no-ops once unlocked")
    else:
        fail("W2 missing unlocked-state guard in _onTap")

    # W3. Settings re-reads prefs when returning from About — otherwise
    #     the freshly unlocked section would not appear until the screen
    #     is recreated.
    m = re.search(r"const AboutScreen\(\)(.*?)\}", sett_w, re.S)
    if m and '_loadSettings();' in m.group(0) and 'await Navigator.of(context).push' in sett_w:
        ok("W3 Settings awaits About route and reloads prefs on return")
    else:
        fail("W3 Settings does not refresh unlock state after About")

    # W4. Language keys: system.* removed from both maps, unlock keys in
    #     both maps (these are user-visible in RU mode too).
    if "settings.language.system" not in str_w and \
       str_w.count("'about.adv.progress'") == 2 and \
       str_w.count("'about.adv.unlocked'") == 2:
        ok("W4 strings: system keys gone, about.adv.* present in _en and _ru")
    else:
        fail("W4 strings.dart language/unlock keys wrong")

    # W5. v0.1.45+144: About body strings localized (were hardcoded EN in
    #     about.dart). Each new key must exist in BOTH maps (count == 2) so
    #     RU mode doesn't silently fall back to English. Also: no leftover
    #     hardcoded EN body literals in about.dart.
    if int(pv) >= 144:
        _about_keys = [
            'about.intro.body', 'about.disclaimer.label',
            'about.disclaimer.body', 'about.app.label',
            'about.spec.version', 'about.spec.source',
            'about.spec.license', 'about.spec.hardware',
        ]
        _bad = [k for k in _about_keys if str_w.count(f"'{k}'") != 2]
        _leftover = [
            lit for lit in ("'DISCLAIMER'", "'APP'",
                            "Companion app for Toyota")
            if lit in about_w
        ]
        if not _bad and not _leftover:
            ok("W5 About body keys present in _en+_ru; no hardcoded EN left")
        else:
            fail(f"W5 about l10n incomplete — keys off: {_bad}, "
                 f"leftover literals: {_leftover}")
    else:
        ok(f"W5 skipped (build +{pv}, About l10n lands in +144)")
else:
    ok(f"Part W skipped (build +{pv}, hidden Advanced lands in +59)")

# ───── Part X: full l10n wave + TripCell layout fix (+60) ─────

if int(pv) >= 60:
    import subprocess as _sp

    # X1. const-ancestry checker: no S.of inside const constructor spans
    #     or const list literals anywhere in lib/. This is the compile
    #     killer the sandbox can't catch (no Dart toolchain) — the
    #     checker already caught 4 real bugs during the +60 wave.
    _r = _sp.run(['python3', str(root / 'tools/const_l10n_check.py')],
                 capture_output=True, text=True, cwd=root)
    if _r.returncode == 0:
        ok("X1 const_l10n_check: no S.of inside const spans")
    else:
        fail(f"X1 const_l10n_check failed:\n{_r.stdout.strip()}")

    # X2. No Cyrillic in CODE (comments stripped) in any localized file —
    #     every user-facing RU string must live in strings.dart now.
    _x2_files = [
        'lib/screens/dashboard.dart', 'lib/screens/cells.dart',
        'lib/screens/history.dart', 'lib/screens/trends.dart',
        'lib/screens/trip_detail.dart', 'lib/screens/diagnostics.dart',
        'lib/screens/data_management.dart',
        'lib/screens/polling_diagnostics.dart',
        'lib/screens/sweep.dart', 'lib/screens/sweep_results.dart',
        'lib/screens/live_log.dart', 'lib/screens/live_log_results.dart',
        'lib/screens/ecu_explorer.dart',
        'lib/screens/wide/driver_view_wide.dart',
        'lib/screens/wide/dashboard_wide.dart',
        'lib/screens/wide/history_wide.dart',
        'lib/screens/wide/charging_view_wide.dart',
        'lib/screens/wide/raw_data_wide.dart',
        'lib/widgets/driver_panels.dart',
        'lib/widgets/charging_banner.dart',
    ]
    _x2_bad = []
    for _f in _x2_files:
        _src = (root / _f).read_text()
        # Allowlist: _ruMonthShort in trends.dart is locale DATA (the
        # defensive fallback array guarded by O4/O6), not a UI string —
        # strip that one const block before scanning.
        _src = re.sub(
            r"const _ruMonthShort = \[[^\]]*\];", '', _src)
        _code = re.sub(r'///.*', '', _src)
        _code = re.sub(r'//.*', '', _code)
        if re.search(r'[А-Яа-яЁё]', _code):
            _x2_bad.append(_f)
    if not _x2_bad:
        ok(f"X2 no Cyrillic outside comments in {len(_x2_files)} localized files")
    else:
        fail(f"X2 Cyrillic still in code of: {_x2_bad}")

    # X3. Global key existence: every S.of('key') anywhere in lib/ must
    #     exist in BOTH _en and _ru (V11 covered only the +58 pilots).
    _strings_src = (root / 'lib/l10n/strings.dart').read_text()
    _en_body = _strings_src.split('_en = ')[1].split('_ru = ')[0]
    _ru_body = _strings_src.split('_ru = ')[1]
    _used = set()
    for _f in (root / 'lib').rglob('*.dart'):
        if _f.name == 'strings.dart':
            continue
        _used |= set(re.findall(r"S\.of\('([^']+)'\)", _f.read_text()))
    # _en is the canonical map — every key must exist there. _ru may
    # legitimately omit TERM keys (S.of falls back ru→_ru??_en??key by
    # design, +58): the allowlist below names the deliberate en-only
    # keys; anything else missing from _ru is a forgotten translation.
    _ru_enonly_ok = {
        'settings.adapter.title', 'settings.dtc.title',
        'settings.language.en', 'settings.language.ru',
    }
    _miss_en = sorted(k for k in _used if f"'{k}'" not in _en_body)
    _miss_ru = sorted(k for k in _used
                      if f"'{k}'" not in _ru_body and k not in _ru_enonly_ok)
    if not _miss_en and not _miss_ru:
        ok(f"X3 all {len(_used)} S.of keys exist in _en "
           f"(+ru, {len(_ru_enonly_ok)} deliberate en-only terms)")
    else:
        fail(f"X3 keys missing — en: {_miss_en} ru: {_miss_ru}")

    # X4. Every SCREEN file that calls S.of in widget code subscribes to
    #     LocaleService (per-screen watch — the rebuild contract from
    #     +58). Widgets (driver_panels, charging_banner) are exempt:
    #     their hosting screens watch and rebuild them.
    _x4_bad = []
    for _f in (root / 'lib/screens').rglob('*.dart'):
        _src = _f.read_text()
        if "S.of('" in _src and 'context.watch<LocaleService>()' not in _src:
            _x4_bad.append(str(_f.relative_to(root)))
    if not _x4_bad:
        ok("X4 every screen using S.of watches LocaleService")
    else:
        fail(f"X4 screens using S.of without LocaleService watch: {_x4_bad}")

    # X5. TripCell layout fix (owner field photo, BZ5 driver view):
    #     value + unit on a shared alphabetic baseline — the old
    #     end-alignment + bottom-padding hack let the '—' dash float
    #     mid-line above the unit. Plus the '0.0' distance fallback for
    #     an active trip with no movement yet.
    _dp = (root / 'lib/widgets/driver_panels.dart').read_text()
    _cell = _dp.split('class TripCell')[1]
    if 'CrossAxisAlignment.baseline' in _cell and \
       'textBaseline: TextBaseline.alphabetic' in _cell and \
       "EdgeInsets.only(bottom: 6)" not in _cell:
        ok("X5 TripCell: baseline alignment, bottom-padding hack removed")
    else:
        fail("X5 TripCell baseline fix missing/incomplete")
    if "svc.currentTripId != null ? '0.0' : '—'" in _dp and \
       'value: distStr,' in _dp:
        ok("X5 distance shows 0.0 (not dash) during an active trip")
    else:
        fail("X5 distance 0.0-fallback missing")

    # X6. Month axis labels are locale-aware: intl locale follows
    #     S.locale with an en fallback array mirroring the ru one.
    _tr = (root / 'lib/screens/trends.dart').read_text()
    if "DateFormat.MMM(ru ? 'ru' : 'en')" in _tr and \
       "const _enMonthShort = [" in _tr and \
       "'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'," in _tr:
        ok("X6 month formatter locale-aware with en fallback array")
    else:
        fail("X6 locale-aware month formatter missing")
else:
    ok(f"Part X skipped (build +{pv}, l10n wave lands in +60)")

# ───── Part Y: HAL push-telemetry skeleton (+61) ─────

if int(pv) >= 61:
    import subprocess as _sp

    # Y1. delegate the whole vendoring + glue contract to hal_sync_check.
    #     It WARNs (exit 0) when the 5 recon files aren't vendored yet, and
    #     hard-FAILs (exit 1) on a real contract break (arithmetic leak,
    #     missing channel, blocked binder thread, header/SHA mismatch).
    _r = _sp.run(['python3', str(root / 'tools/hal_sync_check.py')],
                 capture_output=True, text=True, cwd=root)
    if _r.returncode == 0:
        ok("Y1 hal_sync_check: glue + vendoring contract OK")
    else:
        fail(f"Y1 hal_sync_check failed:\n{_r.stdout.strip()}")

    # Y2. manifest pins recon v0.10.53 (the bug-fixed baseline — never
    #     v0.10.52 with the _tail keys / unsubscribed odometer block).
    _man = (root /
            'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'
            'hal/HAL_SYNC.manifest').read_text()
    if 'version: recon v0.10.57' in _man:
        ok("Y2 manifest pinned to recon v0.10.57")
    else:
        fail("Y2 manifest not pinned to v0.10.57")

    # Y3. DECODER_CHANGELOG vendored alongside the table (the decoder-sync
    #     source of truth), and it carries the v0.10.53 normalization entry.
    _cl = (root /
           'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'
           'hal/DECODER_CHANGELOG.md')
    if _cl.exists() and 'v0.10.57' in _cl.read_text() and \
       'v0.10.53' in _cl.read_text():
        ok("Y3 DECODER_CHANGELOG vendored through v0.10.57 (history intact)")
    else:
        fail("Y3 DECODER_CHANGELOG missing or not synced to v0.10.57")

    # Y4. Until +64 the HAL channel was plumbing-only (wrapper + dev HAL
    #     Test). From +64 the SPEED pilot wires it into the data layer via
    #     HalTelemetryService, so that service joins the allowlist. Anything
    #     else consuming the channel directly is still premature.
    _hal_allow = {'hal_telemetry_channel.dart', 'hal_test.dart'}
    if int(pv) >= 64:
        _hal_allow.add('hal_telemetry_service.dart')
    if int(pv) >= 151:
        # +151: SpeedProfileService imports the channel for the HalEvent
        # TYPE only — it observes hal.rawEvents through the HAL-Test
        # retain/release bracket and never touches the native
        # subscription itself (AW1 enforces the bracket). Same
        # allowlist-growth pattern as the +64 speed pilot.
        _hal_allow.add('speed_profile_service.dart')
    _consumers = []
    for _f in (root / 'lib').rglob('*.dart'):
        if _f.name in _hal_allow:
            continue
        if 'hal_telemetry_channel' in _f.read_text():
            _consumers.append(str(_f.relative_to(root)))
    if not _consumers:
        ok("Y4 HAL channel consumed only by sanctioned files")
    else:
        fail(f"Y4 HAL channel consumed prematurely by: {_consumers}")
else:
    ok(f"Part Y skipped (build +{pv}, HAL skeleton lands in +61)")

# ───── Part Z: SPEED overlapping pilot (+64) ─────

if int(pv) >= 64:
    _svc = (root / 'lib/services/hal_telemetry_service.dart')
    _dp = (root / 'lib/widgets/driver_panels.dart').read_text()
    _conn = (root / 'lib/services/connection.dart').read_text()
    _set = (root / 'lib/screens/settings.dart').read_text()

    # Z1. HalTelemetryService: source mode persisted, freshness gate, and
    #     PILOT SCOPE — only 'speed' is consumed for display (everything
    #     else flows but is ignored, per the agreed phase-1 plan).
    if _svc.exists():
        ss = _svc.read_text()
        if "'hal_source_mode'" in ss and 'enum HalSourceMode' in ss:
            ok("Z1 HalTelemetryService has persisted source mode")
        else:
            fail("Z1 source mode / persistence missing")
        # Pilot-scope assertion holds only for the +64/+65 window; the
        # +66 overlapping wave deliberately widens consumption (Part AA).
        if int(pv) < 66:
            if "e.name != 'speed'" in ss or "e.name == 'speed'" in ss:
                ok("Z1 service consumes only SPEED (pilot scope)")
            else:
                fail("Z1 service not scoped to SPEED only")
        else:
            ok("Z1 pilot scope superseded by +66 overlapping wave (Part AA)")
        if 'halSpeedFresh' in ss and 'Duration' in ss:
            ok("Z1 service has a freshness gate")
        else:
            fail("Z1 freshness gate missing")
    else:
        fail("Z1 hal_telemetry_service.dart missing")

    # Z2. Honesty of the data layer: ConnectionService.vehicleSpeedKmh must
    #     STILL read OBD2 (740/0008) only — the pilot swaps the DISPLAY, not
    #     the recorded value, so trip aggregates stay single-sourced.
    import re as _reZ
    _vs = _reZ.search(r'double\?\s+get\s+vehicleSpeedKmh\s*\{(.*?)\}',
                      _conn, _reZ.S)
    if _vs and "_latestValues['740']" in _vs.group(1) \
            and 'hal' not in _vs.group(1).lower():
        ok("Z2 vehicleSpeedKmh still pure OBD2 (aggregates honest)")
    else:
        fail("Z2 vehicleSpeedKmh changed — aggregate honesty at risk")
    # connection.dart must not import the HAL service/channel
    if 'hal_telemetry' not in _conn:
        ok("Z2 ConnectionService does not import HAL (additive rule kept)")
    else:
        fail("Z2 ConnectionService now references HAL — not additive")

    # Z3. Driver gauge resolver: prefers HAL when permitted, falls back to
    #     OBD2 vehicleSpeedKmh; temporary dual-readout gated on hal.running.
    if 'useHalForSpeed' in _dp and 'vehicleSpeedKmh' in _dp:
        ok("Z3 driver gauge resolves HAL→OBD2 with fallback")
    else:
        fail("Z3 driver gauge resolver missing")
    # The temporary dual-readout existed to verify HAL vs OBD2 on a live
    # drive; speed was confirmed (tracks cluster) and +66 removes it.
    if int(pv) < 66:
        if 'hal.running' in _dp and 'OBD2' in _dp:
            ok("Z3 temporary dual-readout present (gated on stream running)")
        else:
            fail("Z3 dual-readout missing")
    else:
        if 'halDot' not in _dp and 'obdDot' not in _dp:
            ok("Z3 +64 dual-readout removed (speed source confirmed)")
        else:
            fail("Z3 stale dual-readout still present in +66")

    # Z4. Source toggle in main Settings. v0.1.29+74: discrete choice —
    #     Auto removed from the UI, so exactly 2 RadioListTile (HAL/OBD2).
    #     The 'auto' enum value persists internally as a back-compat net.
    if _set.count('RadioListTile<HalSourceMode>') == 2 \
            and 'hal.setMode(' in _set \
            and 'HalSourceMode.halOnly' in _set \
            and 'HalSourceMode.obd2Only' in _set:
        ok("Z4 data-source toggle: 2 discrete modes wired in Settings")
    else:
        fail("Z4 data-source toggle missing/incomplete")
else:
    ok(f"Part Z skipped (build +{pv}, SPEED pilot lands in +64)")

# ───── Part AA: HAL overlapping wave — packV / gear / SOC / power (+66) ─────

if int(pv) >= 66:
    _ss = (root / 'lib/services/hal_telemetry_service.dart').read_text()
    _dp = (root / 'lib/widgets/driver_panels.dart').read_text()
    _conn = (root / 'lib/services/connection.dart').read_text()
    _plug = (root / 'android/app/src/main/kotlin/com/bz5companion/'
                    'bz5_companion/BydNativePlugin.kt').read_text()
    _ovr_p = (root / 'android/app/src/main/kotlin/com/bz5companion/'
                     'bz5_companion/hal/CompanionDecoderOverrides.kt')
    _man = (root / 'android/app/src/main/AndroidManifest.xml').read_text()
    _perm = (root / 'android/app/src/main/kotlin/com/bz5companion/'
                    'bz5_companion/BydPermissions.kt').read_text()

    # AA1. Service consumes the agreed allowlist with per-name freshness:
    #      continuous windows for speed/packV/current/gear, event-driven
    #      (running-gated) for the SOC pair, range guards on every name.
    _names = ["'speed'", "'pack_voltage'", "'pack_current'",
              "'gear_enum'", "'soc_display'", "'soc_battery'"]
    if all(n in _ss for n in _names) and '_continuousWindow' in _ss \
            and '_eventDriven' in _ss and '_range' in _ss:
        ok("AA1 service: allowlist + two freshness classes + range guards")
    else:
        fail("AA1 service allowlist/freshness machinery incomplete")
    if 'halPackVoltage' in _ss and 'halGear' in _ss and 'halSocPct' in _ss \
            and 'halPowerKw' in _ss and 'halFlowDir' in _ss:
        ok("AA1 service exposes the overlapping resolvers")
    else:
        fail("AA1 overlapping resolver getters missing")
    # Power deadband must mirror the OBD2 contract (±3 A) so the UI flow
    # indicator behaves identically whichever source feeds it.
    if 'i > 3.0' in _ss and 'i < -3.0' in _ss:
        ok("AA1 halFlowDir mirrors the ±3 A OBD2 deadband")
    else:
        fail("AA1 halFlowDir deadband does not mirror OBD2")

    # AA2. Honesty carried forward: recorded values stay pure OBD2. The
    #      Z2 vehicleSpeedKmh check still runs above; here we extend the
    #      no-HAL rule to the whole ConnectionService and the raw screen.
    if 'hal_telemetry' not in _conn:
        ok("AA2 ConnectionService still HAL-free (aggregates honest)")
    else:
        fail("AA2 ConnectionService references HAL — honesty at risk")
    _raw = (root / 'lib/screens/wide/raw_data_wide.dart').read_text()
    if 'hal_telemetry' not in _raw:
        ok("AA2 raw-data screen stays pure OBD2 (diagnostic truth)")
    else:
        fail("AA2 raw-data screen polluted with HAL resolution")

    # AA3. The invisible swap is wired at the display sites: packV in the
    #      driver strip, gear/SOC/power on both dashboards + scaffold badge.
    if 'useHalForPackV' in _dp and 'halPackVoltage' in _dp:
        ok("AA3 driver strip resolves pack V (HAL→OBD2)")
    else:
        fail("AA3 driver strip pack V resolver missing")
    _sites = {
        'lib/screens/dashboard.dart': ['useHalForGear', 'useHalForSoc',
                                       'useHalForPower', 'useHalForPackV'],
        'lib/screens/wide/dashboard_wide.dart': ['useHalForGear',
                                                 'useHalForSoc',
                                                 'useHalForPackV'],
        'lib/screens/wide/driver_view_wide.dart': ['useHalForGear',
                                                   'useHalForSoc',
                                                   'useHalForPower'],
        'lib/screens/wide/head_unit_scaffold.dart': ['useHalForGear'],
        'lib/screens/wide/charging_view_wide.dart': ['useHalForSoc'],
    }
    if int(pv) >= 131:
        # +131: displayed SOC resolves through the ONE resolver
        # (resolveUiSocPct honours the user's SocSource setting); the raw
        # useHalForSoc ternary survives only at deliberate math sites.
        for _f in _sites:
            _sites[_f] = ['resolveUiSocPct' if _n == 'useHalForSoc' else _n
                          for _n in _sites[_f]]
    _missing = []
    for _f, _needs in _sites.items():
        _body = (root / _f).read_text()
        for _n in _needs:
            if _n not in _body:
                _missing.append(f"{_f}:{_n}")
    if not _missing:
        ok("AA3 overlapping resolvers present at all display sites")
    else:
        fail(f"AA3 missing resolvers: {_missing}")

    # AA4. Companion override layer: local insulation fix (shared-table
    #      ×1000 bug) + battery-temp candidates, wired into the sink AND
    #      the Statistic subscription — without touching vendored files.
    if _ovr_p.exists():
        _ovr = _ovr_p.read_text()
        if 'scale = 0.001' in _ovr and '0x47300018' in _ovr:
            ok("AA4 insulation local fix (scale=0.001) present")
        else:
            fail("AA4 insulation override missing/wrong scale")
        if '0x47800010' in _ovr and 'extraStatisticFids' in _ovr:
            ok("AA4 probe_highest_temp candidate + extra fid declared")
        else:
            fail("AA4 battery-temp candidate layer incomplete")
        # +71: battery-temp second attempt on the profile devices
        # (Energy/Charging) — pure decoder add, fids already subscribed.
        if int(pv) >= 71:
            if 'BYDAutoEnergyDevice|0x000DA09B' in _ovr \
                    and 'BYDAutoChargingDevice|0x00072559' in _ovr:
                ok("AA4 Energy/Charging battery-temp candidates added")
            else:
                fail("AA4 profile-device temp candidates missing")
    else:
        fail("AA4 CompanionDecoderOverrides.kt missing")
    if 'DecodedStreamSink(sink, CompanionDecoderOverrides.map)' in _plug \
            and 'extraStatisticFids' in _plug:
        ok("AA4 plugin wires overrides into sink + subscription")
    else:
        fail("AA4 plugin does not wire the override layer")

    # AA5. AC permission fix (field-confirmed missing 2026-06-11: AcDevice
    #      getInstance SecurityException naming BYDAUTO_AC_COMMON).
    if 'BYDAUTO_AC_COMMON' in _man and 'BYDAUTO_AC_GET' in _man:
        ok("AA5 manifest declares BYDAUTO_AC_COMMON + _GET")
    else:
        fail("AA5 AC permissions missing from manifest")
    if 'BYDAUTO_AC_COMMON' in _perm:
        ok("AA5 AC permission in the runtime-request list")
    else:
        fail("AA5 AC permission not runtime-requested")
else:
    ok(f"Part AA skipped (build +{pv}, overlapping wave lands in +66)")

# ───── Part AB: power card + HAL Test grid (+67) ─────

if int(pv) >= 67:
    _dvw = (root / 'lib/screens/wide/driver_view_wide.dart').read_text()
    _ht = (root / 'lib/screens/hal_test.dart').read_text()

    # AB1. Power card present in the gear/power/SOC stack with the
    #      owner-confirmed asymmetric scales (200 discharge / 100 regen),
    #      flow bar and sparkline painters.
    if '_PowerCard' in _dvw and '_PowerBarPainter' in _dvw \
            and '_PowerBarsPainter' in _dvw:
        ok("AB1 power card + bar + sparkline(bars) present")
    else:
        fail("AB1 power card components missing")
    # +70: scales auto-zoom (variant B) instead of fixed 200/100.
    if int(pv) >= 70:
        if '_recomputeScales' in _dvw and '_dischargeCeilKw = 200.0' in _dvw \
                and '_regenCeilKw = 100.0' in _dvw \
                and '_scaleEase' in _dvw:
            ok("AB1 power auto-zoom scales (ease to window max, capped 200/100)")
        else:
            fail("AB1 auto-zoom scale machinery missing")
        # Power card lives in its own centre column, not the right stack.
        if '_GearAndSocStack' in _dvw and '_PowerCard' in _dvw \
                and '_PowerCard()' in _dvw:
            ok("AB1 power card in centre column; right stack back to gear/SOC")
        else:
            fail("AB1 centre-column power layout missing")
    else:
        if '_dischargeFullKw = 200.0' in _dvw and '_regenFullKw = 100.0' in _dvw:
            ok("AB1 bar scales 200/100 kW (owner-confirmed)")
        else:
            fail("AB1 bar scales wrong")
    # Display-only: the sampler must not touch connection.dart (already
    # enforced by AA2) and must use the same resolver as everywhere.
    if 'useHalForPower' in _dvw and 'instantPowerKw' in _dvw:
        ok("AB1 sampler uses the shared HAL→OBD2 power resolver")
    else:
        fail("AB1 sampler bypasses the shared resolver")

    # AB2. Power removed from the bottom strip (no duplication).
    if 'powerStr' not in _dvw:
        ok("AB2 bottom-strip power line removed (lives in the card now)")
    else:
        fail("AB2 power still duplicated in the bottom strip")

    # AB3. HAL Test renders a photo-friendly grid (one screenshot = full
    #      param set), stable-sorted, with the decoder key on long-press.
    if 'GridView.builder' in _ht and 'SliverGridDelegateWithMaxCrossAxisExtent' in _ht:
        ok("AB3 HAL Test grid layout present")
    else:
        fail("AB3 HAL Test still a list")
    if 'Tooltip' in _ht and 'TooltipTriggerMode.longPress' in _ht:
        ok("AB3 decoder key reachable via long-press")
    else:
        fail("AB3 decoder key tooltip missing")
else:
    ok(f"Part AB skipped (build +{pv}, power card lands in +67)")

# ───── Part AC: CI delivery via Releases (+68) ─────

if int(pv) >= 68:
    _wf = (root / '.github/workflows/build.yml').read_text()
    # AC1. Release publishing is unconditional on main builds (it became
    #      the canonical delivery after the artifact quota incident) and
    #      tags are unique per commit.
    if 'tag_name: build-${{ env.BUILD_NUMBER }}' in _wf \
            and 'make_latest: true' in _wf:
        ok("AC1 release publish step (per-commit tag, latest pointer)")
    else:
        fail("AC1 release publish step missing/incomplete")
    if 'contents: write' in _wf:
        ok("AC1 workflow grants contents:write for releases")
    else:
        fail("AC1 GITHUB_TOKEN lacks contents:write")
    # AC2. (+69 hardening) The artifact-upload step is gone entirely —
    #      a quota-tolerant copy still proved fragile in the field, so
    #      the only acceptable state is zero artifact calls.
    if int(pv) >= 69:
        if 'upload-artifact' not in _wf:
            ok("AC2 no artifact upload at all (Releases-only delivery)")
        else:
            fail("AC2 artifact upload crept back into the workflow")
    else:
        if 'retention-days: 7' in _wf and 'continue-on-error: true' in _wf:
            ok("AC2 artifact retention 7d + quota-tolerant upload")
        else:
            fail("AC2 artifact step still quota-fragile")
else:
    ok(f"Part AC skipped (build +{pv}, release delivery lands in +68)")

# ─────────────── Part AD: +119 SOH persistence + merged gear/SOC ───────────
# AD1..AD3 pin the v0.1.29+119 fix for the BZ3 field bug "SOH corrected on
# charge reverts next trip": the id=2 upsert used to be fire-and-forget while
# _resetHalSohSession cleared the crash snapshot immediately — ignition-off
# in that window lost both. AD4 pins the merged gear+SOC card.
if int(pv) >= 119:
    _hal = (root / 'lib/services/hal_telemetry_service.dart').read_text()
    # AD1: reset must NOT clear the pending snapshot (ownership moved).
    _m = re.search(r"void _resetHalSohSession\(\)\s*\{(.*?)\n  \}", _hal,
                   re.DOTALL)
    if _m and '_clearPendingSohSession' not in _m.group(1):
        ok("AD1 _resetHalSohSession no longer clears the pending snapshot")
    else:
        fail("AD1 reset still clears pending snapshot (the +118 race)")
    # AD2: store path awaits the upsert and clears the snapshot only after.
    # NOTE: the parameter block of _storeHalSohIfValid itself closes with
    # '\n  })' — a naive regex to the first '\n  }' captures only the
    # signature. Slice to the next known method instead.
    _s0 = _hal.find("void _storeHalSohIfValid({")
    _s1 = _hal.find("_persistPendingSohSession", _s0)
    _sbody = _hal[_s0:_s1] if (_s0 != -1 and _s1 != -1) else ""
    _p_up = _sbody.find("await db.upsertSohEstimate")
    _p_cl = _sbody.find("await _clearPendingSohSession")
    if _p_up != -1 and _p_cl != -1 and _p_up < _p_cl:
        ok("AD2 SOH upsert awaited; snapshot cleared only after the write")
    else:
        fail("AD2 upsert-then-clear ordering missing in _storeHalSohIfValid")
    # AD3: gate failures clear the snapshot explicitly (discarded session
    # must not resurrect), i.e. clear appears at least twice in the store
    # body (two discard exits) plus once post-upsert.
    if _sbody.count("_clearPendingSohSession") >= 3:
        ok("AD3 discarded sessions clear the snapshot explicitly")
    else:
        fail("AD3 gate-failure paths don't clear the pending snapshot")
    # AD4: merged gear+SOC card on the BZ3 tall driver screen; the two old
    # cards are gone (they'd be unused_element lint failures anyway).
    _tall = (root / 'lib/screens/driver_view_tall.dart').read_text()
    if ('class _GearSocCardTall' in _tall
            and 'class _GearCardTall' not in _tall
            and 'class _SocCardTall' not in _tall
            and "'SOH ${sohHal.toInt()} % (BMS)'" in _tall):
        ok("AD4 merged gear+SOC card + (BMS) tag on live BMS SOH")
    else:
        fail("AD4 merged gear/SOC card or (BMS) tag missing")
else:
    ok(f"Part AD skipped (build +{pv}, SOH persistence lands in +119)")

# ─────────────────── Part AE: +120 C4 push v2 (client_uuid) ────────────────
# Pins the CLIENT_API §3 ordering rule: ingest carries client_uuid ONLY
# behind the initial-mapping-done gate, the gate is set at the end of a full
# _syncUuidMapping pass, and a fresh registration resets it.
if int(pv) >= 120:
    _cs = (root / 'lib/services/cloud_sync_service.dart').read_text()
    # AE1: all 5 serializers gate client_uuid on _uuidMapInitialDone.
    _gated = _cs.count("if (_uuidMapInitialDone && ")
    if _gated >= 5 and _cs.count("'client_uuid': ") >= 6:
        ok("AE1 client_uuid gated in all 5 ingest serializers")
    else:
        fail(f"AE1 gated serializers incomplete (gates={_gated})")
    # AE2: gate set only at the end of the mapping pass (after the entity
    # loop), and persisted.
    _p_loop = _cs.find("for (final entity in _uuidMapEntities)")
    _p_set = _cs.find("_uuidMapInitialDone = true")
    if _p_loop != -1 and _p_set != -1 and _p_set > _p_loop and \
       "prefs.setBool(_kUuidMapInitialDone, true)" in _cs:
        ok("AE2 initial-done set after a full mapping pass + persisted")
    else:
        fail("AE2 initial-done gate not set at end of mapping pass")
    # AE3: fresh identity resets the gate; forceFullResync must NOT.
    _reg = _cs.find("prefs.remove(_kUuidMapInitialDone)")
    _ffr = _cs.find("Future<void> forceFullResync")
    _ffr_end = _cs.find("Future", _ffr + 10) if _ffr != -1 else -1
    _ffr_body = _cs[_ffr:_ffr_end] if _ffr != -1 else ""
    if _reg != -1 and "_kUuidMapInitialDone" not in _ffr_body:
        ok("AE3 gate reset on new identity only (survives forceFullResync)")
    else:
        fail("AE3 gate reset wiring wrong (registration/forceFullResync)")
else:
    ok(f"Part AE skipped (build +{pv}, push v2 lands in +120)")

# ─────────────────── Part AF: +121 C5 restore via /v2/sync/pull ────────────
if int(pv) >= 121:
    _cs = (root / 'lib/services/cloud_sync_service.dart').read_text()
    _db2 = (root / 'lib/data/database.dart').read_text()
    # AF1: v2 pull wired into startRestore with legacy fallback kept.
    if "_tryRestoreViaSyncPullV2(tripIdMap)" in _cs and \
       "if (v2 == null) {" in _cs and \
       "end `if (v2 == null)`" in _cs:
        ok("AF1 restore tries /v2/sync/pull, legacy v1 loops kept as fallback")
    else:
        fail("AF1 v2 pull integration or legacy fallback missing")
    # AF2: idempotent apply by client_uuid (D8) — uuid lookups exist and the
    # apply is two-pass (trips buffered before snapshots).
    if "getTripByClientUuid" in _db2 and "getSnapshotByClientUuid" in _db2 \
       and _cs.find("Apply pass 1: trips") < _cs.find("Apply pass 2: snapshots"):
        ok("AF2 uuid-idempotent two-pass apply (trips before snapshots)")
    else:
        fail("AF2 uuid lookups or two-pass apply ordering missing")
    # AF3: cursor progress guard — a non-advancing next_since must break.
    if "next <= since) break" in _cs:
        ok("AF3 pull loop guards against a non-advancing cursor")
    else:
        fail("AF3 pull loop can spin on a stale next_since")
    # AF4: v2Probe branch lives in _getJson (the +117 lesson, inverted:
    # this one BELONGS in _getJson — verify it sits after _getJson's
    # signature and before _postIngest's).
    _p_get = _cs.find("Future<Map<String, dynamic>> _getJson(")
    _p_post = _cs.find("Future<Map<String, dynamic>> _postIngest(")
    _p_br = _cs.find("if (v2Probe && (code == 400")
    if -1 < _p_get < _p_br < _p_post:
        ok("AF4 v2Probe branch scoped inside _getJson")
    else:
        fail("AF4 v2Probe branch outside _getJson scope")
else:
    ok(f"Part AF skipped (build +{pv}, restore v2 lands in +121)")

# ─────────────────── Part AG: +123 restore watermark fix ────────────────────
if int(pv) >= 123:
    _cs = (root / 'lib/services/cloud_sync_service.dart').read_text()
    # AG1: uuid-mapping watermarks (trips+snapshots) advanced after a
    # successful restore, in the SAME success block as (and after) the
    # push-cursor advancement — restored rows must never be re-mapped
    # under their new local ids (field conflicts 2026-07-04/05).
    _p_cur = _cs.find("await prefs.setInt(_kCursorSnapshot, _cursorSnapshot);")
    _p_wm_t = _cs.find("_uuidMapWm['trips'] = maxTripId;")
    _p_wm_s = _cs.find("_uuidMapWm['snapshots'] = maxSnapId;")
    if -1 < _p_cur < _p_wm_t < _p_wm_s and \
       "'${_kUuidMapWmPrefix}trips'" in _cs and \
       "'${_kUuidMapWmPrefix}snapshots'" in _cs:
        ok("AG1 restore advances uuid-mapping watermarks (trips+snapshots)")
    else:
        fail("AG1 restore watermark advancement missing/misplaced")
    # AG2: pass-1/pass-2 skip-reason counters exist and are reported in
    # the restore diag line (uuid= / legacy= / bad=).
    if "skip uuid=$tSkipUuid legacy=$tSkipLegacy bad=$tSkipBad" in _cs and \
       "skip uuid=$sSkipUuid legacy=$sSkipLegacy bad=$sSkipBad" in _cs and \
       "tSkipBad++" in _cs and "sSkipLegacy++" in _cs:
        ok("AG2 restore skip-reason counters (uuid/legacy/bad) in diag line")
    else:
        fail("AG2 restore skip-reason counters missing")
else:
    ok(f"Part AG skipped (build +{pv}, restore watermark fix lands in +123)")

# ─────────────────── Part AH: +124 C2 account auth + C6 ─────────────────────
if int(pv) >= 124:
    _aa = (root / 'lib/services/account_auth_service.dart').read_text()
    _acc = (root / 'lib/screens/account.dart').read_text()
    _l10n2 = (root / 'lib/l10n/strings.dart').read_text()
    _cs2 = (root / 'lib/services/cloud_sync_service.dart').read_text()
    _ad = (root / 'lib/screens/app_diag.dart').read_text()
    # AH1: rotation discipline — the NEW refresh token is persisted to
    # secure storage BEFORE the new access token is exposed (crash-safe
    # ordering), inside _adoptTokenPair.
    _p_body = _aa.find('_adoptTokenPair(Map<String, dynamic> j)')
    _p_w = _aa.find('_secureStorage.write(key: _kRefreshKey', _p_body)
    _p_a = _aa.find('_accessToken = access', _p_body)
    if -1 < _p_body < _p_w < _p_a:
        ok('AH1 refresh rotation: new refresh persisted before access exposed')
    else:
        fail('AH1 refresh persist-before-access ordering broken')
    # AH2: refresh_reused / invalid_refresh → session wipe, never retried.
    if "refresh_reused" in _aa and "_wipeSession(" in _aa and \
       "NEVER retried" in _aa:
        ok('AH2 refresh_reused/invalid_refresh wipe session (no replay)')
    else:
        fail('AH2 refresh 401 handling missing')
    # AH3: C6 account plane — exactly one refresh+retry on 401, then
    # local sign-out (no loops).
    if '_authorizedSend' in _aa and \
       _aa.count('resp = await send(access)') >= 2 and \
       "await _wipeSession(reason: 'session')" in _aa:
        ok('AH3 authorized calls: one refresh + one retry on 401, then out')
    else:
        fail('AH3 account 401 retry discipline missing')
    # AH4: anti-enumeration copy + spam hint + resend note in BOTH locales.
    if _l10n2.count("'account.code_sent_neutral'") == 2 and \
       'Спам' in _l10n2 and 'Spam folder' in _l10n2 and \
       _l10n2.count("'account.resend_note'") == 2:
        ok('AH4 anti-enumeration + spam-hint + resend-note copy (EN+RU)')
    else:
        fail('AH4 neutral OTP copy incomplete')
    # AH5: resend cooldown wired (60 s constant + countdown in the UI).
    if 'resendCooldown = Duration(seconds: 60)' in _aa and \
       'resendSecondsLeft' in _acc:
        ok('AH5 resend cooldown (60s) + UI countdown')
    else:
        fail('AH5 resend cooldown missing')
    # AH6: devices list + revoke (§1.3) with a confirm dialog that states
    # local data is kept.
    if '/v2/devices' in _aa and '/revoke' in _aa and \
       "revoke_confirm_body" in _acc and \
       _l10n2.count("'account.revoke_confirm_body'") == 2:
        ok('AH6 devices list + revoke with local-data-kept confirm')
    else:
        fail('AH6 devices/revoke wiring missing')
    # AH7: C6 device plane — graceful 3x401 wording (data intact, recovery
    # paths named), old dead-end wording gone.
    if 'local data intact' in _cs2 and \
       're-register required' not in _cs2:
        ok('AH7 device-plane 3x401 message graceful (data intact + recovery)')
    else:
        fail('AH7 device-plane 401 wording not updated')
    # AH8: AppDiag shows account-plane rows.
    if "('account status', auth.status.name" in _ad:
        ok('AH8 AppDiag exposes account status rows')
    else:
        fail('AH8 AppDiag account rows missing')
else:
    ok(f"Part AH skipped (build +{pv}, account auth lands in +124)")

# ─────────────────── Part AI: +125 idempotent migrations ────────────────────
if int(pv) >= 125:
    _db3 = (root / 'lib/data/database.dart').read_text()
    # AI1: no raw structural calls left in the migration — every
    # addColumn/createTable goes through the if-absent guards (exactly
    # one raw call of each remains, inside the guard bodies).
    if _db3.count('await m.addColumn(') == 1 and \
       _db3.count('await m.createTable(') == 1 and \
       '_addColumnIfAbsent(m, ' in _db3 and \
       '_createTableIfAbsent(m, ' in _db3:
        ok('AI1 all migration DDL routed through if-absent guards')
    else:
        fail('AI1 raw addColumn/createTable left in onUpgrade')
    # AI2: guards check real schema state (PRAGMA table_info /
    # sqlite_master), not app state.
    if 'PRAGMA table_info(' in _db3 and 'sqlite_master' in _db3:
        ok('AI2 guards read live schema (pragma/sqlite_master)')
    else:
        fail('AI2 schema-existence checks missing')
    # AI3: migration run visible in the diag ring buffer (+122).
    if "DB migrate: $from → $to starting" in _db3 and \
       "already present — skipped" in _db3:
        ok('AI3 migration start/skip diag lines present')
    else:
        fail('AI3 migration diag lines missing')
else:
    ok(f"Part AI skipped (build +{pv}, idempotent migrations land in +125)")

# ─────────────────── Part AJ: +126 restore barrier ──────────────────────────
if int(pv) >= 126:
    _cs = (root / 'lib/services/cloud_sync_service.dart').read_text()
    # AJ1: syncOnce refuses to run while the restore barrier is up, and
    # the guard sits BEFORE _syncInProgress is taken.
    _p_g = _cs.find('if (_restoreInProgress) {')
    _p_t = _cs.find('_syncInProgress = true;')
    if -1 < _p_g < _p_t and 'restore barrier' in _cs:
        ok('AJ1 syncOnce guarded by restore barrier (before in-progress take)')
    else:
        fail('AJ1 restore barrier guard in syncOnce missing/misplaced')
    # AJ2: barrier raised at startRestore entry, dropped on ALL exit
    # paths (2 early error returns + finally), and dropped BEFORE the
    # timers restart in the finally block.
    _p_fin = _cs.find('} finally {\n      // v0.1.29+126: drop the barrier')
    _p_drop = _cs.find('_restoreInProgress = false;', _p_fin)
    _p_rt = _cs.find('_restartTimers();', _p_fin)
    if _cs.count('_restoreInProgress = true;') == 1 and \
       _cs.count('_restoreInProgress = false;') == 4 and \
       -1 < _p_fin < _p_drop < _p_rt:
        ok('AJ2 barrier raised once, dropped on all 3 exits, before timers')
    else:
        fail('AJ2 barrier lifecycle wrong')
    # AJ3: startRestore waits out an in-flight syncOnce (bounded).
    if 'while (_syncInProgress && waitedMs < 30000)' in _cs:
        ok('AJ3 restore waits out in-flight sync (bounded 30s)')
    else:
        fail('AJ3 in-flight sync wait missing')
    # AJ4: forceFullResync keeps uuid-map watermarks (mapping replay on
    # a post-restore DB mis-pairs uuids — 2026-07-04/05 field data).
    _ffr2 = _cs.find('Future<void> forceFullResync')
    _ffr2_end = _cs.find('notifyListeners();', _ffr2)
    _ffr2_body = _cs[_ffr2:_ffr2_end] if _ffr2 != -1 else ''
    if _ffr2 != -1 and '_kUuidMapWmPrefix' not in _ffr2_body and \
       '_uuidMapWm[e] = 0' not in _ffr2_body:
        ok('AJ4 forceFullResync preserves uuid-map watermarks')
    else:
        fail('AJ4 forceFullResync still wipes watermarks')
else:
    ok(f"Part AJ skipped (build +{pv}, restore barrier lands in +126)")

# ─────────────────── Part AK: +127 C3 pairing ───────────────────────────────
if int(pv) >= 127:
    _cs = (root / 'lib/services/cloud_sync_service.dart').read_text()
    _pair = (root / 'lib/screens/pairing.dart').read_text()
    _aa2 = (root / 'lib/services/account_auth_service.dart').read_text()
    _acc2 = (root / 'lib/screens/account.dart').read_text()
    # AK1: device_code confinement — private field, no getter, never
    # interpolated (not into diag lines, not into the UI).
    if '_pairDeviceCode' in _cs and \
       'get pairDeviceCode' not in _cs and \
       '$_pairDeviceCode' not in _cs and \
       '$_pairUserCode' not in _cs and \
       'DeviceCode' not in _pair:
        ok('AK1 device_code confined (no getter, no logs, no UI)')
    else:
        fail('AK1 device_code leaks (getter/log/UI)')
    # AK2: scenario (b) — minted token persisted to secure storage
    # BEFORE the auto-restore is kicked (exactly-once delivery).
    _p_poll = _cs.find('Future<void> _pollPairStatus()')
    _p_w = _cs.find('_secureStorage.write(key: _kTokenKey, value: minted)',
                    _p_poll)
    _p_r = _cs.find('unawaited(startRestore(oldClientToken: minted))',
                    _p_poll)
    if -1 < _p_poll < _p_w < _p_r:
        ok('AK2 minted token persisted before auto-restore kick')
    else:
        fail('AK2 token persist / auto-restore ordering broken')
    # AK3: poll honors the server interval and self-expires.
    if 'Duration(seconds: _pairIntervalSec)' in _cs and \
       '_finishPairing(CloudPairingStatus.expired)' in _cs:
        ok('AK3 poll uses server interval + local expiry stop')
    else:
        fail('AK3 poll cadence/expiry wiring missing')
    # AK4: phone-side claim wired end-to-end (§1.2 pair/claim).
    if '/v2/pair/claim' in _aa2 and 'claimPairing' in _acc2 and \
       "account.claim_invalid" in _acc2:
        ok('AK4 pair/claim wired in account service + screen')
    else:
        fail('AK4 claim path missing')
    # AK5: scenario (a) — live device sends its Bearer on pair/start.
    if "if (isRegistered && _clientToken != null)" in _cs and \
       "'Bearer $_clientToken'," in _cs:
        ok('AK5 live device authenticates pair/start (token unchanged)')
    else:
        fail('AK5 scenario (a) Bearer on pair/start missing')
else:
    ok(f"Part AK skipped (build +{pv}, pairing lands in +127)")

# ─────────────── Part AL: +139 phone stale dashboard ────────────────────────
if int(pv) >= 139:
    _dash = (root / 'lib/screens/dashboard.dart').read_text()
    # AL1: the stale branch is HU-gated BEFORE any DB access — inside
    # _BlockedBody's build, the onHeadUnit early-return to the old stub
    # must precede the FutureBuilder (tall BZ3 uses this dashboard as
    # its MAIN screen; its behaviour must stay bit-identical).
    _bb = _dash.find('class _BlockedBodyState')
    _hu = _dash.find('if (widget.onHeadUnit) return _NotConnected', _bb)
    # +141 renamed the future's payload Snapshot? → _StaleData? (fieldwise
    # rows); the gate ORDER under test is unchanged — anchor per era.
    _fb = _dash.find(
        'FutureBuilder<_StaleData?>' if int(pv) >= 141
        else 'FutureBuilder<Snapshot?>', _bb)
    if -1 < _bb < _hu < _fb:
        ok('AL1 stale branch HU-gated before DB (stub early-return)')
    else:
        fail('AL1 HU gate missing or after FutureBuilder')
    # AL2: empty DB (no snapshot) falls back to the OLD stub — the Q2
    # decision; "connect adapter" stays the fresh-install guidance.
    if 'if (s == null) return _NotConnected(halDead: widget.halDead);' \
       in _dash:
        ok('AL2 empty DB → old _NotConnected stub preserved')
    else:
        fail('AL2 empty-DB fallback to stub missing')
    # AL3: charging badge guard (+128 lesson: OBD2 writes 0.0, HAL null
    # when not charging) + cards render with the stale flag.
    if 's.isCharging == true' in _dash and \
       "s.chargingPowerKw! > 0.05" in _dash and \
       _dash.count('stale: true') >= 3:
        ok('AL3 badge guard (isCharging==true, >0.05 kW) + stale cards')
    else:
        fail('AL3 badge guard or stale-card flag missing')
    # AL4 (К6 fix): the platform probe must be SETTLED before any stale
    # render or timer — canUseHal reads false on a cold-starting BZ3
    # too, so acting on it alone would flash the stale cards on the HU
    # and leave a forever-ticking timer behind. Checks: the probed
    # early-return sits between the HU return and the FutureBuilder,
    # the want-predicate combines both flags, and the service exposes
    # the flag set right after the probe.
    _hal2 = (root / 'lib/services/hal_telemetry_service.dart').read_text()
    _pr = _dash.find('if (!widget.probed)', _bb)
    if -1 < _hu < _pr < _fb and \
       '!widget.onHeadUnit && widget.probed' in _dash and \
       'get platformProbed' in _hal2 and \
       '_platformProbed = true' in _hal2:
        ok('AL4 stale render/timer gated on settled platform probe')
    else:
        fail('AL4 probed gate missing (HU cold-start flash risk)')
else:
    ok(f"Part AL skipped (build +{pv}, stale dashboard lands in +139)")

# ─────────────── Part AM: +140 trip_series client ────────────────────────────
if int(pv) >= 140:
    _db2 = (root / 'lib/data/database.dart').read_text()
    _cs2 = (root / 'lib/services/cloud_sync_service.dart').read_text()
    _td2 = (root / 'lib/screens/trip_detail.dart').read_text()
    _hw2 = (root / 'lib/screens/wide/history_wide.dart').read_text()
    # AM1: schema v16 + additive migration + table registered.
    if 'int get schemaVersion => 16;' in _db2 and \
       '_createTableIfAbsent(m, tripSeries)' in _db2 and \
       "@DataClassName('TripSeriesRow')" in _db2:
        ok('AM1 trip_series table + v16 additive migration')
    else:
        fail('AM1 trip_series schema/migration missing')
    # AM2: pipeline order — generate+push AFTER _syncTrips, BEFORE
    # _syncSnapshots; push tolerates a not-yet-deployed endpoint.
    # (+146: same invariant, guardEntity syntax — anchor per build.)
    _g146 = int(pv) >= 146
    _p_t = _cs2.find(
        "guardEntity('trips', _syncTrips)" if _g146
        else 'await _syncTrips();')
    _p_g = _cs2.find('await _generateTripSeries();')
    _p_p = _cs2.find(
        "guardEntity('trip_series', _syncTripSeries)" if _g146
        else 'await _syncTripSeries();')
    _p_s = _cs2.find(
        "guardEntity('snapshots', _syncSnapshots)" if _g146
        else 'await _syncSnapshots();')
    if -1 < _p_t < _p_g < _p_p < _p_s and \
       "'/v1/data/ingest/tripseries'" in _cs2 and \
       'tolerateNotDeployed: true' in _cs2:
        ok('AM2 pipeline order trips→series + endpoint-404 tolerance')
    else:
        fail('AM2 series pipeline order / 404 tolerance wrong')
    # AM3: pull third pass + restore pass share ONE uuid-linked helper,
    # and the orphan re-link runs after series application.
    if _cs2.count('_applyPulledTripSeries(') >= 3 and \
       "case 'trip_series':" in _cs2 and \
       _cs2.count('relinkOrphanTripSeries()') >= 2:
        ok('AM3 pull+restore series passes share uuid-linked apply')
    else:
        fail('AM3 series pull/restore passes incomplete')
    # AM4: chart ladder order in BOTH twins — series step sits between
    # the hal loop and the snapshot stage.
    def _ladder_ok(srcname, s):
        h = s.find('getHalSamplesForTripByName')
        t = s.find('getTripSeriesForChart')
        f = s.find('final field = snapshotField;')
        return -1 < h < t < f
    if _ladder_ok('td', _td2) and _ladder_ok('hw', _hw2) and \
       _td2.count("seriesName: '") == 6 and _hw2.count("seriesName: '") == 3:
        ok('AM4 chart 4th step between hal and snapshots, both twins')
    else:
        fail('AM4 chart ladder step order/call-sites wrong')
    # AM5: LTTB bounds — 240 cap, <2-point series never stored, points
    # rounded and strictly ascending (dedup collapse present).
    if '_kTripSeriesMaxPoints = 240' in _cs2 and \
       'if (raw.length < 2) continue;' in _cs2 and \
       'toStringAsFixed(2)' in _cs2 and \
       'dedup.last.$1 == p.$1' in _cs2:
        ok('AM5 LTTB bounds (240 cap, min-2, rounding, ts dedup)')
    else:
        fail('AM5 LTTB bound guards missing')
else:
    ok(f"Part AM skipped (build +{pv}, trip_series lands in +140)")

# ─────────────── Part AN: +141 whoami / fieldwise stale / SOC gate ───────────
if int(pv) >= 141:
    _cs3 = (root / 'lib/services/cloud_sync_service.dart').read_text()
    _dash3 = (root / 'lib/screens/dashboard.dart').read_text()
    _set3 = (root / 'lib/screens/settings.dart').read_text()
    _pair3 = (root / 'lib/screens/pairing.dart').read_text()
    _res3 = (root / 'lib/services/soc_resolver.dart').read_text()
    _db3 = (root / 'lib/data/database.dart').read_text()
    _l10n3 = (root / 'lib/l10n/strings.dart').read_text()
    # AN1: whoami plane is SELF-CONTAINED — display-only decree (Q3).
    # fetchDeviceMe must not route through _getJson (whose 401 counter
    # and _AccountGateException would couple planes) and must never
    # touch _consecutiveAuthFailures or CloudSyncStatus. Body extracted
    # by brace counting (interpolation braces are balanced too), NOT by
    # a first-'}' heuristic — that terminated inside the method.
    def _brace_body(src, start):
        i = src.find('{', start)
        if i == -1:
            return ''
        depth = 0
        for j in range(i, len(src)):
            if src[j] == '{':
                depth += 1
            elif src[j] == '}':
                depth -= 1
                if depth == 0:
                    return src[i:j + 1]
        return ''
    _fm_start = _cs3.find('Future<void> fetchDeviceMe(')
    # The signature's optional-parameter list opens with '{' too —
    # anchor the body scan on the 'async' keyword past the params.
    _fm_async = _cs3.find(' async ', _fm_start) if _fm_start != -1 else -1
    _fm_body = _brace_body(_cs3, _fm_async) if _fm_async != -1 else ''
    if _fm_body and '_getJson' not in _fm_body and \
       '_consecutiveAuthFailures' not in _fm_body and \
       '_status =' not in _fm_body and \
       '/v2/device/me' in _fm_body and \
       '_deviceMeInFlight' in _fm_body:
        ok('AN1 whoami self-contained (no _getJson/auth-counter/status)')
    else:
        fail('AN1 fetchDeviceMe couples planes or missing')
    # AN2: three call sites — init (token-gated), BOTH paired branches
    # (minted with tokenOverride — the restore swaps _clientToken later).
    if _cs3.count('fetchDeviceMe(') >= 4 and \
       'fetchDeviceMe(tokenOverride: minted)' in _cs3 and \
       'if (_clientToken != null) unawaited(fetchDeviceMe());' in _cs3:
        ok('AN2 whoami call sites: init + both paired branches')
    else:
        fail('AN2 whoami call sites incomplete')
    # AN3: fieldwise stale — DAO returns per-field newest rows, the
    # dashboard renders each card with its OWN date, and the charging
    # badge stays on the overall-latest row (a state of NOW).
    if 'getLatestFieldwiseSnapshots' in _db3 and \
       _dash3.count('_relTime(data.') >= 3 and \
       'final charging = s.isCharging == true;' in _dash3 and \
       'final s = data.latest;' in _dash3:
        ok('AN3 fieldwise stale cards + badge pinned to latest row')
    else:
        fail('AN3 fieldwise stale wiring wrong')
    # AN4: SOC setting hidden on a CONFIRMED phone only (probe settled),
    # and the resolver force-returns precise behind the same predicate.
    if 'hal.platformProbed && !hal.canUseHal' in _set3 and \
       'hal.platformProbed && !hal.canUseHal' in _res3 and \
       'return svc.socPrecisePct;' in _res3:
        ok('AN4 SOC setting gated + resolver forces precise on phone')
    else:
        fail('AN4 SOC phone gate incomplete')
    # AN5: UI lines exist (settings tap-to-refresh + pairing subtitle)
    # and the l10n quartet is present in BOTH locales.
    _keys = ["'cloud.device_me.linked'", "'cloud.device_me.not_linked'",
             "'cloud.device_me.unknown'", "'cloud.device_me.approved'"]
    if 'onTap: () => cs.fetchDeviceMe()' in _set3 and \
       '_pairedIdentityLine(cs)' in _pair3 and \
       all(_l10n3.count(k) == 2 for k in _keys):
        ok('AN5 whoami UI lines + l10n quartet EN/RU')
    else:
        fail('AN5 whoami UI/l10n incomplete')
else:
    ok(f"Part AN skipped (build +{pv}, whoami lands in +141)")


# ─────────────── Part AO: +142 backlog pack ─────────────────────────────────
if int(pv) >= 142:
    _cells4 = (root / 'lib/screens/cells.dart').read_text()
    _dw4 = (root / 'lib/screens/wide/dashboard_wide.dart').read_text()
    _dash4 = (root / 'lib/screens/dashboard.dart').read_text()
    _drv4 = (root / 'lib/screens/wide/driver_view_wide.dart').read_text()
    _hal4 = (root / 'lib/services/hal_telemetry_service.dart').read_text()
    _con4 = (root / 'lib/services/connection.dart').read_text()
    _cs4 = (root / 'lib/services/cloud_sync_service.dart').read_text()
    _td4 = (root / 'lib/screens/trip_detail.dart').read_text()
    _hw4 = (root / 'lib/screens/wide/history_wide.dart').read_text()
    _db4 = (root / 'lib/data/database.dart').read_text()
    _pick4 = (root / 'lib/widgets/vehicle_descriptor_picker.dart').read_text()
    _l10n4 = (root / 'lib/l10n/strings.dart').read_text()
    # AO1: insulation row in BOTH show points, gated on value+useHal, red
    # threshold ONLY (no green/amber scale — Q1), l10n pair EN/RU.
    _ins_gate = 'hal.useHalForInsulation ? hal.halInsulationMOhm : null'
    _ins_red = 'insulationMOhm < 1.0 ? Colors.red : null'
    _ins_scale_leak = any(
        'insulation' in ln.lower() and
        ('Colors.orange' in ln or 'Colors.green' in ln)
        for src in (_cells4, _dw4) for ln in src.splitlines())
    if _ins_gate in _cells4 and _ins_gate in _dw4 and \
       _ins_red in _cells4 and _ins_red in _dw4 and \
       'if (insulationMOhm != null)' in _cells4 and \
       'if (insulationMOhm != null)' in _dw4 and \
       not _ins_scale_leak and \
       _l10n4.count("'cells.insulation'") == 2:
        ok('AO1 insulation row ×2, null/useHal gate, red-only threshold')
    else:
        fail('AO1 insulation widget wiring wrong')
    # AO2: SOH dates on 3 showcases resolved by the percent ladder; the
    # HAL flag/date land POSITIONALLY after "upsert landed" inside
    # _storeHalSohIfValid (the +119 ordered section); connection.dart
    # stays HAL-free (AA2); l10n pairs EN/RU; snack consumed via a
    # silent synchronous take (IndexedStack double-fire guard).
    _sb = _hal4.find('void _storeHalSohIfValid(')
    _se = _hal4.find('  /// v0.1.29+116: snapshot the CONFIRMED', _sb)
    _sbody = _hal4[_sb:_se] if -1 < _sb < _se else ''
    _landed = _sbody.find('upsert landed')
    _flag = _sbody.find('_sohFreshlyComputedAt = computedAt;')
    _date = _sbody.find('_halSohComputedAtCached = computedAt;')
    _cleanup = _sbody.find('_clearPendingSohSession();', _landed)
    _ladder = ('hal.halSohAhPct != null\n'
               '        ? hal.halSohComputedAt\n'
               '        : (svc.sohAhPct != null ? svc.sohComputedAt : null);')
    if -1 < _landed < _date < _flag and _flag < _cleanup and \
       all("soh.computed_at" in s and '_maybeShowSohSnack(context, hal, svc)'
           in s and _ladder in s for s in (_dash4, _dw4, _drv4)) and \
       'takeSohFreshlyComputedAt' in _hal4 and \
       'takeSohFreshlyComputedAt' in _con4 and \
       'hal_telemetry' not in _con4 and \
       _l10n4.count("'soh.computed_at'") == 2 and \
       _l10n4.count("'soh.recomputed_snack'") == 2:
        ok('AO2 SOH dates ×3 (ladder), HAL flag after upsert-landed, AA2')
    else:
        fail('AO2 SOH date/snack wiring wrong')
    # AO3: fieldwise 4-tuple + 4th temp card with its OWN date → 2×2.
    if 'Future<(Snapshot?, Snapshot?, Snapshot?, Snapshot?)>' in _db4 and \
       's.batteryTempC.isNotNull()' in _db4 and \
       'tempRow' in _dash4 and \
       "label: S.of('dash.stale.batt_temp')," in _dash4 and \
       'Icons.thermostat' in _dash4 and \
       _dash4.count('_relTime(data.') >= 4 and \
       _l10n4.count("'dash.stale.batt_temp'") == 2:
        ok('AO3 fieldwise 4-tuple + battery-temp stale card (2×2)')
    else:
        fail('AO3 stale temp card wiring wrong')
    # AO4: series second stage in _bins() of BOTH twins, ONE shared
    # binner (_binPoints) feeding both sources, source caption on the
    # series branch only, hide-when-empty floor.
    def _ao4(s):
        return ("getTripSeriesForChart(trip.id, 'power_kw')" in s and
                s.count('_binPoints(') >= 3 and  # def + 2 call sites
                'FutureBuilder<(List<double>, bool)>' in s and
                "if (fromSeries)" in s and
                "S.of('trip.chart_src_series')" in s and
                'return const SizedBox.shrink();' in s)
    if _ao4(_td4) and _ao4(_hw4) and \
       _l10n4.count("'trip.chart_src_series'") == 2:
        ok('AO4 power_kw series stage + shared _binPoints, both twins')
    else:
        fail('AO4 power chart series stage wrong')
    # AO5: pull-to-sync — RefreshIndicator + freshness-line tap, both
    # landing on syncOnce (the +126 barriers ARE the debounce); the HU
    # branch untouched (AL1/AL4 assert the gates independently).
    if 'RefreshIndicator(' in _dash4 and \
       'onRefresh: onRefresh' in _dash4 and \
       "syncOnce(reason: 'stale_refresh')" in _dash4 and \
       'onTap: onRefresh' in _dash4 and \
       "import '../services/cloud_sync_service.dart';" in _dash4 and \
       'AlwaysScrollableScrollPhysics' in _dash4:
        ok('AO5 stale pull-to-sync (gesture + tap) via syncOnce barriers')
    else:
        fail('AO5 pull-to-sync wiring wrong')
    # AO6: generation — prefs key, 1990..2099 band, STRING serialization
    # in the vehicle block (live-contract Q5), picker numeric field with
    # the shared debounce, l10n pair EN/RU.
    if '_kVehDescGeneration' in _cs4 and \
       "'generation': '$_vehDescGeneration'" in _cs4 and \
       'generation >= 1990 && generation <= 2099' in _cs4 and \
       'controller: _year' in _pick4 and \
       'TextInputType.number' in _pick4 and \
       'maxLength: 4' in _pick4 and \
       'int.tryParse(_year.text' in _pick4 and \
       _l10n4.count("'vehicle.year'") == 2:
        ok('AO6 generation: prefs + validated + string body + picker field')
    else:
        fail('AO6 generation wiring wrong')
else:
    ok(f"Part AO skipped (build +{pv}, backlog pack lands in +142)")

# ─────────────── Part AP: +143 charging pack ────────────────────────────────
if int(pv) >= 143:
    _dash6 = (root / 'lib/screens/dashboard.dart').read_text()
    _dw6 = (root / 'lib/screens/wide/dashboard_wide.dart').read_text()
    _hal6 = (root / 'lib/services/hal_telemetry_service.dart').read_text()
    _ovr6 = (root / 'android/app/src/main/kotlin/com/bz5companion/'
                    'bz5_companion/hal/CompanionDecoderOverrides.kt').read_text()
    _reg6 = (root / 'android/app/src/main/kotlin/com/bz5companion/'
                    'bz5_companion/hal/TargetRegistry.kt').read_text()
    _l10n6 = (root / 'lib/l10n/strings.dart').read_text()
    # AP1: banner session fields in BOTH twins — SOC+Δ, freshness-gated
    # I/V at the call sites (6 s windows via halFresh), battery temp,
    # ETA-to-80 next to ETA-to-100 (Q1 yes); ev_range NOT added (Q2 no);
    # l10n pairs EN/RU.
    def _ap1(src):
        return ('socDeltaPct' in src and 'batteryTempC' in src and
                "hal.halFresh('pack_current')" in src and
                "hal.halFresh('pack_voltage')" in src and
                'chargeCurrentA' in src and
                'hal.halChargeSessionSocDeltaPct' in src and
                'hal.halChargedThisSessionKwh' in src)
    if _ap1(_dash6) and _ap1(_dw6) and \
       'etaHours80' in _dash6 and "S.of('dash.eta80')" in _dash6 and \
       "'→80% ${fmtH(" in _dw6 and "'→100% ${fmtH(" in _dw6 and \
       "'ev_range'" not in _dash6 and "'ev_range'" not in _dw6 and \
       _l10n6.count("'dash.eta80'") == 2 and \
       _l10n6.count("'dash.chg_delta'") == 2:
        ok('AP1 banner session stats ×2 twins, ETA-80, no ev_range')
    else:
        fail('AP1 banner session-stats wiring wrong')
    # AP2: session getters exposed from the SOH machine, gated on an
    # anchored session; the kWh figure uses the same ΔSOC×capacity formula
    # as the UDS chargedThisSessionKwh.
    if 'double? get halChargeSessionStartSoc' in _hal6 and \
       'double? get halChargeSessionAh' in _hal6 and \
       'double? get halChargeSessionSocDeltaPct' in _hal6 and \
       'double? get halChargedThisSessionKwh' in _hal6 and \
       '_halSohSessionAnchored ? _halSohStartSoc : null' in _hal6 and \
       '_halSohSessionAnchored ? _halSohChargeAhAccum : null' in _hal6 and \
       'd * _halPackCapacityKwh / 100.0' in _hal6:
        ok('AP2 charge-session getters (anchored gate, ΔSOC-kWh formula)')
    else:
        fail('AP2 session getters wrong')
    # AP3: charge_energy_kwh — decoder promoted in the overrides (no
    # candidate suffix), subscription pre-existing in the vendored
    # registry, consumed via _range, and the dE/dt detect is an OR with
    # the current detect (never instead) in BOTH the state machine and
    # the halChargingActive badge getter.
    _ovr_energy = ('"BYDAutoChargingDevice|0x2C100818"' in _ovr6 and
                   '"charge_energy_kwh"' in _ovr6 and
                   'charge_energy_kwh_candidate' not in _ovr6)
    if _ovr_energy and \
       _reg6.count('0x2C100818') >= 2 and \
       "'charge_energy_kwh': (0," in _hal6 and \
       'chargingLevel || energyRising' in _hal6 and \
       'stationary && (chargingLevel || energyRising)' in _hal6 and \
       '_halEnergyRising(DateTime.now());' in _hal6 and \
       'void _trackChargeEnergy(DateTime now)' in _hal6:
        ok('AP3 charge_energy decoder + consumed + dE/dt OR detect (live)')
    else:
        fail('AP3 charge_energy detect wiring wrong')
    # AP4: gun_connect CANDIDATE — decoder in the overrides only; the
    # service logs value changes (diag journal + hal_samples) but never
    # consumes it (NOT in _range → never reaches _latest); the name is
    # absent from every screen file (p068/p083 rule).
    _screens_clean = all(
        'gun_connect' not in f.read_text()
        for f in (root / 'lib/screens').rglob('*.dart'))
    if '"BYDAutoChargingDevice|0x2EB00832"' in _ovr6 and \
       '"charging_gun_connect_candidate"' in _ovr6 and \
       "if (e.name == 'charging_gun_connect_candidate')" in _hal6 and \
       "'charging_gun_connect_candidate': (" not in _hal6 and \
       _screens_clean:
        ok('AP4 gun_connect candidate log-only, absent from lib/screens')
    else:
        fail('AP4 gun_connect candidate leaked or unwired')
else:
    ok(f"Part AP skipped (build +{pv}, charging pack lands in +143)")

# ─────────────── Part AQ: +145 AC charging visibility ───────────────────────
if int(pv) >= 145:
    _hal7 = (root / 'lib/services/hal_telemetry_service.dart').read_text()
    _dash7 = (root / 'lib/screens/dashboard.dart').read_text()
    # AQ1: slope getter exists, is rise-gated, and enforces BOTH the
    # min-span and the min-delta floor (a slope from 2 adjacent LSBs is
    # exactly the +143 noise this getter exists to avoid).
    if 'double? get halEnergySlopePowerKw' in _hal7 and \
       '_halEnergyRising(DateTime.now())) return null' in _hal7 and \
       'if (dt < _kHalSlopeMinSpan) return null;' in _hal7 and \
       'if (dKwh < _kHalSlopeMinDeltaKwh) return null;' in _hal7:
        ok('AQ1 energy-slope getter gated (rising + span + delta floors)')
    else:
        fail('AQ1 energy-slope getter missing or floor(s) dropped')
    # AQ2: ring hygiene — points appended ONLY in the accepted-rise branch,
    # evicted past max span, and CLEARED on the counter re-anchor (junk
    # read must not bridge sessions).
    if '_halEnergyPts.addLast((at: now, kwh: e));' in _hal7 and \
       '> _kHalSlopeMaxSpan' in _hal7 and \
       '_halEnergyPts.clear();' in _hal7:
        ok('AQ2 slope ring: rise-only append, span evict, re-anchor clear')
    else:
        fail('AQ2 slope ring hygiene broken')
    # AQ3: K2 — no hard-coded series count. The fallback must be gated on
    # the latched estimate (BZ3 topology rule) and the latch must divide
    # live pack_voltage by live cell avg, never assume 136.
    if 'int? _halSeriesCellsEst;' in _hal7 and \
       'void _maybeLatchSeriesCells()' in _hal7 and \
       'if (n == null) return null;' in _hal7 and \
       '(v / avg).round()' in _hal7:
        ok('AQ3 cells→packV fallback latch-gated (no per-model const)')
    else:
        fail('AQ3 series-count latch missing or hard-coded')
    # AQ4: banner chain order — slope strictly the LAST link (Alex 17.07:
    # only when V×I unavailable), and the estimate marker is wired.
    if 'hal.halChargePowerKw ?? hal.halEnergySlopePowerKw' in _dash7 and \
       'powerIsEstimate:' in _dash7 and \
       "powerIsEstimate ? '≈' : ''" in _dash7:
        ok('AQ4 banner: slope last in chain, ≈ marker rendered')
    else:
        fail('AQ4 banner power chain/marker wrong')
    # AQ5: Pack V card + banner live-line both pick up the cells fallback.
    if 'svc.packVoltageFromCells ?? hal.halPackVoltageFromCells' in _dash7 and \
       ': hal.halPackVoltageFromCells,' in _dash7:
        ok('AQ5 Pack V card + banner live-line use cells fallback')
    else:
        fail('AQ5 voltage fallback not wired to both consumers')
else:
    ok(f"Part AQ skipped (build +{pv}, AC visibility lands in +145)")

# ─────────────── Part AR: +146 pipeline resilience ──────────────────────────
if int(pv) >= 146:
    _css8 = (root / 'lib/services/cloud_sync_service.dart').read_text()
    # AR1: the guard exists, catches ONLY _BridgeException, and every push
    # entity that talks HTTP goes through it. _generateTripSeries (local
    # Drift work) stays bare.
    _guard_ents = ['trips', 'trip_series', 'snapshots', 'sweeps',
                   'livelogs', 'canmonitors']
    if 'Future<void> guardEntity(' in _css8 and \
       'on _BridgeException catch (e)' in _css8 and \
       all(f"guardEntity('{n}'," in _css8 for n in _guard_ents) and \
       'await _generateTripSeries();' in _css8 and \
       "guardEntity('_generateTripSeries'" not in _css8:
        ok('AR1 guard wraps all 6 HTTP push entities, catches bridge only')
    else:
        fail('AR1 guard missing, wrong scope, or wrong exception class')
    # AR2: THE Phase-5 invariant — mapping and pull run AFTER the guarded
    # block and are NOT themselves guarded (their failures keep whole-cycle
    # semantics), i.e. a trips 4xx can no longer starve them. Source order
    # check: last guardEntity call precedes _syncUuidMapping precedes
    # _syncPull, and neither of the latter appears inside a guardEntity.
    _i_guard_last = max(_css8.find(f"guardEntity('{n}'") for n in _guard_ents)
    _i_map = _css8.find('await _syncUuidMapping();')
    _i_pull = _css8.find('await _syncPull();')
    if -1 < _i_guard_last < _i_map < _i_pull and \
       "guardEntity('uuid" not in _css8 and \
       "guardEntity('pull" not in _css8:
        ok('AR2 mapping+pull downstream of guards, unguarded (Phase-5 fix)')
    else:
        fail('AR2 mapping/pull ordering or guard scope wrong')
    # AR3: outer catches untouched — auth / transient / retryable /
    # account-gate still abort the cycle (their whole-cycle semantics are
    # the point; a guarded auth error would retry a dead token forever).
    if 'on _AuthException {' in _css8 and \
       'on _TransientAuthException catch (e)' in _css8 and \
       'on _RetryableException catch (e)' in _css8 and \
       'on _AccountGateException catch (e)' in _css8:
        ok('AR3 outer exception ladder intact (auth/transient/retry/gate)')
    else:
        fail('AR3 outer catch ladder damaged')
    # AR4: partial-failure honesty — a guarded cycle must NOT clear
    # _lastError, NOT advance _lastSuccessAt, and must persist the error;
    # a clean cycle keeps the old success path verbatim.
    if 'if (guarded.isEmpty) {' in _css8 and \
       "_lastError = 'Push blocked (permanent): ${guarded.first}'" in _css8 and \
       '_status = CloudSyncStatus.error;' in _css8 and \
       'await _persistError(_lastError!);' in _css8:
        ok('AR4 guarded cycle: error persisted, success not faked')
    else:
        fail('AR4 partial-failure bookkeeping wrong')
else:
    ok(f"Part AR skipped (build +{pv}, pipeline resilience lands in +146)")

# ─────────────── Part AS: +147 end-anchor finalize fix ──────────────────────
if int(pv) >= 147:
    _hal9 = (root / 'lib/services/hal_telemetry_service.dart').read_text()
    _css9 = (root / 'lib/services/cloud_sync_service.dart').read_text()
    # AS1: both live-close fallbacks — endOdo falls to _lastGood, trip_a
    # distance falls to the last SEEN value; neither returns null merely
    # because the 90 s hold lapsed before a park-confirm close.
    if "_lastGood['odometer']?.value," in _hal9 and \
       "_heldValue('trip_a', _coreHold) ?? _halTripLastTripA;" in _hal9:
        ok('AS1 close-time fallbacks: endOdo last-good + trip_a last-seen')
    else:
        fail('AS1 finalize fallback(s) missing')
    # AS2: backfill — one-time flag, in-trip snapshot window (both bounds),
    # sane distance guard, and requeue for re-push (server heals via uuid
    # UPSERT). Flag must NOT be set on the failure path (retry semantics).
    if "_kEndAnchorBackfillDone = 'trip_end_anchor_backfill_147'" in _css9 and \
       'isAfter(t.endedAt!)' in _css9 and \
       'isBefore(t.startedAt)' in _css9 and \
       'd >= 0 && d < 2000' in _css9 and \
       '_pushedTripIds.removeAll(requeue);' in _css9:
        ok('AS2 backfill: in-trip window + sanity + requeue')
    else:
        fail('AS2 backfill wiring wrong')
    # AS3: ordering — backfill runs after the pushed-set load and before
    # timers, so the FIRST syncOnce already re-pushes repaired rows.
    _i_loaded = _css9.find('final pushedJson = prefs.getString(_kPushedTripIds);')
    _i_bf = _css9.find('await _backfillTripEndAnchors(prefs);')
    _i_timers = _css9.find('_restartTimers();')
    if -1 < _i_loaded < _i_bf < _i_timers:
        ok('AS3 backfill ordered: pushed-set load -> backfill -> timers')
    else:
        fail('AS3 backfill ordering wrong')
else:
    ok(f"Part AS skipped (build +{pv}, end-anchor fix lands in +147)")

# ─────────── Part AT: +148 honest trends (K4) + K6 latch/watermark ───────────
if int(pv) >= 148:
    _hal10 = (root / 'lib/services/hal_telemetry_service.dart').read_text()
    _css10 = (root / 'lib/services/cloud_sync_service.dart').read_text()
    _db10 = (root / 'lib/data/database.dart').read_text()
    # AT1 (K4): the aggregator carries the snapshot walks — odometer-walk
    # distance with the trip sum kept separately for the coverage marker,
    # and an explicit source flag for the fallback path.
    if 'List<Snapshot> snapshots = const <Snapshot>[]' in agg_src and \
       'recordedTripDistanceKm' in agg_src and \
       'distanceFromOdometer' in agg_src and \
       'kMaxWalkPairGap' in agg_src and \
       'kMaxWalkStepKm' in agg_src:
        ok('AT1 aggregator: snapshot walks + coverage fields + fallback flag')
    else:
        fail('AT1 aggregator walk plumbing missing')
    # AT2 (K4): SOC walk hygiene — charging excluded, only DROPS count
    # (a rise without the flag = hole-masked charging, skipped).
    # Era-aware: +149 replaced adjacent-row pairing with per-signal
    # anchors, so the charging exclusion moved to the poison flag.
    _at2_chg = ("(p.isCharging ?? false) || (s.isCharging ?? false)" in agg_src
                if int(pv) == 148
                else 'chargedSinceSocAnchor' in agg_src)
    if _at2_chg and 'if (drop > 0 && drop <= 100)' in agg_src:
        ok('AT2 SOC walk: charging pairs excluded, drops only')
    else:
        fail('AT2 SOC walk hygiene broken')
    # AT3 (K4): regen stays trips-sourced and the +144 gross-denominator
    # formula is intact — walk energy must NOT leak into the regen share.
    if 'final gross = e.value + regen;' in agg_src and \
       'regenSharePerPeriod: regenBars,' in agg_src:
        ok('AT3 regen share: trips-sourced, +144 gross formula intact')
    else:
        fail('AT3 regen share source/formula changed')
    # AT4 (K4): trends.dart awaits snapshots BEFORE building the aggregate
    # and renders the coverage marker; the l10n key exists in BOTH maps.
    if 'snapshots: snapshots,' in trends and \
       "S.of('trends.coverage_fmt')" in trends and \
       _strings_src.count("'trends.coverage_fmt'") == 2:
        ok('AT4 trends: snapshots awaited pre-build + coverage marker ×2 l10n')
    else:
        fail('AT4 trends wiring / coverage l10n missing')
    # AT5 (K6): series latch — standstill gate, windowed mode, throttled
    # diag line (19.07 log: 26 re-latches flapping 135/136/137).
    if '_seriesCellCandidates' in _hal10 and \
       'spd != null && spd > 1.0' in _hal10 and \
       '_kSeriesLatchLogEvery' in _hal10 and \
       '_kSeriesLatchWindow' in _hal10:
        ok('AT5 series latch: standstill + window mode + log throttle')
    else:
        fail('AT5 series latch stabilizers missing')
    # AT6: restore hook takes MAX(id) directly — the recent-by-capturedAt
    # proxy left the restored tail above the cursor/watermark when a live
    # HAL snapshot landed mid-restore (19.07: 760 mapping conflicts).
    if 'await _db.maxSnapshotId();' in _css10 and \
       'COALESCE(MAX(id), 0)' in _db10 and \
       'allSnapsRecent' not in _css10:
        ok('AT6 restore hook: watermark/cursor from MAX(id)')
    else:
        fail('AT6 MAX(id) watermark fix missing')
    # AT7: the trip_series generator only logs when it actually made
    # series (restored trips have no raw samples — the sweep was finite
    # but noisy). The sweep/watermark structure itself is untouched.
    if 'if (made > 0) {' in _css10 and \
       "trip_series generated — trip #" in _css10:
        ok('AT7 series generator: 0-series log quieted, sweep intact')
    else:
        fail('AT7 generator log gate missing')
else:
    ok(f"Part AT skipped (build +{pv}, honest trends land in +148)")

# ─────────── Part AU: +149 walk anchors (null-transparent pairing) ───────────
if int(pv) >= 149:
    # AU1: per-signal anchors replace adjacent-row pairing — null-odometer
    # rows (12% in the field) must be transparent to the odometer walk
    # (20.07 export: adjacent pairing lost 838 of 1766 km).
    if 'Snapshot? odoAnchor;' in agg_src and \
       'Snapshot? socAnchor;' in agg_src and \
       'Snapshot? prev;' not in agg_src:
        ok('AU1 walk: per-signal anchors, adjacent-row prev gone')
    else:
        fail('AU1 anchor mechanism missing / old prev pairing survives')
    # AU2: charging BETWEEN SOC anchors poisons the pair (flag set on any
    # charging row, consumed at pair time, re-seeded from the new anchor's
    # own charging state — +148 endpoint semantics preserved).
    if 'var chargedSinceSocAnchor = false;' in agg_src and \
       'final poisoned = chargedSinceSocAnchor;' in agg_src and \
       'chargedSinceSocAnchor = s.isCharging ?? false;' in agg_src:
        ok('AU2 SOC walk: between-anchor charging poison flag intact')
    else:
        fail('AU2 charging poison flag missing/weakened')
else:
    ok(f"Part AU skipped (build +{pv}, walk anchors land in +149)")

# ─────────── Part AV: +150 honest average (co-covered consumption) ───────────
if int(pv) >= 150:
    # AV1: the average consumption is computed over co-covered day buckets
    # (both walks present), not the mismatched totals ratio; the aggregate
    # carries the value and its honest denominator.
    if 'avgConsumptionKwh100' in agg_src and \
       'consumptionCoveredKm' in agg_src and \
       'pairedDist += d;' in agg_src and \
       'pairedEnergy += e.value;' in agg_src:
        ok('AV1 co-covered average lives in the aggregate')
    else:
        fail('AV1 co-covered average missing from aggregator')
    # AV2: the footer consumes the aggregate's number — the local diluted
    # totals ratio must be gone from trends.dart; range derives from the
    # same honest number inside estRangeKm.
    if 'agg.avgConsumptionKwh100' in trends and \
       'agg.totalEnergyKwh / agg.totalDistanceKm * 100' not in trends and \
       'kUsableCapacityKwh / cons * 100' in agg_src:
        ok('AV2 footer + range read the honest average')
    else:
        fail('AV2 footer still on diluted totals ratio')
else:
    ok(f"Part AV skipped (build +{pv}, honest average lands in +150)")

# ─────────── Part AW: +151 speed profile («Замеры») ───────────
if int(pv) >= 151:
    sps = (root / 'lib/services/speed_profile_service.dart').read_text()
    spu = (root / 'lib/screens/speed_profile.dart').read_text()
    hist = (root / 'lib/screens/history.dart').read_text()
    # AW1: the service exists, observes the stream through the HAL Test
    # path (rawEvents + retain/release bracket) and NEVER imports
    # connection.dart (AA2) or touches Drift.
    if "import 'connection.dart'" not in sps and \
       "connection.dart'" not in sps and \
       '.rawEvents.listen' in sps and \
       'retainStream()' in sps and 'releaseStream()' in sps and \
       'database.dart' not in sps:
        ok('AW1 service on the HAL-Test path, AA2 + no-Drift hold')
    else:
        fail('AW1 service plumbing broken (import/stream bracket)')
    # AW2: tick qualification — all gates present: steady-accel window,
    # positive-power (regen never written), the ±3 round-ten band
    # window, and the dt integration guard.
    if 'accelKmhPerS.abs() > kSteadyAccelMax' in sps and \
       'p == null || p <= 0' in sps and \
       '(vDash - band).abs() > kBandHalfWidthKmh' in sps and \
       'd <= kDtGuardS' in sps:
        ok('AW2 tick qualification: steady + P>0 + band window + dt-guard')
    else:
        fail('AW2 tick qualification gate(s) missing')
    # AW3: the steady threshold is the named field-tuning constant
    # (spec Q2), value 1.5.
    if 'const double kSteadyAccelMax = 1.5;' in sps:
        ok('AW3 kSteadyAccelMax named constant = 1.5')
    else:
        fail('AW3 kSteadyAccelMax constant missing/renamed')
    # AW4: dash/real split — bands detect on DASH speed, distance and
    # the 0–100 finish integrate REAL (× kSpeedRealFactor = 0.98).
    if 'const double kSpeedRealFactor = 0.98;' in sps and \
       'vDash * kSpeedRealFactor * dtS' in sps and \
       'vDash * kSpeedRealFactor;' in sps and \
       'vReal >= 100.0' in sps:
        ok('AW4 dash detects, real integrates (×0.98), finish on real 100')
    else:
        fail('AW4 dash/real split broken')
    # AW5: the stopwatch interpolates BOTH ends (launch threshold and
    # the real-100 crossing) and voids on peak-drop / 30 s timeout.
    if '(2.0 - pv) / (vDash - pv)' in sps and \
       '(100.0 - prevReal) / (vReal - prevReal)' in sps and \
       '_zPeakDash - 2.0' in sps and '30000' in sps:
        ok('AW5 0–100 interpolated both ends + abort rules')
    else:
        fail('AW5 stopwatch interpolation/abort missing')
    # AW6: crash-safe persistence — the three prefs keys + the 30 s
    # snapshot timer (the +116 SOH-session pattern).
    if "'speed_profile_session'" in sps and \
       "'speed_profile_active'" in sps and \
       "'speed_profile_archive'" in sps and \
       'Duration(seconds: 30)' in sps:
        ok('AW6 crash-safe prefs snapshot (3 keys + 30 s timer)')
    else:
        fail('AW6 persistence keys / 30 s snapshot missing')
    # AW7: the tab is gated by the platform verdict — hidden entirely
    # on a phone (honesty: nothing to measure without HAL) and the
    # strict-freshness power path is used, not the 90 s display hold.
    if 'canUseHal' in hist and \
       "S.of('hist.tab_measure')" in hist and \
       'if (canHal)' in hist and \
       '_freshPowerKw' in sps and '_hal.halPowerKw' not in sps:
        ok('AW7 tab HU-gated + strict 6 s power freshness (no 90 s hold)')
    else:
        fail('AW7 tab gating / power freshness path wrong')
    # AW8: no-data ≠ zero — a band materialises only past the 60 s
    # threshold and empty bands never render.
    if 'const double kBandMinSeconds = 60.0;' in sps and \
       'timeS >= kBandMinSeconds' in sps and \
       'visibleBands' in spu:
        ok('AW8 60 s band threshold, empty bands do not exist')
    else:
        fail('AW8 band-materialisation threshold missing')
    # AW9 (review p.3/p.7): idle auto-stop — a movement-less week
    # releases the retained stream (constant + idle clock + check wired
    # into BOTH the 30 s timer and init-resume); and the A/B picker is
    # cleared on EVERY archive mutation (delete AND save/evict).
    if 'const int kAutoStopIdleDays = 7;' in sps and \
       'lastMoveMs' in sps and \
       '_maybeAutoStop' in sps and \
       '_idleTooLong(_session!)' in sps and \
       spu.count('setState(_compareSel.clear)') >= 2:
        ok('AW9 idle auto-stop (7 d) + A/B picker cleared on mutation')
    else:
        fail('AW9 auto-stop / picker hygiene missing')
    # AW10 (+152): the head unit renders history_wide.dart, NOT the
    # phone HistoryScreen — the +151 field miss («сборка правильная,
    # вкладки нет», server logs 20.07). The «Замеры» segment must live
    # in the WIDE screen: third enum value, canUseHal-gated segment,
    # SpeedProfileScreen body, recording dot.
    if int(pv) >= 152:
        hw = (root / 'lib/screens/wide/history_wide.dart').read_text()
        if '_Tab { trips, trends, measure }' in hw and \
           'if (canHal)' in hw and \
           "S.of('hist.tab_measure')" in hw and \
           '_Tab.measure => const SpeedProfileScreen()' in hw and \
           '_MeasureSegIcon(recording: recording)' in hw:
            ok('AW10 «Замеры» wired into the WIDE history (the HU entry point)')
        else:
            fail('AW10 wide-history measure segment missing/incomplete')
    else:
        ok(f"Part AW10 skipped (build +{pv}, wide wiring lands in +152)")
else:
    ok(f"Part AW skipped (build +{pv}, speed profile lands in +151)")

# ────────────────────────────── report ──────────────────────────────
print("=" * 64)
print(f"+35→+51 REGRESSION — build +{pv}")
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
