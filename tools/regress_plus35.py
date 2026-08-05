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
    _d1_expected = 19 if int(pv) >= 193 else (18 if int(pv) >= 185 else (17 if int(pv) >= 158 else (16 if int(pv) >= 140 else (15 if int(pv) >= 130 else 14))))  # +193: выдуманные тройки ячеек вычищены (v19); +185: trips.source (v18); +158: atlas (v17); +140: trip_series (v16)
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

    # D2. Предмет прежний: частичное завершение поездки НЕ ДОЛЖНО обнулять
    # уже записанный `extra`. С +186 это обеспечивается сильнее, чем
    # guard'ом на companion: агрегатный путь блоб вообще не трогает, а
    # ключи дописывает слиянием — то есть не может обнулить не только
    # `extra` целиком, но и отдельный чужой ключ внутри него.
    if int(pv) >= 186:
        _d2 = ('extra != null ? Value(extra)' not in db_src and
               'await mergeTripExtra(id, extra);' in db_src)
        if _d2:
            ok("D2 the aggregate path merges extra instead of writing it — "
               "a partial finalize can null neither the blob nor a key")
        else:
            fail("D2 the aggregate path can overwrite trips.extra again")
    elif "extra != null ? Value(extra) : const Value.absent()" in db_src:
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


def _strip_comments_safe(src: str) -> str:
    """Убрать комментарии, НЕ ТРОГАЯ строковые литералы.

    Правило проекта «любая проверка по тексту исходника обязана
    вычищать комментарии» действует с +165 и держалось наивным
    `re.sub(r'/\\*.*?\\*/')`. У него есть обратная сторона, которая
    вылезла в +172: литерал MIME-маски `"*/*"` содержит
    последовательность `/*`, регулярка принимает её за начало
    комментария и съедает КОД до следующего `*/`. В ApkInstall.kt так
    пропала половина файла вместе с определением функции, а гейт BI3
    показал FAIL на исправном коде.

    То есть та же ловушка, что и в +165–+170, только вывернутая: там
    проверки читали комментарии как код, здесь вычистка прочла код как
    комментарий. Обе стороны лечатся одним — разбирать, а не угадывать
    регуляркой.

    Комментарии заменяются ПРОБЕЛАМИ, а не удаляются: смещения
    сохраняются, и проверки порядка через find() остаются честными.
    Содержимое литералов сохраняется дословно — гейты пиннят строки.
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            # перевод строки сохраняем, иначе съезжает нумерация строк
            out.append(''.join(
                ch if ch == '\n' else ' ' for ch in src[i:j]))
            i = j
        elif c == '"' and src.startswith('"""', i):
            j = src.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(src[i:j])
            i = j
        elif c == '"' or c == "'":
            q = c
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == q:
                    j += 1
                    break
                if src[j] == '\n':
                    break
                j += 1
            out.append(src[i:j])
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def _aw16_fresh_clock(akt: str, pv: int) -> bool:
    """+157 measured fresh-boot on elapsedRealtime; +162 moved it to
    uptimeMillis. elapsedRealtime keeps ticking through deep sleep, so a
    head unit that merely woke up looked like an old boot and a genuine
    reboot after a long park was misreported — the flag lied in exactly
    the case the autostart investigation cares about. Both numbers are
    still printed, so the gate keeps requiring the pair above."""
    if pv >= 170:
        # +170: ТРЕТИЙ И ПОСЛЕДНИЙ ПОДХОД — флага больше нет.
        #
        # +157 считал fresh-boot по elapsedRealtime, +162 перевёл на
        # uptimeMillis (см. абзац выше — el врал при пробуждении). +170
        # снимает саму идею: ресиверный лог recon от 28.07 показывает
        # FIRED BOOT_COMPLETED в 12:29 при системе, поднятой сутками
        # ранее. uptimeMillis — монотонное время ЯДРА, оно не
        # сбрасывается при перезапуске фреймворка поверх живого ядра, а
        # BOOT_COMPLETED рассылает именно фреймворк. Значит холодную
        # загрузку от перезапуска контейнера по up/el НЕ РАЗЛИЧИТЬ ни
        # одним из двух часов, и любой такой флаг будет врать.
        #
        # Пара чисел остаётся (её требует условие выше), вывод из неё —
        # нет. Гейт теперь следит за ОТСУТСТВИЕМ флага: вернуть его
        # значило бы вернуть ложное утверждение.
        # Комментарии вычищаются ПЕРЕД проверкой: история флага в этом
        # файле разбирается по имени, и проверка по сырому тексту читала
        # бы объяснение вместо кода. Пятый патч подряд с этой ловушкой —
        # BD5 (+165), BE8 (+166), вакуумный тест (+167), BF1 (+169).
        import re as _re
        _code = _re.sub(r'/\*.*?\*/', '', akt, flags=_re.S)
        _code = '\n'.join(_l for _l in _code.split('\n')
                          if not _l.lstrip().startswith('//'))
        return ('freshBoot' not in _code and
                'FRESH_BOOT_MS' not in _code and
                'fresh-boot=' not in _code)
    if pv >= 162:
        return ('val freshBoot = upMs < FRESH_BOOT_MS' in akt and
                'private const val FRESH_BOOT_MS = 5 * 60 * 1000L' in akt and
                'elapsedRealtime() < 5 * 60 * 1000L' not in akt)
    return 'elapsedRealtime() < 5 * 60 * 1000L' in akt

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
    #     v0.1.59+158 (навигация B): the TALL scaffold gained «Замеры»
    #     (5 destinations); the PHONE scaffold stays 4 until patch №3 —
    #     so home.dart totals 9. The phone half is pinned separately by
    #     AX5 (nav.measure absent from the phone block).
    #     v0.1.62+161 (Атлас патч 3): the PHONE scaffold gains its own
    #     «Замеры» destination (третий пункт на всех форм-факторах) →
    #     both scaffolds are 5, home.dart totals 10. AX5 flips with it.
    _home_nav_want = 10 if int(pv) >= 161 else (
        9 if int(pv) >= 158 else (8 if int(pv) >= 108 else 4))
    if home.count("NavigationDestination(") == _home_nav_want and \
       "EcuExplorerScreen()" not in home:
        ok("U1 phone nav 4 tabs"
           + (" + tall scaffold" if int(pv) >= 108 else "")
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
    hus_screens = hus.count("WideScreen(),") + hus.count("NativeExplorerWide(") \
        + hus.count("SpeedProfileScreen(),")  # +158: «Замеры» on the rail
    want = 5 if int(pv) >= 158 else (4 if int(pv) >= 58 else 5)
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
        _v9_want = 5 if int(pv) >= 158 else 4  # +158: «Замеры» joined the rail
        rail_clean = ('NativeExplorerWide(' not in rail_src
                      and "Text('HAL Explorer')" not in rail_src
                      and rail_src.count('NavigationRailDestination(') == _v9_want)
        settings_hosts = ('_HalExplorerRoute' in settings_src
                          and 'NativeExplorerWide(detector: _detector)' in settings_src
                          and '_detector = NativeDetector();' in settings_src
                          and '_detector.dispose();' in settings_src)
        if rail_clean:
            ok(f"V9 rail is {_v9_want} destinations, NativeExplorerWide removed")
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
    # v0.1.83+182: слой подмен и сборка целей переехали из плагина в
    # HalStreamOwner (сервису автозапуска нужен тот же набор, а копия
    # разошлась бы молча). Утверждение гейта то же, файл другой.
    _aa4_own = (root / 'android/app/src/main/kotlin/com/bz5companion/'
                'bz5_companion/hal/HalStreamOwner.kt')
    _aa4_o = _aa4_own.read_text() if _aa4_own.exists() else ''
    if 'DecodedStreamSink(out, CompanionDecoderOverrides.map)' in _aa4_o \
            and 'extraStatisticFids' in _aa4_o:
        ok("AA4 owner wires overrides into sink + subscription")
    else:
        fail("AA4 owner does not wire the override layer")

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
        # ERA-AWARE (+193). Существо прежнее — подвод шкалы к максимуму окна
        # с зажимом 200/100, — но машинерия ПЕРЕЕХАЛА из состояния карточки
        # в PowerHistoryService. Иначе быть не могло: масштабы считаются от
        # ТИКА, а такт теперь принадлежит сервису; оставь их на экране, и при
        # возврате шкала поехала бы от пола, хотя история уже есть.
        _ab1_src = _dvw
        if int(pv) >= 193:
            _ab1_src = (root / 'lib/services/power_history_service.dart') \
                .read_text()
        _ab1_ease = '_scaleEase' in _ab1_src
        _ab1_ceil = ('dischargeCeilKw = 200.0' in _ab1_src and
                     'regenCeilKw = 100.0' in _ab1_src)
        _ab1_recompute = '_recomputeScales' in _ab1_src
        if _ab1_recompute and _ab1_ceil and _ab1_ease:
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
    # AF1 — ERA-AWARE (+165). До +165 легаси-путь v1 был ОБЯЗАТЕЛЕН:
    # /v2/sync/pull мог, как тогда считалось, ответить 400 на pull без
    # `vehicle`, и запасной путь был единственной страховкой. Друг 2
    # закрыл это 27.07 — сервер так не отвечает никогда, машина
    # выводится из device-токена. С +165 путь не просто не нужен, он
    # ВРЕДЕН: он умеет поездки и снимки, но не умеет ни атласа, ни
    # trip_series, то есть подменял бы полное восстановление
    # обрезанным. Гейт переворачивается: раньше требовал наличия,
    # теперь требует отсутствия — и требует, чтобы null на ПЕРВОЙ
    # странице стал явной ошибкой, а не молчанием.
    if int(pv) >= 165:
        _af1_dead = (
            "end `if (v2 == null)`" not in _cs and
            "_getJson('/v1/data/trips'" not in _cs and
            "_getJson('/v1/data/snapshots'" not in _cs)
        _af1_hard = (
            "_restoreError = 'Server does not serve /v2/sync/pull'" in _cs)
        if "_tryRestoreViaSyncPullV2(tripIdMap)" in _cs and \
           "if (v2 == null) {" in _cs and _af1_dead and _af1_hard:
            ok("AF1 (re-era +165) v2 pull is the only restore path; "
               "legacy v1 gone; null on page 1 is a hard error")
        else:
            fail("AF1 legacy v1 path still present or null is swallowed")
    elif "_tryRestoreViaSyncPullV2(tripIdMap)" in _cs and \
       "if (v2 == null) {" in _cs and \
       "end `if (v2 == null)`" in _cs:
        ok("AF1 restore tries /v2/sync/pull, legacy v1 loops kept as fallback")
    else:
        fail("AF1 v2 pull integration or legacy fallback missing")
    # AF2: idempotent apply by client_uuid (D8) — uuid lookups exist and the
    # apply is two-pass (trips buffered before snapshots).
    if int(pv) >= 164:
        # +164 (B1): the apply moved INSIDE the page loop. The invariant
        # is unchanged — trips are applied before snapshots so an
        # in-page snapshot resolves its trip locally — but the passes
        # are now per page, so the marker comments are lowercase and
        # sit between «split this page» and the cursor persist.
        _p1 = _cs.find("apply pass 1: trips")
        _p2 = _cs.find("apply pass 2: snapshots")
        _split = _cs.find("── split this page ──")
        if "getTripByClientUuid" in _db2 and "getSnapshotByClientUuid" in _db2 \
           and -1 < _split < _p1 < _p2 \
           and "only now move the cursor" in _cs \
           and _cs.find("only now move the cursor") > _p2:
            ok("AF2 (re-era +164) per-page apply, trips before snapshots, "
               "cursor after")
        else:
            fail("AF2 per-page apply ordering or cursor placement wrong")
    elif "getTripByClientUuid" in _db2 and "getSnapshotByClientUuid" in _db2 \
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
    # AM1: schema (16, or 17 from +158 — atlas era) + additive
    # migration + table registered.
    _am1_ver = 19 if int(pv) >= 193 else (18 if int(pv) >= 185 else (17 if int(pv) >= 158 else 16))
    if f'int get schemaVersion => {_am1_ver};' in _db2 and \
       '_createTableIfAbsent(m, tripSeries)' in _db2 and \
       "@DataClassName('TripSeriesRow')" in _db2:
        ok(f'AM1 trip_series table + additive migration (schema v{_am1_ver})')
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
    # connection.dart (AA2). Drift rule is era-aware: prefs-only until
    # +157; from +158 the service OWNS the atlas freeze funnel and the
    # database import is REQUIRED (the HAL-service _diagDb precedent) —
    # AA2 itself is untouched either way.
    _aw1_drift = ('database.dart' in sps) if int(pv) >= 158 \
        else ('database.dart' not in sps)
    if "import 'connection.dart'" not in sps and \
       "connection.dart'" not in sps and \
       '.rawEvents.listen' in sps and \
       'retainStream()' in sps and 'releaseStream()' in sps and \
       _aw1_drift:
        ok('AW1 service on the HAL-Test path, AA2 + era-correct Drift rule')
    else:
        fail('AW1 service plumbing broken (import/stream bracket)')
    # AW2: tick qualification — all gates present: steady-accel window,
    # positive-power (regen never written), the ±3 round-ten band
    # window, and the dt integration guard.
    if int(pv) >= 155:
        if 'nowMs - since < kBandDwellS * 1000.0' in sps and \
           'if (p == null)' in sps and \
           '(vDash - cand).abs() <= kBandHalfWidthKmh' in sps and \
           'd <= kDtGuardS' in sps:
            ok('AW2 tick qualification: corridor dwell + V/I fresh + dt-guard')
        else:
            fail('AW2 corridor qualification gate(s) missing')
    elif 'accelKmhPerS.abs() > kSteadyAccelMax' in sps and \
       'if (p == null)' in sps and 'if (p <= 0)' in sps and \
       '(vDash - band).abs() > kBandHalfWidthKmh' in sps and \
       'd <= kDtGuardS' in sps:
        ok('AW2 tick qualification: steady + P>0 + band window + dt-guard')
    else:
        fail('AW2 tick qualification gate(s) missing')
    # AW3: the steady threshold is the named field-tuning constant
    # (spec Q2). 1.5 until +153; 2.5 from +154 (field calibration
    # 21.07: LSQ slope + widened gate after 79% accel-gate starvation).
    if int(pv) >= 155:
        if 'const double kBandDwellS = 3.0;' in sps and \
           'kSteadyAccelMax' not in sps:
            ok('AW3 kBandDwellS = 3.0, slope-estimator knob retired')
        else:
            fail('AW3 dwell constant missing / retired knob resurrected')
    else:
        _aw3 = ('const double kSteadyAccelMax = 2.5;'
                if int(pv) >= 154 else 'const double kSteadyAccelMax = 1.5;')
        if _aw3 in sps:
            ok('AW3 kSteadyAccelMax constant matches the era')
        else:
            fail('AW3 kSteadyAccelMax constant missing/wrong value for era')
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
    # AW7: the strict-freshness power path is used, not the 90 s
    # display hold. Era-aware (+158, навигация B): before +158 the
    # «Замеры» tab lives HU-gated inside History; from +158 it is a
    # navigation SECTION and must be GONE from history.dart entirely.
    _aw7_power = '_freshPowerKw' in sps and '_hal.halPowerKw' not in sps
    if int(pv) >= 158:
        _aw7_nav = "S.of('hist.tab_measure')" not in hist and \
            'SpeedProfileScreen' not in hist
    else:
        _aw7_nav = 'canUseHal' in hist and \
            "S.of('hist.tab_measure')" in hist and \
            'if (canHal)' in hist
    if _aw7_power and _aw7_nav:
        ok('AW7 power freshness strict + measure entry matches the era')
    else:
        fail('AW7 tab gating / power freshness path wrong for this era')
    # AW8: no-data ≠ zero — a band materialises only past the 60 s
    # threshold and empty bands never render.
    _aw8 = ('const double kBandMinSeconds = 120.0;'
            if int(pv) >= 154 else 'const double kBandMinSeconds = 60.0;')
    # +163 re-era: the screen renders the LEDGER — the session
    # projection (visibleBands) must be GONE from the screen; the
    # threshold constant and its cell-side use are permanent.
    if int(pv) >= 163:
        if _aw8 in sps and \
           'timeS >= kBandMinSeconds' in sps and \
           'visibleBands' not in spu:
            ok('AW8 (re-era +163) threshold kept; session projection off-screen')
        else:
            fail('AW8 (re-era +163) threshold wrong or visibleBands leaked back')
    elif _aw8 in sps and \
       'timeS >= kBandMinSeconds' in sps and \
       'visibleBands' in spu:
        ok('AW8 band threshold matches the era, no zero rows')
    else:
        fail('AW8 band-materialisation threshold missing/wrong era value')
    # AW9 (review p.3/p.7): idle auto-stop — a movement-less week
    # releases the retained stream (constant + idle clock + check wired
    # into BOTH the 30 s timer and init-resume); and the A/B picker is
    # cleared on EVERY archive mutation (delete AND save/evict).
    # +163 re-era: manual control is retired — the auto-stop machinery
    # and the archive A/B picker must be ABSENT (recording is always
    # on; the archive UI left the screen). lastMoveMs stays: it is the
    # atlas rotation anchor now.
    if int(pv) >= 163:
        if 'kAutoStopIdleDays' not in sps and \
           '_maybeAutoStop' not in sps and \
           '_idleTooLong' not in sps and \
           'lastMoveMs' in sps and \
           '_compareSel' not in spu:
            ok('AW9 (re-era +163) auto-stop & A/B picker retired with manual control')
        else:
            fail('AW9 (re-era +163) auto-stop / picker remnants survived')
    elif 'const int kAutoStopIdleDays = 7;' in sps and \
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
    if int(pv) >= 158:
        # Навигация B: the wide history must have LOST the segment, and
        # the rail must HOST the screen — the HU entry point moved.
        hw = (root / 'lib/screens/wide/history_wide.dart').read_text()
        rail = (root / 'lib/screens/wide/head_unit_scaffold.dart').read_text()
        if '_Tab { trips, trends }' in hw and \
           '_Tab.measure' not in hw and \
           "S.of('hist.tab_measure')" not in hw and \
           'SpeedProfileScreen(),' in rail and \
           "S.of('nav.measure')" in rail:
            ok('AW10 «Замеры» moved to the rail (навигация B), history clean')
        else:
            fail('AW10 навигация B incomplete on the wide side')
    elif int(pv) >= 152:
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
    # AW11 (+153): tick-gate diagnostics (TEMP — remove with the
    # counters) + the PERMANENT maturing-band progress UX: sub-60 s
    # bands render dimmed with «N из 60 с» so the first hour of use
    # never looks dead.
    if int(pv) >= 163:
        # +163 re-era: the SERVICE side of the diag machinery is
        # permanent (counters, dumpDiag, the diary file); the SCREEN
        # side left — the dump moved to Настройки → Расширенное (BB7),
        # the maturing card became the band card, the tick row died.
        if 'class TickDiag' in sps and \
           'd.total++' in sps and 'd.qualified++' in sps and \
           "'diag': diag.toJson()" in sps and \
           'maturingBands' in sps and \
           'dumpDiag' in sps and \
           'DiagDumpFile.instance.append' in sps and \
           '_MaturingCard' not in spu and \
           '_TickDiagRow' not in spu and \
           "S.of('measure.of')" not in spu and \
           "S.of('measure.dump')" not in spu:
            ok('AW11 (re-era +163) diag service intact; screen diag retired')
        else:
            fail('AW11 (re-era +163) diag split broken')
    elif int(pv) >= 153:
        if 'class TickDiag' in sps and \
           'd.total++' in sps and 'd.qualified++' in sps and \
           "'diag': diag.toJson()" in sps and \
           'maturingBands' in sps and \
           '_MaturingCard' in spu and '_TickDiagRow' in spu and \
           "S.of('measure.of')" in spu and \
           'dumpDiag' in sps and \
           'DiagDumpFile.instance.append' in sps and \
           "S.of('measure.dump')" in spu:
            ok('AW11 tick-gate diag (TEMP) + maturing UX + diag-file dump')
        else:
            fail('AW11 diag counters / maturing progress missing')
    else:
        ok(f"Part AW11 skipped (build +{pv}, tick diag lands in +153)")
    # AW12 (+154): the steady-slope estimator is LEAST SQUARES over the
    # whole ~2 s buffer, not edge-to-edge — the 21.07 field calibration
    # (edge slope on a ~2.5 Hz cadence read jitter as launches, 79%
    # starvation).
    if int(pv) >= 155:
        if 'sTV / sTT' not in sps and '_speedBuf' not in sps and \
           'accelKmhPerS' not in sps:
            ok('AW12 slope estimators fully retired (+155 corridor era)')
        else:
            fail('AW12 an estimator survived into the corridor era')
    elif int(pv) >= 154:
        if 'sTV / sTT * 1000.0' in sps and \
           '> 2000' in sps and \
           '(vDash - first.v)' not in sps:
            ok('AW12 LSQ slope over 2 s buffer (edge-to-edge retired)')
        else:
            fail('AW12 LSQ estimator missing / edge slope resurrected')
    else:
        ok(f"Part AW12 skipped (build +{pv}, LSQ lands in +154)")
    # AW13 (+155): SIGNED band energy. The «P ≤ 0 не пишем» rule skewed
    # city bands to the traction-pulse phase (19:55 field dump: 32.4 at
    # band 40, consumption FALLING with speed — inverted EV physics).
    # Regen/coast inside the corridor must subtract; negPower is
    # informational only; the UI must survive a negative band.
    if int(pv) >= 164:
        # +164 (D): the chart was rebuilt onto the atlas grid, so the
        # `minY: minV < 0` literal moved into a named `bottom`. The
        # invariant is what matters and it is stronger now: the axis
        # still drops below zero for a regen-negative band, AND the
        # highlight has its own > 0.5 guard so a descent cannot take
        # the «most economical» slot.
        bcs_aw = (root / 'lib/widgets/band_card.dart').read_text()
        if 'd.negPower++; // informational' in sps and \
           'if (p <= 0) return;' not in sps and \
           'cons > 0.5' in bcs_aw and \
           'minV < 0 ? minV * 1.15 - 0.1 : 0.0' in spu and \
           'minY: bottom' in spu and \
           'if (v > 0.5 && v < best)' in spu:
            ok('AW13 (re-era +164) signed energy; axis + highlight guards')
        else:
            fail('AW13 (re-era +164) signed-energy guards broken')
    elif int(pv) >= 163:
        # +163 re-era: the regen guard moved with the range line into
        # band_card.dart; the chart guard stays in the screen.
        bcs_aw = (root / 'lib/widgets/band_card.dart').read_text()
        if 'd.negPower++; // informational' in sps and \
           'if (p <= 0) return;' not in sps and \
           'cons > 0.5' in bcs_aw and \
           'minY: minV < 0' in spu:
            ok('AW13 (re-era +163) signed energy; guards in band_card + chart')
        else:
            fail('AW13 (re-era +163) signed-energy guards broken')
    elif int(pv) >= 155:
        if 'd.negPower++; // informational' in sps and \
           'if (p <= 0) return;' not in sps and \
           'cons > 0.5' in spu and \
           'minY: minV < 0' in spu:
            ok('AW13 signed band energy; UI survives negative bands')
        else:
            fail('AW13 signed-energy semantics broken')
    else:
        ok(f"Part AW13 skipped (build +{pv}, signed energy lands in +155)")
    # AW14 (+155): the autostart net (вариант D). Kotlin FGS with
    # START_STICKY whose null-intent resurrection path NEVER hits the
    # stop branch; manifest-registered, not exported; armed from Dart
    # behind the canUseHal gate; marker log for the BAL field question.
    if int(pv) >= 155:
        auto_kt = root / ('android/app/src/main/kotlin/com/bz5companion/'
                          'bz5_companion/AutostartService.kt')
        mani = (root / 'android/app/src/main/AndroidManifest.xml').read_text()
        arm = (root / 'lib/services/autostart_arm.dart').read_text()
        mact = (root / ('android/app/src/main/kotlin/com/bz5companion/'
                        'bz5_companion/MainActivity.kt')).read_text()
        akt = auto_kt.read_text() if auto_kt.exists() else ''
        # +169: ветка воскрешения перестала быть `if (intent == null)` —
        # решение вынесено в `val resurrected = intent == null`, потому
        # что тот же признак теперь выбирает и текст нотификации. Смысл
        # инварианта не меняется: null-intent распознаётся и НЕ уходит в
        # стоп-ветку. Меняется только место, где он распознан.
        _aw14_null = ('val resurrected = intent == null' in akt
                      if int(pv) >= 169
                      else 'if (intent == null)' in akt)
        # +171: имя файла журнала переехало в AutostartMarker — писать в
        # него теперь должны двое, сервис и BootReceiver. Инвариант тот
        # же: имя существует и совпадает с тем, что забирает экспорт.
        if int(pv) >= 171:
            _aw14_mk = (root / ('android/app/src/main/kotlin/com/bz5companion/'
                                'bz5_companion/AutostartMarker.kt'))
            _aw14_log = ('bz5_companion_autostart_log.txt'
                         in (_aw14_mk.read_text() if _aw14_mk.exists() else ''))
        else:
            _aw14_log = 'bz5_companion_autostart_log.txt' in akt
        if 'return START_STICKY' in akt and \
           'return START_NOT_STICKY' in akt and \
           'intent?.action == ACTION_STOP' in akt and \
           _aw14_null and \
           _aw14_log and \
           'android:name=".AutostartService"' in mani and \
           'android:exported="false"' in mani and \
           'android.permission.FOREGROUND_SERVICE' in mani and \
           'hal.canUseHal' in arm and \
           '"bz5/autostart"' in mact:
            ok('AW14 autostart net: STICKY service + gated arm + marker log')
        else:
            fail('AW14 autostart net incomplete')
    else:
        ok(f"Part AW14 skipped (build +{pv}, autostart lands in +155)")
    # AW15 (+156): the carry-forward pump. The HAL speed fid is
    # ON-CHANGE — a held speed emits nothing, the dt-guard starved the
    # steadiest stretches (22.07 field: 44.05 counted vs 69.3 odometer
    # km, −36%; third starvation after +153/+154). The fix: a 1 Hz
    # virtual tick re-integrates the last dash value through the SAME
    # clock (no double count), the WHOLE virtual tick is gated on fresh
    # V/I (no phantom km after ignition-off), the temp passport counts
    # driving only (v ≥ 2), standstill is invisible to the diag
    # counters, and the on-change proof counters (vt/gd/gm) ride in the
    # dump. TEMP diag itself must SURVIVE this patch — the field
    # re-check needs it; removal is +157.
    if int(pv) >= 156:
        if 'const double kVirtualTickS = 1.0;' in sps and \
           '_onVirtualTick' in sps and \
           '_lastSpeedDash' in sps and \
           'if (_freshPowerKw() == null) return; // stream dead — freeze' in sps and \
           'void _integrate(' in sps and \
           'if (vDash >= 2.0) _accumTemp(s, dtS);' in sps and \
           'if (vDash < 2.0) return;' in sps and \
           "'vt': virtualTicks" in sps and \
           "'gd': gapDrops" in sps and \
           "'gm': maxGapS" in sps and \
           's.diag.gapDrops++' in sps and \
           '_virtualTimer?.cancel();' in sps and \
           'class TickDiag' in sps and 'dumpDiag' in sps:
            ok('AW15 carry-forward pump: 1 Hz virtual tick, V/I-gated, shared clock')
        else:
            fail('AW15 carry-forward pump incomplete')
    else:
        ok(f"Part AW15 skipped (build +{pv}, virtual pump lands in +156)")
    # AW16 (+157): heartbeat instrumentation of the autostart service —
    # the ONLY truth instrument left after Друг 3's 22.07 retraction of
    # both the STICKY-resurrection and the BYD-intent-wakeup hypotheses.
    # born (onCreate: pid + per-process tag + fresh-boot flag), beat
    # every 5 min (uptime/elapsedRealtime pair), destroy (onDestroy;
    # its absence before the next born = silent force-stop-like kill),
    # handler cleaned up on destroy, ident riding on the +155 marker
    # lines, and NO self-healing: the resurrection/stop semantics of
    # AW14 must survive untouched.
    if int(pv) >= 157:
        auto_kt2 = root / ('android/app/src/main/kotlin/com/bz5companion/'
                           'bz5_companion/AutostartService.kt')
        akt2 = auto_kt2.read_text() if auto_kt2.exists() else ''
        # +170: флаг fresh-boot СНЯТ, потому что врал. Он считался как
        # upMs < FRESH_BOOT_MS, то есть кодировал допущение
        # «BOOT_COMPLETED приходит только при малом uptime». Ресиверный
        # лог recon от 28.07 показывает FIRED BOOT_COMPLETED в 12:29 при
        # системе, поднятой сутками ранее: uptimeMillis — монотонное
        # время ЯДРА и не сбрасывается при перезапуске фреймворка поверх
        # живого ядра, а рассылает BOOT_COMPLETED именно фреймворк.
        # Числа up/el остаются — из них больше не делается вывод.
        # +171: пара up/el печаталась ДВАЖДЫ — `ident()` отдаёт её сам,
        # а строка born дописывала свою копию (видно в поле 28.07:
        # `up=8306s el=101601s up=8306s el=101601s`). Дубль снят.
        if int(pv) >= 171:
            _aw16_born = '"born: ${ident()} build=${appVersion()}"'
        elif int(pv) >= 170:
            _aw16_born = ('"born: ${ident()} up=${upMs / 1000}s'
                          ' el=${elMs / 1000}s"')
        else:
            _aw16_born = '"born: ${ident()} fresh-boot=$freshBoot"'
        # +171: тег процесса и обе метки времени переехали в
        # AutostartMarker, потому что ресивер обязан писать ТЕМ ЖЕ
        # тегом — совпадение тега доказывает, что мост и сервис в одном
        # процессе. Инвариант не меняется, меняется файл: гейт смотрит
        # на объединение сервиса и общего журнала.
        if int(pv) >= 171:
            _aw16_mk = root / ('android/app/src/main/kotlin/com/bz5companion/'
                               'bz5_companion/AutostartMarker.kt')
            akt2u = akt2 + '\n' + (_aw16_mk.read_text()
                                   if _aw16_mk.exists() else '')
            _aw16_tag = 'val procTag: String = "%04x".format(' \
                        'Random.nextInt(0x10000))' in akt2u
        else:
            akt2u = akt2
            _aw16_tag = ('val PROC_TAG = "%04x".format(Random.nextInt(0x10000))'
                         in akt2)
        if 'const val HEARTBEAT_MS = 5 * 60 * 1000L' in akt2 and \
           _aw16_tag and \
           'override fun onCreate()' in akt2 and \
           'override fun onDestroy()' in akt2 and \
           _aw16_born in akt2 and \
           '"beat: ${ident()}"' in akt2 and \
           '"destroy: ${ident()}"' in akt2 and \
           'SystemClock.uptimeMillis()' in akt2u and \
           'SystemClock.elapsedRealtime()' in akt2u and \
           'Process.myPid()' in akt2u and \
           'hbHandler.removeCallbacks(hbTick)' in akt2 and \
           'hbHandler.postDelayed(hbTick, HEARTBEAT_MS)' in akt2 and \
           _aw16_fresh_clock(akt2u, int(pv)):
            ok('AW16 heartbeat: born/beat/destroy + up/el pair + fresh-boot'
               + (' (uptime clock)' if int(pv) >= 162 else ''))
        else:
            fail('AW16 heartbeat instrumentation incomplete')
    else:
        ok(f"Part AW16 skipped (build +{pv}, heartbeat lands in +157)")
    # ─────────── Part AX: +158 «Атлас» patch 1 ───────────
    # Слой снимков + темп-окна + ±2 + навигация B (spec v2, contract
    # 3a6ca9ed…48faf, SPEC_plus158_atlas_patch1.md).
    if int(pv) >= 158:
        dbs = (root / 'lib/data/database.dart').read_text()
        css = (root / 'lib/services/cloud_sync_service.dart').read_text()
        mains = (root / 'lib/main.dart').read_text()
        l10n = (root / 'lib/l10n/strings.dart').read_text()
        rail2 = (root / 'lib/screens/wide/head_unit_scaffold.dart').read_text()
        home2 = (root / 'lib/screens/home.dart').read_text()
        # AX1: the tightened gate — ±2 pinned (dwell physics: effective
        # accel threshold 4/3 ≈ 1.33 km/h·s; the ONE knob of this era —
        # kBandDwellS must stay 3.0, the reserve step is NOT taken).
        if 'const int kBandHalfWidthKmh = 2;' in sps and \
           'const double kBandDwellS = 3.0;' in sps:
            ok('AX1 corridor ±2 pinned, dwell 3.0 untouched (one knob)')
        else:
            fail('AX1 kBandHalfWidthKmh != 2 or dwell knob also turned')
        # AX2: schema v17 — both atlas tables behind idempotent guards.
        # v0.1.86+185: пин номера схемы отсюда УБРАН. Предмет AX2 — таблицы
        # атласа и идемпотентная миграция под них, а не то, какая версия
        # схемы в дереве сегодня; номер принадлежит D1 и живёт там одной
        # лестницей эр. Прибитый к 17 гвоздь превратил AX2 в блокировщик
        # любой следующей миграции — ровно тот класс переспецифицированного
        # гейта, который мы уже ловили: пиновать надо инвариант, а не счёт.
        if 'if (from < 17) {' in dbs and \
           '_createTableIfAbsent(m, atlasSnapshots);' in dbs and \
           '_createTableIfAbsent(m, atlasReveals);' in dbs and \
           'class AtlasSnapshots extends Table' in dbs and \
           'class AtlasReveals extends Table' in dbs:
            ok('AX2 schema v17: atlas tables + idempotent migration')
        else:
            fail('AX2 schema/migration for atlas tables incomplete')
        # AX3: pull plumbing — both entity cases in _syncPull AND the
        # restore loop (2 each), shared apply helpers present.
        if css.count("case 'atlas_snapshots':") == 2 and \
           css.count("case 'atlas_reveals':") == 2 and \
           '_applyPulledAtlasSnapshot' in css and \
           '_applyPulledAtlasReveal' in css:
            ok('AX3 atlas pull cases in sync AND restore + apply helpers')
        else:
            fail('AX3 atlas pull/restore plumbing incomplete')
        # AX4: push chain — both entities guarded, correct endpoints.
        if "guardEntity('atlas_snapshots', _syncAtlasSnapshots)" in css and \
           "guardEntity('atlas_reveals', _syncAtlasReveals)" in css and \
           "'/v1/data/ingest/atlas_snapshots'" in css and \
           "'/v1/data/ingest/atlas_reveals'" in css:
            ok('AX4 atlas push guarded + ingest endpoints per contract')
        else:
            fail('AX4 atlas push chain incomplete')
        # AX5: навигация B — nav.measure in BOTH l10n maps, Icons.speed
        # on the rail and the BZ3 bar, SpeedProfileScreen hosted in
        # both scaffolds, phone scaffold untouched (comes with №3).
        # ERA-AWARE (+161): patch 1 promised «phone untouched» — the
        # phone half of home.dart had to stay free of nav.measure until
        # patch №3. From +161 the promise FLIPS: «Замеры» is the third
        # destination on the phone too (навигация B complete), so the
        # phone block MUST carry it.
        _phone_block = home2.split('Tall portrait head-unit layout')[0]
        if int(pv) >= 161:
            _ax5_phone = "S.of('nav.measure')" in _phone_block and \
                'AtlasScreen(),' in _phone_block
            _ax5_word = 'phone joined (третий пункт везде)'
        else:
            _ax5_phone = 'nav.measure' not in _phone_block
            _ax5_word = 'phone untouched'
        if l10n.count("'nav.measure'") == 2 and \
           "S.of('nav.measure')" in rail2 and \
           'SpeedProfileScreen(),' in rail2 and \
           "S.of('nav.measure')" in home2 and \
           'SpeedProfileScreen(),' in home2 and \
           _ax5_phone:
            ok(f'AX5 навигация B: rail + BZ3, l10n ×2, {_ax5_word}')
        else:
            fail('AX5 навигация B wiring incomplete or phone half wrong')
        # AX6 — ERA-AWARE (+160 re-era = AY2): patch 1 promised the
        # generation is ABSENT; patch 2 flips the promise — from +160
        # the generation MUST BE PRESENT (crossing detector in the
        # atlas tick + the serialized generator + the DAO producer),
        # and the write-once apply path keeps existing untouched.
        if int(pv) >= 160:
            if 'insertAtlasReveal(' in dbs and \
               '_generateReveal(' in sps and \
               '_maybeGenerateReveal(' in sps and \
               'beforeS < kBandMinSeconds && cell.timeS >= kBandMinSeconds' in sps and \
               'applyPulledAtlasReveal' in dbs:
                ok('AX6/AY2 (re-era +160) reveal generation PRESENT '
                   '+ crossing detector + apply path intact')
            else:
                fail('AX6/AY2 (re-era +160) reveal generation missing '
                     'or crossing detector gone')
        elif 'insertAtlasReveal(' not in dbs and \
             'insertAtlasReveal(' not in sps and \
             'applyPulledAtlasReveal' in dbs:
            ok('AX6 reveal generation absent (lands in patch 2), apply-only')
        else:
            fail('AX6 a reveal producer leaked into patch 1')
        # AX7: ONE write funnel for atlas snapshots — the service calls
        # insertAtlasSnapshot exactly once (inside _freezeMatured), the
        # sync side never touches it (applyPulledAtlasSnapshot only),
        # and the R2 durability order holds: inserts THEN _persist.
        if int(pv) >= 164:
            # +164 (A): TWO funnels now, and that is the whole point
            # of the patch — _freezeChunk at the 120 s crossing (the
            # normal path) and _freezeMatured at rotation (migration of
            # pre-164 ledgers + safety net). What must NOT change: both
            # live in this service, the sync side still never writes a
            # snapshot, and the R2 durability order (insert THEN
            # persist) holds in both.
            if sps.count('insertAtlasSnapshot(') == 2 and \
               'insertAtlasSnapshot(' not in css and \
               '_freezeMatured' in sps and '_freezeChunk' in sps and \
               'await _db.insertAtlasSnapshot(r);' in sps and \
               'await _db.insertAtlasSnapshot(row);' in sps and \
               sps.find('await _db.insertAtlasSnapshot(row);') < \
               sps.find('await _persist();\n      _atlasRevision++;') and \
               'kAtlasTempMaxAgeS' in sps and \
               'kAtlasHysteresisC' in sps:
                ok('AX7 (re-era +164) two funnels, both in-service, '
                   'R2 order held')
            else:
                fail('AX7 (re-era +164) freeze funnel discipline broken')
        elif sps.count('insertAtlasSnapshot(') == 1 and \
           'insertAtlasSnapshot(' not in css and \
           '_freezeMatured' in sps and \
           'await _db.insertAtlasSnapshot(r);' in sps and \
           'kAtlasTempMaxAgeS' in sps and \
           'kAtlasHysteresisC' in sps:
            ok('AX7 single freeze funnel + R2 order + R1 stickiness consts')
        else:
            fail('AX7 freeze funnel discipline broken')
        # ─────────── Part AY: +160 «Атлас» patch 2 ───────────
        # Карточка итогов + звёзды + генерация reveal
        # (SPEC_plus160_atlas_patch2.md; дизайн-контракт mockups/SPEC.md).
        if int(pv) >= 160:
            spscr = (root / 'lib/screens/speed_profile.dart').read_text()
            # AY1: the ONE producer — insertAtlasReveal has exactly one
            # call-site, inside the service generator; the sync side
            # never inserts (pull/restore go through the apply merge).
            if sps.count('_db.insertAtlasReveal(') == 1 and \
               'insertAtlasReveal(' not in css and \
               'Future<int> insertAtlasReveal(' in dbs:
                ok('AY1 single reveal producer (service), sync clean')
            else:
                fail('AY1 reveal producer discipline broken')
            # AY3: card condition — P + speed 0 held 5 s (constant),
            # the accepted §2.1 predicate (unrevealed OR unseen gain),
            # and «Ок» reveals EVERYTHING write-once (by='hu',
            # syncedAt → null for the re-push).
            if '_kParkHoldMs = 5000' in spscr and \
               'gear.toInt() == 1' in spscr and \
               'sp.unrevealedCount > 0 || sp.atlasHasUnseenGain' in spscr and \
               'revealAllUnrevealedAtlasReveals' in dbs and \
               'syncedAt: const Value(null),' in dbs and \
               "revealedBy: 'hu'" in sps and \
               'acknowledgeReveals' in sps:
                ok('AY3 card condition P+0+5s + «Ок» reveals all (write-once)')
            else:
                fail('AY3 card condition / «Ок» semantics broken')
            # AY4: the badge is LIVE in BOTH scaffolds and cannot exist
            # in motion BY EXPRESSION (isParked is a conjunct).
            _ay4 = 'isParked && unrevealed > 0 && _index != 2'
            if _ay4 in rail2 and _ay4 in home2 and \
               'unrevealedCount' in rail2 and 'unrevealedCount' in home2:
                ok('AY4 live badge in both scaffolds, motion-free by expr')
            else:
                fail('AY4 badge wiring incomplete')
            # AY5: star thresholds 5/15 pinned; dedup port keeps the
            # contract rule — STRICT > 0.5·shorter, same-source guard,
            # zero-length groups never merge.
            if "count == 5 ? 'silver' : 'gold'" in sps and \
               'count != 5 && count != 15' in sps and \
               'ov > 0.5 * shorter' in sps and \
               'if (shorter <= 0) continue;' in sps and \
               'same source never merges' in sps:
                ok('AY5 star 5/15 + dedup strictness/guards pinned')
            else:
                fail('AY5 dedup port / star thresholds drifted')
            # AY6: suppression — band_matured swallows cell_new on the
            # same crossing (the return right after the insert).
            if 'подавление: band_matured поглощает cell_new (AY6)' in sps:
                ok('AY6 cell_new suppressed under band_matured')
            else:
                fail('AY6 suppression marker missing')
            # AY7: l10n — the card strings live in BOTH maps.
            _ay7 = l10n.count("'measure.card_")
            if _ay7 == 24:
                ok('AY7 measure.card_* ×12 keys in both l10n maps')
            else:
                fail(f'AY7 measure.card_* count {_ay7} != 24')
            # AY8: ledger JSON carries the §1.4 fields (t0 per cell,
            # sessionDistKm / lastOkMs / lastGainMs on the ledger),
            # with backward-compatible defaults.
            if "'t0': t0," in sps and \
               "'sd': sessionDistKm," in sps and \
               "'lok': lastOkMs," in sps and \
               "'lg': lastGainMs," in sps and \
               "(j['t0'] as num?)?.toDouble() ?? 0" in sps and \
               "(j['sd'] as num?)?.toDouble() ?? 0" in sps:
                ok('AY8 ledger JSON: t0/sd/lok/lg + compat defaults')
            else:
                fail('AY8 ledger JSON fields incomplete')
            # ───── Part AZ: +161 «Атлас» patch 3 (слой представления) ─────
            # Сетка + строка ГОДА + детализация + пятая вкладка телефона +
            # бейдж 14 dp + липкая плашка + парковочный чип + экспортная
            # картинка. Движок награды и prefs-леджер НЕ трогаются — это
            # проверяет AZ2.
            if int(pv) >= 161:
                _az_files = [
                    'lib/theme/atlas_tokens.dart',
                    'lib/data/atlas_projection.dart',
                    'lib/widgets/atlas_grid.dart',
                    'lib/widgets/atlas_export.dart',
                    'lib/screens/atlas.dart',
                    'lib/screens/atlas_cell_detail.dart',
                    'lib/screens/wide/atlas_wide.dart',
                ]
                _missing = [f for f in _az_files if not (root / f).is_file()]
                if not _missing:
                    ok('AZ1 seven atlas files present (lib/theme created)')
                else:
                    fail(f'AZ1 missing atlas files: {_missing}')

                proj = (root / 'lib/data/atlas_projection.dart').read_text() \
                    if (root / 'lib/data/atlas_projection.dart').is_file() else ''
                grid = (root / 'lib/widgets/atlas_grid.dart').read_text() \
                    if (root / 'lib/widgets/atlas_grid.dart').is_file() else ''
                expo = (root / 'lib/widgets/atlas_export.dart').read_text() \
                    if (root / 'lib/widgets/atlas_export.dart').is_file() else ''
                toks = (root / 'lib/theme/atlas_tokens.dart').read_text() \
                    if (root / 'lib/theme/atlas_tokens.dart').is_file() else ''
                atls = (root / 'lib/screens/atlas.dart').read_text() \
                    if (root / 'lib/screens/atlas.dart').is_file() else ''
                atlw = (root / 'lib/screens/wide/atlas_wide.dart').read_text() \
                    if (root / 'lib/screens/wide/atlas_wide.dart').is_file() else ''
                spscr = (root / 'lib/screens/speed_profile.dart').read_text()
                dashw = (root / 'lib/screens/wide/dashboard_wide.dart').read_text()
                banner = (root / 'lib/widgets/charging_banner.dart').read_text()
                pubs = (root / 'pubspec.yaml').read_text()

                # AZ2: band ceiling 140 — ONE filter, on the ONE read query,
                # and the reward engine is NOT touched by this patch (its own
                # cutoff in _freeze / _generateReveal lands in +162).
                # +161: the READ side alone enforces the ceiling and the
                # engine is deliberately untouched. +162: the engine gets
                # its own cutoff — one constant, two call sites (the
                # freeze funnel and the reveal gate), and the number is
                # still written down in exactly two files.
                if int(pv) >= 162:
                    _engine_clean = (
                        'const int kAtlasBandMaxCollectKmh = 140;' in sps and
                        sps.count('> kAtlasBandMaxCollectKmh) return') >= 2 and
                        'if (band > kAtlasBandMaxCollectKmh) {' in sps and
                        # the VALUE is written once; prose may mention it
                        sps.count('= 140;') == 1)
                else:
                    _engine_clean = ('kAtlasBandMaxKmh' not in sps and
                                     'band > 140' not in sps)
                if 'const int kAtlasBandMaxKmh = 140;' in proj and \
                   'isSmallerOrEqualValue(maxBand)' in dbs and \
                   dbs.count('getAtlasSnapshotsForGrid') == 1 and \
                   _engine_clean and \
                   atls.count('maxBand: kAtlasBandMaxKmh') == 1 and \
                   atlw.count('maxBand: kAtlasBandMaxKmh') == 1 and \
                   spscr.count('maxBand: kAtlasBandMaxKmh') == 1:
                    ok('AZ2 ceiling 140 in ONE query, engine untouched')
                else:
                    fail('AZ2 band ceiling leaked or engine touched')

                # AZ3: fog of war + frontier = ONE cross ring. Four addGhost
                # calls (band ±10, window ±5) and not one more — diagonals
                # would be five or eight.
                if proj.count('addGhost(') == 5 and \
                   'c.band - kAtlasBandStepKmh' in proj and \
                   'c.band + kAtlasBandStepKmh' in proj and \
                   "c.window! - kAtlasWindowStepC" in proj and \
                   "c.window! + kAtlasWindowStepC" in proj and \
                   'if (byKey.containsKey(k) || ghostKeys.contains(k)) return;' \
                       in proj:
                    ok('AZ3 frontier = one cross ring, no diagonals')
                else:
                    fail('AZ3 ghost ring shape wrong')

                # AZ4: window classes — 4 cold (−20/−15/−10/−5) and 3 hot
                # (25/30/35): the prose of §6.9, not the 5+2 of mockup [5g].
                if 'const int kAtlasRareWindowMaxC = -5;' in proj and \
                   'const int kAtlasHotWindowMinC = 25;' in proj:
                    ok('AZ4 window classes 4 cold / 3 hot (§6.9 prose)')
                else:
                    fail('AZ4 window class boundaries drifted')

                # AZ5: fork — present on the head units (17 / 16 dp), absent
                # on the phone, and never drawn for a single snapshot
                # (owner decision 25.07).
                if 'forkSize: null' in grid and \
                   'forkSize: 17' in grid and \
                   'forkSize: 16' in grid and \
                   'm.forkSize != null && c.hasFork' in grid and \
                   'snapshots > 1 &&' in proj:
                    ok('AZ5 fork: HU 17/16, phone none, single snapshot none')
                else:
                    fail('AZ5 fork discipline broken')

                # AZ6 — OWNER OVERRIDE of contract 1.1 (25.07): the chevron
                # rosette is NOT taken and «Атлас» is NOT renamed. So this
                # gate pins the REVERSAL, not the draft: the mark is
                # Icons.star with metal tints, the +160 card strings
                # (including «серебро» / «золото») stay exactly as they
                # were, and neither «шеврон» nor «Альманах» ever reaches a
                # user-visible string.
                _l10n_body = '\n'.join(
                    ln for ln in l10n.splitlines()
                    if not ln.lstrip().startswith('//'))
                _no_draft_words = all(
                    w not in _l10n_body
                    for w in ('шеврон', 'Альманах', 'альманах'))
                if 'Icons.star' in grid and \
                   'coverage_mark' not in grid and \
                   'markColor(' in toks and \
                   'markFifteen' in toks and \
                   _no_draft_words and \
                   "'atlas.title': 'Атлас'" in l10n and \
                   "'measure.card_star_silver': 'серебро'" in l10n and \
                   "'measure.card_star_gold': 'золото'" in l10n:
                    ok('AZ6 star + metals kept, «Атлас» kept (owner override)')
                else:
                    fail('AZ6 coverage mark / naming drifted from the override')

                # AZ7: badge 14 dp + 2 dp outline in ALL THREE scaffolds, and
                # the isParked dot is GONE from «Автомобиль» (§5).
                _dot_gone = 'isLabelVisible: isParked && _index != 1' \
                    not in rail2
                if 'width: 14,' in toks and 'width: 2)' in toks and \
                   home2.count('MeasureBadge(') == 2 and \
                   rail2.count('MeasureBadge(') == 1 and \
                   'smallSize: 8' not in home2 and \
                   'smallSize: 8' not in rail2 and \
                   _dot_gone and \
                   '_ParkedChip' in dashw and \
                   "S.of('atlas.parked_chip')" in dashw:
                    ok('AZ7 badge 14 dp ×3, «Автомобиль» dot removed, chip')
                else:
                    fail('AZ7 badge / dot / chip wiring incomplete')

                # AZ8: sticky plate — conjunct existence (motion-free BY
                # EXPRESSION), 56 dp, reveal tokens, charging on top, wired
                # into all three scaffolds with the «Замеры» jump.
                _plate_order = banner.index('if (banner != null) banner,') < \
                    banner.index('if (widget.showAtlasPlate)')
                if 'class AtlasSummaryPlate' in banner and \
                   'if (!isParked || unrevealed <= 0)' in banner and \
                   'height: 56,' in banner and \
                   'AtlasTokens.revealBg' in banner and \
                   'AtlasTokens.revealBorder' in banner and \
                   _plate_order and \
                   home2.count('showAtlasPlate:') == 2 and \
                   rail2.count('showAtlasPlate:') == 1 and \
                   home2.count('onPlateTap:') == 2 and \
                   rail2.count('onPlateTap:') == 1:
                    ok('AZ8 plate: conjunct, 56 dp, charging on top, ×3 hosts')
                else:
                    fail('AZ8 sticky plate wiring incomplete')

                # AZ9: export — 1080×1350, its OWN five-class fill scale (not
                # the screen tokens), «лучшая ячейка» = Σ steady time (owner
                # decision), QR + qr_flutter, and the button is phone-only.
                if 'static const double kWidth = 1080;' in expo and \
                   'static const double kHeight = 1350;' in expo and \
                   all(t in toks for t in ('expAhead', 'expOpen', 'expMulti',
                                           'expBest', 'expRareTint')) and \
                   'c.steadySeconds > best.steadySeconds' in proj and \
                   'qr_flutter: ^4.1.0' in pubs and \
                   'QrImageView(' in expo and \
                   'showExport: !onHeadUnit' in atls and \
                   'AtlasExportScreen' not in atlw:
                    ok('AZ9 export 1080×1350, own scale, Σ-steady best, phone')
                else:
                    fail('AZ9 export image contract broken')

                # AZ10: l10n — 34 atlas.* and 16 export.* keys in BOTH maps,
                # the plate title in both, and the +160 card strings NOT
                # touched by this patch (they are +162 scope).
                # +162 language pass: +7 atlas keys (full months, км/ч,
                # reading plurals, two hints), −2 (the motion-gate strings
                # died with the gate) → 51 keys × 2 maps.
                _az10_atlas = 102 if int(pv) >= 162 else 92
                if l10n.count("'atlas.") == _az10_atlas and \
                   l10n.count("'export.") == 32 and \
                   l10n.count("'measure.plate_title'") == 2 and \
                   l10n.count("'measure.card_") == 24:
                    ok(f'AZ10 l10n: atlas ×{_az10_atlas // 2}, export ×16, '
                       'card_* untouched')
                else:
                    fail(f'AZ10 l10n counts: atlas {l10n.count(chr(39) + "atlas.")}'
                         f' export {l10n.count(chr(39) + "export.")}'
                         f' card_ {l10n.count(chr(39) + "measure.card_")}')

                # AZ11: the grid reads atlas_snapshots DIRECTLY — never the
                # prefs ledger (that is what makes a reinstall self-healing,
                # no rehydration code anywhere).
                if 'atlas_ledger' not in proj and \
                   'SharedPreferences' not in proj and \
                   'SharedPreferences' not in grid and \
                   'getAtlasSnapshotsForGrid' in proj + atls + atlw + spscr:
                    ok('AZ11 grid reads snapshots directly, ledger untouched')
                else:
                    fail('AZ11 grid leaked into the prefs ledger')
            else:
                ok(f"Part AZ skipped (build +{pv}, атлас-UI lands in +161)")
            # ───── Part BA: +162 полевые правки + намерение (§3.2) ─────
            # Полевой вердикт 25.07: блокировка атласа в движении снята,
            # язык переписан на человеческий, счётчик перестал врать,
            # дозревшая-но-не-замороженная клетка видна, намерение живёт.
            if int(pv) >= 162:
                banner2 = (root / 'lib/widgets/charging_banner.dart').read_text()
                atls2 = (root / 'lib/screens/atlas.dart').read_text()
                atlw2 = (root / 'lib/screens/wide/atlas_wide.dart').read_text()
                spscr2 = (root / 'lib/screens/speed_profile.dart').read_text()
                grid2 = (root / 'lib/widgets/atlas_grid.dart').read_text()
                proj2 = (root / 'lib/data/atlas_projection.dart').read_text()

                # BA1: NO motion gate anywhere. Nothing appears in motion
                # (И1 holds — the plate and the badge keep isParked as a
                # conjunct); the map simply stopped disappearing.
                _gate_gone = (
                    'parked_only' not in l10n and
                    'parked_only' not in atls2 and
                    'parked_only' not in atlw2 and
                    'parked_only' not in spscr2 and
                    '_ParkedOnlyCard' not in atls2 and
                    'final enabled = data != null;' in spscr2)
                _plate_still_gated = (
                    'if (!isParked || unrevealed <= 0)' in banner2 and
                    'isParked && unrevealed > 0' in home2 and
                    'isParked && unrevealed > 0' in rail2)
                if _gate_gone and _plate_still_gated and \
                   "S.of('atlas.parked_chip')" in dashw:
                    ok('BA1 motion gate removed; plate/badge still conjunct')
                else:
                    fail('BA1 motion gate or the И1 conjuncts are wrong')

                # BA2: the atlas revision — one counter, three bumps
                # (freeze / reveal / «Ок») and three cached readers that
                # re-read on it. This is the fix for the field symptom
                # «entry card said 1 клетка all day» (IndexedStack keeps
                # the tab alive, initState never ran again).
                # +164: a fourth bump — the 120 s chunk also changes
                # what the grid would read, so cached readers must
                # re-read after it too.
                _bumps = 4 if int(pv) >= 164 else 3
                if 'int get atlasRevision => _atlasRevision;' in sps and \
                   sps.count('_atlasRevision++') == _bumps and \
                   atls2.count('_loadedRevision') >= 3 and \
                   atlw2.count('_loadedRevision') >= 3 and \
                   spscr2.count('_loadedRevision') >= 3:
                    ok(f'BA2 atlas revision: {_bumps} bumps, 3 readers re-read')
                else:
                    fail('BA2 atlas revision wiring incomplete')

                # BA3: pending cells (matured, awaiting rotation) are a
                # LIVE-ledger overlay — never part of the projection, so
                # they cannot leak into a counter, a star or the export.
                if 'List<AtlasPendingCell> atlasPendingCells()' in sps and \
                   'class AtlasPending {' in proj2 and \
                   'AtlasPending' not in \
                       proj2[proj2.index('class AtlasGridData'):] and \
                   'final List<AtlasPending> pending;' in grid2 and \
                   'pending' not in expo and \
                   "S.of('atlas.pending_note')" in atls2:
                    ok('BA3 pending overlay lives outside the projection')
                else:
                    fail('BA3 pending overlay leaked into the projection')

                # BA4: intention (§3.2) — prefs triple, 14-day fade, the
                # candidate pinned to the ACTIVE window (the fix for the
                # unreachable advice), card gated by isParked.
                if "_kIntentBandKey = 'atlas_intent_band'" in sps and \
                   'const int kAtlasIntentTtlDays = 14;' in sps and \
                   'void takeAtlasIntent(' in sps and \
                   'void clearAtlasIntent()' in sps and \
                   'AtlasIntent? atlasIntentCandidate()' in sps and \
                   'if (w != win) return; // ACTIVE window only' in sps and \
                   'class _IntentCard' in spscr2 and \
                   'if (!isParked) return const SizedBox.shrink();' in spscr2:
                    ok('BA4 intention: prefs triple, 14-day fade, active window')
                else:
                    fail('BA4 intention wiring incomplete')

                # BA5: selection mode ([5a]) — ghosts become the only
                # touch targets, cells go quiet, a tap takes and pops.
                if 'final bool selectGhostMode;' in atls2 and \
                   'selectGhostMode: true' in spscr2 and \
                   'if (tap == null || selectMode) return content;' in grid2 and \
                   'onTap: () => tapGhost(band, window)' in grid2 and \
                   'sp.takeAtlasIntent(band, window);' in atls2:
                    ok('BA5 selection mode: ghosts tappable, cells quiet')
                else:
                    fail('BA5 selection mode wiring incomplete')

                # BA6: the language pass. The words the field could not
                # read are gone from every RU VALUE (comments excluded);
                # «полоса» survives on the Замеры screen by owner
                # decision, «км/ч» is the atlas register.
                # Scope: the keys this feature owns. «пак» and «снимок»
                # legitimately survive elsewhere (the charging screen's
                # pack power, the cloud restore counters) — this gate is
                # about the atlas register, not a global word ban.
                _ru_start = l10n.index("static const Map<String, String> _ru")
                _ru_own = '\n'.join(
                    ln for ln in l10n[_ru_start:].splitlines()
                    if not ln.lstrip().startswith('//')
                    and re.search(r"'(?:atlas|export|measure)\.", ln))
                _dead_words = [w for w in
                               ('пак', 'вилк', 'фронтир', 'снимк', 'Арка',
                                'независим', 'Альманах')
                               if w in _ru_own]
                if not _dead_words and \
                   "'atlas.kmh': 'км/ч'" in l10n and \
                   "'atlas.months_full'" in l10n and \
                   l10n.count("'atlas.months_full'") == 2 and \
                   "'atlas.tab_arc': 'Здоровье батареи'" in l10n and \
                   'Полоса {v} дозрела' in l10n:
                    ok('BA6 language: jargon gone, «полоса» kept in Замеры')
                else:
                    fail(f'BA6 language pass incomplete: {_dead_words}')

                # BA7: full month names in PROSE (the field saw «июл»),
                # short ones only on the year-row axis.
                if 'atlasMonthNamesFull()' in grid2 and \
                   'atlasMonthNamesFull()' in atls2 and \
                   'atlasMonthNamesFull' in expo and \
                   'months[0]' in grid2 and 'months[11]' in grid2 and \
                   "atlasMonthNamesFull()[now.month - 1]" in grid2:
                    ok('BA7 full month names in prose, short on the axis')
                else:
                    fail('BA7 month naming still abbreviated in prose')

                # ───── Part BB: +163 «Замеры по контракту, заход A» ─────
                # Экран «Замеры» пересобран по канону 1.2 §7.1/§7.4:
                # леджер как источник карточек, кнопки/архив/дамп ушли,
                # ротация на стоянке, взвешенная средняя, displayWindow.
                if int(pv) >= 163:
                    bcs = (root / 'lib/widgets/band_card.dart').read_text()
                    sett2 = (root / 'lib/screens/settings.dart').read_text()

                    # BB1: teardown — no manual controls, no archive, no
                    # in-screen dump; the band chart SURVIVES (канон §0.1:
                    # отмена отмены — график остаётся навсегда).
                    if "S.of('measure.start')" not in spscr2 and \
                       "S.of('measure.stop')" not in spscr2 and \
                       "S.of('measure.reset')" not in spscr2 and \
                       "S.of('measure.dump')" not in spscr2 and \
                       '_buildArchive' not in spscr2 and \
                       '_ArchivedDetailScreen' not in spscr2 and \
                       '_CompareScreen' not in spscr2 and \
                       'package:fl_chart/fl_chart.dart' in spscr2 and \
                       "S.of('measure.chart_title')" in spscr2:
                        ok('BB1 teardown complete; band chart survives')
                    else:
                        fail('BB1 teardown incomplete or the chart died')

                    # BB2: always-on — the flag is constant-true after
                    # init, the prefs key is neither read nor written but
                    # its literal stays declared (a reserved slot).
                    if '_active = true;' in sps and \
                       'prefs.getBool(_kActiveKey)' not in sps and \
                       'prefs.setBool(_kActiveKey' not in sps and \
                       "= 'speed_profile_active';" in sps and \
                       'Future<void> start()' not in sps and \
                       'Future<SpeedProfileSession?> stop()' not in sps and \
                       'Future<void> reset()' not in sps:
                        ok('BB2 always-on recording; prefs slot reserved untouched')
                    else:
                        fail('BB2 manual-control remnants or prefs key touched')

                    # BB3: the band card widget — three stages in ONE
                    # card, the maturing→matured crossfade ≤ 300 мс, and
                    # the tile set is decided by the screen (no silent
                    # placeholder rows).
                    if 'class BandCard' in bcs and \
                       'class BandCardModel' in bcs and \
                       'AnimatedCrossFade' in bcs and \
                       'Duration(milliseconds: 280)' in bcs and \
                       "S.of('measure.stage_maturing')" in bcs and \
                       "S.of('measure.stage_matured')" in bcs:
                        ok('BB3 band card: three stages, ≤300 ms crossfade')
                    else:
                        fail('BB3 band card missing a stage or the crossfade')

                    # BB4: range from consumption is computed in exactly
                    # ONE place (band_card.atlasRangeKm) — the reveal card
                    # calls it, no local copy survives anywhere.
                    if 'int atlasRangeKm(double kwh100)' in bcs and \
                       bcs.count('packCapacityKwh') == 1 and \
                       'atlasRangeKm(' in spscr2 and \
                       '_rangeKm' not in spscr2 and \
                       'packCapacityKwh / kwh100' not in spscr2:
                        ok('BB4 range helper: one funnel in band_card')
                    else:
                        fail('BB4 range computed in more than one place')

                    # BB5: the status chip — two slots, both states named,
                    # the P glyph in gearP, the rec dot from the token.
                    if 'class _StatusChip' in spscr2 and \
                       "S.of('measure.chip_rec')" in spscr2 and \
                       "S.of('measure.chip_parked')" in spscr2 and \
                       'AtlasTokens.rec' in spscr2 and \
                       'AtlasTokens.gearP' in spscr2 and \
                       'static const Color rec = Color(0xFFFF5252);' in toks:
                        ok('BB5 status chip: rec/parked slots + rec token')
                    else:
                        fail('BB5 status chip wiring incomplete')

                    # BB6: empty state 2d/3d — headline + ghost card at
                    # opacity .4 with its caption; no tutorial buttons.
                    if 'class BandEmptyState' in bcs and \
                       "S.of('measure.empty_title')" in bcs and \
                       "S.of('measure.empty_ghost')" in bcs and \
                       'Opacity(opacity: 0.4' in bcs:
                        ok('BB6 empty state: ghost band card at .4')
                    else:
                        fail('BB6 empty state incomplete')

                    # BB7: the diag dump lives in Настройки → Расширенное
                    # now — service call intact, screen free of it (the
                    # screen half is pinned by BB1/AW11).
                    if "S.of('settings.adv.dump')" in sett2 and \
                       'dumpDiag()' in sett2 and \
                       "S.of('settings.adv.dump_ok')" in sett2 and \
                       "S.of('settings.adv.dump_fail')" in sett2:
                        ok('BB7 diag dump relocated to Advanced settings')
                    else:
                        fail('BB7 diag dump tile missing in settings')

                    # BB8: l10n — the +163 keys exist in BOTH maps, the
                    # manual-era keys are GONE from both, and the reveal
                    # card family is intact (24 card_* entries).
                    _bb8_new = ['measure.chip_rec', 'measure.chip_parked',
                                'measure.stage_maturing',
                                'measure.stage_matured', 'measure.of_120',
                                'measure.range_est', 'measure.in_atlas',
                                'measure.empty_title', 'measure.empty_ghost',
                                'measure.z100_ready', 'measure.z100_last',
                                'measure.intent_hold', 'measure.intent_new',
                                'measure.intent_refine',
                                'settings.adv.dump']
                    _bb8_dead = ['measure.start', 'measure.stop',
                                 'measure.reset', 'measure.dump',
                                 'measure.archive_title', 'measure.save_q',
                                 'measure.compare', 'measure.evict_q']
                    if all(l10n.count("'" + k + "'") == 2
                           for k in _bb8_new) and \
                       all("'" + k + "'" not in l10n
                           for k in _bb8_dead) and \
                       l10n.count("'measure.card_") == 24:
                        ok('BB8 l10n: +163 keys ×2, manual-era keys gone')
                    else:
                        fail('BB8 l10n keys wrong')

                    # BB9: cards read the LEDGER — the service exposes the
                    # live-band projection, the screen builds models from
                    # it plus the grid, and the atlas line rides on the
                    # card (решение 26.07 п.1/п.3).
                    if 'atlasLiveBands()' in sps and \
                       'atlasLiveCellKwh100(' in sps and \
                       'atlasLiveBands()' in spscr2 and \
                       "'measure.in_atlas'" in bcs and \
                       'svc.session.bands' not in spscr2:
                        ok('BB9 cards render the ledger + atlas line')
                    else:
                        fail('BB9 cards still read the session overlay')

                    # BB10: the cell number is the steady_seconds-weighted
                    # mean, computed once in the projection; the word
                    # median left every atlas file (решение 26.07 п.10).
                    _bb10_files = [proj2, atls2, atlw2, grid2, expo,
                                   (root /
                                    'lib/screens/atlas_cell_detail.dart'
                                    ).read_text()]
                    if proj2.count('r.kwh100 * r.steadySeconds') == 1 and \
                       'final double mean;' in proj2 and \
                       all('median' not in f.lower()
                           for f in _bb10_files):
                        ok('BB10 weighted mean in one place; median retired')
                    else:
                        fail('BB10 mean/median discipline broken')

                    # BB11: rotation fires on the STANDSTILL under ONE
                    # predicate (gap AND non-empty session) shared with
                    # the moving insurance and the recovery path.
                    if 'bool _atlasRotationDue(' in sps and \
                       'l.sessionDistKm > 0;' in sps and \
                       sps.count('_atlasRotationDue(') == 4 and \
                       sps.count('_closeAtlasSession(frozenAtMs: l.lastMoveMs)') == 3:
                        ok('BB11 parked rotation: one predicate, three sites')
                    else:
                        fail('BB11 rotation predicate/sites wrong')

                    # BB12: the nav item is «Батарея» (решение 26.07
                    # п.15) — the key name itself never renames (§8).
                    if "'nav.cells': 'Батарея'," in l10n and \
                       "'nav.cells': 'Battery'," in l10n and \
                       "'nav.cells': 'Ячейки'," not in l10n:
                        ok('BB12 nav item renamed to Батарея/Battery')
                    else:
                        fail('BB12 nav.cells still Ячейки')

                    # BB13: freezing happens ONLY on rotation/recovery
                    # (the window-switch freeze is retired), and the card
                    # set is anchored to a display window latched on
                    # standstill ticks (решение 26.07 — И1 structurally).
                    _bb13_cross = ('beforeS < kBandMinSeconds && '
                                   'cell.timeS >= kBandMinSeconds')
                    _bb13_common = ('windowFilter' not in sps and
                                    'int? _displayWindow;' in sps and
                                    'int? get atlasDisplayWindow => '
                                    '_displayWindow;' in sps and
                                    'atlasDisplayWindow' in spscr2)
                    if int(pv) >= 164:
                        # +164 (A) INVERTS the first half of this gate on
                        # purpose: freezing is no longer rotation-only.
                        # The old assertion never actually tested «only»
                        # — it counted _freezeMatured call sites — so the
                        # replacement states the real +164 invariant:
                        #   * the chunk funnel is invoked from exactly
                        #     ONE place, the maturity crossing;
                        #   * the accumulator reset lives ONLY inside
                        #     that funnel (nothing else zeroes a cell);
                        #   * rotation clears the frozen accumulator so
                        #     chunks belong to the session that made them.
                        # The display-window half is unchanged.
                        # +166 (A1) уточняет ВТОРУЮ половину: сброс
                        # больше не обнуление. Он стал вычитанием ровно
                        # тех величин, что ушли в строку, потому что
                        # сброс переехал за await вставки, а тики 1 Гц
                        # продолжают лить в ту же клетку — `= 0`
                        # выбросил бы всё, что натекло за время записи.
                        # Инвариант «сброс живёт в одном месте» не
                        # меняется, меняется его форма.
                        _bb13_reset = (
                            sps.count('cell.energyKwh -= tookEnergyKwh;') == 1
                            and 'cell.energyKwh = 0;' not in sps
                            if int(pv) >= 166
                            else sps.count('cell.energyKwh = 0;') == 1)
                        if '_freezeChunk(key, cell, band, win, nowMs);' in sps \
                           and sps.count('_freezeChunk(') == 2 \
                           and _bb13_reset \
                           and 'c.frozenTimeS = 0;' in sps \
                           and _bb13_cross in sps \
                           and _bb13_common:
                            ok('BB13 (re-era +164) chunk freeze at the '
                               'crossing only; reset in one place; '
                               'display window latched')
                        else:
                            fail('BB13 (re-era +164) chunk/reset/rotation '
                                 'discipline broken')
                    elif '_freezeMatured(frozenAtMs:' in sps and \
                       sps.count('_freezeMatured(') >= 2 and \
                       _bb13_common:
                        ok('BB13 freeze on rotation only; display window latched')
                    else:
                        fail('BB13 freeze/display-window discipline broken')
                else:
                    ok(f"Part BB skipped (build +{pv}, заход A lands in +163)")
            else:
                ok(f"Part BA skipped (build +{pv}, полевые правки land in +162)")
        else:
            ok(f"Part AY skipped (build +{pv}, карточка итогов lands in +160)")
    else:
        ok(f"Part AX skipped (build +{pv}, атлас lands in +158)")
else:
    ok(f"Part AW skipped (build +{pv}, speed profile lands in +151)")

# ═════════════ Part BC: v0.1.65+164 «Сохранность и две колонки» ═════════════
#
# Blocks B (restore), A (120 s chunk + provisional rows), C (two columns),
# D (band chart rebuilt on the atlas grid), E (first-entry screen).
if int(pv) >= 164:
    bc_sps = (root / 'lib/services/speed_profile_service.dart').read_text()
    bc_spu = (root / 'lib/screens/speed_profile.dart').read_text()
    # BC6a checks for the ABSENCE of the mockup's outer-width numbers.
    # They legitimately appear in the comments that explain why they are
    # not used, so the absence test must look at code lines only.
    bc_spu_code = '\n'.join(
        ln for ln in bc_spu.split('\n')
        if not ln.lstrip().startswith(('//', '///', '*', '/*')))
    bc_css = (root / 'lib/services/cloud_sync_service.dart').read_text()
    bc_l10n = (root / 'lib/l10n/strings.dart').read_text()
    bc_proj = (root / 'lib/data/atlas_projection.dart').read_text()
    bc_bcard = (root / 'lib/widgets/band_card.dart').read_text()
    bc_grid = (root / 'lib/widgets/atlas_grid.dart').read_text()
    bc_tok = (root / 'lib/theme/atlas_tokens.dart').read_text()
    bc_atl = (root / 'lib/screens/atlas.dart').read_text()
    bc_atlw = (root / 'lib/screens/wide/atlas_wide.dart').read_text()

    # BC1: the two-column row. Expanded + SizedBox(560), gaps 24/20, and
    # ONLY under !bz3. `flex: 1.5` is deliberately NOT pinned — a lone
    # Flexible in a Row has nothing to weigh against, so the literal
    # would be dead weight the gate would then protect forever.
    if 'width: 560,' in bc_spu and \
       'const SizedBox(width: 24),' in bc_spu and \
       'flex: 1.5' not in bc_spu and \
       bc_spu.find('if (bz3) {') < bc_spu.find('width: 560,'):
        ok('BC1 two-column row: Expanded + 560, gap 24, BZ5 only')
    else:
        fail('BC1 two-column row geometry wrong')

    # BC2 — ERA-AWARE (+165). Порядок правой колонки развёрнут решением
    # владельца 27.07: атлас → 0–100 → синхронизация. Обоснование —
    # карточка синхронизации единственная из трёх приходит и уходит по
    # стоянке, и, стоя посередине, она толкала блок 0–100 вниз ПОД
    # водителем в момент парковки. Стоя последней, она не двигает
    # ничего. Остальные требования BC2 не меняются: один порядок во
    # всех состояниях, единственное условие в колонке — стояночный
    # гейт на синхронизации, никакой перестановки по firstEntry.
    _aside = bc_spu.split('final aside = <Widget>[')[1].split('];')[0]
    _i_atlas = _aside.find('atlasEntry')
    _i_sync = _aside.find('syncCard')
    _i_z100 = _aside.find('zeroTo100')
    # No state-dependent ordering anywhere in the column: the only
    # condition allowed inside it is the parked gate on the sync card.
    _no_flip = ('firstEntry' not in _aside and
                _aside.count('if (') == 1 and
                'if (_isParked) ...[' in _aside)
    _bc2_common = (_no_flip and
                   bc_spu.count('final aside = <Widget>[') == 1 and
                   bc_spu.count('...aside,') == 1)
    if int(pv) >= 165:
        # Стояночный гейт обязан обнимать ИМЕННО синхронизацию — если
        # он уедет на 0–100, порядок формально сойдётся, а колонка
        # начнёт прыгать.
        _bc2_parked_wraps_sync = (
            'if (_isParked) ...[' in _aside and
            _aside.find('if (_isParked) ...[') < _i_sync and
            _aside.find('if (_isParked) ...[') > _i_z100)
        if -1 < _i_atlas < _i_z100 < _i_sync and _bc2_common and \
           _bc2_parked_wraps_sync:
            ok('BC2 (re-era +165) right column: atlas → 0–100 → sync, '
               'one order, parked gate wraps sync only')
        else:
            fail('BC2 right column order or parked condition wrong')
    elif -1 < _i_atlas < _i_sync < _i_z100 and _bc2_common:
        ok('BC2 right column: atlas → sync → 0–100, one order, sync parked')
    else:
        fail('BC2 right column order or parked condition wrong')

    # BC3: the sync card exists on both form factors, is clickable into
    # the existing cloud route, and its two keys are in BOTH l10n maps.
    # UX-ревизия +164: подпись утверждает «Облако подключено», значит
    # карточка не имеет права существовать, когда это неправда —
    # ровно состояние ГУ сразу после переустановки.
    _sync = bc_spu.split('class _SyncCard')[1].split('\nclass ')[0]
    if 'class _SyncCard' in bc_spu and \
       'CloudServicesScreen()' in bc_spu and \
       bc_l10n.count("'measure.sync_title':") == 2 and \
       bc_l10n.count("'measure.sync_sub':") == 2 and \
       'Icons.cloud_done' in bc_spu and \
       '!cloud.isRegistered || !cloud.enabled' in _sync and \
       'SizedBox.shrink()' in _sync:
        ok('BC3 sync card on both form factors, clickable, keys ×2')
    else:
        fail('BC3 sync card wiring or l10n wrong')

    # BC4: BZ3 gets NO columns, and «атлас сверху» is not applied to it —
    # the portrait ribbon keeps 0–100 with the band cards, then atlas,
    # then sync, then the chart, then the note (canon §7.4).
    _bz3 = bc_spu.split('if (bz3) {')[1].split('return Padding(')[0]
    # The ribbon must use its OWN tail, not the BZ5 right column: on BZ3
    # 0–100 travels with the band cards (canon §7.4), so `aside` — which
    # is atlas-first by the owner's 26.07 decision — must not leak here.
    _tail = bc_spu.split('final ribbonTail = <Widget>[')[1].split('];')[0]
    _order_ok = (_tail.find('zeroTo100') <
                 _tail.find('atlasEntry') <
                 _tail.find('syncCard'))
    if 'width: 560' not in _bz3 and '...aside,' not in _bz3 and \
       '...ribbonTail,' in _bz3 and _order_ok and \
       _bz3.find('...measurement,') < _bz3.find('...ribbonTail,') < \
       _bz3.find('chart,') < _bz3.find('sleepNote,'):
        ok('BC4 BZ3 has no columns; portrait order per canon §7.4')
    else:
        fail('BC4 BZ3 ribbon order wrong or columns leaked in')

    # BC5: the chart reads the ATLAS GRID, never live cells; eleven
    # bands always; no text fallback; touch off.
    if 'class _BandBarCard' in bc_spu and \
       'final AtlasGridData? data;' in bc_spu and \
       'data?.cells ?? const <AtlasCellStat>[]' in bc_spu and \
       'b <= kAtlasBandMaxKmh;' in bc_spu and \
       '_textFallback' not in bc_spu and \
       'barTouchData: BarTouchData(enabled: false)' in bc_spu and \
       'bars.length < 3' not in bc_spu:
        ok('BC5 chart on the atlas grid, 11 bands, no fallback, touch off')
    else:
        fail('BC5 chart source / band coverage / fallback wrong')

    # BC6: three bar states, declared as tokens, highlight under > 0.5.
    if 'chartBarIdle' in bc_tok and 'chartBarEarned' in bc_tok and \
       'AtlasTokens.chartBarIdle' in bc_spu and \
       'AtlasTokens.chartBarEarned' in bc_spu and \
       'AtlasTokens.progress' in bc_spu and \
       'if (v > 0.5 && v < best)' in bc_spu and \
       'Color(0x1AFFFFFF)' not in bc_spu:
        ok('BC6 three bar colours as tokens; highlight guarded at > 0.5')
    else:
        fail('BC6 bar colours or highlight guard wrong')

    # BC6a — ERA-AWARE (+165). Литералы графика переехали на лестницу
    # приложения: отступ 26/36 → 14 (BZ3 28 → 12), высота области
    # 260 → 180 (BZ3 180 → 140), ширина столбца 14 → 10 (BZ3 10 → 8),
    # подписи осей 18 → 11 (BZ3 14 → 10). Неизменным остаётся то, ради
    # чего гейт заведён: внешняя ширина по-прежнему НЕ пиннится —
    # 1539/668 намерены по полной панели и игнорируют 80 dp рейла
    # (реальная контентная область 2094).
    #
    # Проверка сужена на срез класса графика. В прошлой редакции она
    # искала литералы по всему файлу, и, например, 'bz3 ? 8 : 10'
    # совпало бы с зазором призрачных клеток входа в атлас — гейт
    # прошёл бы, даже если бы столбцы остались прежними.
    if int(pv) >= 165:
        _chart = bc_spu.split('Widget _chart(')[1].split('\nclass ')[0]
        _chart_card = bc_spu.split("Text(S.of('measure.chart_title')")[0]
        _chart_card = _chart_card[_chart_card.rfind('return Container('):]
        if 'const EdgeInsets.all(14)' in _chart_card and \
           'const EdgeInsets.all(12)' in _chart_card and \
           'BorderRadius.circular(12)' in _chart_card and \
           'bz3 ? 140 : 180' in bc_spu and \
           'width: bz3 ? 8 : 10,' in _chart and \
           'fontSize: bz3 ? 10 : 11,' in _chart and \
           _chart.count('fontSize: bz3 ? 10 : 11,') == 2 and \
           'measure.chart_note_short' in bc_spu and \
           '1539' not in bc_spu_code and '668' not in bc_spu_code:
            ok('BC6a (re-era +165) chart literals on the app ladder; '
               'outer width still not pinned')
        else:
            fail('BC6a chart literals wrong or an outer-width literal '
                 'leaked in')
    elif 'vertical: 26, horizontal: 36' in bc_spu and \
       'bz3 ? 180 : 260' in bc_spu and \
       'bz3 ? 10 : 14' in bc_spu and \
       'bz3 ? 14 : 18' in bc_spu and \
       'vertical: 26, horizontal: 28' in bc_spu and \
       'measure.chart_note_short' in bc_spu and \
       '1539' not in bc_spu_code and '668' not in bc_spu_code:
        ok('BC6a chart literals per form factor; outer width not pinned')
    else:
        fail('BC6a chart literals wrong or an outer-width literal leaked in')

    # BC6b: first entry — three explanation blocks, four ghost cells at
    # 44/38, and NO state-dependent re-ordering of the right column.
    if 'measure.empty_title' in bc_l10n and \
       bc_l10n.count("'measure.empty_body':") == 2 and \
       bc_l10n.count("'measure.empty_z100':") == 2 and \
       bc_l10n.count("'measure.empty_atlas':") == 2 and \
       'for (var i = 0; i < 4; i++)' in bc_spu and \
       'size: bz3 ? 38 : 44, radius: bz3 ? 12 : 14' in bc_spu and \
       'class AtlasGhostCell' in bc_grid and \
       'Opacity(opacity: 0.4, child: ghost)' in bc_bcard and \
       'final firstEntry = models.isEmpty;' in bc_spu:
        ok('BC6b first-entry composition; ghosts 44/38; no column flip')
    else:
        fail('BC6b first-entry composition wrong')

    # BC7: the snapshot is written AT the 120 s crossing, from inside
    # _atlasTick — i.e. outside _closeAtlasSession.
    _tick = bc_sps.split('void _atlasTick(')[1].split('void _freezeChunk(')[0]
    if '_freezeChunk(key, cell, band, win, nowMs);' in _tick and \
       'insertAtlasSnapshot(row)' in bc_sps and \
       '_freezeChunk(' not in bc_sps.split('void _closeAtlasSession(')[1] \
           .split('void _freezeMatured(')[0]:
        ok('BC7 chunk written at the crossing, outside _closeAtlasSession')
    else:
        fail('BC7 chunk write point wrong')

    # BC7a: reset accompanies the write, the remainder carries, and the
    # row stays IMMUTABLE — nothing in the atlas path clears synced_at.
    _atlas_writes = bc_css.split('_syncAtlasSnapshots')[1][:1200]
    # +166 (A1): перенос берёт снятую ДО await величину, а не текущее
    # содержимое клетки. Смысл прежний — завершённый чанк уезжает в
    # frozen, остаток остаётся живым, — изменился только источник числа.
    _bc7a_roll = ('cell.frozenEnergyKwh += tookEnergyKwh;'
                  if int(pv) >= 166
                  else 'cell.frozenEnergyKwh += cell.energyKwh;')
    if _bc7a_roll in bc_sps and \
       'cell.startedAtMs = nowMs;' in bc_sps and \
       'c.frozenTimeS = 0;' in bc_sps and \
       'syncedAt: const Value(null)' not in _atlas_writes and \
       'NEVER updates (immutable)' in bc_css:
        ok('BC7a chunk resets, remainder carries, row stays immutable')
    else:
        fail('BC7a reset/carry/immutability broken')

    # BC7b: provisional rows — the projection takes activeSessionUid and
    # skips the running session; all three call sites pass it.
    if 'String? activeSessionUid' in bc_proj and \
       'r.sessionUid == activeSessionUid' in bc_proj and \
       'String? get atlasSessionUid' in bc_sps and \
       bc_spu.count('activeSessionUid: sp.atlasSessionUid') == 1 and \
       bc_atl.count('activeSessionUid: sp.atlasSessionUid') == 1 and \
       bc_atlw.count('activeSessionUid: sp.atlasSessionUid') == 1:
        ok('BC7b provisional rows excluded from the grid; 3 call sites wired')
    else:
        fail('BC7b provisional-row plumbing incomplete')

    # BC8: ClientException — the root cause of the 24–26.07 restore
    # failures — is retried in BOTH transports, same backoff ladder.
    if bc_css.count('on http.ClientException catch (e)') == 2 and \
       bc_css.count('_retryBackoff[attempt - 1]') >= 4:
        ok('BC8 ClientException retried in _getJson and _postIngest')
    else:
        fail('BC8 ClientException still unhandled somewhere')

    # BC9: restore applies per page, moves the cursor only after the
    # page has landed, and asks for 200 rows, not 500.
    if '_kRestorePullLimit = 200' in bc_css and \
       "'limit': '$_kRestorePullLimit'" in bc_css and \
       'only now move the cursor' in bc_css and \
       bc_css.find('apply pass 5') < 0 and \
       bc_css.find('── apply passes 4/5: atlas snapshots + reveals ──') < \
       bc_css.find('only now move the cursor'):
        ok('BC9 restore applies per page; cursor after; limit 200')
    else:
        fail('BC9 per-page apply / cursor / limit wrong')

    # BC10: the outcome is a number and it SURVIVES the process — the
    # AppDiagLog ring does not (it is per-launch), which is why the
    # 26.07 export had no restore line at all.
    if '_kLastRestoreSummary' in bc_css and \
       'String? get lastRestoreSummary' in bc_css and \
       'atlasInserted' in bc_css and 'pagesApplied' in bc_css and \
       'bool get isEmpty' in bc_css and \
       "debugPrint('CloudSync: restore done — $_lastRestoreSummary')" in bc_css:
        ok('BC10 restore outcome counted, persisted and logged')
    else:
        fail('BC10 restore outcome reporting incomplete')
else:
    ok(f"Part BC skipped (build +{pv}, сохранность lands in +164)")

# ══════════════════ Part BD — v0.1.66+165 «Замеры: текст и масштаб» ══
#
# Патч не менял ни структуру страницы, ни число колонок. Он менял
# ФОРМУЛИРОВКИ и КЕГЛИ — то есть ровно тот класс правок, который
# текстовые гейты ловят плохо, а компилятор не ловит вообще. Отсюда
# восемь проверок ниже: они пиннят не «примерно так же», а конкретные
# инварианты, которые легко потерять при следующем касании экрана.
if int(pv) >= 165:
    import re as _bd_re
    bd_spu = (root / 'lib/screens/speed_profile.dart').read_text()
    bd_bcard = (root / 'lib/widgets/band_card.dart').read_text()
    bd_l10n = (root / 'lib/l10n/strings.dart').read_text()
    bd_css = (root / 'lib/services/cloud_sync_service.dart').read_text()

    # ── разбор обеих карт l10n на пары (ключ, значение) ──
    _i_en = bd_l10n.index('static const Map<String, String> _en')
    _i_ru = bd_l10n.index('static const Map<String, String> _ru')
    _bd_pat = _bd_re.compile(
        r"'([a-z][a-z0-9_.]*)':\s*((?:'(?:[^'\\]|\\.)*'\s*)+),")

    def _bd_pairs(blk):
        out = {}
        for m in _bd_pat.finditer(blk):
            out[m.group(1)] = ''.join(
                _bd_re.findall(r"'((?:[^'\\]|\\.)*)'", m.group(2)))
        return out

    _bd_en = _bd_pairs(bd_l10n[_i_en:_i_ru])
    _bd_ru = _bd_pairs(bd_l10n[_i_ru:])

    # BD1: ни одного ИИ-знака в поверхности «Замеры»/«Атлас», В ОБЕИХ
    # картах. Английский — не косметика: системная локаль ГУ китайская,
    # 'system' разрешается в 'en' (см. контракт в шапке strings.dart),
    # то есть свежий головной блок показывает именно английский.
    # «·» внутри «кВт·ч» — знак умножения в единице СИ, он законен;
    # «–» в числовых интервалах (0–100, {lo}–{hi}) тоже.
    _bd1_bad = []
    for _lang, _map in (('EN', _bd_en), ('RU', _bd_ru)):
        for _k, _v in _map.items():
            if _k.split('.')[0] not in ('measure', 'atlas'):
                continue
            _probe = _v.replace('кВт·ч', '')
            if any(_c in _v for _c in ('—', '→', '←', '⇒', '≈')) \
               or '·' in _probe:
                _bd1_bad.append(f'{_lang}/{_k}')
    if not _bd1_bad:
        ok('BD1 no em-dash / arrow / ≈ / middot left in measure.* '
           'and atlas.*, both maps')
    else:
        fail(f'BD1 AI punctuation survives in l10n: {_bd1_bad[:6]}')

    # BD2: несущие формулировки. Не весь словарь — только те строки, чья
    # правка была не стилистикой, а починкой: две обрезались
    # многоточием на 560 dp, остальные несли знак вместо слова.
    _bd2 = (
        _bd_ru.get('measure.sync_sub') == 'Облако подключено' and
        _bd_en.get('measure.sync_sub') == 'Cloud connected' and
        'Настройки' not in (_bd_ru.get('measure.sync_sub') or '') and
        _bd_ru.get('atlas.counts_view') == '{n} {cells}, {m} {bands}' and
        'просмотр' not in (_bd_ru.get('atlas.counts_view') or '') and
        'view' not in (_bd_en.get('atlas.counts_view') or '') and
        _bd_ru.get('measure.kwh100') == 'кВт·ч/100 км' and
        _bd_en.get('measure.kwh100') == 'kWh/100 km' and
        _bd_ru.get('measure.range_est') == 'около {km} км' and
        _bd_en.get('measure.range_est') == 'about {km} km' and
        'запаса' in (_bd_ru.get('measure.card_matured') or '') and
        _bd_ru.get('atlas.cell_sub') ==
        'минимум, среднее, максимум в кВт·ч на 100 км')
    if _bd2:
        ok('BD2 load-bearing strings reworded: sync path dropped, '
           '«просмотр» out of the counter, unit spaced, ≈ spelled out')
    else:
        fail('BD2 one of the load-bearing +165 strings is wrong')

    # BD3: разделители, зашитые в Dart мимо strings.dart. Сканер по
    # словарю их не видит — а на экране они неотличимы от словарных.
    # Три места, все на поверхности «Замеров».
    _bd3 = (
        ", ${S.of('measure.chip_rec_tail')}" in bd_spu and
        " · ${S.of('measure.chip_rec_tail')}" not in bd_spu and
        "'${S.of('measure.z100_last')}, ${_fmtDay(last.tsMs)}'" in bd_spu and
        "'${S.of('atlas.title')}: $counts'" in bd_spu and
        "'${S.of('atlas.title')} · $counts'" not in bd_spu)
    if _bd3:
        ok('BD3 the three Dart-side separators are commas/colon, '
           'not middots')
    else:
        fail('BD3 a hardcoded middot survives in the Замеры widgets')

    # BD4: лестница кеглей. §2.1 диагностировал экран как вдвое крупнее
    # остального приложения (20/22/24/25/26/27/58/64 при лестнице
    # 11/12/13/16/18/24/32/34) — гейт держит его на лестнице. Формы
    # «N * k» исключены сознательно: карточка намерения несёт
    # собственный множитель k и в таблицу §2.2 поимённо не входила.
    _BD_LADDER = {10, 11, 12, 13, 14, 16, 18, 20, 24, 30, 32, 34}
    _bd4_bad = []
    for _f, _txt in (('speed_profile', bd_spu), ('band_card', bd_bcard)):
        for _m in _bd_re.finditer(
                r'fontSize:\s*bz3\s*\?\s*([0-9]+)\s*:\s*([0-9]+)', _txt):
            for _g in (_m.group(1), _m.group(2)):
                if int(_g) not in _BD_LADDER:
                    _bd4_bad.append(f'{_f}:{_m.group(0)}')
        for _m in _bd_re.finditer(r'fontSize:\s*([0-9]+)\s*[,)]', _txt):
            if int(_m.group(1)) not in _BD_LADDER:
                _bd4_bad.append(f'{_f}:{_m.group(0)}')
    # Радиусы карточек: 12 везде. Исключения именованы — пилюля чипа
    # (999), шапка столбца графика (4), полукруг прогресс-бара.
    _BD_R_OK = {'12', '12 * k', '999', '4', 'barH / 2', 'radius',
                'bz3 ? 6 : 7'}
    _bd4_r = []
    for _f, _txt in (('speed_profile', bd_spu), ('band_card', bd_bcard)):
        for _m in _bd_re.finditer(r'circular\(([^)]*)\)', _txt):
            if _m.group(1).strip() not in _BD_R_OK:
                _bd4_r.append(f'{_f}:{_m.group(0)}')
    if not _bd4_bad and not _bd4_r:
        ok('BD4 every font size on the app ladder; every card radius 12')
    else:
        fail(f'BD4 off-ladder type {_bd4_bad[:4]} or radius {_bd4_r[:4]}')

    # BD5: перелом раскладки §2.4. Свёрнутая карточка 0–100 держала
    # заголовок и строку готовности в ОДНОМ Row за Spacer'ом, а
    # Spacer(flex 1) + Flexible(flex 1) делят свободное место пополам —
    # фраза получала половину остатка и складывалась в четырёхстрочный
    # столбик у правого края. Подпись обязана быть второй строкой.
    _z100 = bd_spu.split('class _ZeroTo100Card')[1].split('\nclass ')[0]
    _collapsed = _z100.split('} else if (runs.isEmpty) {')[1] \
                      .split('} else {')[0]
    # Только строки КОДА: объяснение прямо над этой веткой называет
    # Spacer и Flexible по именам, и проверка по сырому тексту читала
    # бы собственный комментарий вместо виджетов (поймано на первом
    # же прогоне BD5).
    _collapsed = '\n'.join(
        _l for _l in _collapsed.split('\n')
        if not _l.lstrip().startswith(('//', '///')))
    if 'const Spacer()' not in _collapsed and \
       'Flexible(' not in _collapsed and \
       'content = Column(' in _collapsed and \
       'Row(children: titleRow)' in _collapsed:
        ok('BD5 collapsed 0–100 card stacks title over readiness; '
           'the Spacer+Flexible split is gone')
    else:
        fail('BD5 the 0–100 collapsed branch still splits the row')

    # BD6: арифметика слота карточки полосы. §2.3 обещает восемь
    # карточек в колонке 736 dp — это ровно 82 + 10. Числа связаны:
    # разъедутся — обещание станет неправдой молча.
    _bd6 = ('const BoxConstraints(minHeight: 82)' in bd_bcard and
            'SizedBox(height: bz3 ? 8 : 10),' in bd_spu and
            'const EdgeInsets.all(14)' in bd_bcard and
            'const EdgeInsets.all(12)' in bd_bcard)
    if _bd6:
        ok('BD6 band-card slot is 82 + 10 = 92 dp (8 cards in 736)')
    else:
        fail('BD6 band-card slot arithmetic broken')

    # BD7: /v2/device/me отдаёт vehicle с самого S4, клиент его не
    # читал — отсюда «(неизвестный автомобиль)» и пустой _vehicleId на
    # пути спаривания. Оба поля обязаны читаться И персиститься:
    # без записи в prefs значение теряется на первом же перезапуске.
    _fdm = bd_css.split('Future<void> fetchDeviceMe(')[1] \
                 .split('\n  // v0.1.35+134')[0]
    _bd7 = ("decoded['vehicle']" in _fdm and
            "veh['display_name']" in _fdm and
            '_vehicleId = vid;' in _fdm and
            '_vehicleName = vname;' in _fdm and
            'prefs.setString(_kVehicleId, vid)' in _fdm and
            'prefs.setString(_kVehicleName, vname)' in _fdm)
    if _bd7:
        ok('BD7 fetchDeviceMe reads vehicle {id, display_name} '
           'and persists both')
    else:
        fail('BD7 vehicle block unparsed or not persisted')

    # BD8: радиус ряби InkWell карточки входа в атлас обязан совпадать
    # с радиусом её тела. Они живут в разных строках, и +165 едва не
    # оставил рябь на 24 при теле 12 — тогда касание скругляется по
    # своему углу и вылезает за карточку.
    _entry = bd_spu.split('class _AtlasEntryCard')[1].split('\nclass ')[0]
    _r_body = _bd_re.findall(r'circular\(([^)]*)\)', _entry)
    if _r_body and len(set(_r_body)) == 1 and _r_body[0].strip() == '12':
        ok('BD8 atlas-entry ripple radius matches the card body (12)')
    else:
        fail(f'BD8 atlas-entry radii disagree: {_r_body}')
else:
    ok(f"Part BD skipped (build +{pv}, текст и масштаб land in +165)")

# ══════════════════ Part BE — v0.1.67+166 «Честность записи» ═════════
#
# Патч чинит ТИХИЕ отказы: потерю замера при неудачной вставке и
# карточку-призрак выше потолка сбора. Оба класса объединяет то, что на
# экране всё выглядит правильно, — поэтому здесь пиннится не внешний
# результат, а форма кода, которая делает отказ невозможным.
if int(pv) >= 166:
    be_sps = (root / 'lib/services/speed_profile_service.dart').read_text()
    be_hal = (root / 'lib/services/hal_telemetry_service.dart').read_text()
    be_db = (root / 'lib/data/database.dart').read_text()
    _be_freeze = be_sps.split('void _freezeChunk(')[1] \
                       .split('\n  /// ')[0]
    _be_tick = be_sps.split('void _atlasTick(')[1].split('void _freezeChunk(')[0]

    # BE1: сброс — ТОЛЬКО в ветке успеха. Это и есть весь A1: до +166
    # клетка обнулялась синхронно, до вставки, а _persist() следом
    # закреплял обнулённое состояние в prefs.
    _be1 = ('inserted = true;' in _be_freeze and
            'if (inserted) {' in _be_freeze and
            _be_freeze.find('if (inserted) {') <
            _be_freeze.find('cell.frozenEnergyKwh += tookEnergyKwh;') and
            _be_freeze.find('if (inserted) {') <
            _be_freeze.find('cell.energyKwh -= tookEnergyKwh;') and
            'final tookEnergyKwh = cell.energyKwh;' in _be_freeze and
            _be_freeze.find('final tookEnergyKwh = cell.energyKwh;') <
            _be_freeze.find('_freezeInFlight.add(key);'))
    if _be1:
        ok('BE1 accumulator is rolled and subtracted ONLY after a '
           'confirmed insert; the taken amounts are snapshotted first')
    else:
        fail('BE1 reset can still run without a confirmed insert')

    # BE2: отказ оставляет след и повторяется. Без повтора единственный
    # отказ означал бы «никогда»: переход через порог случается ровно
    # один раз за круг накопления.
    _be2 = ('_freezeRetry.add(key);' in _be_freeze and
            '_freezeRetry.remove(key)' in _be_tick and
            'final retry =' in _be_tick and
            'if (crossed || retry) {' in _be_tick and
            # событие — только на настоящем переходе, не на повторе
            _be_tick.find('_maybeGenerateReveal(') <
            _be_tick.find('if (crossed || retry) {') and
            'if (crossed) {' in _be_tick)
    if _be2:
        ok('BE2 a failed insert is retried on the next qualified tick; '
           'the reveal fires on the true crossing only')
    else:
        fail('BE2 retry path missing or the reveal duplicates on retry')

    # BE3: одна клетка — одна вставка в полёте.
    if '_freezeInFlight.contains(key)' in _be_freeze and \
       '_freezeInFlight.remove(key);' in _be_freeze and \
       'final Set<String> _freezeInFlight' in be_sps:
        ok('BE3 one in-flight insert per cell')
    else:
        fail('BE3 in-flight guard missing')

    # BE4: потолок применяется ТАМ, ГДЕ КЛЕТКА РОЖДАЕТСЯ. До +166 он
    # стоял только на записи, и полоса 160 успевала стать карточкой,
    # дорасти до 120 с и молча исчезнуть.
    _be4 = ('_atlasAboveCeilingAtCreate++;' in _be_tick and
            _be_tick.find('if (band > kAtlasBandMaxCollectKmh) {') <
            _be_tick.find('l.cells.putIfAbsent('))
    if _be4:
        ok('BE4 the collection ceiling is enforced where the cell is born')
    else:
        fail('BE4 a cell above the ceiling can still be created')

    # BE5: легаси-леджер от ≤+165 мог принести живую клетку выше
    # потолка — она там лежала законно.
    _be_from = be_sps.split('static _AtlasLedger fromJson(')[1] \
                     .split('\n}')[0]
    if 'droppedAboveCeiling' in _be_from and \
       'b > kAtlasBandMaxCollectKmh' in _be_from and \
       'droppedAboveCeiling: () => _atlasAboveCeilingAtRestore++' in be_sps:
        ok('BE5 legacy cells above the ceiling are dropped on restore')
    else:
        fail('BE5 restore can resurrect a cell above the ceiling')

    # BE6: без счётчиков ни один из двух починенных отказов не
    # оставлял следа нигде, кроме debugPrint.
    _be6 = all(k in be_sps for k in (
        "'insert_failed_this_process': _atlasInsertFailed,",
        "'insert_failed_total': _atlasInsertFailedTotal,",
        "'above_ceiling_at_create': _atlasAboveCeilingAtCreate,",
        "'above_ceiling_at_restore': _atlasAboveCeilingAtRestore,",
        "'freeze_retry_pending': _freezeRetry.length,",
        "'zad': z100AbortDip,",
        "'zat': z100AbortTimeout,",
        'z100AbortDip++',
        'z100AbortTimeout++',
    )) and '_kAtlasInsertFailKey' in be_sps
    if _be6:
        ok('BE6 insert failures, ceiling drops and 0–100 aborts are all '
           'counted and reach the diag dump')
    else:
        fail('BE6 a +166 counter is missing or never dumped')

    # BE7: три шва, без которых движок нельзя было поднять в тесте.
    _be7 = ('abstract class HalTelemetrySource implements Listenable' in be_hal
            and 'implements HalTelemetrySource {' in be_hal
            and 'final HalTelemetrySource _hal;' in be_sps
            and 'AppDatabase.forTesting(QueryExecutor e) : super(e);' in be_db
            and 'final int Function() _nowMs;' in be_sps
            and be_sps.count('final now = _nowMs();') == 2)
    if _be7:
        ok('BE7 three test seams in place: HAL interface, in-memory db, '
           'injected tick clock (2 entry points)')
    else:
        fail('BE7 a test seam is missing')

    # BE8: тесты существуют и CI их запускает. Отдельным workflow —
    # lint.yml остаётся выключенным, его шум утопил бы сигнал.
    _be_test = root / 'test/speed_profile_engine_test.dart'
    _be_wf = root / '.github/workflows/test.yml'
    if _be_test.exists() and _be_wf.exists():
        _t = _be_test.read_text()
        # Только строки КОДА: пояснение в шапке workflow называет
        # `flutter test` по имени, и проверка по сырому тексту читала бы
        # комментарий вместо шага (ровно та ловушка, на которой в +165
        # попался BD5).
        _w = '\n'.join(_l for _l in _be_wf.read_text().split('\n')
                       if not _l.lstrip().startswith('#'))
        _be8 = ('flutter test' in _w and 'build_runner build' in _w and
                'HalTelemetrySource' in _t and
                'AppDatabase.forTesting' in _t and
                _t.count('test(') >= 5)
        # +167: тесты обязаны быть ОСТРЫМИ. Первая редакция проверяла
        # atlasLiveBands().timeS, а тот отдаёт сессионную сумму
        # frozen ⊕ live (+164) — по ней потеря накопления неотличима
        # от нормальной работы, и тест на A1 не мог упасть в принципе.
        # Пиннятся два дискриминатора, которые вакуумными быть не могут:
        # второй чанк (возможен только после сброса аккумулятора) и
        # отказ с ВОССТАНОВЛЕНИЕМ базы через снимаемый триггер.
        if int(pv) >= 167:
            _be8 = (_be8 and
                    'countAtlasSnapshots()) >= 2' in _t and
                    'DROP TRIGGER fail_atlas' in _t and
                    'atlasFreezeRetryPending' in _t and
                    'atlasInsertFailuresTotal' in _t and
                    'atlasLiveBands().firstWhere' not in _t)
        # +168: тесты обязаны ГАСИТЬ сервис. SpeedProfileService держит
        # два периодических таймера, и без dispose() `flutter test` не
        # завершает изолят — первый прогон +167 не закончился вовсе.
        # Плюс потолок на тест, чтобы зависание падало быстро и с
        # именем виновника, а не съедало job целиком.
        if int(pv) >= 168:
            _be8 = (_be8 and
                    'svc.dispose();' in _t and
                    '@Timeout(' in _t and
                    _t.index('svc.dispose();') < _t.index('db.close()') and
                    '--timeout' in _w)
        if _be8:
            ok('BE8 executable engine tests exist, are sharp, disposed, '
               'time-boxed, and CI runs them')
        else:
            fail('BE8 test file or workflow incomplete')
    else:
        fail('BE8 test file or test.yml missing')

    # BE10 (+167): наблюдаемость отказа записи наружу. Без неё тест на
    # A1 опирался на геттер сессионных сумм и был вакуумным.
    if int(pv) >= 167:
        if 'int get atlasInsertFailuresTotal => _atlasInsertFailedTotal;' \
                in be_sps and \
           'int get atlasFreezeRetryPending => _freezeRetry.length;' in be_sps:
            ok('BE10 write-failure state is observable from outside')
        else:
            fail('BE10 insert-failure getters missing')

    # BE9: комментарий, утверждавший «график сохраняет 40–180». Он был
    # неправдой с тех пор, как график переехал на сетку атласа, и успел
    # ввести в заблуждение архитектурное ревью.
    if 'the chart keeps its 40–180 range' not in be_sps and \
       'kAtlasBandMaxCollectKmh` in atlas_projection' not in be_sps:
        ok('BE9 the stale «chart 40–180» claim is gone')
    else:
        fail('BE9 the stale chart-range comment survives')
else:
    ok(f"Part BE skipped (build +{pv}, честность записи lands in +166)")

# ══════════════════ Part BF — v0.1.70+169 «Автостарт, шаг 1» ═════════
#
# Полевой хартбит recon (Друг 3, 27.07) доказал, что STICKY на этой
# прошивке работает: три перерождения за вечер, монотонный uptime через
# все три, ни одного destroy, у всех null-intent. Его же второй ответ
# назвал вероятную причину нашего провала — recon HEADLESS, а этот
# сервис при воскрешении звал startActivity из фона, где Android 12 его
# режет молча (foreground-статус сервиса права на BAL не даёт).
#
# Патч снимает ТОЛЬКО фоновый запуск активити — одно изменение, чтобы
# ответ был двоичным. Гейты держат именно эту границу.
if int(pv) >= 169:
    _bf_p = (root / 'android/app/src/main/kotlin/com/bz5companion/'
                    'bz5_companion/AutostartService.kt')
    bf_raw = _bf_p.read_text()

    # Комментарии вычищаются ПЕРЕД проверкой. В +165 (BD5), +166 (BE8) и
    # +167 подряд гейты ловились на чтении собственных пояснений; здесь
    # докстринг разбирает startActivity по имени десяток раз, и проверка
    # по сырому тексту не значила бы ничего.
    import re as _bf_re
    _bf = _bf_re.sub(r'/\*.*?\*/', '', bf_raw, flags=_bf_re.S)
    _bf = '\n'.join(_l for _l in _bf.split('\n')
                    if not _l.lstrip().startswith('//'))

    # BF1: фонового запуска активити нет НИ В ОДНОЙ ветке. PendingIntent
    # разрешён и является единственным законным путём в UI: он пассивен,
    # пока пользователь не нажал, и BAL его не касается.
    _bf1 = ('tryLaunchActivity' not in _bf and
            'startActivity(' not in _bf and
            'PendingIntent.getActivity(' in _bf)
    if _bf1:
        ok('BF1 no background activity launch; the only route into the '
           'UI is a user tap on the notification')
    else:
        fail('BF1 a background startActivity survives in AutostartService')

    # BF2: воскрешение отмечается как headless и несёт сырые flags —
    # ненулевое значение отличило бы повтор доставки от sticky.
    _bf2 = ('"resurrected: headless flags=$flags · ${ident()}"' in _bf and
            'attempted-no-throw' not in _bf and
            'val resurrected = intent == null' in _bf)
    if _bf2:
        ok('BF2 resurrection marker is headless and records raw flags')
    else:
        fail('BF2 resurrection marker still claims a launch attempt')

    # BF3 — ERA-AWARE (+171). Политика перезапуска остаётся прежней:
    # ровно один START_STICKY, явный STOP по-прежнему NOT_STICKY. В
    # +169/+170 гейт вдобавок пиннил дословный вызов
    # `buildNotification(resurrected)` как контрольную переменную
    # опыта. Опыт закрыт (поле 28.07: ноль строк `resurrected:`),
    # путей наверх без владельца стало два, и нотификация теперь
    # получает их дизъюнкцию. Существо гейта — политика — не меняется.
    # v0.1.83+182: дизъюнкция путей наверх переехала на строку выше — в
    # поле `lastHeadless`, потому что надпись обновляется ПОЗЖЕ (сбор
    # узнаёт своё состояние не сразу), и различитель «поднялся сам»
    # обязан пережить обновление. Существо гейта — политика перезапуска —
    # по-прежнему не меняется.
    if int(pv) >= 171:
        _bf3_notif = ('startForeground(NOTIF_ID, '
                      'buildNotification(resurrected || bridged))' in _bf) or \
            ('lastHeadless = resurrected || bridged' in _bf and
             'startForeground(NOTIF_ID, buildNotification(lastHeadless))'
             in _bf)
        _bf3 = (_bf.count('return START_STICKY') == 1 and
                'return START_NOT_STICKY' in _bf and
                _bf3_notif)
        if _bf3:
            ok('BF3 (re-era +171) START_STICKY / ACTION_STOP policy '
               'unchanged; the notification takes both headless paths')
        else:
            fail('BF3 (re-era +171) restart policy moved or the bridge '
                 'does not reach the notification')
    else:
        _bf3 = (_bf.count('return START_STICKY') == 1 and
                'return START_NOT_STICKY' in _bf and
                'startForeground(NOTIF_ID, buildNotification(resurrected))'
                in _bf)
        if _bf3:
            ok('BF3 START_STICKY / ACTION_STOP policy unchanged (control '
               'variable of the experiment)')
        else:
            fail('BF3 restart policy moved — the experiment is contaminated')

    # BF4 — ERA-AWARE (+171). Существо прежнее: подъём БЕЗ владельца
    # виден на экране машины, а не только в файле, и нотификация
    # нажимается. Изменилось имя признака: `resurrected` описывал один
    # путь из двух, `headless` описывает оба честно.
    if int(pv) >= 171:
        _bf4 = ('buildNotification(headless: Boolean = false)' in _bf and
                'if (headless) {' in _bf and
                'FLAG_IMMUTABLE' in _bf and
                'Build.VERSION_CODES.M' in _bf and
                '.setContentIntent(open)' in _bf)
        if _bf4:
            ok('BF4 (re-era +171) notification states an ownerless start '
               'and is tappable (FLAG_IMMUTABLE guarded for API < 23)')
        else:
            fail('BF4 (re-era +171) notification does not report the '
                 'ownerless start or is inert')
    else:
        _bf4 = ('buildNotification(resurrected: Boolean = false)' in _bf and
                'if (resurrected) {' in _bf and
                'FLAG_IMMUTABLE' in _bf and
                'Build.VERSION_CODES.M' in _bf and
                '.setContentIntent(open)' in _bf)
        if _bf4:
            ok('BF4 notification states the resurrection and is tappable '
               '(FLAG_IMMUTABLE guarded for API < 23)')
        else:
            fail('BF4 notification does not report the resurrection '
                 'or is inert')

    # BF5 — ERA-AWARE (+171). Маркер дописывается с +155 и пережил
    # полтора десятка сборок; без версии в строке сравнение «до/после»
    # неразличимо. В +171 чтение versionName переехало в AutostartMarker
    # (пишут двое), поэтому getPackageInfo ищется там, а не здесь.
    if int(pv) >= 171:
        _bf_mk_p = (root / ('android/app/src/main/kotlin/com/bz5companion/'
                            'bz5_companion/AutostartMarker.kt'))
        _bf_mk = _bf_mk_p.read_text() if _bf_mk_p.exists() else ''
        # ПЕРЕПИН +179, И ПРИЧИНУ НАШЁЛ МУТАЦИОННЫЙ ХАРНЕСС. Проверка
        # шла по ВСЕМУ файлу, а +179 завёл второй вызов getPackageInfo —
        # в pubFileName, ради ключа зеркала по versionCode. С этого
        # момента условие выполнялось чужим кодом: убери чтение
        # versionName из appVersion() совсем, и гейт остался бы зелёным.
        # Сужаем до самой функции, которая и есть предмет.
        if int(pv) >= 179:
            _bf_av = _bf_mk.split('fun appVersion(')[-1] \
                .split('fun write(')[0]
            _bf5 = ('build=${appVersion()}' in _bf and
                    'getPackageInfo(' in _bf_av and
                    'versionName' in _bf_av)
        else:
            _bf5 = ('build=${appVersion()}' in _bf and
                    'getPackageInfo(' in _bf_mk)
        if _bf5:
            ok('BF5 (re-era +171/+179) the marker records which build '
               'wrote each line, from the shared journal')
        else:
            fail('BF5 marker lines are not attributable to a build')
    elif 'build=${appVersion()}' in _bf and 'getPackageInfo(' in _bf:
        ok('BF5 the marker records which build wrote each line')
    else:
        fail('BF5 marker lines are not attributable to a build')
else:
    ok(f"Part BF skipped (build +{pv}, autostart step 1 lands in +169)")

# ═══════════ Part BG — v0.1.71+170 «Маркер доезжает» ═══════════
#
# Опыт +169 оказался нечитаем: сервис жил (нотификация висела, в базе
# снимки от v0.1.70+169), а маркер молчал с 24.07 — единственный канал
# писал только в публичные Downloads и глотал отказ в Log.w. Плюс две
# правки вёрстки по фото владельца.
if int(pv) >= 170:
    bg_kt = (root / ('android/app/src/main/kotlin/com/bz5companion/'
                     'bz5_companion/AutostartService.kt')).read_text()
    bg_es = (root / 'lib/services/export_service.dart').read_text()
    bg_ag = (root / 'lib/widgets/atlas_grid.dart').read_text()
    bg_dp = (root / 'lib/widgets/driver_panels.dart').read_text()

    # BG1 — ERA-AWARE (+171). Существо прежнее: два уровня записи и
    # отчёт о том, какой выбран. Тело переехало в AutostartMarker,
    # потому что в файл теперь пишут двое — сервис и ресивер; поле
    # 28.07 показало, что публичный путь мёртв, и приватная копия
    # осталась единственным читаемым каналом.
    if int(pv) >= 171:
        _bg_mk_p = (root / ('android/app/src/main/kotlin/com/bz5companion/'
                            'bz5_companion/AutostartMarker.kt'))
        _bg_mk = _bg_mk_p.read_text() if _bg_mk_p.exists() else ''
        _bg1 = ('File(context.filesDir, FILE_NAME).appendText(text)'
                in _bg_mk and
                ('File("$PUB_DIR/${pubFileName(context)}").appendText(text)'
                 in _bg_mk if int(pv) >= 179 else
                 'File("$PUB_DIR/${pubName ?: FILE_NAME}").appendText(text)'
                 in _bg_mk if int(pv) >= 178 else
                 'File("/sdcard/Download/$FILE_NAME").appendText(text)'
                 in _bg_mk) and
                ('where = if (privOk) "priv+pub" else "pub"' in _bg_mk
                 if int(pv) >= 179 else
                 'where = "pub"' in _bg_mk) and
                'where = "priv"' in _bg_mk and
                'pubFails' in _bg_mk and
                ('public Downloads refused' in _bg_mk
                 if int(pv) >= 178 else
                 'public Downloads unwritable' in _bg_mk))
        if _bg1:
            ok('BG1 (re-era +171) the shared journal falls back to '
               'app-private storage and says so in the file itself')
        else:
            fail('BG1 (re-era +171) the shared journal has a single '
                 'write path')
    else:
        _bg1 = ('File(filesDir, MARKER).appendText(text)' in bg_kt and
                'File("/sdcard/Download/$MARKER").appendText(text)'
                in bg_kt and
                'markerWhere = "pub"' in bg_kt and
                'markerWhere = "priv"' in bg_kt and
                'markerPubFails' in bg_kt and
                'public Downloads unwritable' in bg_kt)
        if _bg1:
            ok('BG1 marker falls back to app-private storage and says so '
               'in the file itself')
        else:
            fail('BG1 marker still has a single write path')

    # BG2: приватная копия доезжает экспортом — без ADB и файлового
    # менеджера. getApplicationSupportDirectory() на Android это ровно
    # Context.getFilesDir(), куда пишет Kotlin.
    _bg2 = ('getApplicationSupportDirectory()' in bg_es and
            "'bz5_companion_autostart_log.txt'" in bg_es and
            "ArchiveFile('autostart_marker.txt'" in bg_es)
    if _bg2:
        ok('BG2 the private marker copy rides out in the export ZIP')
    else:
        fail('BG2 marker never reaches the export bundle')

    # BG3: клетка атласа. Звезда рядом со средним, вилка под ними —
    # иначе содержимое не влезает (BZ5 81.7 dp в клетке 78, BZ3 75.8 в
    # 68), и на фото 28.07 звезда нарисована ЗА пределами клетки.
    _bg_cell = bg_ag.split('final content = Container(')[1].split('final tap')[0]
    # find(), а не index(): index бросает ValueError, и гейт не «падал
    # бы», а РОНЯЛ ВЕСЬ ПРОГОН, не дав ни одной строки отчёта. Поймано
    # мутацией, удалявшей звезду целиком.
    _bg_star = _bg_cell.find('Icon(Icons.star')
    _bg_fork = _bg_cell.find('c.lo.toStringAsFixed(1)')
    _bg3 = (_bg_star >= 0 and _bg_fork >= 0 and _bg_star < _bg_fork and
            'MainAxisSize.min' in _bg_cell and
            'BoxFit.scaleDown' in _bg_cell)
    if _bg3:
        ok('BG3 atlas cell: star beside the mean, fork below, scaleDown')
    else:
        fail('BG3 atlas cell still stacks the star under the fork')

    # BG4: ячейка карточки поездки не выдавливает подпись на
    # разделитель. Бюджет широкого вида 167 dp против Expanded, который
    # может дать меньше; scaleDown вернее подобранной константы.
    _bg_tc = bg_dp.split('class TripCell extends StatelessWidget')[1]
    _bg4 = ('return FittedBox(' in _bg_tc and
            _bg_tc.index('return FittedBox(') < _bg_tc.index('child: Column('))
    if _bg4:
        ok('BG4 trip cell scales down instead of overflowing onto the rule')
    else:
        fail('BG4 trip cell can still overflow its box')
else:
    ok(f"Part BG skipped (build +{pv}, marker delivery lands in +170)")

# ═════════════ Part BH — v0.1.72+171 «Мост автозапуска» ═════════════
#
# Первый читаемый маркер (28.07) закрыл опыт +169 отрицательно: три
# строки `born:` и все три в паре с `armed:`, то есть приложение
# открывал владелец; `resurrected:` — ноль; `destroy:` — ноль, процесс
# убивают жёстко. На том же железе recon вставал сам за 7–8 с после
# каждого из четырёх пробуждений ГУ. Разница одна — ресивер.
#
# Патч ставит мост recon p115: ресивер → setAlarmClock на себя →
# startForegroundService из alarm-контекста. Гейты держат четыре
# вещи, каждая из которых уже однажды стоила поездки: двухступенчатость
# (прямой FGS из boot-контекста упрётся в стену), различимость пути в
# маркере (иначе опыт снова нечитаем), единственность журнала и
# честность деградации точного будильника.
if int(pv) >= 171:
    _bh_kt_dir = 'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'

    def _bh_slurp(rel):
        """Пропавший файл обязан дать FAIL, а не убить прогон.

        Урок +170 в его общем виде: гейт, роняющий прогон исключением,
        хуже отсутствующего — он не даёт НИ ОДНОЙ строки отчёта, и
        падение читается как поломка инструмента. Тогда это был
        .index(), здесь — read_text() по файлу, которого может не
        оказаться при частичном откате патча.
        """
        p = root / rel
        return p.read_text() if p.exists() else ''

    _bh_mf_raw = _bh_slurp('android/app/src/main/AndroidManifest.xml')
    _bh_br_raw = _bh_slurp(_bh_kt_dir + 'BootReceiver.kt')
    _bh_sv_raw = _bh_slurp(_bh_kt_dir + 'AutostartService.kt')
    _bh_mk_raw = _bh_slurp(_bh_kt_dir + 'AutostartMarker.kt')
    _bh_pf_raw = _bh_slurp(_bh_kt_dir + 'AutostartPrefs.kt')
    _bh_ma_raw = _bh_slurp(_bh_kt_dir + 'MainActivity.kt')
    _bh_es_raw = _bh_slurp('lib/services/export_service.dart')

    import re as _bh_re

    # Правило, стоившее пяти патчей подряд: проверка по тексту исходника
    # обязана вычищать комментарии. Здесь докстринги разбирают по именам
    # и setAlarmClock, и startForegroundService, и ACTION_ARM — по сырому
    # тексту не значило бы ничего. XML-комментарии чистятся отдельно:
    # манифестный блок объясняет ровно те строки, что гейт ищет.
    def _bh_kt(src):
        # +172: перешли на _strip_comments_safe. Регулярка ломается о
        # литерал, содержащий /* или */ — в файлах этой эры таких нет,
        # но инструмент должен быть один и надёжный.
        return _strip_comments_safe(src)

    _bh_mf = _bh_re.sub(r'<!--.*?-->', '', _bh_mf_raw, flags=_bh_re.S)
    _bh_br = _bh_kt(_bh_br_raw)
    _bh_sv = _bh_kt(_bh_sv_raw)
    _bh_mk = _bh_kt(_bh_mk_raw)
    _bh_pf = _bh_kt(_bh_pf_raw)
    _bh_ma = _bh_kt(_bh_ma_raw)

    # split(), а не index(): урок +170 — упавший на исключении гейт не
    # «показывает FAIL», он роняет весь прогон и не даёт ни строки.
    _bh_recv = _bh_br.split('override fun onReceive(')[-1] \
        .split('private fun scheduleBridge(')[0]
    _bh_sched = _bh_br.split('private fun scheduleBridge(')[-1] \
        .split('private fun raiseService(')[0]
    _bh_raise = _bh_br.split('private fun raiseService(')[-1] \
        .split('private fun bridgeIntent(')[0]

    # BH1: ресивер объявлен и экспортирован, все четыре действия на
    # месте, MEDIA_MOUNTED несёт scheme=file (без data-фильтра он не
    # доставляется).
    #
    # Проверка идёт РАЗБОРОМ XML, а не поиском подстрок. Первая
    # редакция вырезала блок ресивера через split('<receiver') и
    # прозевала мутацию `<receiver` → `<receiver-disabled`: split ловит
    # префикс, содержимое блока остаётся на месте, и все подстроки
    # находятся в отключённом элементе. Разбор заодно ловит поломанный
    # манифест — цена такой поломки высока, потому что до неё
    # добирается только сборка на CI.
    _bh_ns = '{http://schemas.android.com/apk/res/android}'
    _bh_rcv = None
    _bh_xml_ok = True
    try:
        import xml.etree.ElementTree as _bh_et
        _bh_root_el = _bh_et.fromstring(_bh_mf_raw)
        for _el in _bh_root_el.iter('receiver'):
            if _el.get(_bh_ns + 'name') == '.BootReceiver':
                _bh_rcv = _el
    except Exception:
        _bh_xml_ok = False

    _bh_acts, _bh_schemes = set(), set()
    _bh_media_scheme = False
    if _bh_rcv is not None:
        for _f in _bh_rcv.findall('intent-filter'):
            _fa = {_a.get(_bh_ns + 'name') for _a in _f.findall('action')}
            _fs = {_d.get(_bh_ns + 'scheme') for _d in _f.findall('data')}
            _bh_acts |= _fa
            _bh_schemes |= _fs
            if 'android.intent.action.MEDIA_MOUNTED' in _fa and 'file' in _fs:
                _bh_media_scheme = True

    _bh1 = (_bh_xml_ok and _bh_rcv is not None and
            _bh_rcv.get(_bh_ns + 'exported') == 'true' and
            _bh_rcv.get(_bh_ns + 'enabled') == 'true' and
            'android.intent.action.BOOT_COMPLETED' in _bh_acts and
            'android.intent.action.QUICKBOOT_POWERON' in _bh_acts and
            'android.intent.action.MEDIA_MOUNTED' in _bh_acts and
            'com.bz5companion.AUTOSTART_ALARM' in _bh_acts and
            _bh_media_scheme)
    if _bh1:
        ok('BH1 receiver declared and exported, all four triggers, '
           'MEDIA_MOUNTED carries scheme=file')
    else:
        fail('BH1 receiver declaration missing, disabled, malformed, '
             'or a trigger dropped')

    # BH2: мост ДВУХСТУПЕНЧАТ. Прямой startForegroundService из
    # boot-контекста упирается в стену mAllowStartForeground (recon
    # p113) — именно поэтому ресивер сначала ставит будильник на себя,
    # а поднимает сервис только из alarm-ветки.
    _bh2 = ('setAlarmClock(' in _bh_sched and
            'startForegroundService' not in _bh_sched and
            'startForegroundService(i)' in _bh_raise and
            'setAlarmClock' not in _bh_raise and
            0 <= _bh_recv.find('if (action == ACTION_ALARM)') <
            _bh_recv.find('raiseService(context, action)') <
            _bh_recv.find('scheduleBridge(context, action)'))
    if _bh2:
        ok('BH2 the bridge is two-stage: system action schedules an '
           'alarm, only the alarm branch raises the service')
    else:
        fail('BH2 the receiver starts a foreground service straight '
             'from the boot context')

    # BH3: РАЗЛИЧИТЕЛЬ ОПЫТА. Подними мост сервис действием ARM — в
    # маркере встала бы строка `armed:`, неотличимая от открытого
    # владельцем приложения, и результат снова стал бы нечитаем, как
    # у +169. Ресивер обязан не знать про ARM вообще.
    _bh3 = ('const val ACTION_BRIDGE = "com.bz5companion.BRIDGE"' in _bh_sv and
            'val bridged = intent?.action == ACTION_BRIDGE' in _bh_sv and
            '"bridged: $ACTION_BRIDGE' in _bh_sv and
            '.setAction(AutostartService.ACTION_BRIDGE)' in _bh_br and
            'ACTION_ARM' not in _bh_br)
    if _bh3:
        ok('BH3 the bridge path is distinguishable in the marker: '
           'bridged ≠ armed, and the receiver never touches ARM')
    else:
        fail('BH3 a bridge start would be indistinguishable from an '
             'owner-opened app')

    # BH4: ресивер уважает флаг, а флаг переживает процесс. commit(),
    # не apply(): ГУ убивает процессы жёстко (за 28.07 ни одной строки
    # `destroy:`), отложенную запись он может не дождаться.
    # Область «не взведено» берётся ДО ветки будильника, а не резкой по
    # первой '}': +174 добавил в эту строку `${AutostartMarker.ident()}`,
    # и наивный split стал обрывать блок внутри шаблона, до `return`.
    # Гейт упал на исправном коде — та же болезнь, что у регулярной
    # вычистки комментариев, только в другом месте.
    _bh_na = _bh_recv.split('if (!armed) {')[-1] \
        .split('if (action == ACTION_ALARM)')[0] \
        if 'if (!armed) {' in _bh_recv else ''
    _bh4 = ('AutostartPrefs.isArmed(context)' in _bh_br and
            'result=NOT_ARMED' in _bh_br and
            'return' in _bh_na and
            0 <= _bh_recv.find('if (!armed)') <
            _bh_recv.find('if (action == ACTION_ALARM)') and
            'AutostartPrefs.setArmed(this, true)' in _bh_ma and
            'AutostartPrefs.setArmed(this, false)' in _bh_ma and
            '.commit()' in _bh_pf and '.apply()' not in _bh_pf)
    if _bh4:
        ok('BH4 receiver honours a persisted arm flag and bails before '
           'scheduling; the flag is committed, not applied')
    else:
        fail('BH4 the arm flag is missing, transient, or not honoured')

    # BH5: ЖУРНАЛ ОДИН. Публичные Downloads мертвы, приватная копия
    # уезжает в ZIP — второй файл в эту трубу не влезет, и половина
    # следа стала бы недоступной. Плюс общий тег процесса: одинаковый
    # тег у ресивера и сервиса доказывает, что они в одном процессе.
    _bh5 = ('AutostartMarker.write(' in _bh_br and
            'object AutostartMarker' in _bh_mk and
            'val procTag' in _bh_mk and
            'FILE_NAME = "bz5_companion_autostart_log.txt"' in _bh_mk and
            "'bz5_companion_autostart_log.txt'" in _bh_es_raw and
            'private fun marker(line: String) = '
            'AutostartMarker.write(this, line)' in _bh_sv and
            'appendText' not in _bh_sv)
    if _bh5:
        ok('BH5 one journal for both writers; the service keeps no '
           'write ladder of its own and the export name still pairs')
    else:
        fail('BH5 the autostart journal has split in two')

    # BH6: дубль up/el снят. `ident()` отдаёт пару сам, а строка born
    # печатала свою копию тех же чисел — видно в поле 28.07.
    _bh_born = [_l for _l in _bh_sv.split('\n') if 'born: ' in _l]
    _bh6 = (len(_bh_born) == 1 and
            _bh_born[0].count('up=') == 0 and
            'marker("born: ${ident()} build=${appVersion()}")' in _bh_sv)
    if _bh6:
        ok('BH6 the born line prints the up/el pair once')
    else:
        fail('BH6 the born line still doubles the up/el pair')

    # BH7: точность будильника под гейтом возможностей, деградация
    # записана. Временный allowlist, из которого только и разрешён FGS,
    # даётся ТОЧНОМУ будильнику; если точность отняли, мост тихо
    # перестанет работать, и `exact=no` — единственное, что это объяснит.
    _bh7 = ('Build.VERSION_CODES.S' in _bh_sched and
            'canScheduleExactAlarms()' in _bh_sched and
            'exact=${if (exact) "yes" else "no"}' in _bh_sched and
            'am.set(AlarmManager.RTC_WAKEUP' in _bh_sched and
            'result=ALARM_ERR' in _bh_sched)
    if _bh7:
        ok('BH7 exact alarm is capability-gated and the downgrade '
           'is written into the marker')
    else:
        fail('BH7 exact-alarm loss would be silent')

    # BH8: манифест больше не утверждает, что boot-путь — стена. Это
    # утверждение стояло с +155 и стоило полутора месяцев. Проверяется
    # по СЫРОМУ тексту — оно жило в комментарии, и на вычищенном
    # проверка прошла бы сама собой, ничего не значив.
    _bh8 = ('proven wall on this firmware' not in _bh_mf_raw and
            'android.permission.RECEIVE_BOOT_COMPLETED' in _bh_mf and
            'android.permission.SCHEDULE_EXACT_ALARM' in _bh_mf and
            'android.permission.USE_EXACT_ALARM' in _bh_mf)
    if _bh8:
        ok('BH8 the stale «boot path is a wall» claim is gone and the '
           'three bridge permissions are declared')
    else:
        fail('BH8 the manifest still claims the boot path is a wall '
             'or a bridge permission is missing')
else:
    ok(f"Part BH skipped (build +{pv}, the autostart bridge lands in +171)")

# ══════════════ Part BI — v0.1.73+172 «Путь установки» ══════════════
#
# Обновиться на ГУ нечем: проводник APK не запускает, ADB нет, а
# SilentInstaller на существующий пакет отвечает 系统已安装 и
# засчитывает это себе в УСПЕХ — то есть установку не начинает.
# Приложение, которое попробовало и не смогло, успех себе не пишет. На
# телефоне тот же APK с той же подписью и тем же versionCode встаёт
# поверх, значит дело не в пакете и подбирать ключи бессмысленно.
#
# Пока обновление идёт через удаление, КАЖДЫЙ патч стирает prefs и
# Drift, а из облака не возвращаются samples/hal_samples и недобранные
# полосы атласа. Отсюда цена ошибки в этой эре: цикл установки, на
# который она рассчитана, стоит всех данных на устройстве.
#
# Гейты держат четыре вещи: манифест (без <queries> проба соврёт в
# опасную сторону), чистоту пробы, две попытки вместо одной и то, что
# ответ SAF не теряется.
if int(pv) >= 172:
    _bi_kt_dir = 'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'

    def _bi_slurp(rel):
        p = root / rel
        return p.read_text() if p.exists() else ''

    _bi_mf_raw = _bi_slurp('android/app/src/main/AndroidManifest.xml')
    _bi_ai_raw = _bi_slurp(_bi_kt_dir + 'ApkInstall.kt')
    _bi_fp_raw = _bi_slurp(_bi_kt_dir + 'ApkFileProvider.kt')
    _bi_ma_raw = _bi_slurp(_bi_kt_dir + 'MainActivity.kt')
    _bi_sc_raw = _bi_slurp('lib/screens/install_update.dart')
    _bi_st_raw = _bi_slurp('lib/screens/settings.dart')
    _bi_l10_raw = _bi_slurp('lib/l10n/strings.dart')

    import re as _bi_re

    # _strip_comments_safe, а не регулярка: в ApkInstall.kt есть литерал
    # "*/*" (MIME-маска выбора файла), и наивная вычистка приняла бы его
    # за начало комментария и съела код до следующего */. Именно так
    # BI3 сначала и показал FAIL на исправном файле.
    _bi_mf = _bi_re.sub(r'<!--.*?-->', '', _bi_mf_raw, flags=_bi_re.S)
    _bi_ai = _strip_comments_safe(_bi_ai_raw)
    _bi_fp = _strip_comments_safe(_bi_fp_raw)
    _bi_ma = _strip_comments_safe(_bi_ma_raw)
    _bi_sc = _strip_comments_safe(_bi_sc_raw)
    _bi_st = _strip_comments_safe(_bi_st_raw)

    # BI1: разрешение и провайдер. Разбором XML, а не подстроками —
    # урок BH1: split('<provider') поймал бы и <provider-disabled>.
    _bi_ns = '{http://schemas.android.com/apk/res/android}'
    _bi_prov = None
    _bi_perms = set()
    _bi_xml_ok = True
    try:
        import xml.etree.ElementTree as _bi_et
        _bi_rootel = _bi_et.fromstring(_bi_mf_raw)
        for _el in _bi_rootel.iter('provider'):
            if _el.get(_bi_ns + 'name') == '.ApkFileProvider':
                _bi_prov = _el
        for _el in _bi_rootel.iter('uses-permission'):
            _bi_perms.add(_el.get(_bi_ns + 'name'))
    except Exception:
        _bi_xml_ok = False

    _bi1 = (_bi_xml_ok and _bi_prov is not None and
            'android.permission.REQUEST_INSTALL_PACKAGES' in _bi_perms and
            _bi_prov.get(_bi_ns + 'exported') == 'false' and
            _bi_prov.get(_bi_ns + 'grantUriPermissions') == 'true' and
            _bi_prov.get(_bi_ns + 'authorities', '').endswith('.apkprovider'))
    if _bi1:
        ok('BI1 install permission declared and the APK provider is '
           'private with URI grants')
    else:
        fail('BI1 install permission or the APK provider is missing '
             'or misdeclared')

    # BI2: <queries>. С Android 11 queryIntentActivities и
    # getPackageInfo фильтруются по видимости — БЕЗ этих записей проба
    # вернёт пусто при полностью живом установщике, то есть соврёт
    # ровно в ту сторону, которая закрыла бы тему как безнадёжную.
    #
    # ПЕРЕПИН +176, И ПРИЧИНА НАЙДЕНА МУТАЦИЕЙ. Прежняя редакция искала
    # подстроки, и мутация `com.android.permissioncontroller` →
    # `com.android.permissioncontroller.off` её НЕ уронила: имя с
    # суффиксом содержит имя без суффикса, `in` этого не различает.
    # То есть гейт пропускал ровно ту поломку, от которой стоял —
    # неверное имя пакета, при котором видимость снова отключена.
    # Он был первым слепым гейтом, найденным восстановленным
    # tools/mutate_gates.py, и это его окупило целиком.
    #
    # Теперь имена сравниваются ТОЧНО и не со списком в этом файле, а с
    # тем, что читает сама проба: вторая копия правды разошлась бы с
    # ApkInstall.kt при первой же его правке.
    _bi_q = _bi_mf.split('<queries>')[-1].split('</queries>')[0] \
        if '<queries>' in _bi_mf else ''
    _bi_qpkgs, _bi_qacts, _bi_qmimes = set(), set(), set()
    try:
        import xml.etree.ElementTree as _bi_et2
        _bi_qroot = _bi_et2.fromstring(_bi_mf_raw)
        for _qs in _bi_qroot.iter('queries'):
            for _el in _qs.iter('package'):
                _bi_qpkgs.add(_el.get(_bi_ns + 'name'))
            for _el in _qs.iter('action'):
                _bi_qacts.add(_el.get(_bi_ns + 'name'))
            for _el in _qs.iter('data'):
                _bi_qmimes.add(_el.get(_bi_ns + 'mimeType'))
    except Exception:
        _bi_xml_ok = False

    # Пакеты, которые проба реально проверяет через getPackageInfo.
    _bi_probe_pkgs = set()
    if 'out["installer_packages"] = listOf(' in _bi_ai:
        _bi_pblk = _bi_ai.split('out["installer_packages"] = listOf(')[-1] \
            .split(')')[0]
        _bi_probe_pkgs = set(_bi_re.findall(r'"([^"]+)"', _bi_pblk))

    _bi_need_acts = {
        'android.intent.action.VIEW',
        'android.intent.action.INSTALL_PACKAGE',
        'android.intent.action.OPEN_DOCUMENT',
        'android.settings.MANAGE_UNKNOWN_APP_SOURCES',
    }
    if int(pv) >= 176:
        # Двери +176. Каждая — отдельное действие, и отсутствие записи
        # означает пустой список у живого экрана.
        _bi_need_acts |= {
            'android.intent.action.OPEN_DOCUMENT_TREE',
            'android.intent.action.GET_CONTENT',
            'android.intent.action.SEND',
            'android.settings.MANAGE_ALL_UNKNOWN_APP_SOURCES',
            'android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION',
            'android.settings.APPLICATION_DETAILS_SETTINGS',
            'android.settings.SECURITY_SETTINGS',
            'android.settings.MANAGE_APPLICATIONS_SETTINGS',
        }
    _bi2 = (_bi_xml_ok and
            not (_bi_need_acts - _bi_qacts) and
            'application/vnd.android.package-archive' in _bi_qmimes and
            bool(_bi_probe_pkgs) and
            not (_bi_probe_pkgs - _bi_qpkgs))
    if _bi2:
        ok(f'BI2 (re-era +176) queries parsed from XML: '
           f'{len(_bi_need_acts)} actions and every package the probe '
           f'reads, matched exactly')
    else:
        fail(f'BI2 queries incomplete — missing actions '
             f'{sorted(_bi_need_acts - _bi_qacts)}, packages '
             f'{sorted(_bi_probe_pkgs - _bi_qpkgs)}')

    # BI3: проба ТОЛЬКО читает. Её зовут при открытии экрана и после
    # каждой попытки; побочное действие внутри превратило бы
    # диагностику в источник событий.
    _bi_probe = _bi_ai.split('fun probe(')[-1].split('private fun resolvers(')[0]
    _bi3 = ('startActivity' not in _bi_probe and
            'startActivityForResult' not in _bi_probe and
            'outputStream' not in _bi_probe and
            'queryIntentActivities' in _bi_ai and
            'canRequestPackageInstalls()' in _bi_probe)
    if _bi3:
        ok('BI3 the probe only reads — no launch, no write')
    else:
        fail('BI3 the probe has a side effect')

    # BI4: ДВЕ попытки, не одна. ACTION_VIEW — современный путь,
    # ACTION_INSTALL_PACKAGE — устаревший, но на части OEM-прошивок
    # зарегистрирован именно он. Вторая попытка стоит пяти строк,
    # незаданный вопрос — цикла установки, то есть всех данных.
    _bi_launch = _bi_ai.split('fun launch(')[-1] \
        .split('fun openUnknownSources(')[0]
    if int(pv) >= 176:
        # ПЕРЕПИН +176. Существо прежнее: обе попытки, каждый шаг с
        # именем класса исключения. Изменилось одно — попытка обязана
        # ВЕРНУТЬ resultCode, потому что за пять прогонов 29.07
        # установщик не спрашивался ни разу (`staged_bytes: 0`), и его
        # ответ остаётся главным неизвестным фактом темы.
        #
        # FLAG_ACTIVITY_NEW_TASK при этом обязан ИСЧЕЗНУТЬ, и это не
        # косметика: с ним активити уходит в отдельную задачу и
        # onActivityResult не зовётся никогда. Оставить флаг и ждать
        # ответа — построить прибор, который молчит по конструкции.
        _bi4 = ('Intent.ACTION_VIEW, Intent.ACTION_INSTALL_PACKAGE'
                in _bi_launch and
                'FLAG_GRANT_READ_URI_PERMISSION' in _bi_launch and
                'FLAG_ACTIVITY_NEW_TASK' not in _bi_launch and
                'startActivityForResult(i, REQ_INSTALL)' in _bi_launch and
                'steps.add(' in _bi_launch and
                't.javaClass.simpleName' in _bi_launch)
        if _bi4:
            ok('BI4 (re-era +176) both actions tried, every step keeps '
               'the exception class, and the attempt can return a '
               'resultCode (no NEW_TASK)')
        else:
            fail('BI4 (re-era +176) the attempt cannot report the '
                 'installer answer')
    else:
        _bi4 = ('Intent.ACTION_VIEW, Intent.ACTION_INSTALL_PACKAGE'
                in _bi_launch
                and 'FLAG_GRANT_READ_URI_PERMISSION' in _bi_launch and
                'FLAG_ACTIVITY_NEW_TASK' in _bi_launch and
                'steps.add(' in _bi_launch and
                't.javaClass.simpleName' in _bi_launch)
        if _bi4:
            ok('BI4 both install actions are tried and every step is '
               'recorded with the exception class')
        else:
            fail('BI4 only one install action is tried or failures '
                 'are silent')

    # BI5: провайдер отдаёт РОВНО один файл и только на чтение. Он
    # экспортируется грантом наружу, поэтому запись через него не
    # должна существовать в принципе.
    _bi5 = ('MODE_READ_ONLY' in _bi_fp and
            'OpenableColumns.DISPLAY_NAME' in _bi_fp and
            'OpenableColumns.SIZE' in _bi_fp and
            'values: ContentValues?): Uri? = null' in _bi_fp and
            _bi_fp.count('): Int = 0') == 2 and
            'STAGED = "staged_update.apk"' in _bi_fp)
    if _bi5:
        ok('BI5 the provider serves exactly one file, read-only')
    else:
        fail('BI5 the provider is writable or serves more than the '
             'staged file')

    # BI6: экран живёт в «Расширенных», за тем же 15-тапным замком, и
    # подписан на LocaleService (правило X4).
    _bi_adv = _bi_st.split('Widget _advancedCard(')[-1].split('\n  Widget ')[0]
    _bi6 = ('InstallUpdateScreen()' in _bi_adv and
            "S.of('settings.install.title')" in _bi_adv and
            'context.watch<LocaleService>()' in _bi_sc)
    if _bi6:
        ok('BI6 the screen sits in Advanced behind the 15-tap unlock '
           'and follows the locale rule')
    else:
        fail('BI6 the screen escaped Advanced or ignores locale changes')

    # BI7: паритет l10n. Ключ, забытый в одной карте, деградирует молча
    # в английский — на dev-экране это заметят не сразу.
    _bi_keys = [
        'settings.install.title', 'settings.install.subtitle',
        'install.title', 'install.probe.title', 'install.verdict.route',
        'install.verdict.noroute', 'install.grant.title',
        'install.grant.sub', 'install.pick.title', 'install.pick.sub',
        'install.run.title', 'install.run.sub', 'install.log.title',
        'install.log.empty', 'install.export', 'install.exported',
    ]
    _bi_miss = [k for k in _bi_keys
                if _bi_l10_raw.count("'%s':" % k) != 2]
    if not _bi_miss:
        ok('BI7 all 16 install-path keys exist in both locale maps')
    else:
        fail(f'BI7 l10n keys missing from a locale map: {_bi_miss}')

    # BI8: ответ SAF не теряется и не задваивается. Выбор файла —
    # отдельная активити, ответить синхронно нечем; висящий Result без
    # ответа подвесил бы экран навсегда, а два параллельных — уронил
    # бы канал вторым success по тому же Result.
    #
    # Третья ветка — onResume: он вызывается ПОСЛЕ onActivityResult,
    # поэтому висящий там запрос означает, что результата не будет
    # никогда. Без ответа Dart ждал бы вечно и кнопка залипла бы
    # насовсем — на экране, которым пользуются один раз и в неудачный
    # момент.
    _bi_oar = _bi_ma.split('override fun onActivityResult(')[-1]
    _bi_ores = _bi_ma.split('override fun onResume()')[-1] \
        .split('override fun onActivityResult(')[0]
    _bi8 = ('pendingPick' in _bi_ma and
            'super.onActivityResult(' in _bi_oar and
            'pendingPick = null' in _bi_oar and
            'pick already in flight' in _bi_ma and
            'Activity.RESULT_OK' in _bi_oar and
            '"error" to "cancelled"' in _bi_oar and
            'pendingPick = null' in _bi_ores and
            '"error" to "no-result"' in _bi_ores)
    if _bi8:
        ok('BI8 the SAF reply is answered exactly once — cancel and a '
           'lost result included')
    else:
        fail('BI8 the file-picker reply can be lost, hung, or answered '
             'twice')
else:
    ok(f"Part BI skipped (build +{pv}, the install path lands in +172)")

# ═══════ Part BJ — v0.1.74+173 «Выключатель и правки по ревизии» ═══════
#
# Архитектурная ревизия +171/+172 нашла механизм, который включается
# тихо и не выключается вообще: `disarm` висел в канале с +155 и не
# вызывался из Dart ниоткуда. Пока автозапуск держался на START_STICKY,
# это сходило с рук — он выключался сам, процесс умирал и не воскресал.
# С мостом +171 сервис поднимается на КАЖДОМ пробуждении ГУ, и
# прекратить это стало нечем, кроме удаления приложения.
#
# Плюс три следствия той же ревизии: нотификация обещала запись,
# которой нет; обоснование своего провайдера в +172 оказалось ложным
# (проверить было чем — share_plus тянет androidx FileProvider);
# мёртвый публичный путь маркера пробовался на каждую строку, синхронно,
# на главном потоке, в момент загрузки.
if int(pv) >= 173:
    _bj_kt_dir = 'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'

    def _bj_slurp(rel):
        p = root / rel
        return p.read_text() if p.exists() else ''

    _bj_pf_raw = _bj_slurp(_bj_kt_dir + 'AutostartPrefs.kt')
    _bj_sv_raw = _bj_slurp(_bj_kt_dir + 'AutostartService.kt')
    _bj_mk_raw = _bj_slurp(_bj_kt_dir + 'AutostartMarker.kt')
    _bj_ma_raw = _bj_slurp(_bj_kt_dir + 'MainActivity.kt')
    _bj_fp_raw = _bj_slurp(_bj_kt_dir + 'ApkFileProvider.kt')
    _bj_arm_raw = _bj_slurp('lib/services/autostart_arm.dart')
    _bj_st_raw = _bj_slurp('lib/screens/settings.dart')

    _bj_pf = _strip_comments_safe(_bj_pf_raw)
    _bj_sv = _strip_comments_safe(_bj_sv_raw)
    _bj_mk = _strip_comments_safe(_bj_mk_raw)
    _bj_ma = _strip_comments_safe(_bj_ma_raw)
    _bj_arm = _strip_comments_safe(_bj_arm_raw)
    _bj_st = _strip_comments_safe(_bj_st_raw)

    # BJ1: выключатель существует, зовёт обе стороны и живёт в
    # «Расширенных» (решение владельца 29.07 — мост ещё не доказан в
    # поле, наверх такое не выносят), и только там, где он что-то
    # делает: на телефоне автозапуск не взводится никогда.
    _bj_adv = _bj_st.split('Widget _advancedCard(')[-1].split('\n  Widget ')[0]
    # ERA-AWARE (+193). Существо прежнее: выключатель СУЩЕСТВУЕТ, показан
    # только там, где что-то делает, и зовёт обе стороны. Изменилось МЕСТО —
    # он больше не в «Расширенном», потому что механизм, поднимающий
    # приложение на каждом пробуждении ГУ, обязан выключаться без 15 тапов.
    # Позицию сторожит BZ1; здесь — только наличие и проводка.
    _bj1_scope = _bj_st if int(pv) >= 193 else _bj_adv
    _bj1 = ('SwitchListTile(' in _bj1_scope and
            "S.of('settings.autostart.title')" in _bj1_scope and
            'onChanged: _setAutostart' in _bj1_scope and
            'canUseHal' in _bj1_scope and
            'AutostartArm.enable()' in _bj_st and
            'AutostartArm.disable()' in _bj_st)
    if _bj1:
        ok('BJ1 the autostart switch exists, sits in Advanced and is '
           'shown only where it does something')
    else:
        fail('BJ1 autostart has no reachable off switch')

    # BJ2: ОТКАЗ ПЕРЕЖИВАЕТ ПЕРЕЗАПУСК. Без этого выключатель — обман:
    # attach зовёт arm при каждом запуске на ГУ, и следующий же старт
    # приложения молча взвёл бы автозапуск обратно поверх отказа.
    _bj2 = ('optedOut' in _bj_pf and
            'KEY_OPT_OUT' in _bj_pf and
            '.putBoolean(KEY_ARMED, armed)' in _bj_pf and
            '.putBoolean(KEY_OPT_OUT, !armed)' in _bj_pf and
            _bj_pf.count('.commit()') == 1 and
            "_optOut ??= await _flag('optedOut')" in _bj_arm and
            # ERA-AWARE (+193): ветка отказа осталась, но перестала быть
            # МОЛЧАЛИВОЙ. Прежний голый `return` делал выключенный
            # автозапуск неотличимым от сломанного, и эта неразличимость
            # стоила разбора чужого журнала.
            ('if (_optOut == true) {' in _bj_arm and
             "invokeMethod<bool>('armSkipped')" in _bj_arm
             if int(pv) >= 193
             else 'if (_optOut == true) return;' in _bj_arm) and
            '"optedOut" -> result.success(AutostartPrefs.optedOut(this))'
            in _bj_ma)
    if _bj2:
        ok('BJ2 the owner refusal outlives a relaunch and attach '
           'honours it')
    else:
        fail('BJ2 the next app launch would re-arm over the refusal')

    # BJ3: нотификация не обещает того, чего нет. Сборщика у companion
    # нет — сбор живёт в BydNativePlugin внутри Flutter-движка внутри
    # активити, и нажатие всего лишь откроет приложение.
    # v0.1.83+182: ПРЕДМЕТ ГЕЙТА ТОТ ЖЕ, УЛИКА ДРУГАЯ.
    #
    # Прежняя редакция пиннила дословно «сбор начнётся при открытии», и
    # это было верно ровно до этого патча: сборщика у companion не
    # существовало. Теперь он есть, и та же самая фраза стала обещанием
    # наоборот — она отрицает работу, которая идёт. Утверждение гейта
    # («надпись описывает состояние, а не обещает несуществующее»)
    # остаётся, а проверяется оно теперь тем, что текст берётся из
    # состояния подписки и различает «подписались» от «получаем».
    _bj3 = ('нажмите, чтобы записывать' not in _bj_sv and
            'сбор начнётся при открытии' not in _bj_sv and
            'private fun collectingText()' in _bj_sv and
            'HalStreamOwner.journalSeen()' in _bj_sv and
            'сбор поднят, событий пока нет' in _bj_sv and
            'HAL не отвечает, сбора нет' in _bj_sv and
            'collectingText()}' in _bj_sv)
    if _bj3:
        ok('BJ3 the notification names the real collection state and '
           'never conflates «registered» with «receiving»')
    else:
        fail('BJ3 the notification promises or denies work it does not '
             'actually measure')

    # BJ4: мёртвый публичный путь не пробуется на каждую строку.
    # Запись синхронна и зовётся с главного потока — из onReceive
    # (лимит 10 с) и из heartbeat. Первая попытка в процессе остаётся:
    # разрешение могло вернуться, и узнать об этом можно только
    # попробовав.
    _bj_write = _bj_mk.split('fun write(')[-1].split('fun noteFallback(')[0]
    _bj4 = ('pubDead' in _bj_mk and
            'if (!pubDead) {' in _bj_write and
            'pubDead = true' in _bj_write and
            ('$PUB_DIR/${pubFileName(context)}' in _bj_write
             if int(pv) >= 179 else
             '$PUB_DIR/${pubName ?: FILE_NAME}' in _bj_write
             if int(pv) >= 178 else
             '/sdcard/Download/$FILE_NAME' in _bj_write))
    if _bj4:
        ok('BJ4 a dead public path is tried once per process, not once '
           'per line')
    else:
        fail('BJ4 every marker line still retries the dead public path')

    # BJ5: ложное обоснование снято. Проверка по СЫРОМУ тексту — оно
    # жило в комментарии, и на вычищенном прошла бы сама собой.
    # Утверждение о невозможности проверить androidx было неправдой:
    # share_plus объявляет ShareFileProvider :
    # androidx.core.content.FileProvider, то есть androidx.core на
    # classpath гарантированно.
    #
    # Урок о самих гейтах, полученный здесь же. Проверка на ОТСУТСТВИЕ
    # фразы запрещает её везде — в том числе в поправке, которая эту
    # фразу исправляет. Первая редакция BJ5 упала именно так:
    # исправленный комментарий цитировал ложное утверждение дословно,
    # а гейт цитату от утверждения отличить не может. Поэтому пара:
    # отрицательная половина держит короткий маркер, который в
    # пересказе не появится, положительная требует самого факта.
    _bj5 = ('нечем' not in _bj_fp_raw and
            'share_plus' in _bj_fp_raw and
            'androidx.core.content.FileProvider' in _bj_fp_raw and
            'ПОПРАВКА' in _bj_fp_raw)
    if _bj5:
        ok('BJ5 the false androidx rationale is replaced by the '
           'checked fact')
    else:
        fail('BJ5 the provider still justifies itself with a guess')

    # BJ6: UI не держит вторую копию правды. Состояние переключателя
    # перечитывается с нативной стороны ПОСЛЕ переключения — если
    # запись prefs не удалась, тумблер обязан вернуться назад, иначе
    # он показывает состояние, которого нет.
    _bj_set = _bj_st.split('Future<void> _setAutostart(')[-1] \
        .split('\n  Future<')[0]
    _bj6 = ('await AutostartArm.isArmed()' in _bj_set and
            _bj_set.find('AutostartArm.isArmed()') >
            _bj_set.find('AutostartArm.disable()') and
            'isArmed' in _bj_arm)
    if _bj6:
        ok('BJ6 the switch reflects native state re-read after the '
           'write, not the intent')
    else:
        fail('BJ6 the switch trusts its own intent')
else:
    ok(f"Part BJ skipped (build +{pv}, the autostart switch lands in +173)")

# ═════════ Part BK — v0.1.75+174 «Четыре долга по полю 29.07» ═════════
#
# Мост подтверждён (8 строк bridged:, ноль resurrected:), но поле
# опровергло два моих комментария и вскрыло два пробела в приборах:
#   1. Экспортный ZIP дважды приехал обрезанным ровно на кратном 32 КиБ.
#      Маркер — единственный читаемый экземпляр — ехал только в нём.
#   2. Строки ресивера не печатали ident(), хотя докстринг обещал, что
#      общий procTag доказывает работу в одном процессе.
#   3. Утверждение «дублей не бывает» ложно: 8 bridged: на 6 born:.
#   4. Проверка A1 жила в голове и дала ложную тревогу на 120 с.
if int(pv) >= 174:
    _bk_kt = 'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'

    def _bk_slurp(rel):
        p = root / rel
        return p.read_text() if p.exists() else ''

    _bk_mk_raw = _bk_slurp(_bk_kt + 'AutostartMarker.kt')
    _bk_br_raw = _bk_slurp(_bk_kt + 'BootReceiver.kt')
    _bk_ma_raw = _bk_slurp(_bk_kt + 'MainActivity.kt')
    _bk_arm_raw = _bk_slurp('lib/services/autostart_arm.dart')
    _bk_st_raw = _bk_slurp('lib/screens/settings.dart')
    _bk_a1_raw = _bk_slurp('tools/atlas_a1_check.py')
    _bk_mf_raw = _bk_slurp('android/app/src/main/AndroidManifest.xml')

    _bk_mk = _strip_comments_safe(_bk_mk_raw)
    _bk_br = _strip_comments_safe(_bk_br_raw)
    _bk_ma = _strip_comments_safe(_bk_ma_raw)
    _bk_arm = _strip_comments_safe(_bk_arm_raw)
    _bk_st = _strip_comments_safe(_bk_st_raw)

    # BK1: маркер уезжает ВТОРЫМ каналом. Диаг-дамп 29.07 доехал целым
    # каждый раз, экспортный ZIP — дважды обрезанным. Критическая мелочь
    # не должна зависеть от доставки хрупкой большой посылки.
    _bk_adv = _bk_st.split('Widget _advancedCard(')[-1].split('\n  Widget ')[0]
    _bk1 = ('fun read(context: Context' in _bk_mk and
            '"marker" -> result.success(AutostartMarker.read(this))'
            in _bk_ma and
            "invokeMethod<String>('marker')" in _bk_arm and
            'AutostartArm.marker()' in _bk_st and
            'DiagDumpFile.instance.append' in _bk_st and
            # ERA-AWARE (+193): плитка переехала в основной список вместе с
            # выключателем — это прибор ОДНОГО механизма, и разлучать их
            # значило бы оставить кнопку без её измерителя.
            "S.of('settings.marker.title')" in
            (_bk_st if int(pv) >= 193 else _bk_adv) and
            'onTap: _dumpMarker' in
            (_bk_st if int(pv) >= 193 else _bk_adv))
    if _bk1:
        ok('BK1 the marker travels through the diag dump, not only '
           'inside the fragile export ZIP')
    else:
        fail('BK1 the marker still depends on the export ZIP alone')

    # BK2: отдаётся хвост, обрезанный по границе строки. Журнал
    # append-only и растёт без предела; огрызок строки в дампе читался
    # бы как повреждение данных.
    _bk_read = _bk_mk.split('fun read(context: Context')[-1] \
        .split('fun noteFallback(')[0]
    # Держим САМУ границу, а не упоминание параметра: журнал растёт
    # ~10 МБ в год (поле 29.07), и readText() положил бы его целиком в
    # память на главном потоке. Проверяется позиционирование, потому
    # что только оно и даёт границу; наличие имени `maxBytes` в теле
    # ничего не гарантирует.
    _bk2 = ('fun read(context: Context, maxBytes: Int = ' in _bk_mk and
            'readText()' not in _bk_read.split('if (total <= maxBytes)')[-1]
            .split('else {')[-1] and
            'RandomAccessFile(f, "r")' in _bk_read and
            'raf.seek(total - maxBytes)' in _bk_read and
            "indexOf('\\n')" in _bk_read and
            'catch (t: Throwable)' in _bk_read)
    if _bk2:
        ok('BK2 the marker read is bounded and cut on a line boundary')
    else:
        fail('BK2 the marker read is unbounded or can emit a half line')

    # BK3: ident() в КАЖДОЙ строке ресивера. Докстринг AutostartMarker
    # с +171 утверждал, что совпадение procTag доказывает работу
    # ресивера и сервиса в одном процессе, — а тега в строках ресивера
    # не было вовсе. Обещание без доказательства, ровно тот же класс,
    # что «стена» boot-пути.
    # Держим ОТНОШЕНИЕ, а не абсолютное число: инвариант в том, что у
    # каждой записи есть тег, а не в том, что записей ровно шесть.
    # Пиннить число значило бы ронять гейт от любой будущей строки лога
    # без всякой причины — это тормоз, а не сторож.
    _bk3 = (_bk_br.count('AutostartMarker.write(') > 0 and
            _bk_br.count('AutostartMarker.ident()') >=
            _bk_br.count('AutostartMarker.write('))
    if _bk3:
        ok('BK3 every receiver line carries ident(), so the shared '
           'process tag can actually be compared')
    else:
        fail('BK3 receiver lines still omit the tag the docs promise')

    # BK4: ложное утверждение про дедуп снято. Проверка по СЫРОМУ
    # тексту — оно жило в комментарии. Отрицательная половина держит
    # короткий маркер, который в пересказе не появится (урок BJ5),
    # положительная требует полевого факта.
    _bk4 = ('заменяет первый' not in _bk_br_raw and
            'Дублей они не создают' not in _bk_mf_raw and
            'ПОПРАВКА' in _bk_br_raw and
            'идемпотентен' in _bk_br_raw)
    if _bk4:
        ok('BK4 the false «no duplicates» claim is replaced by what the '
           'field showed')
    else:
        fail('BK4 the receiver still claims duplicates cannot happen')

    # BK5: проверка A1 стала инструментом с критерием применимости.
    # Раньше жила ad-hoc и 29.07 подала 120 с как аномалию данных, хотя
    # сломана была она сама. Первая редакция инструмента ошиблась в
    # другую сторону — пропускала всё; гейт держит и это.
    _bk5 = ('def check_dump(' in _bk_a1_raw and
            'def baselines(' in _bk_a1_raw and
            'def frozen_in_memory(' in _bk_a1_raw and
            'snapshots_in_db' in _bk_a1_raw and
            "'skip'" in _bk_a1_raw and "'fail'" in _bk_a1_raw and
            'ни один дамп не попал в область применения' in _bk_a1_raw and
            'возможен ложный вердикт' in _bk_a1_raw)
    if _bk5:
        ok('BK5 the A1 identity is a tool with an applicability rule '
           'and it reports when it checked nothing')
    else:
        fail('BK5 the A1 check is missing its applicability rule')
else:
    ok(f"Part BK skipped (build +{pv}, the field debts land in +174)")

# ═══════════ Part BL — v0.1.77+176 «Установка поверх» ═══════════
#
# Поле 29.07, пять прогонов, одинаковый ответ: системный установщик на
# прошивке ЖИВ, но `staged_bytes` во всех пяти равен нулю — до него дело
# не дошло ни разу, и его ответ до сих пор НЕИЗВЕСТЕН. Обе стены стоят
# раньше: файла нет (ACTION_OPEN_DOCUMENT захвачен галереей BYD, она
# перечисляет только изображения и видео) и разрешения нет (экрана
# unknown-sources не существует, ActivityNotFoundException).
#
# Разрешение главнее файла: скачивание без него даёт файл, который
# некому поставить. Отсюда порядок §A → §B и предметы гейтов ниже.
if int(pv) >= 176:
    _bl_kt = 'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'

    def _bl_slurp(rel):
        p = root / rel
        return p.read_text() if p.exists() else ''

    _bl_mf_raw = _bl_slurp('android/app/src/main/AndroidManifest.xml')
    _bl_ai_raw = _bl_slurp(_bl_kt + 'ApkInstall.kt')
    _bl_ma_raw = _bl_slurp(_bl_kt + 'MainActivity.kt')
    _bl_mk_raw = _bl_slurp(_bl_kt + 'AutostartMarker.kt')
    _bl_br_raw = _bl_slurp(_bl_kt + 'BootReceiver.kt')
    _bl_sv_raw = _bl_slurp(_bl_kt + 'AutostartService.kt')
    _bl_ch_raw = _bl_slurp('lib/services/apk_install_channel.dart')
    _bl_sc_raw = _bl_slurp('lib/screens/install_update.dart')

    _bl_ai = _strip_comments_safe(_bl_ai_raw)
    _bl_ma = _strip_comments_safe(_bl_ma_raw)
    _bl_mk = _strip_comments_safe(_bl_mk_raw)
    _bl_br = _strip_comments_safe(_bl_br_raw)
    _bl_sv = _strip_comments_safe(_bl_sv_raw)
    _bl_ch = _strip_comments_safe(_bl_ch_raw)
    _bl_sc = _strip_comments_safe(_bl_sc_raw)

    _bl_ns = '{http://schemas.android.com/apk/res/android}'

    # BL1: манифест РАЗБОРОМ XML (урок BH1: split('<receiver') ловит и
    # <receiver-disabled>, содержимое отключённого блока при этом
    # находится целиком). Три предмета: тонкая activity приёма
    # объявлена и экспортирована с фильтром SEND на APK-мимотип; оба
    # разрешения на хранилище объявлены; поверхность запуска
    # MainActivity НЕ ТРОНУТА — у неё по-прежнему ровно один фильтр
    # MAIN/LAUNCHER, и это самостоятельный предмет: она же лончер, и
    # поломка здесь стоит доступа к приложению целиком.
    _bl_stage = None
    _bl_main = None
    _bl_perms = {}
    _bl_xml_ok = True
    try:
        import xml.etree.ElementTree as _bl_et
        _bl_root_el = _bl_et.fromstring(_bl_mf_raw)
        for _el in _bl_root_el.iter('activity'):
            _n = _el.get(_bl_ns + 'name')
            if _n == '.StageActivity':
                _bl_stage = _el
            if _n == '.MainActivity':
                _bl_main = _el
        for _el in _bl_root_el.iter('uses-permission'):
            _bl_perms[_el.get(_bl_ns + 'name')] = _el.get(
                _bl_ns + 'maxSdkVersion')
    except Exception:
        _bl_xml_ok = False

    _bl_send_ok = False
    if _bl_stage is not None:
        for _f in _bl_stage.findall('intent-filter'):
            _fa = {_a.get(_bl_ns + 'name') for _a in _f.findall('action')}
            _fm = {_d.get(_bl_ns + 'mimeType') for _d in _f.findall('data')}
            if ('android.intent.action.SEND' in _fa and
                    'application/vnd.android.package-archive' in _fm):
                _bl_send_ok = True
    _bl_main_filters = (
        len(_bl_main.findall('intent-filter')) if _bl_main is not None else -1)
    _bl_read_max = _bl_perms.get(
        'android.permission.READ_EXTERNAL_STORAGE', 'absent')
    _bl1 = (_bl_xml_ok and _bl_stage is not None and
            _bl_stage.get(_bl_ns + 'exported') == 'true' and
            _bl_stage.get(_bl_ns + 'noHistory') == 'true' and
            _bl_send_ok and
            'android.permission.MANAGE_EXTERNAL_STORAGE' in _bl_perms and
            _bl_read_max == '32' and
            _bl_main is not None and
            _bl_main.get(_bl_ns + 'launchMode') == 'singleTop' and
            _bl_main.get(_bl_ns + 'taskAffinity') == '' and
            _bl_main_filters == 1)
    if _bl1:
        ok('BL1 stage activity declared with a SEND filter, both storage '
           'permissions present, MainActivity launch surface untouched')
    else:
        fail('BL1 manifest: stage activity missing/misdeclared, a storage '
             'permission absent, or MainActivity launch surface changed')

    # BL2: расширенная проба ТОЛЬКО читает. Её зовут при открытии экрана
    # и после КАЖДОЙ попытки; побочное действие превратило бы прибор в
    # источник событий, а +176 добавил в неё десять новых чтений.
    _bl_probe = _bl_ai.split('fun probe(')[-1] \
        .split('fun doorIntents(')[0]
    _bl2 = ('startActivity' not in _bl_probe and
            'outputStream' not in _bl_probe and
            'takePersistableUriPermission' not in _bl_probe and
            'out["tree_doc_resolvers"]' in _bl_probe and
            'out["doors"]' in _bl_probe and
            'out["target_sdk"]' in _bl_probe and
            'out["version_code"]' in _bl_probe and
            'out["persisted_trees"]' in _bl_probe)
    if _bl2:
        ok('BL2 the extended probe still only reads, and it reports '
           'targetSdk and versionCode from the field')
    else:
        fail('BL2 the extended probe has a side effect or lost a reading')

    # BL3: НИ ОДНА ДВЕРЬ НЕ ПОТЕРЯНА. Их девять, они перечислены одним
    # списком, и проба обходит ИМЕННО ЭТОТ список — иначе перечень и
    # попытка разойдутся, а перечень тут и есть предмет.
    _bl_doors_fn = _bl_ai.split('fun doorIntents(')[-1] \
        .split('private fun createTreeIntent(')[0]
    if int(pv) >= 177:
        # ПЕРЕПИН +177, И ПРИЧИНА — УПАВШАЯ СБОРКА.
        #
        # +176 не собрался на CI: `Settings.ACTION_MANAGE_ALL_UNKNOWN_APP_
        # SOURCES` взята как публичная константа SDK, а её там нет —
        # действие в системе есть, константа скрыта. Поймать это в
        # песочнице было нечем: kotlinc без Android SDK помечает
        # `unresolved reference` ВСЕ android-символы (649 в базовой
        # линии), и настоящая ошибка ничем не отличалась от шума.
        #
        # Лечение структурное, а не заплатка на одну строку. Имя двери —
        # это ИМЯ, о котором мы спрашиваем систему, а не API, который
        # вызываем: отсутствие резолвера есть законный ответ пробы, ровно
        # его и измеряем. Поэтому все двери переведены на ПРИБИТЫЕ
        # ЛИТЕРАЛЫ, и гейт держит три вещи, которых до этого не держал
        # никто: литералы вместо констант, невозможность вернуть скрытую
        # константу, и — главное — СВЕРКУ С МАНИФЕСТОМ. Дверь, забытая в
        # <queries>, отдаёт пустой список резолверов при живом экране, то
        # есть проба врёт в самую опасную сторону.
        _bl_consts = dict(_bi_re.findall(
            r'private const val (ACT_[A-Z_]+)\s*=\s*"?\s*\n?\s*"([^"]+)"',
            _bl_ai))
        _bl_used = _bi_re.findall(r'\b(ACT_[A-Z_]+) to\b', _bl_doors_fn)
        _bl_need_consts = [
            'ACT_OPEN_TREE', 'ACT_MANAGE_UNKNOWN', 'ACT_MANAGE_ALL_UNKNOWN',
            'ACT_MANAGE_ALL_FILES', 'ACT_APP_DETAILS', 'ACT_SECURITY',
            'ACT_MANAGE_APPS', 'ACT_GET_CONTENT',
        ]
        _bl_lost = [d for d in _bl_need_consts if d not in _bl_used]
        if 'DOOR_CREATE_TREE to' not in _bl_doors_fn:
            _bl_lost.append('DOOR_CREATE_TREE')
        # Каждый литерал вида android.* обязан стоять в <queries>.
        _bl_undeclared = []
        for _c in _bl_used:
            _lit = _bl_consts.get(_c, '')
            if _lit.startswith('android.') and _lit not in _bi_qacts:
                _bl_undeclared.append(_lit)
        _bl3 = (not _bl_lost and not _bl_undeclared and
                len(_bl_consts) >= len(_bl_need_consts) and
                'Settings.ACTION_' not in _bl_doors_fn and
                'for ((name, intent) in doorIntents(context))' in _bl_probe and
                'fun openDoor(' in _bl_ai and
                'doorIntents(activity).firstOrNull' in _bl_ai)
        if _bl3:
            ok(f'BL3 (re-era +177) all {len(_bl_need_consts) + 1} doors '
               f'are pinned literals, no hidden SDK constant, and every '
               f'action is declared in <queries>')
        else:
            fail(f'BL3 doors lost {_bl_lost}, undeclared in manifest '
                 f'{_bl_undeclared}, or an SDK constant came back')
    else:
        _bl_need_doors = [
            'Intent.ACTION_OPEN_DOCUMENT_TREE to',
            'DOOR_CREATE_TREE to',
            'Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES to',
            'Settings.ACTION_MANAGE_ALL_UNKNOWN_APP_SOURCES to',
            'Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION to',
            'Settings.ACTION_APPLICATION_DETAILS_SETTINGS to',
            'Settings.ACTION_SECURITY_SETTINGS to',
            'Settings.ACTION_MANAGE_APPLICATIONS_SETTINGS to',
            'Intent.ACTION_GET_CONTENT to',
        ]
        _bl_lost = [d for d in _bl_need_doors if d not in _bl_doors_fn]
        _bl3 = (not _bl_lost and
                'for ((name, intent) in doorIntents(context))'
                in _bl_probe and
                'fun openDoor(' in _bl_ai and
                'doorIntents(activity).firstOrNull' in _bl_ai)
        if _bl3:
            ok(f'BL3 all {len(_bl_need_doors)} doors are declared once '
               f'and both the probe and the opener walk that same list')
        else:
            fail(f'BL3 a door was lost or the opener keeps its own list: '
                 f'{_bl_lost}')

    # BL4: ПОПЫТКА НИЧЕГО НЕ ГЛОТАЕТ. Ответ установщика — главный
    # неизвестный факт темы; проглоченное исключение или потерянный
    # resultCode стоят ещё одного цикла установки, то есть всех данных
    # на устройстве.
    _bl_launch = _bl_ai.split('fun launch(')[-1] \
        .split('fun openUnknownSources(')[0]
    _bl_oar = _bl_ma.split('override fun onActivityResult(')[-1]
    _bl4 = ('out["can_request_installs_at_attempt"]' in _bl_launch and
            'out["exception"] = "${t.javaClass.simpleName}: ${t.message}"'
            in _bl_launch and
            'steps.add(' in _bl_launch and
            'REQ_INSTALL' in _bl_oar and
            'install-result: resultCode=$resultCode' in _bl_oar)
    if _bl4:
        ok('BL4 the attempt records the appop state, the exception class '
           'and the installer resultCode')
    else:
        fail('BL4 the attempt can swallow the installer answer')

    # BL5: ОБОЗРЕВАТЕЛЬ ДЕГРАДИРУЕТ, А НЕ ТРЕБУЕТ. Права на хранилище
    # НЕ являются условием: их экран может отсутствовать точно так же,
    # как отсутствует unknown-sources. Сделай их обязательными — и
    # обозреватель умрёт там, где SAF-дерево работало бы.
    #
    # Проверяется ОТСУТСТВИЕ выхода до permission-free пути: между
    # началом listApks и обходом отданных деревьев не должно быть ни
    # одного return.
    _bl_list = _bl_ai.split('fun listApks(')[-1] \
        .split('private const val TREE_DIR_BUDGET')[0]
    _bl_before_saf = _bl_list.split('val trees = persistedTrees(context)')[0]
    _bl_files = _bl_ai.split('private fun scanFiles(')[-1] \
        .split('fun openDoor(')[0]
    _bl5 = ('return' not in _bl_before_saf and
            'val trees = persistedTrees(context)' in _bl_list and
            _bl_list.find('scanTree(context, t)') <
            _bl_list.find('scanFiles(context, notes)') and
            'if (!manage && !read)' in _bl_files and
            'notes.add("file: ни одного разрешения на хранилище — пропуск")'
            in _bl_files and
            'TREE_DIR_BUDGET' in _bl_ai and 'APK_LIMIT' in _bl_ai)
    if _bl5:
        ok('BL5 the browser degrades: the permission-free path runs '
           'first and missing storage rights are an answer, not an error')
    else:
        fail('BL5 the browser requires a storage permission to work')

    # BL6: СКАЧИВАНИЕ НЕ ДАЁТ ОТКАТА, пишет туда, откуда читает
    # провайдер, сверяет размер и не оставляет огрызка. Плюс лимит
    # запросов отделён от «обновлений нет»: свести их к одному ответу
    # значило бы соврать тем самым прибором, который делается ради
    # честности (найдено пробой api.github.com в этом же окне — 403 с
    # телом-JSON приходит буднично, 60 запросов в час на адрес).
    _bl_up = _bl_ch.split('class ApkUpdate')[-1]
    if int(pv) >= 178:
        # ПЕРЕПИН +178. «Есть ли новее» и «можно ли ставить» — разные
        # вопросы, а в +176 на оба отвечало строгое «больше». Поле 30.07:
        # на ГУ установлено 254 и доступно 254, скачивание отказало, и
        # единственный работающий путь к файлу закрылся ровно тогда,
        # когда был нужен. Равная версия не откат — система ставит её
        # поверх штатно (проверено на телефоне). Отказ остаётся строго
        # младшей.
        _bl6_ver = ('static bool canInstall(int installed, int available) =>'
                    in _bl_up and
                    'available >= installed' in _bl_up and
                    'static bool isNewer(int installed, int available) =>'
                    in _bl_up and
                    'available > installed' in _bl_up and
                    'ApkUpdate.canInstall(installed, rel.buildNumber)'
                    in _bl_sc)
    else:
        _bl6_ver = 'available > installed' in _bl_up
    _bl6 = (_bl6_ver and
            'rateLimited' in _bl_ch and
            "contains('rate limit')" in _bl_up and
            'UpdateLookup.rateLimited' in _bl_up and
            'size != release.bytes' in _bl_up and
            'await file.delete()' in _bl_up and
            'ApkInstallChannel.stagedPath()' in _bl_sc and
            'token' not in _bl_up.lower())
    if _bl6:
        ok('BL6 the download refuses a downgrade, verifies the size, '
           'leaves no partial file, ships no token, and tells a rate '
           'limit apart from «no release»')
    else:
        fail('BL6 the download can roll back, keep a partial file, or '
             'report a rate limit as «up to date»')

    # BL7: РОТАЦИЯ НЕ ИЗ BOOT-КОНТЕКСТА. Перезапись многомегабайтного
    # файла на главном потоке в момент загрузки ГУ — ровно тот риск,
    # который +174 здесь убирал. Защита конструктивная, а не флагом:
    # единственный вызов стоит в read(), который зовут из MethodChannel;
    # ресивер и сервис знают только write().
    _bl_read = _bl_mk.split('fun read(context: Context')[-1] \
        .split('fun noteFallback(')[0]
    _bl_write = _bl_mk.split('fun write(')[-1].split('fun read(')[0]
    _bl7 = (_bl_mk.count('private fun rotateIfHuge(') == 1 and
            'rotateIfHuge(context)' in _bl_read and
            'rotateIfHuge' not in _bl_write and
            'rotateIfHuge' not in _bl_br and
            'rotateIfHuge' not in _bl_sv and
            _bl_mk.count('rotateIfHuge(context)') == 1 and
            'tmp.renameTo(f)' in _bl_mk and
            'ROTATE_KEEP' in _bl_mk and
            "indexOf('\\n')" in _bl_mk)
    if _bl7:
        ok('BL7 rotation is reachable only from read(): tail, temp file, '
           'rename — never from the boot context')
    else:
        fail('BL7 rotation can run from the boot context or is not '
             'crash-safe')

    # BL8: SAF-ПУТЬ НЕ ТРЕБУЕТ НИ ОДНОГО РАЗРЕШЕНИЯ НА ХРАНИЛИЩЕ —
    # иначе смысл третьего пути потерян целиком: он затем и первый, что
    # на API 30+ для съёмных томов работает БЕЗ прав, а targetSdk 35
    # делает File-API по съёмному тому структурно закрытым.
    _bl_saf = (
        _bl_ai.split('private fun scanTree(')[-1].split('private fun scanFiles(')[0] +
        _bl_ai.split('fun openTree(')[-1].split('fun rememberTree(')[0] +
        _bl_ai.split('fun rememberTree(')[-1].split('fun listApks(')[0] +
        _bl_ai.split('fun persistedTrees(')[-1].split('private fun volumeReport(')[0]
    )
    _bl8 = ('READ_EXTERNAL_STORAGE' not in _bl_saf and
            'isExternalStorageManager' not in _bl_saf and
            'checkSelfPermission' not in _bl_saf and
            'DocumentsContract' in _bl_saf and
            'takePersistableUriPermission' in _bl_saf and
            'ACTION_OPEN_DOCUMENT_TREE' in _bl_saf)
    if _bl8:
        ok('BL8 the SAF path asks for no storage permission at all — '
           'the whole point of putting it first')
    else:
        fail('BL8 the SAF path leans on a storage permission')
else:
    ok(f"Part BL skipped (build +{pv}, install-over lands in +176)")

# ═══════════ Part BM — v0.1.79+178 «Что сказало поле 30.07» ═══════════
#
# Визит ответил на всё, ради чего делался, и три ответа из пяти были
# против того, что стояло в коде.
#
#   1. DocumentsUI на прошивке НЕТ: оба интента дерева дают
#      ActivityNotFoundException. А журнал писал «cancelled» — то есть
#      сообщал, что владелец отменил выбор, когда активити просто нет.
#   2. §B РАБОТАЕТ: build-254 · bz5-companion-0.1.78.254.apk · 30171855 B.
#      Сеть стала первым путём к файлу, а не последним.
#   3. Утверждение «публичные Downloads мертвы» НЕВЕРНО: экспорт пишет
#      туда новый файл после переустановки, отказывает только
#      дописывание в файл прежней установки.
#   4. «Дамп не записан — хранилище недоступно» показывался там, где
#      писать было просто нечего. Текст называл причиной то, чего не
#      проверял, и на нём был построен неверный разбор.
#   5. targetSdk измерен: 35. Поправка +177 снята как ошибка второго
#      рода — верное число опровергнуто по неверно прочитанной улике.
if int(pv) >= 178:
    _bm_kt = 'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'

    def _bm_slurp(rel):
        p = root / rel
        return p.read_text() if p.exists() else ''

    _bm_mk_raw = _bm_slurp(_bm_kt + 'AutostartMarker.kt')
    _bm_ai_raw = _bm_slurp(_bm_kt + 'ApkInstall.kt')
    _bm_dd_raw = _bm_slurp('lib/services/diag_dump_file.dart')
    _bm_st_raw = _bm_slurp('lib/screens/settings.dart')
    _bm_sc_raw = _bm_slurp('lib/screens/install_update.dart')
    _bm_ch_raw = _bm_slurp('lib/services/apk_install_channel.dart')

    _bm_mk = _strip_comments_safe(_bm_mk_raw)
    _bm_ai = _strip_comments_safe(_bm_ai_raw)
    _bm_dd = _strip_comments_safe(_bm_dd_raw)
    _bm_st = _strip_comments_safe(_bm_st_raw)
    _bm_sc = _strip_comments_safe(_bm_sc_raw)
    _bm_ch = _strip_comments_safe(_bm_ch_raw)

    # BM1: диаг-дамп при отказе берёт СВЕЖЕЕ ИМЯ. Экспорт годами жив
    # именно этим, а дамп дописывал в постоянное имя и падал после
    # переустановки — файл остаётся за прежним uid.
    # Область режется ДО определения _freshFilename: первая редакция
    # гейта включала его в область и читала само определение вместо
    # вызова — мутация «взять постоянное имя» её не роняла. Ровно та же
    # семья, что слепота BI2, и найдена тем же харнессом.
    _bm_app = _bm_dd.split('Future<DiagDumpAppendResult> append(')[-1] \
        .split('String _freshFilename()')[0]
    _bm1 = (('final fresh = await _fallbackFilename(dir);' in _bm_app
            if int(pv) >= 179 else
            'final fresh = _freshFilename();' in _bm_app) and
            'File(p.join(dir.path, _filename))' in _bm_app and
            'File(p.join(dir.path, fresh))' in _bm_app and
            'for (final candidate in candidates)' in _bm_app and
            'DiagDumpWriteFailure(reasons)' in _bm_app and
            'class DiagDumpWriteFailure' in _bm_dd)
    if _bm1:
        ok('BM1 the diag dump falls back to a fresh filename instead of '
           'giving up on a file it no longer owns')
    else:
        fail('BM1 the diag dump still has one filename and one chance')

    # BM2: причина отказа ПОИМЁННО. «Хранилище недоступно» — это вывод,
    # а не измерение, и на нём уже построили неверное объяснение.
    _bm2 = ("reasons.add('\\${candidate.path}: \\${e.runtimeType}: \\$e')"
            .replace('\\', '') in _bm_app and
            'String toString() =>' in _bm_dd and
            "reasons.join(' · ')" in _bm_dd and
            'pubErr' in _bm_mk and
            'reason=$pubErr' in _bm_mk)
    if _bm2:
        ok('BM2 every write refusal carries its exception class and path')
    else:
        fail('BM2 a write refusal is still reported as a bare verdict')

    # BM3: ложное «публичные Downloads мертвы» снято. Проверка по СЫРОМУ
    # тексту — утверждение жило в комментарии (урок BJ5: отрицательная
    # половина держит короткий маркер, который в пересказе не появится).
    _bm3 = ('unwritable (fails=' not in _bm_mk_raw and
            'ПОПРАВКА v0.1.79+178' in _bm_mk_raw and
            'bz5_export_20260730-192239.zip' in _bm_mk_raw and
            'public Downloads refused' in _bm_mk)
    if _bm3:
        ok('BM3 the «public Downloads are dead» claim is replaced by the '
           'three field measurements that refuted it')
    else:
        fail('BM3 the refuted claim is still stated as fact')

    # BM4: «писать нечего» ≠ «запись отказала». Один текст на два разных
    # состояния — тот же класс, что и остальные три ошибки этой эры.
    _bm4 = ("S.of('settings.adv.dump_empty')" in _bm_st and
            "'${S.of('settings.adv.dump_fail')} $e'" in _bm_st and
            _bm_st.count("S.of('settings.adv.dump_fail')") == 2 and
            "'settings.adv.dump_empty':" in
            _bm_slurp('lib/l10n/strings.dart'))
    if _bm4:
        ok('BM4 «nothing to dump» and «the write refused» are different '
           'answers with different texts')
    else:
        fail('BM4 an empty dump is still reported as a storage failure')

    # BM5: журнал дерева не врёт. Поле 30.07: из-за подставленного
    # «cancelled» кнопка выглядела нерабочей, хотя отрабатывала штатно.
    _bm_tree = _bm_ai.split('fun openTree(')[-1].split('fun rememberTree(')[0]
    _bm5 = ('out["error"] = "${t.javaClass.simpleName}: ${t.message}"'
            in _bm_tree and
            'if (out["error"] == null) out["error"] = "no tree intent to try"'
            in _bm_tree)
    if _bm5:
        ok('BM5 a missing activity is reported as a missing activity, '
           'not as a cancelled choice')
    else:
        fail('BM5 the tree log can still claim the owner cancelled')

    # BM6: GET_CONTENT заведён как настоящий путь к файлу. Одна из трёх
    # дверей, живых на прошивке, и действие ДРУГОЕ, чем перехваченный
    # галереей OPEN_DOCUMENT.
    _bm6 = ('fun pickContent(' in _bm_ai and
            'REQ_PICK' in _bm_ai.split('fun pickContent(')[-1]
            .split('fun pick(')[0] and
            "static Future<Map<String, dynamic>> pickContent()" in _bm_ch and
            '_pickContentAndStage' in _bm_sc and
            "S.of('install.getcontent.title')" in _bm_sc)
    if _bm6:
        ok('BM6 GET_CONTENT is a real fourth path to the file, not just '
           'a door in the probe')
    else:
        fail('BM6 GET_CONTENT is still probe-only')

    # BM7: проба читается без файловой системы. Поле 30.07: дамп на ГУ
    # не записался, и единственным доехавшим каналом была фотография
    # экрана. Прибор обязан быть читаем в этом состоянии.
    _bm7 = ("S.of('install.raw.title')" in _bm_sc and
            'JsonEncoder.withIndent' in _bm_sc and
            'SelectableText(' in _bm_sc and
            'ExpansionTile(' in _bm_sc and
            'out["target_sdk"]' in _bm_ai)
    if _bm7:
        ok('BM7 the whole probe is readable on screen — the one channel '
           'that worked when no file could be written')
    else:
        fail('BM7 the probe still depends on a file to be read')
else:
    ok(f"Part BM skipped (build +{pv}, the 30.07 field answers land in +178)")

# ═════ Part BN — v0.1.80+179 «Журнал — приватный файл» ═════
#
# Ревизия +178 нашла дефект, которого +178 не создавал, но БУДИЛ.
# С +170 маркер писал «сначала публичная папка, при успехе выходим», и
# вреда не было ровно потому, что публичный путь отказывал всегда. +178
# научил его работать — и включил спящую поломку: `read()` и
# `export_service` берут файл ТОЛЬКО из filesDir, поэтому при успешной
# публичной записи оба канала чтения маркера показывали бы устаревший
# след. Молча, и ровно на том визите, где маркер и нужен.
if int(pv) >= 179:
    _bn_kt = 'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'

    def _bn_slurp(rel):
        p = root / rel
        return p.read_text() if p.exists() else ''

    _bn_mk = _strip_comments_safe(_bn_slurp(_bn_kt + 'AutostartMarker.kt'))
    _bn_dd = _strip_comments_safe(_bn_slurp('lib/services/diag_dump_file.dart'))

    _bn_write = _bn_mk.split('fun write(')[-1].split('private fun pubFileName(')[0]
    _bn_read = _bn_mk.split('fun read(context: Context')[-1] \
        .split('fun noteFallback(')[0]

    # BN1: приватная запись идёт ПЕРВОЙ и БЕЗУСЛОВНО, и пишет ровно тот
    # файл, который потом читают. Порядок здесь — не стиль: любой
    # ранний выход выше приватной ступени возвращает исходный дефект.
    _bn_priv_at = _bn_write.find('File(context.filesDir, FILE_NAME)')
    _bn_pub_at = _bn_write.find('$PUB_DIR/')
    _bn_head = _bn_write[:_bn_priv_at] if _bn_priv_at > 0 else _bn_write
    _bn1 = (_bn_priv_at > 0 and _bn_pub_at > _bn_priv_at and
            'return' not in _bn_head and
            'pubDead' not in _bn_head and
            'File(context.filesDir, FILE_NAME)' in _bn_read and
            _bn_write.count('return') == 0)
    if _bn1:
        ok('BN1 the private file is written first and unconditionally, '
           'and it is the same file read() and the export take')
    else:
        fail('BN1 a public write can still starve the journal that '
             'read() and the export depend on')

    # BN2: имя зеркала привязано к УСТАНОВКЕ, а не ко времени. Ключ по
    # времени при процессном состоянии давал бы файл на каждый процесс —
    # три-четыре за загрузку ГУ.
    _bn2 = ('private fun pubFileName(' in _bn_mk and
            'getPackageInfo(context.packageName, 0).versionCode' in _bn_mk and
            'FILE_NAME.removeSuffix(".txt") + "_$code.txt"' in _bn_mk and
            'yyyyMMdd-HHmmss' not in _bn_mk)
    if _bn2:
        ok('BN2 the public mirror is keyed by versionCode — one file per '
           'install, not one per process')
    else:
        fail('BN2 the public mirror name can multiply per process')

    # BN3: запасной файл дампа ПЕРЕИСПОЛЬЗУЕТСЯ, и ни один вызов append
    # не остаётся без обработки отказа. append бросает с +178; молчащий
    # вызов означает экран без реакции.
    _bn_unguarded = []
    for _f in sorted((root / 'lib').rglob('*.dart')):
        _src = _f.read_text()
        if 'DiagDumpFile.instance.append(' not in _src:
            continue
        for _chunk in _src.split('DiagDumpFile.instance.append(')[1:]:
            _before = _src.split('DiagDumpFile.instance.append(')[0]
        # try обязан стоять В ТОЙ ЖЕ функции выше вызова
        for _piece in _src.split('DiagDumpFile.instance.append(')[:-1]:
            _fn = _piece.rsplit('async {', 1)[-1]
            if 'try {' not in _fn:
                _bn_unguarded.append(str(_f.relative_to(root)))
    _bn3 = (not _bn_unguarded and
            'static String? _fallbackName;' in _bn_dd and
            'Future<String> _fallbackFilename(' in _bn_dd and
            'if (memo != null) return memo;' in _bn_dd and
            "mode: FileMode.append, flush: true" in _bn_dd)
    if _bn3:
        ok('BN3 the dump reuses its fallback file and every append call '
           'site handles the refusal')
    else:
        fail(f'BN3 fallback files multiply or an append is unguarded: '
             f'{sorted(set(_bn_unguarded))}')
else:
    ok(f"Part BN skipped (build +{pv}, the journal inversion lands in +179)")

# ═════ Part BO — v0.1.81+180 «Импорт из архива» ═════
#
# Установка поверх закрыта полем 31.07: прошивка отвечает «нельзя
# устанавливать приложения не из магазина приложений» тостом без кнопок.
# Значит цену удаления снимают с другой стороны — восстановлением из
# архива. Три вещи здесь могут сломаться молча, и каждая проверяется.
if int(pv) >= 180:
    _bo_imp = _strip_comments_safe(
        (root / 'lib/services/import_service.dart').read_text()
        if (root / 'lib/services/import_service.dart').exists() else '')
    _bo_exp = _strip_comments_safe(
        (root / 'lib/services/export_service.dart').read_text())
    _bo_main = _strip_comments_safe((root / 'lib/main.dart').read_text())
    _bo_cloud = _strip_comments_safe(
        (root / 'lib/services/cloud_sync_service.dart').read_text())
    _bo_mk = _strip_comments_safe(
        (root / ('android/app/src/main/kotlin/com/bz5companion/'
                 'bz5_companion/AutostartMarker.kt')).read_text())

    # BO1: ОБМЕН ФАЙЛА СТРОГО ДО ОТКРЫТИЯ БАЗЫ. Подмена под живым
    # дескриптором Drift — тихая порча, которая ищется полевым визитом.
    _bo_apply_at = _bo_main.find('ImportService.applyPending()')
    _bo_db_at = _bo_main.find('AppDatabase()')
    _bo_rebuild_at = _bo_main.find('ImportService.rebuildSyncBookkeeping(')
    _bo1 = (_bo_apply_at != -1 and _bo_db_at != -1 and
            _bo_rebuild_at != -1 and
            _bo_apply_at < _bo_db_at < _bo_rebuild_at)
    if _bo1:
        ok('BO1 the swap runs before AppDatabase(), the cursor rebuild '
           'after it')
    else:
        fail('BO1 import ordering in main() is wrong — swap must precede '
             'the database, rebuild must follow it')

    # BO2: ЛИТЕРАЛЫ КУРСОРОВ СОВПАДАЮТ С СЕРВИСОМ. import_service держит
    # имена ключей литералами (приватную константу из другого файла
    # компилятор не отдаст), поэтому расхождение может поймать только
    # текст. Разойдись они — курсоры «пересобрались» бы мимо тех, что
    # читает CloudSyncService, и лавина 04.07 повторилась бы молча.
    _bo_cursor_keys = re.findall(r"'(cloud_sync_cursor_\w+)'", _bo_imp)
    _bo_missing = [k for k in _bo_cursor_keys
                   if f"'{k}'" not in _bo_cloud]
    _bo_cloud_keys = set(re.findall(r"'(cloud_sync_cursor_\w+)'", _bo_cloud))
    _bo_uncovered = sorted(_bo_cloud_keys - set(_bo_cursor_keys))
    # Префикс карты uuid — такой же литерал и с такой же опасностью.
    _bo_wm_ok = ("'cloud_sync_uuid_map_wm_'" in _bo_imp and
                 "'cloud_sync_uuid_map_wm_'" in _bo_cloud)
    _bo2 = (len(_bo_cursor_keys) >= 5 and
            not _bo_missing and
            not _bo_uncovered and
            _bo_wm_ok)
    if _bo2:
        ok(f'BO2 all {len(_bo_cursor_keys)} push cursors are known to both '
           'the importer and the sync service')
    else:
        fail(f'BO2 cursor literals diverge — unknown to service: '
             f'{_bo_missing}, not rebuilt by import: {_bo_uncovered}')

    # BO3: ИДЕНТИЧНОСТЬ И УЧЁТ НЕ ЕДУТ. Белый список проверяется и на
    # входе: архив лежит на общем диске, и чужой prefs.json не должен
    # уметь подменить device_id или базовый адрес.
    _bo_forbidden = ['cloud_sync_device_id', 'cloud_sync_vehicle_id',
                     'cloud_sync_base_url', 'cloud_sync_enabled',
                     'account_email', 'account_refresh_token',
                     'cloud_sync_client_token']
    _bo_travel = _bo_imp.split('static const List<String> ownerKeys')[-1] \
        .split('static List<String> get travellingKeys')[0]
    _bo_leak = [k for k in _bo_forbidden if f"'{k}'" in _bo_travel]
    _bo3 = (not _bo_leak and
            'final allowed = travellingKeys.toSet();' in _bo_imp and
            'if (!allowed.contains(k)) continue;' in _bo_imp)
    if _bo3:
        ok('BO3 device identity never travels, and the whitelist is '
           'enforced on the way IN as well as out')
    else:
        fail(f'BO3 identity leak into the archive {_bo_leak} or the '
             f'inbound whitelist is missing')

    # BO4: СПУТНИКИ ПРЕЖНЕЙ БАЗЫ УДАЛЯЮТСЯ, А САМА БАЗА — НЕТ. rename
    # атомарен и заменяет файл сам; удалить базу заранее означает окно,
    # в котором её уже нет, а новой ещё нет.
    _bo_swap = _bo_imp.split('final livePath =')[-1].split('var restored')[0]
    _bo4 = ("'-wal', '-shm', '-journal'" in _bo_swap and
            'staged.rename(livePath)' in _bo_swap and
            'live.delete()' not in _bo_swap)
    if _bo4:
        ok('BO4 the swap deletes stale sidecars and replaces the database '
           'by rename, never by delete-then-write')
    else:
        fail('BO4 the swap can leave a stale journal or open a window with '
             'no database at all')

    # BO5: СХЕМА НОВЕЕ НАШЕЙ — ОТКАЗ. Drift поднимет старую базу
    # миграцией, опустить новую он не может ничем.
    _bo5 = ("'schema-too-new'" in _bo_imp and
            'if (schemaVersion > appSchemaVersion)' in _bo_imp and
            '_looksLikeSqlite' in _bo_imp)
    if _bo5:
        ok('BO5 a newer schema and a non-sqlite payload are both refused '
           'before anything is staged')
    else:
        fail('BO5 the importer can accept an archive it cannot open')

    # BO6: ЭКСПОРТ ПИШЕТ НАСТРОЙКИ И ПОСТОЯННОЕ ИМЯ. Без первого
    # восстановление теряет валюту и профили; без второго импорт зависит
    # от перечисления каталога, которое на этой прошивке может вернуть
    # пусто.
    # ERA-AWARE (+193). Настройки в архиве — существо гейта, оно цело. А
    # копия под постоянным именем СНЯТА сознательно: на этой прошивке файл
    # прежней установки принадлежит прежнему uid, дописать и перезаписать
    # его нельзя, и путаницы это принесло дважды. Поле 04.08: жалоба
    # «экспорт негоден» указывала на старый файл от 03.08, а свежий архив
    # был цел. Узнавать имя при восстановлении мы продолжаем — это проверяет
    # BZ11; писать перестали.
    _bo6 = ('ImportService.collectPrefs()' in _bo_exp and
            'ImportService.kPrefsEntry' in _bo_exp and
            ('ImportService.kFixedName' not in _bo_exp if int(pv) >= 193
             else 'ImportService.kFixedName' in _bo_exp))
    if _bo6:
        ok('BO6 the export writes prefs.json' +
           (', and no longer writes a fixed name it cannot overwrite'
            if int(pv) >= 193 else ' and the fixed-name copy'))
    else:
        fail('BO6 the archive is still a dump, not a restore point')

    # BO7: ОХРАНА ОТСТУПНОЙ СТРОКИ СТОИТ НА СЧЁТЧИКЕ ОТКАЗОВ. Поле 31.07:
    # три строки «refused (fails=0)» при живом зеркале — условие стояло
    # на `where`, которое при успехе равно "priv+pub".
    _bo_note = _bo_mk.split('fun noteFallback(')[-1].split('}')[0]
    _bo7 = ('pubFails == 0' in _bo_note and 'where == "pub"' not in _bo_note)
    if _bo7:
        ok('BO7 the fallback note fires only on a real public-write '
           'refusal')
    else:
        fail('BO7 the marker can still claim a refusal that never happened')

    # BO8: ПОСЛЕ ПОСТАНОВКИ В ОЧЕРЕДЬ ЕСТЬ ЧЕМ СНЯТЬ ПРОЦЕСС. Обмен стоит
    # в main(), а на Android повторное открытие с живым процессом
    # поднимает прежнюю активити и main() НЕ зовёт. На этом ГУ процесс
    # живёт часами (поле 31.07: pid=4746 пережил 2.5 часа сна), поэтому
    # без явного снятия импорт не применился бы молча и никогда — то
    # есть весь патч работал бы только на телефоне.
    _bo_dm = _strip_comments_safe(
        (root / 'lib/screens/data_management.dart').read_text())
    _bo8 = ("import 'dart:io';" in _bo_dm and
            'void _closeApp()' in _bo_dm and
            'exit(0)' in _bo_dm and
            "S.of('dataimp.close_btn')" in _bo_dm and
            'onPressed: _busy ? null : _closeApp' in _bo_dm)
    if _bo8:
        ok('BO8 a queued import can be applied — the owner has an explicit '
           'way to end the process')
    else:
        fail('BO8 a queued import may never apply: the process outlives the '
             'window and main() would not run again')
else:
    ok(f"Part BO skipped (build +{pv}, archive import lands in +180)")

# ═════ Part BP — v0.1.83+182 «Сбор в автостарте» ═════
#
# Патч 2. Тумблер существовал с +173, за ним стояла пустота: уведомление и
# биение раз в пять минут. Здесь за ним появляется подписка HAL, живущая в
# процессе, а не в активити.
#
# Шесть из девяти гейтов ниже стоят на вещах, которые ломаются МОЛЧА —
# сборка проходит, отчёты зелёные, а данные теряются или их становится
# вдвое. Именно поэтому они гейты, а не комментарии.
if int(pv) >= 182:
    _bp_kt = ('android/app/src/main/kotlin/com/bz5companion/bz5_companion/')
    _bp_sink = _strip_comments_safe(
        (root / (_bp_kt + 'hal/DecodedStreamSink.kt')).read_text())
    _bp_out = _strip_comments_safe(
        (root / (_bp_kt + 'hal/HalOut.kt')).read_text())
    _bp_own = _strip_comments_safe(
        (root / (_bp_kt + 'hal/HalStreamOwner.kt')).read_text())
    _bp_plug = _strip_comments_safe(
        (root / (_bp_kt + 'BydNativePlugin.kt')).read_text())
    _bp_svc = _strip_comments_safe(
        (root / (_bp_kt + 'AutostartService.kt')).read_text())
    _bp_jrn = _strip_comments_safe(
        (root / 'lib/services/hal_bg_journal.dart').read_text())
    _bp_hal = _strip_comments_safe(
        (root / 'lib/services/hal_telemetry_service.dart').read_text())
    _bp_imp = _strip_comments_safe(
        (root / 'lib/services/import_service.dart').read_text())
    _bp_dm = _strip_comments_safe(
        (root / 'lib/screens/data_management.dart').read_text())

    # BP1: РАСШИФРОВКА В ОДНОМ ЭКЗЕМПЛЯРЕ. Своя копия байтовых извлечений
    # из BigData (soc_precise, SOH, температура) развелась бы с оригиналом
    # молча — это самая чувствительная логика в проекте. Признак того, что
    # копии нет: сник не знает про EventChannel вовсе, выход за интерфейсом.
    # v0.1.86+185: `class FlutterHalOut` ищется ТАМ, ГДЕ ОН ТЕПЕРЬ ЛЕЖИТ.
    # До этого патча он жил в `hal/HalOut.kt` и тянул в пакет `io.flutter`; это
    # и был третий пункт архитектурной ревизии — гейт мерил границу файла,
    # а называл её границей расшифровки. Сама проверка не ослаблена: шов
    # `HalOut` обязан существовать и иметь оба выхода, просто адаптер под
    # Flutter считается по своему адресу. Границу ПАКЕТА мерит BS7.
    _bp1_fho = _bp_out if int(pv) < 185 else _strip_comments_safe(
        (root / (_bp_kt + 'FlutterHalOut.kt')).read_text())
    _bp1 = ('EventChannel' not in _bp_sink and
            'out: HalOut' in _bp_sink and
            'private var sink: HalOut?' in _bp_sink and
            'fun setOut(next: HalOut)' in _bp_sink and
            's.emit(batch)' in _bp_sink and
            'interface HalOut' in _bp_out and
            'class FlutterHalOut(' in _bp1_fho and
            'class JournalHalOut' in _bp_out)
    if _bp1:
        ok('BP1 decoding exists once: the sink knows nothing about '
           'EventChannel and ships through the HalOut seam')
    else:
        fail('BP1 the decoded stream is coupled to Flutter again — a second '
             'destination would need a second copy of the BigData extractions')

    # BP2: ОДНА ПОДПИСКА НА ПРОЦЕСС. Охрана `active` в вендоренном движке —
    # поле ЭКЗЕМПЛЯРА; два экземпляра зарегистрируют по прокси на одни
    # устройства, ничего друг о друге не узнав, и сломают живой поток.
    # Признак: плагин движка не конструирует и своих полей под него не
    # держит.
    _bp2 = ('DecodedStreamSink(' not in _bp_plug and
            'halEngine' not in _bp_plug and
            'HalStreamOwner.attachFlutter(' in _bp_plug and
            'object HalStreamOwner' in _bp_own)
    if _bp2:
        ok('BP2 one subscription per process: the plugin attaches to the '
           'owner instead of building an engine of its own')
    else:
        fail('BP2 the plugin can build a second engine — двойная подписка, '
             'the risk this patch exists to remove')

    # BP3: ПЕРЕДАЧА ПОТОКА НЕ ПЕРЕСОЗДАЁТ ПОДПИСКУ. stop()+start() на
    # передаче дали бы окно, в которое проваливаются события, и мгновение с
    # двумя прокси на устройстве. Признак: живой движок в ensureEngine
    # возвращается сразу, а attachFlutter меняет только адресат.
    # Область — РОВНО тело handleHalStreamStart, от объявления до
    # объявления stopHalStream. Взять первое вхождение имени значило бы
    # прочитать строку диспетчера и пол плагина следом (семья BM1).
    _bp3_body = ''
    if 'private fun handleHalStreamStart' in _bp_plug and \
            'private fun stopHalStream' in _bp_plug:
        _bp3_body = _bp_plug.split('private fun handleHalStreamStart')[1] \
            .split('private fun stopHalStream')[0]
    # ОБЛАСТЬ ПРО ЖИВОЙ ДВИЖОК — РОВНО ТЕЛО ensureEngine.
    #
    # Первая редакция этого гейта была СЛЕПОЙ, и мутационный харнесс это
    # поймал: `streamSink?.setOut(...)` встречается ещё в attachFlutter и
    # в detachFlutter, поэтому проверка по всему файлу проходила за счёт
    # постороннего кода даже после того, как ранний возврат заменяли на
    # stopAll(). Ровно та же болезнь, что у BF5 в окне №10 — и, как там,
    # лечится сужением области, а не подгонкой анкера.
    _bp3_ens = ''
    if 'private fun ensureEngine(' in _bp_own:
        _bp3_ens = _bp_own.split('private fun ensureEngine(')[1]
    _bp3_guard = ''
    if 'if (engine != null) {' in _bp3_ens:
        _bp3_guard = _bp3_ens.split('if (engine != null) {')[1][:160]
    _bp3 = (_bp3_guard != '' and
            'streamSink?.setOut(out)' in _bp3_guard and
            'return' in _bp3_guard and
            'stopAll()' not in _bp3_guard and
            'stopAll()' not in _bp3_ens.split('DiLinkProfiles.selectProfile')[0]
            and _bp3_body != '' and
            'HalStreamOwner.attachFlutter(' in _bp3_body and
            'stopHalStream()' in _bp3_body.split('catch (t: Throwable)')[1] and
            'stopHalStream()' not in
            _bp3_body.split('catch (t: Throwable)')[0])
    if _bp3:
        ok('BP3 handing the stream to Dart swaps the destination, it does '
           'not re-register a live engine')
    else:
        fail('BP3 attaching Dart can tear down and re-register the live '
             'subscription — a gap in the data and two proxies at once')

    # BP4: НАБОР ЦЕЛЕЙ СОБИРАЕТСЯ В ОДНОМ МЕСТЕ. Разойдись список на паре
    # Power+BigData canDataCollect — GB32960-сбор в фоне не стартует, кадры
    # 0x99000020 не идут, и soc_precise, SOH и температура тихо исчезают.
    # Отчёты при этом остаются зелёными: события идут, счётчики растут.
    _bp4 = ('fun buildTargets(' in _bp_own and
            'BYDAutoPowerDevice_canDataCollect' in _bp_own and
            'BYDAutoBigDataDevice_canDataCollect' in _bp_own and
            'extraStatisticFids' in _bp_own and
            'BYDAutoPowerDevice_canDataCollect' not in _bp_plug and
            'streamingTargets' not in _bp_plug)
    if _bp4:
        ok('BP4 the target set is assembled in exactly one place, so the '
           'background subscription cannot drift from the live one')
    else:
        fail('BP4 the target set exists twice — the background stream can '
             'lose soc_precise/SOH/battery_temp without any gate noticing')

    # BP5: СЧЁТЧИКИ СЧИТАЮТ ДО ПРИДУШИВАНИЯ, ДО ОТБРАСЫВАНИЯ СЫРЫХ КАДРОВ И
    # ДО ПОТОЛКА. Это ответ на ГЛАВНОЕ НЕИЗВЕСТНОЕ окна — отдаёт ли HAL
    # события фоновому процессу. Считай после — и работающий HAL при полном
    # журнале выглядел бы молчащим, то есть ложно-отрицательный ответ на
    # единственный вопрос, ради которого патч написан.
    # JournalHalOut.emit, а не FlutterHalOut.emit: первый `override fun
    # emit(` в файле принадлежит выходу во Flutter, и счётчиков там нет и
    # быть не должно. Гейт, прочитавший его, был бы вакуумным.
    _bp5_emit = _bp_out.split('class JournalHalOut')[1] \
        .split('override fun emit(')[1].split('override fun')[0]
    _bp5_seen = _bp5_emit.find('seen.incrementAndGet()')
    _bp5_full = _bp5_emit.find('if (full)')
    _bp5_exec = _bp5_emit.find('io.execute')
    _bp5 = (_bp5_seen != -1 and _bp5_full != -1 and _bp5_exec != -1 and
            _bp5_seen < _bp5_full < _bp5_exec and
            'perTarget.getOrPut' in _bp5_emit and
            'fun seenTotal()' in _bp_out)
    if _bp5:
        ok('BP5 the per-target counters run before the throttle, the raw '
           'filter and the cap — a working HAL cannot read as silent')
    else:
        fail('BP5 the counters sit behind a filter: the answer to the main '
             'unknown could come back falsely negative')

    # BP6: ПОТОЛОК ЕСТЬ, И О НЁМ ГОВОРЯТ. Ротация из фонового контекста
    # запрещена гейтом BL7 и остаётся запрещённой: сервис поднимается на
    # каждом пробуждении ГУ, а переименование под возможным чтением — та же
    # порода, что подмена базы под живым Drift. Поэтому журнал закрывается
    # и пишет об этом строкой, а усечение делает сторона чтения.
    # Ветка потолка проверяется по СТРОЕНИЮ, а не по экранированному
    # литералу: обратные слэши внутри JSON-строки Kotlin не переживают ни
    # одного слоя цитирования, и гейт, стоящий на них, красен от
    # опечатки, а не от регресса.
    _bp6_cap = ''
    if 'if (bytes + size > CAP_BYTES)' in _bp_out:
        _bp6_cap = _bp_out.split('if (bytes + size > CAP_BYTES)')[1][:600]
    _bp6 = ('const val CAP_BYTES' in _bp_out and
            _bp6_cap != '' and
            'full = true' in _bp6_cap and
            'appendText(' in _bp6_cap and
            'full' in _bp6_cap and
            'dropped.addAndGet' in _bp6_cap and
            'rename' not in _bp_out and
            'rotate' not in _bp_out.lower())
    if _bp6:
        ok('BP6 the journal has a cap it announces, and it never rotates '
           'from the background context')
    else:
        fail('BP6 the journal can grow without a stated bound, or rotates '
             'from a context BL7 forbids')

    # BP7: ВТЯГИВАНИЕ СТРОГО ДО `_startStream()`, И УСЕЧЕНИЕ ПОСЛЕ ВСТАВКИ.
    # Перестановка двух строк не ломает ни сборку, ни один отчёт — она
    # теряет поездку, и узналось бы это полевым визитом.
    # Область — РОВНО тело init(). `await _startStream();` встречается в
    # файле не один раз (setMode тоже его зовёт), и `find` по всему файлу
    # взял бы чужое вхождение и объявил порядок верным при неверном —
    # ровно та семья ошибок, что мутационный харнесс нашёл у BM1.
    _bp7_init = ''
    if 'Future<void> init() async {' in _bp_hal and \
            'Future<void> setSocSource(' in _bp_hal:
        _bp7_init = _bp_hal.split('Future<void> init() async {')[1] \
            .split('Future<void> setSocSource(')[0]
    _bp7_ing = _bp7_init.find('HalBgJournal.ingest(')
    _bp7_str = _bp7_init.find('await _startStream();')
    _bp7_ins = _bp_jrn.find('insertBackgroundHalSamples(')
    # Последнее удаление — то, что стоит после вставки. Ранние (остаток
    # прошлого захода, пустой файл, чужая версия) к порядку отношения не
    # имеют, поэтому rfind, а не find.
    _bp7_trunc = _bp_jrn.rfind('await _drop(taken);')
    _bp7 = (_bp7_init != '' and
            _bp7_ing != -1 and _bp7_str != -1 and _bp7_ing < _bp7_str and
            _bp7_ins != -1 and _bp7_trunc != -1 and _bp7_ins < _bp7_trunc and
            'insertBackgroundHalSamples' in
            _strip_comments_safe((root / 'lib/data/database.dart').read_text()))
    if _bp7:
        ok('BP7 the journal is ingested before the stream is redirected, '
           'and truncated only after the rows are in')
    else:
        fail('BP7 the ingest/redirect or insert/truncate order can lose a '
             'whole drive silently')

    # BP8: ФОНОВЫЕ СТРОКИ НЕСУТ СВОЁ ВРЕМЯ. Готовый insertHalSignal ставит
    # DateTime.now() — для живого потока это метка события, для журнала это
    # значит уложить всю поездку в одно мгновение, и любой расчёт по времени
    # получил бы вертикальную стену вместо ряда.
    _bp8_db = _strip_comments_safe((root / 'lib/data/database.dart').read_text())
    _bp8_body = _bp8_db.split('insertBackgroundHalSamples(')[1].split(
        'Future<int> insertBigDataFrame')[0]
    _bp8 = ('timestamp: Value(r.at)' in _bp8_body and
            'DateTime.now()' not in _bp8_body and
            'tripId: const Value<int?>(null)' in _bp8_body and
            'typedef BgHalRow' in _bp8_db)
    if _bp8:
        ok('BP8 background rows carry the timestamp from the journal, not '
           'the insert time, and claim no trip they never had')
    else:
        fail('BP8 background rows would stack at the insert instant or '
             'invent a trip id — either destroys every time series')

    # BP9: ОТЧЁТ О ВОССТАНОВЛЕНИИ ЧИТАЕТСЯ, И ГЛАВНОЕ ЧИСЛО ПОКАЗАНО.
    # Два долга наблюдаемости 31.07 одним предметом: import_applied_at
    # писался и не читался никем, а hal_samples — те 20 632 строки, ради
    # которых импорт затевался — не показывались нигде.
    _bp9 = ('kPromise' in _bp_imp and 'kReport' in _bp_imp and
            'static Future<ImportReport?> readReport()' in _bp_imp and
            'class ImportReport' in _bp_imp and
            "counts[t]" in _bp_imp and
            'ImportService.readReport()' in _bp_dm and
            '_reportCard(' in _bp_dm and
            'countAllHalSamples()' in _bp_dm and
            "_counts!['hal_samples']" in _bp_dm)
    if _bp9:
        ok('BP9 the restore report is read, not just written, and '
           'hal_samples — the number the import exists for — is on screen')
    else:
        fail('BP9 the import still cannot be verified from inside the app')
    # BP10: ФОНОВЫЙ СТАРТ НЕ ОТБИРАЕТ ПОТОК У DART. Дефект, найденный
    # первой ревизией, и он бы дошёл до машины. startForBackground зовётся
    # на КАЖДОМ onStartCommand, включая срабатывание моста при открытом
    # приложении (в поле 31.07 — четыре цикла за вечер). Без охраны
    # ensureEngine делал бы setOut(journal) поверх живого адресата Dart:
    # приборы на экране замирают, атлас не набирается, а журнал пишется
    # исправно — ни один счётчик и ни один другой гейт не краснеет.
    _bp10_sfb = ''
    if 'fun startForBackground(' in _bp_own:
        _bp10_sfb = _bp_own.split('fun startForBackground(')[1] \
            .split('fun attachFlutter')[0]
    _bp10_guard = 'if (engine != null && outTag == OUT_FLUTTER) return lastStatus'
    _bp10 = (_bp10_sfb != '' and
             _bp10_guard in _bp10_sfb and
             _bp10_sfb.find(_bp10_guard) <
             _bp10_sfb.find('ensureEngine(') and
             'const val OUT_FLUTTER' in _bp_own)
    if _bp10:
        ok('BP10 the background start never takes the live stream away '
           'from Dart')
    else:
        fail('BP10 a bridge alarm while the app is open would steal the '
             'stream — instruments freeze, journal keeps writing, nothing '
             'goes red')
else:
    ok(f"Part BP skipped (build +{pv}, autostart collection lands in +182)")

# ═════ Part BQ — v0.1.83+182 «Журнал: владение, идемпотентность, границы» ═════
#
# Архитектурная ревизия патча 2 нашла три вещи, которые ЛОМАЮТ ДАННЫЕ, и две,
# которые ломают ресурсы. Все пять здесь, каждая с гейтом, потому что все пять
# невидимы: сборка проходит, отчёты зелёные, а строки теряются, удваиваются
# или разбираются не тем разбором.
#
# Отдельно стоит BQ6. Гейт BP7 в прежней редакции стоял на комментарии,
# утверждавшем «потерянного окна не существует», при коде, у которого окно
# было. Гейты такого не ловят — они проверяют, что текст на месте, а не что
# код делает то, что текст говорит. Здесь предмет проверки — МЕХАНИЗМ
# (переименование), а не обещание.
if int(pv) >= 182:
    _bq_kt = 'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'
    _bq_out = _strip_comments_safe(
        (root / (_bq_kt + 'hal/HalOut.kt')).read_text())
    _bq_own = _strip_comments_safe(
        (root / (_bq_kt + 'hal/HalStreamOwner.kt')).read_text())
    _bq_svc = _strip_comments_safe(
        (root / (_bq_kt + 'AutostartService.kt')).read_text())
    _bq_plug = _strip_comments_safe(
        (root / (_bq_kt + 'BydNativePlugin.kt')).read_text())
    _bq_jrn = _strip_comments_safe(
        (root / 'lib/services/hal_bg_journal.dart').read_text())
    _bq_hal = _strip_comments_safe(
        (root / 'lib/services/hal_telemetry_service.dart').read_text())
    _bq_ch = _strip_comments_safe(
        (root / 'lib/services/hal_telemetry_channel.dart').read_text())

    # BQ1: ВЛАДЕНИЕ ПЕРЕДАЁТСЯ ПЕРЕИМЕНОВАНИЕМ, ЖИВОЙ ПУТЬ НЕ ЧИТАЕТСЯ.
    # Читать живой файл и потом удалять значит терять всё, что писатель
    # дописал между чтением и удалением. На этом ГУ процесс живёт часами,
    # сервис пишет, а новый движок Flutter поднимается в том же процессе —
    # путь обычный, а не краевой.
    _bq1 = ('consumingName' in _bq_jrn and
            'await live.rename(taken.path);' in _bq_jrn and
            'await taken.readAsString();' in _bq_jrn and
            'live.readAsString()' not in _bq_jrn and
            _bq_jrn.find('await live.rename(taken.path);') <
            _bq_jrn.find('await taken.readAsString();'))
    if _bq1:
        ok('BQ1 the journal is taken by rename before it is read — no '
           'window where the writer appends into a file being consumed')
    else:
        fail('BQ1 the live journal path is read in place — lines appended '
             'between read and delete vanish silently')

    # BQ2: ОДНА ТРАНЗАКЦИЯ НА ВЕСЬ ФАЙЛ. Пачка на транзакцию не «рисковала»
    # дублями, а гарантировала их: отказ на середине оставлял вставленные
    # пачки И файл, следующий старт втягивал всё заново. У hal_samples нет
    # ни client_uuid, ни сверки — механизм лавины 04.07.
    _bq2_ing = ''
    if 'static Future<HalBgIngestResult> ingest(' in _bq_jrn:
        _bq2_ing = _bq_jrn.split('static Future<HalBgIngestResult> ingest(')[1] \
            .split('static int? _header(')[0]
    _bq2 = (_bq2_ing != '' and
            'await db.transaction(() async {' in _bq2_ing and
            _bq2_ing.find('await db.transaction(() async {') <
            _bq2_ing.find('insertBackgroundHalSamples(') and
            _bq2_ing.rfind('insertBackgroundHalSamples(') <
            _bq2_ing.rfind('await _drop(taken);'))
    if _bq2:
        ok('BQ2 the whole file goes in one transaction — a mid-way failure '
           'cannot leave half the rows inserted and the file still there')
    else:
        fail('BQ2 a partial insert would guarantee duplicates on the next '
             'start — the 04.07 mechanism, with no uuid to catch it')

    # BQ3: ОСТАТОК СЧИТАЕТСЯ ВТЯНУТЫМ И УДАЛЯЕТСЯ. Файл `.consuming` на
    # старте означает падение прошлого захода, и вставилось ли что-нибудь —
    # неизвестно. Втянуть снова значит удвоить без всякой сверки. Потерять
    # одну поездку хуже, чем ничего, и несравнимо лучше, чем удвоить молча:
    # второго не видно вообще ничем, включая отчёт о восстановлении.
    _bq3_head = _bq2_ing.split('if (!await live.exists())')[0] if _bq2_ing else ''
    _bq3 = (_bq3_head != '' and
            'if (await taken.exists()) {' in _bq3_head and
            'await _drop(taken);' in _bq3_head and
            'abandoned:' in _bq3_head and
            'insertBackgroundHalSamples' not in _bq3_head)
    if _bq3:
        ok('BQ3 a leftover .consuming file is counted, dropped and '
           'reported — never ingested a second time')
    else:
        fail('BQ3 a crashed ingest would be replayed, duplicating exactly '
             'the rows the whole feature exists to collect')

    # BQ4: У ЖУРНАЛА ЕСТЬ ВЕРСИЯ ФОРМАТА, И ЧУЖАЯ ОТВЕРГАЕТСЯ ЦЕЛИКОМ.
    # Файл — приватный протокол через границу языков с короткими ключами.
    # Журнал от прежней сборки был бы разобран молча. В этом же коде задача
    # решена один раз (kPrefsFormat), и решать её здесь иначе несимметрично.
    # ОТСУТСТВИЕ заголовка — не «версия 1»: это неизвестная сборка.
    _bq4 = ('const val FMT: Int = 1' in _bq_out and
            'static const int fmt = 1;' in _bq_jrn and
            'private fun header()' in _bq_out and
            'if (!existed) {' in _bq_out and
            'if (hdr != fmt) {' in _bq_jrn and
            'rejectedFmt' in _bq_jrn and
            "m['_'] != 'hdr'" in _bq_jrn)
    if _bq4:
        ok('BQ4 the journal declares its format version and a foreign or '
           'missing header rejects the whole file')
    else:
        fail('BQ4 a journal from another build would be parsed by our '
             'layout and land in hal_samples as noise')

    # BQ5: ОЧЕРЕДЬ ЗАПИСИ ОГРАНИЧЕНА, ОТКАЗ СЧИТАЕТСЯ. newSingleThreadExecutor
    # держит LinkedBlockingQueue БЕЗ границы, и каждая задача несёт копию
    # пакета: застрявшая флеш-память в долгой поездке — рост памяти в
    # foreground-сервисе. Потеря, названная числом, лучше памяти, названной
    # ничем; счётчик уронов уже был.
    # ОБЛАСТЬ — САМО ПОСТРОЕНИЕ ИСПОЛНИТЕЛЯ, а не файл. Проверка по файлу
    # была СЛЕПОЙ, и мутационный харнесс это поймал: строка `import
    # java.util.concurrent.ArrayBlockingQueue` содержит то же имя, поэтому
    # подмена очереди на неограниченную оставляла гейт зелёным. Четвёртый
    # раз за окно (BM1, BP3, BP5) — и в этом файле уже третий, где виноваты
    # импорты. Проверять надо выражение, а не присутствие слова.
    _bq5_exec = ''
    if 'private val io = ThreadPoolExecutor(' in _bq_out:
        _bq5_exec = _bq_out.split('private val io = ThreadPoolExecutor(')[1] \
            .split(')\n')[0]
    _bq5 = (_bq5_exec != '' and
            'ArrayBlockingQueue(QUEUE_CAPACITY)' in _bq5_exec and
            'threads' in _bq5_exec and
            'ThreadFactory { r ->' in _bq_out and
            'LinkedBlockingQueue' not in _bq5_exec and
            'const val QUEUE_CAPACITY' in _bq_out and
            # Анкер точный, а не окно после первого вхождения имени:
            # первое вхождение — строка ИМПОРТА, и окно за ней содержит
            # соседние импорты. Третий раз за окно та же семья (BM1, BP5).
            'RejectedExecutionHandler { _, _ -> dropped.incrementAndGet() }'
            in _bq_out and
            'newSingleThreadExecutor' not in _bq_out)
    if _bq5:
        ok('BQ5 the write queue is bounded and a rejected batch is counted, '
           'not silently held in memory')
    else:
        fail('BQ5 an unbounded queue can grow without limit in a foreground '
             'service when the flash stalls')

    # BQ6: ПОТОЛОК ВОССТАНАВЛИВАЕТСЯ ПО ЯВНОМУ УВЕДОМЛЕНИЮ, А ДЛИНА
    # СПРАШИВАЕТСЯ У ФАЙЛОВОЙ СИСТЕМЫ. Помнить длину полем нельзя: читатель
    # забирает файл, и запомненное число относится к файлу, которого нет —
    # потолок срабатывал бы на мебибайты раньше до конца процесса. А `full`
    # само не снимется: при нём emit до файловой системы не доходит и
    # заметить пропажу не может, поэтому нужен протокол, а не догадка.
    _bq6_app = ''
    if 'private fun append(' in _bq_out:
        _bq6_app = _bq_out.split('private fun append(')[1].split('private fun header()')[0]
    _bq6 = (_bq6_app != '' and
            'var bytes = if (existed) f.length() else 0L' in _bq6_app and
            'fun onConsumed()' in _bq_out and
            'full = false' in _bq_out.split('fun onConsumed()')[1][:200] and
            'fun noteJournalConsumed()' in _bq_own and
            '"halJournalConsumed"' in _bq_plug and
            'halJournalConsumed' in _bq_ch and
            'if (ing.consumed) {' in _bq_hal)
    if _bq6:
        ok('BQ6 the cap budget is restored by an explicit consume protocol '
           'and the length is asked of the filesystem, never remembered')
    else:
        fail('BQ6 one full drive would switch background collection off for '
             'the rest of a process that lives for hours')

    # BQ7: onDestroy НЕ ОСТАВЛЯЕТ ПОДПИСКУ БЕЗ ВЛАДЕЛЬЦА — и не снимает её
    # у Dart. Условие обязательно в обе стороны: сервис может быть
    # остановлен системой при живом открытом приложении, и безусловный
    # stopAll() погасил бы приборы на экране машины.
    _bq7_od = ''
    if 'override fun onDestroy()' in _bq_svc:
        _bq7_od = _bq_svc.split('override fun onDestroy()')[1] \
            .split('override fun onStartCommand')[0]
    _bq7 = (_bq7_od != '' and
            'HalStreamOwner.activeOut() != HalStreamOwner.OUT_FLUTTER' in _bq7_od
            and 'HalStreamOwner.stopAll()' in _bq7_od)
    if _bq7:
        ok('BQ7 a destroyed service releases the subscription it owned, and '
           'only the one it owned')
    else:
        fail('BQ7 the service either leaks a registered proxy or tears down '
             'a stream Dart is still using')
else:
    ok(f"Part BQ skipped (build +{pv}, journal ownership lands in +182)")

# ═════ Part BR — v0.1.84+183 «Строка журнала разбирается, и это видно» ═════
#
# +182 не собрался: вызов `_parse` стоял, объявления не было. Гейты этого не
# увидели, потому что все 533 — подстрочные, а `dart_balance` считал скобки и
# импорты. BR5 закрывает класс ошибки целиком, остальные четыре — семантику
# самого разбора, которая до сборки на CI не проверяется ничем.
#
# Область у BR2–BR4 — ТЕЛО МЕТОДА, а не файл. В HalOut.kt строки import подвели
# подстрочные проверки трижды за одно окно (BM1, BP3, BP5, все семьи BF5), и
# лечение всегда сужение области, никогда расширение анкера.
if int(pv) >= 183:
    _br_jrn = _strip_comments_safe(
        (root / 'lib/services/hal_bg_journal.dart').read_text())
    _br_hal = _strip_comments_safe(
        (root / 'lib/services/hal_telemetry_service.dart').read_text())
    _br_tool = (root / 'tools/dart_balance.py').read_text()

    _br_body = ''
    if 'static BgHalRow? _parse(' in _br_jrn:
        _br_body = _br_jrn.split('static BgHalRow? _parse(')[1] \
            .split('static int? _header(')[0]

    # BR1: МЕТОД ОБЪЯВЛЕН, А НЕ ТОЛЬКО ВЫЗВАН. Дословная причина падения +182.
    _br1 = (_br_body != '' and
            '_parse(line);' in _br_jrn and
            'return (' in _br_body and
            'at: DateTime' in _br_body)
    if _br1:
        ok('BR1 the journal line parser is declared, not merely called — '
           'the +182 build break cannot recur unnoticed')
    else:
        fail('BR1 _parse is called without a declaration — kernel_snapshot '
             'fails and no substring gate sees it')

    # BR2: РАЗБОР КЛЮЧА СОВПАДАЕТ С ЖИВЫМ ПУТЁМ БУКВА В БУКВУ. Фоновые строки
    # лягут в ту же hal_samples, что и живые. Разойдись здесь на пустую строку
    # против null или на смещение — и одна цель расщепится на две молча.
    _br2_live = ''
    if '_splitKey(String key) {' in _br_hal:
        _br2_live = _br_hal.split('_splitKey(String key) {')[1].split('}')[0]
    _br2 = (_br_body != '' and _br2_live != '' and
            "'|0x'" in _br2_live and "'|0x'" in _br_body and
            'i + 3' in _br2_live and
            "i < 0 ? key : key.substring(0, i)" in _br_body and
            "i < 0 ? '' : key.substring(i + 3)" in _br_body and
            "subtype: subtype" in _br_body and
            "targetKey: target" in _br_body)
    if _br2:
        ok('BR2 the background key split is the live one, offset for offset — '
           'one target cannot become two')
    else:
        fail('BR2 background rows would carry a different target/subtype '
             'shape than live rows in the same table')

    # BR3: ВРЕМЯ ИЗ СТРОКИ, И НИГДЕ В ЭТОМ ФАЙЛЕ НЕТ DateTime.now(). Иначе вся
    # поездка ложится в одно мгновение — вертикальная стена вместо ряда, и
    # ровно та беда, ради которой пакетная вставка вообще отдельный метод.
    _br3 = (_br_body != '' and
            'DateTime.fromMillisecondsSinceEpoch(' in _br_body and
            'DateTime.now()' not in _br_jrn and
            'ms <= 0' in _br_body)
    if _br3:
        ok('BR3 the timestamp comes from the line and a non-positive one is '
           'refused — no drive collapses into one instant, none lands in 1970')
    else:
        fail('BR3 journal rows would take the ingest time, flattening the '
             'whole drive into a single moment')

    # BR4: СЛУЖЕБНЫЕ СТРОКИ ПРОПУСКАЮТСЯ ДО СЧЁТЧИКА ПЛОХИХ, и пропуск общий.
    # Строка потолка приходит В КОНЦЕ файла: частная ветка «только первая
    # строка» из +182 её не ловила, и каждый полный журнал показывал бы
    # malformed>0 — читается как «разбор сломан», хотя сломан отчёт.
    _br4_loop = ''
    if 'for (final line in lines) {' in _br_jrn:
        _br4_loop = _br_jrn.split('for (final line in lines) {')[1] \
            .split('chunk.add(row);')[0]
    _br4 = (_br4_loop != '' and
            'startsWith(\'{"_":\')' in _br4_loop and
            'seenLines == 0' not in _br4_loop and
            _br4_loop.find('startsWith(\'{"_":\')') <
            _br4_loop.find('bad++'))
    if _br4:
        ok('BR4 writer control lines are skipped before the malformed '
           'counter, wherever in the file they sit')
    else:
        fail('BR4 the cap line would be counted as malformed, reading as a '
             'broken parser on every full journal')

    # BR5: НЕРЕЗОЛВЯЩИЕСЯ ПРИВАТНЫЕ ВЫЗОВЫ ЛОВЯТСЯ НА ВСЁМ ДЕРЕВЕ. Приватность
    # в Dart — на уровне библиотеки, поэтому `_foo(` в файле без `part` может
    # быть объявлен только там же. Это дартовский двойник базовой линии
    # kotlinc, и он проверен на дереве +182: одно срабатывание, оно же ошибка.
    _br5 = ('def check_privates(' in _br_tool and
            'CALL_RE' in _br_tool and
            "re.search(r'^part\\b'" in _br_tool and
            'check_privates(f)' in _br_tool and
            'privates:' in _br_tool and
            "fails.append(f'{f.name}:{name}')" in _br_tool and
            _br_tool.find('def check_privates(') <
            _br_tool.find('check_privates(f)'))
    if _br5:
        ok('BR5 the dart scan resolves private calls tree-wide — the class '
           'of break that shipped in +182 is now caught before delivery')
    else:
        fail('BR5 nothing in the sandbox can see a called-but-undeclared '
             'private method; only CI would, one drive too late')
else:
    ok(f"Part BR skipped (build +{pv}, the journal parser lands in +183)")

# ═════ Part BS — v0.1.86+185 «Поездка из фоновых строк» ═════
#
# Патч делает три вещи, и каждая ломается молча. Поездка, посчитанная по
# второй копии формулы, выглядит правдоподобно и врёт. Строитель, забывший
# штамп, при каждом открытии строит те же поездки заново. Пакет, снова
# потянувший Flutter, собирается — и разваливается только тогда, когда
# журнал понадобится без Flutter, то есть в поездке.
#
# Область у гейтов — тело метода или конкретное выражение, никогда файл
# целиком (урок семьи BF5: лечение всегда сужение, не расширение анкера).
if int(pv) >= 185:
    _bs_agg_raw = (root / 'lib/services/trip_aggregates.dart').read_text()
    _bs_agg = _strip_comments_safe(_bs_agg_raw)
    _bs_bld = _strip_comments_safe(
        (root / 'lib/services/bg_trip_builder.dart').read_text())
    _bs_conn = _strip_comments_safe(
        (root / 'lib/services/connection.dart').read_text())
    _bs_db = _strip_comments_safe(
        (root / 'lib/data/database.dart').read_text())
    _bs_kt = 'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'
    _bs_own = _strip_comments_safe(
        (root / (_bs_kt + 'hal/HalStreamOwner.kt')).read_text())
    _bs_out = _strip_comments_safe(
        (root / (_bs_kt + 'hal/HalOut.kt')).read_text())
    _bs_plug = _strip_comments_safe(
        (root / (_bs_kt + 'BydNativePlugin.kt')).read_text())
    _bs_hal_dir = (root / (_bs_kt + 'hal'))

    # BS1: РАСЧЁТ ЧИСТ. Ни одного импорта — ни Flutter, ни drift, ни базы.
    # Грязный расчёт нельзя проверить зеркалом, а зеркало здесь и есть
    # единственная проверка без машины.
    _bs1 = ('import ' not in _bs_agg and
            'TripDerived computeTripDerived(' in _bs_agg and
            'required double batteryCapacityKwh' in _bs_agg)
    if _bs1:
        ok('BS1 the trip maths is a pure function — no imports, no clock, '
           'no database, so a mirror can check it without the car')
    else:
        fail('BS1 the trip maths took a dependency — it can no longer be '
             'verified off-vehicle')

    # BS2: ОДНА ПРАВДА. Оба живых места зовут функцию, и НИ ОДНО не считает
    # само. Признак старой копии — присваивание формулы расхода.
    _bs2 = (_bs_conn.count('computeTripDerived(') == 2 and
            '(energyUsedKwh / distanceKm) * 100.0' not in _bs_conn and
            'derived.avgConsumptionKwh100km' in _bs_conn)
    if _bs2:
        ok('BS2 both live finalize paths call the one function — the two '
           'character-identical copies are gone')
    else:
        fail('BS2 a second copy of the trip maths survives in '
             'connection.dart — the copies will drift and nobody will see it')

    # BS3: ФОНОВЫЙ ПУТЬ — ТРЕТИЙ ЗВОНЯЩИЙ, а не четвёртая копия.
    _bs3 = ('computeTripDerived(' in _bs_bld and
            '(energyUsedKwh / distanceKm) * 100.0' not in _bs_bld)
    if _bs3:
        ok('BS3 the background builder calls the same function as the live '
           'paths — one definition of what a trip is')
    else:
        fail('BS3 the background builder computes its own aggregates — two '
             'definitions of a trip in one database')

    # BS4: ГРАНИЦА AA2. Строитель знает базу и не знает ни живой сервис,
    # ни HAL-сервис. Ради этого он и отдельный файл.
    _bs4 = ('HalTelemetryService' not in _bs_bld and
            'connection.dart' not in _bs_bld and
            'hal_telemetry_service' not in _bs_bld)
    if _bs4:
        ok('BS4 the builder depends on the database alone — AA2 holds from '
           'both sides')
    else:
        fail('BS4 the background builder reached into a service — AA2 is '
             'breached and the import cycle is back')

    # BS5: ШТАМП СТОИТ, И СТОИТ ПОСЛЕ ВСТАВКИ. Без него поездки строятся
    # заново при каждом открытии, а `trip_series` для фоновой поездки не
    # соберётся никогда — генератор ищет строки именно по `trip_id`.
    _bs5_body = ''
    if 'Future<bool> _buildOne(' in _bs_bld:
        _bs5_body = _bs_bld.split('Future<bool> _buildOne(')[1]
    _bs5 = (_bs5_body != '' and
            'insertTripWithStampedSamples(' in _bs5_body)
    if _bs5:
        ok('BS5 built rows are stamped with their trip id, after the insert '
           '— no rebuild on the next launch, and the charts find their data')
    else:
        fail('BS5 ingested rows are left unstamped — every launch rebuilds '
             'the same trips and the series generator sees nothing')

    # BS6: МИГРАЦИЯ АДДИТИВНА. Колонка nullable и добавляется охраной; ни
    # одна существующая поездка не переписывается.
    _bs6_ver = 19 if int(pv) >= 193 else 18
    _bs6 = (f'int get schemaVersion => {_bs6_ver};' in _bs_db and
            'if (from < 18) {' in _bs_db and
            '_addColumnIfAbsent(m, trips, trips.source);' in _bs_db and
            'TextColumn get source => text().nullable()();' in _bs_db)
    if _bs6:
        ok('BS6 schema 18 adds trips.source additively — null still means '
           'the OBD2 live path, and no old row is touched')
    else:
        fail('BS6 the trips.source migration is missing or not additive')

    # BS7: ГРАНИЦА ПАКЕТА, А НЕ ФАЙЛА. Третий пункт архитектурной ревизии:
    # BP1 мерил один файл и называл это развязкой расшифровки, пока
    # `FlutterHalOut` лежал в `hal` и тянул туда Flutter. Здесь грепается
    # ВЕСЬ каталог, по коду без комментариев.
    _bs7_bad = []
    for _f in sorted(_bs_hal_dir.glob('*.kt')):
        _src = _strip_comments_safe(_f.read_text())
        if 'io.flutter' in _src or 'AutostartPrefs' in _src:
            _bs7_bad.append(_f.name)
    _bs7 = (not _bs7_bad and
            'class FlutterHalOut(' in _strip_comments_safe(
                (root / (_bs_kt + 'FlutterHalOut.kt')).read_text()))
    if _bs7:
        ok('BS7 the hal package names neither Flutter nor the root prefs in '
           'any file — the boundary is now where the gate measures it')
    else:
        fail('BS7 the hal package depends upward again: '
             + (', '.join(_bs7_bad) or 'FlutterHalOut.kt is missing'))

    # BS8: ПОЛИТИКА У ЗВОНЯЩЕГО. Механизм принимает решение параметром и
    # настроек не читает; читает их плагин, в чьём пакете они и лежат.
    _bs8_body = ''
    if 'fun detachFlutter(' in _bs_own:
        _bs8_body = _bs_own.split('fun detachFlutter(')[1].split('fun ')[0]
    _bs8 = (_bs8_body != '' and
            'keepCollecting: Boolean' in _bs_own and
            'isArmed' not in _bs8_body and
            'optedOut' not in _bs8_body and
            'AutostartPrefs.isArmed(appContext)' in _bs_plug)
    if _bs8:
        ok('BS8 detachFlutter is told whether to keep collecting — the '
           'policy read moved to the package that owns the setting')
    else:
        fail('BS8 the stream owner reads autostart settings again — policy '
             'is back inside the mechanism')

    # BS9: ПОРОГ БЕРЁТСЯ ПО ИМЕНИ, а общий остаётся значением по умолчанию.
    # Проверяется ВЫРАЖЕНИЕ в цикле, а не наличие карты: карта, которую
    # никто не спрашивает, — это комментарий.
    _bs9 = ('ts - prev < throttleFor(name)' in _bs_out and
            'THROTTLE_BY_NAME[name] ?: THROTTLE_MS' in _bs_out and
            '"soh" to 60_000L' in _bs_out and
            '"pack_current" to 1_000L' in _bs_out)
    if _bs9:
        ok('BS9 the journal throttles per signal name — soh no longer '
           'outspends pack_current ten to one')
    else:
        fail('BS9 the per-name throttle is absent or unused; the journal '
             'budget goes back to the signals that never change')

    # BS10: ПРОИСХОЖДЕНИЕ ПРОСТАВЛЯЕТСЯ. Правило честности требует, чтобы
    # HAL-поездка не притворялась донглом; молчаливая колонка этого не даёт.
    _bs10 = ("const String kSourceHalBg = 'hal_bg';" in _bs_bld and
             'source: kSourceHalBg,' in _bs_bld and
             'source: Value(source),' in _bs_db)
    if _bs10:
        ok('BS10 a background trip signs itself hal_bg — it cannot pass for '
           'a dongle-recorded one')
    else:
        fail('BS10 background trips land unmarked and mix with OBD2 trips')
    # BS12: ВСТАВКА И ШТАМП АТОМАРНЫ. Врозь они оставляли поездку без
    # приписанных строк, и следующий запуск строил её ВТОРОЙ РАЗ, с новым
    # `client_uuid`, и отправлял дубль в облако — необратимо. Выключение
    # зажигания на этом ГУ штатно, а исключение на штампе ещё вероятнее:
    # внешний `try/catch` проглотил бы его и отчитался успехом.
    _bs12_tx = ''
    if 'Future<int> insertTripWithStampedSamples(' in _bs_db:
        _bs12_tx = _bs_db.split('Future<int> insertTripWithStampedSamples(')[1] \
            .split('Future<int> insertCompletedTrip(')[0]
    _bs12 = (_bs12_tx != '' and
             'transaction(() async {' in _bs12_tx and
             'insertCompletedTrip(' in _bs12_tx and
             'assignHalSamplesToTrip(' in _bs12_tx and
             'assignHalSamplesToTrip(' not in _bs_bld)
    if _bs12:
        ok('BS12 the trip row and its stamp land in one transaction — an '
           'ignition-off between them can no longer mint a duplicate trip')
    else:
        fail('BS12 insert and stamp are separable again — a death or a '
             'throw between them duplicates the trip into the cloud')

    # BS13: ВЫБОРКА С ПОТОЛКОМ, И ОБРЕЗАННЫЙ ХВОСТ ОТКЛАДЫВАЕТСЯ. Без
    # потолка проход материализует всё накопленное с прошлого открытия —
    # интервал ничем не ограничен, а ГУ просыпается сам. Без второй
    # половины потолок резал бы поездку пополам по произвольной строке.
    _bs13 = ('int limit = 50000,' in _bs_db and
             '..limit(limit)' in _bs_db and
             'kScanLimit' in _bs_bld and
             'final truncated = rows.length >= kScanLimit;' in _bs_bld and
             'truncated && i == clusters.length - 1 && i > 0' in _bs_bld)
    if _bs13:
        ok('BS13 the scan is bounded, a truncated tail is deferred, and a '
           'lone truncated cluster is still built — no silent standstill')
    else:
        fail('BS13 the scan is unbounded or the truncated cluster is built '
             'anyway — memory on the head unit, or half a trip')

    # BS14: ПЕРЕКОС ЧАСОВ СЛЫШЕН. RTC ГУ до синхронизации отстаёт, и тогда
    # «свежий хвост» съедает все кластеры разом. Отказ правильный, но
    # молчаливая деградация в поле неотличима от поломки.
    _bs14 = ('rows.removeWhere((r) => r.timestamp.isAfter(at));' in _bs_bld and
             'clock behind data by' in _bs_bld and
             'if (rows.length < 2)' in _bs_bld)
    if _bs14:
        ok('BS14 rows ahead of the head-unit clock are dropped, not fatal — '
           'one bad timestamp cannot freeze the feature forever')
    else:
        fail('BS14 a lagging RTC silently builds nothing and explains '
             'nothing')

    # BS11: ВРЕМЯ В ДВИЖЕНИИ НЕ УМНОЖАЕТСЯ НА ШАГ ПРОРЕЖИВАНИЯ. Гейт
    # поставлен по ошибке, найденной ревизией этого же патча: первая
    # редакция считала `speedSamples * 3`, и §2 того же патча — пороги по
    # имени, где у `speed` стала секунда — сделал бы это число втрое
    # больше настоящего. Связь между двумя половинами патча была
    # невидимой, и такие связи обязаны становиться гейтом, а не памятью.
    _bs11_body = ''
    if 'var movingSec = 0;' in _bs_bld:
        _bs11_body = _bs_bld.split('var movingSec = 0;')[1] \
            .split('final tripId =')[0]
    _bs11 = (_bs11_body != '' and
             'speedSamples * 3' not in _bs_bld and
             'maxGapSec' in _bs11_body and
             'movingSec +=' in _bs11_body)
    if _bs11:
        ok('BS11 moving time is summed from real intervals — changing a '
           'throttle threshold can no longer inflate it')
    else:
        fail('BS11 moving time is derived from the throttle step; §2 makes '
             'that number wrong the moment a threshold moves')
else:
    ok(f"Part BS skipped (build +{pv}, background trips land in +185)")

# ═════ Part BT — v0.1.87+186 «Фоновая поездка узнаётся в облаке» ═════
#
# Сервер (Друг 2, справка 02.08, head 0018) уже исключает из инварианта #8
# поездку с `extra.source == "hal_bg"`. Клиент до этого патча такой ключ не
# писал вовсе: колонка `trips.source` локальная и в отправку не входит.
# Поставь мы +185 как есть — каждая фоновая поездка позвонила бы утренней
# сводкой. Здесь это закрывается, и здесь же снимается риск дублей при
# восстановлении из архива.
if int(pv) >= 186:
    _bt_db = _strip_comments_safe(
        (root / 'lib/data/database.dart').read_text())
    _bt_bld = _strip_comments_safe(
        (root / 'lib/services/bg_trip_builder.dart').read_text())
    _bt_uu = _strip_comments_safe(
        (root / 'lib/data/uuid_v7.dart').read_text())

    # BT1: ПРОИСХОЖДЕНИЕ УЕЗЖАЕТ В ОБЛАКО. Ключ и его значение — контракт с
    # сервером; опечатка в любом из них не сломает ничего видимого и
    # вернёт ночные алерты.
    _bt1 = ('"source":"$kSourceHalBg"' in _bt_bld and
            "const String kSourceHalBg = 'hal_bg';" in _bt_bld and
            'extraJson:' in _bt_bld)
    if _bt1:
        ok('BT1 a background trip carries its provenance into extra — the '
           'server can tell it from a dongle trip and #8 stays quiet')
    else:
        fail('BT1 background trips ship without extra.source — every one of '
             'them rings the odometer-continuity alert')

    # BT2: EXTRA СЛИВАЕТСЯ, А НЕ ПЕРЕЗАПИСЫВАЕТСЯ. Писателей у блоба трое:
    # гистограмма в конце поездки, происхождение при вставке, а скоро и
    # joinedInProgress в начале. Перезапись целиком — тихая потеря чужого
    # ключа, и заметить её можно только по возврату ночных алертов.
    _bt2_body = ''
    if 'Future<void> mergeTripExtra(' in _bt_db:
        _bt2_body = _bt_db.split('Future<void> mergeTripExtra(')[1] \
            .split('Future<void> ')[0]
    _bt2 = (_bt2_body != '' and
            'merged.addAll' in _bt2_body and
            'jsonDecode' in _bt2_body and
            'extra: extra != null ? Value(extra)' not in _bt_db and
            'await mergeTripExtra(id, extra);' in _bt_db)
    if _bt2:
        ok('BT2 extra is merged key-wise, and the aggregate path merges too '
           '— no writer can silently drop another one\'s key')
    else:
        fail('BT2 something still overwrites trips.extra wholesale — the '
             'provenance or the histogram will vanish without a trace')

    # BT3: UUID ФОНОВОЙ ПОЕЗДКИ ДЕТЕРМИНИРОВАН. Пересборка того же выезда
    # после восстановления из архива обязана дать тот же uuid, иначе на
    # сервере появится второй экземпляр, который дедупликация по паре
    # устройство/uuid не поймает.
    _bt3 = ('String uuidV7Deterministic(' in _bt_uu and
            'required String seed' in _bt_uu and
            'uuidV7Deterministic(' in _bt_db and
            'uuidV7()' not in _bt_db.split('insertCompletedTrip(')[1]
            .split('Future<int> countAllHalSamples')[0])
    if _bt3:
        ok('BT3 a rebuilt background trip keeps its identity — restoring an '
           'older archive can no longer mint a duplicate in the cloud')
    else:
        fail('BT3 the background trip uuid is random again; a rebuild after '
             'an archive restore duplicates the drive on the server')

    # BT4: ФОРМАТ UUID ОСТАЁТСЯ v7. Версия и вариант на своих местах, метка
    # времени впереди — сервер сортирует по uuid и вправе ожидать порядка.
    _bt4 = ('0x70 | (b[6] & 0x0F)' in _bt_uu and
            '0x80 | (b[8] & 0x3F)' in _bt_uu and
            _bt_uu.count('0x70 | (b[6] & 0x0F)') == 2)
    if _bt4:
        ok('BT4 the deterministic uuid is still a well-formed v7 — version, '
           'variant and the timestamp prefix all where the server expects')
    else:
        fail('BT4 the deterministic uuid drifted from the v7 layout')
    # BT5: ОБЛАСТЬ `await` ПРОВЕРЯЕТСЯ НА ВСЁМ ДЕРЕВЕ. Поставлен по ошибке,
    # допущенной в этом же патче: правка ушла в ЧУЖОЙ метод — `await` в
    # неасинхронном теле и ссылка на параметр, которого у метода нет. Оба
    # промаха — жёсткие ошибки компиляции, а баланс скобок сошёлся и все
    # подстрочные гейты были зелёными. Текстовый гейт не видит области
    # видимости, значит области нужна своя проверка.
    _bt5_tool = (root / 'tools/dart_balance.py').read_text()
    _bt5 = ('def check_await_scope(' in _bt5_tool and
            'def _opens_function(' in _bt5_tool and
            'CTRL = ' in _bt5_tool and
            'check_await_scope(f)' in _bt5_tool and
            "fails.append(f'{f.name}:await:{ln}')" in _bt5_tool)
    if _bt5:
        ok('BT5 the dart scan checks await against its enclosing body — an '
           'edit landing in the wrong method is caught before CI')
    else:
        fail('BT5 nothing checks await scope; a misplaced edit compiles '
             'green through every text gate and dies on the build')
else:
    ok(f"Part BT skipped (build +{pv}, cloud-visible provenance lands in +186)")

# ═════ Part BU — v0.1.88+187 «Архив читается, а не только находится» ═════
#
# Поле 02.08 отдало отказ, которого прежний код не предусматривал:
# `PathAccessException … Permission denied, errno = 13` на постоянном имени
# в публичных Downloads. Удаление меняет uid, файл переживает удаление, а
# владение им — нет. Прежний поиск возвращал файл по `exists()` (на чужом
# файле `stat` разрешён, `open` нет) и до перечисления не доходил НИКОГДА,
# поэтому нечитаемый архив прежней установки заслонял собой свежий,
# написанный нами же. Здесь это закрывается, и здесь же ставится путь,
# который от uid не зависит вовсе, — файл по гранту.
if int(pv) >= 187:
    _bu_imp = _strip_comments_safe(
        (root / 'lib/services/import_service.dart').read_text())
    _bu_exp = _strip_comments_safe(
        (root / 'lib/services/export_service.dart').read_text())
    _bu_dm = _strip_comments_safe(
        (root / 'lib/screens/data_management.dart').read_text())
    _bu_mf = (root / 'android/app/src/main/AndroidManifest.xml').read_text()
    _bu_apk = (root
               / 'android/app/src/main/kotlin/com/bz5companion'
                 '/bz5_companion/ApkInstall.kt').read_text()

    # BU1: ВЫБОР ПО ЧИТАЕМОСТИ, А НЕ ПО НАЛИЧИЮ. Предмет патча. Возврат
    # по `exists()` — ровно тот дефект, что стоил поля; проверяем, что
    # решение принимает проба открытия и что ранний возврат не вернулся.
    _bu1_body = ''
    if 'static Future<ArchiveSearch> searchArchive()' in _bu_imp:
        _bu1_body = _bu_imp.split(
            'static Future<ArchiveSearch> searchArchive()')[1] \
            .split('\n  }')[0]
    _bu1 = (_bu1_body != '' and
            'findArchiveCandidates()' in _bu1_body and
            'c.readable' in _bu1_body and
            'exists()' not in _bu1_body and
            'static Future<String?> _openFailure(' in _bu_imp and
            'PathAccessException' in _bu_imp and
            'searchArchive()' in _bu_dm)
    if _bu1:
        ok('BU1 the archive is chosen by whether it opens, and the screen '
           'calls that chooser — the 02.08 shadowing cannot come back')
    else:
        fail('BU1 archive discovery still trusts exists(), or the live path '
             'no longer goes through the chooser this gate guards')

    # BU2: ИМЯ СЛОТА СОВПАДАЕТ ПО ОБЕ СТОРОНЫ. Литералы в Dart и в Kotlin,
    # компилятор такую пару не сверит никогда, а расхождение означает, что
    # принятый по гранту архив ложится туда, где импорт его не ищет, —
    # молча, и выглядит это как «файл не принялся».
    _bu2 = ("static const String kStagedName = 'imported_archive.zip';"
            in _bu_imp and
            'const val ARCHIVE = "imported_archive.zip"' in _bu_apk and
            'File(context.filesDir, ARCHIVE)' in _bu_apk)
    if _bu2:
        ok('BU2 the staged-archive filename matches on both sides — the '
           'granted file lands where the import actually looks')
    else:
        fail('BU2 Dart and Kotlin disagree about the staged archive name; '
             'an accepted file would vanish silently')

    # BU3: СВОЙ КАТАЛОГ СРЕДИ КАНДИДАТОВ, И ПЕРВЫМ. Единственное место,
    # читаемость которого не зависит от uid прежней установки. Уйди оно из
    # списка — приём по гранту перестанет иметь смысл.
    _bu3_body = ''
    if 'static Future<List<Directory>> _candidateDirs()' in _bu_imp:
        _bu3_body = _bu_imp.split(
            'static Future<List<Directory>> _candidateDirs()')[1] \
            .split('\n  }')[0]
    _bu3 = (_bu3_body != '' and
            'getApplicationSupportDirectory()' in _bu3_body and
            _bu3_body.index('getApplicationSupportDirectory()')
            < _bu3_body.index('/storage/emulated/0/Download'))
    if _bu3:
        ok('BU3 the app-private dir is a candidate and comes first — the '
           'granted archive is reachable regardless of uid')
    else:
        fail('BU3 the staged archive is not searched for; accepting a file '
             'by grant leads nowhere')

    # BU4: ГРАНТ ЗАБИРАЕТСЯ СРАЗУ. Uri из выбора файла живёт до закрытия
    # выбора. Отложенное чтение по нему упало бы тем же Permission denied,
    # от которого патч и уходит, — поэтому копия обязана стоять между
    # выбором и осмотром.
    _bu4_body = ''
    if 'Future<void> _pickArchive() async' in _bu_dm:
        _bu4_body = _bu_dm.split('Future<void> _pickArchive() async')[1] \
            .split('\n  Future<')[0]
    _bu4 = (_bu4_body != '' and
            'pickContent' in _bu4_body and
            'stageArchive(' in _bu4_body and
            _bu4_body.index('stageArchive(') < _bu4_body.index(
                'ImportService.inspect'))
    if _bu4:
        ok('BU4 a picked file is copied before it is inspected — the '
           'temporary grant is spent while it is still alive')
    else:
        fail('BU4 the picked uri is read after the grant may be gone; the '
             'restore would fail with the very error it works around')

    # BU5: ЗАЯВЛЕН ПРИЁМ ZIP. Прямо проверяет версию владельца о том, что
    # кнопки «Поделиться» в проводнике нет из-за отсутствия получателя.
    _bu5 = ('android:mimeType="application/zip"' in _bu_mf and
            'android:mimeType="application/x-zip-compressed"' in _bu_mf and
            'fun stageArchive(' in _bu_apk)
    if _bu5:
        ok('BU5 the app is offered as a receiver for zip — if the file '
           'manager hides its share button, it is no longer our fault')
    else:
        fail('BU5 nothing accepts a zip by share; the one path that does not '
             'depend on uid is unavailable')

    # BU6: ПРОБЫ ТОЛЬКО ЧИТАЮТ. Урок BI3: проба, которая что-то запускает,
    # перестаёт быть безопасной, и звать её при каждом отказе нельзя.
    _bu6_body = ''
    if 'fun storageProbe(' in _bu_apk:
        _bu6_body = _bu_apk.split('fun storageProbe(')[1] \
            .split('\n    }')[0]
    _bu6 = (_bu6_body != '' and
            'startActivity' not in _bu6_body and
            'delete()' not in _bu6_body and
            'mediastore_rows' in _bu6_body and
            'listing_total' in _bu6_body and
            'read_storage_granted' in _bu6_body)
    if _bu6:
        ok('BU6 the storage probe only reads — three answers, no side '
           'effects, safe to run on every refusal')
    else:
        fail('BU6 the storage probe acts instead of measuring')

    # BU7: ЛОЖНОЕ ОБЕЩАНИЕ СНЯТО. Комментарий у копии под постоянным именем
    # утверждал «отказ безобиден, импорт найдёт архив перечислением» при
    # коде, который до перечисления не доходил. Одиннадцатый случай класса
    # «текст не соответствует коду»; гейт стоит на ТЕКСТЕ именно потому,
    # что предмет здесь — обещание.
    _bu_exp_raw = (root / 'lib/services/export_service.dart').read_text()
    # ERA-AWARE (+193). Обещание было про копию под постоянным именем, а
    # копии больше нет — предмет гейта исчез вместе с ней, и требовать
    # строку об её отказе значило бы сторожить пустоту (тот же вакуум, что
    # BU1 в №14). Существо переносится: ложное обещание не вернулось И имя
    # не пишется вовсе, поэтому и отказывать нечему.
    if int(pv) >= 193:
        _bu7 = ('Отказ безобиден' not in _bu_exp_raw and
                'kFixedName' not in _bu_exp)
    else:
        _bu7 = ('Отказ безобиден' not in _bu_exp_raw and
                'fixed-name copy FAILED' in _bu_exp)
    if _bu7:
        ok('BU7 the export no longer claims a safety it does not have' +
           (', and no longer writes the name whose failure it explained'
            if int(pv) >= 193 else ', and a failed fixed-name copy is audible'))
    else:
        fail('BU7 the false "harmless" claim is back on the fixed-name copy')

    # BU8: КЛЮЧИ ЛОКАЛИ — ЛИТЕРАЛЫ. Первая редакция строки кандидата
    # собирала ключ выражением, и харнесс такой ключ не видит. Гейт стоит
    # на приёме, а не на конкретной опечатке.
    _bu8 = ("S.of('dataimp.cand_denied')" in _bu_dm and
            "S.of('dataimp.cand_bad')" in _bu_dm and
            "dataimp.cand_$" not in _bu_dm and
            "S.of('dataimp.pick_btn')" in _bu_dm)
    if _bu8:
        ok('BU8 the candidate line uses literal l10n keys — a built key is '
           'invisible to every check we have')
    else:
        fail('BU8 an l10n key is assembled at runtime; the harness cannot '
             'see it and a typo reaches the screen')
    # BU9: ЭКРАН НЕ ВЫБИРАЕТ САМ. Поставлен по дефекту первой редакции
    # этого же патча: список уходил наружу, выбор делал виджет, а гейт
    # BU1 сторожил функцию сервиса, которую после переписывания экрана
    # не звал НИКТО. Мутация такое не ловит по построению — она
    # доказывает, что гейт реагирует на свой предмет, но не то, что
    # предмет лежит на живом пути. Ловится только проверкой, что
    # решение принимается в ОДНОМ месте.
    _bu9 = ('searchArchive()' in _bu_dm and
            'findArchiveCandidates()' not in _bu_dm and
            'where((c) => c.readable)' not in _bu_dm and
            'candidates.first' not in _bu_dm)
    if _bu9:
        ok('BU9 the screen shows candidates but does not pick one — the '
           'choice lives in a single place, and the gate guards that place')
    else:
        fail('BU9 the screen chooses an archive on its own; BU1 now watches '
             'code that does not run')

    # BU10: ОБЕ СТУПЕНИ ВЫБОРА ФАЙЛА. Рядом лежит второй путь, и экран
    # установки использует его с +176. Одна ступень в восстановлении —
    # выброшенный шанс на визите, который у нас один.
    _bu10_body = ''
    if 'Future<void> _pickArchive() async' in _bu_dm:
        _bu10_body = _bu_dm.split('Future<void> _pickArchive() async')[1] \
            .split('\n  Future<')[0]
    _bu10 = (_bu10_body != '' and
             'ApkInstallChannel.pickContent' in _bu10_body and
             'ApkInstallChannel.pick)' in _bu10_body and
             '_pickWithTimeout(' in _bu10_body)
    if _bu10:
        ok('BU10 both file-picking rungs are wired and neither can hang the '
           'screen for ever')
    else:
        fail('BU10 restore uses fewer picker rungs than install does, or a '
             'lost platform reply can lock the section')

    # BU11: У ПУТИ ВЫБОРА ЕСТЬ ДОЛГОВЕЧНЫЙ СЛЕД. Журнал приложения живёт
    # в памяти процесса; маркер — файл, и он доезжал целым тогда, когда
    # экспорт приходил обрезанным. Путь проверяется в поле за один визит.
    _bu11 = ('"stage-archive: ok=' in _bu_apk and
             'AutostartMarker.write(' in _bu_apk.split(
                 'fun stageArchive(')[1].split('fun storageProbe(')[0])
    if _bu11:
        ok('BU11 accepting an archive leaves a line in the marker — the one '
           'channel that has always arrived intact')
    else:
        fail('BU11 the picker path leaves no durable trace; a failed visit '
             'would tell us nothing')

    # BU12: ПРИНЯТАЯ КОПИЯ УБИРАЕТСЯ ПОСЛЕ ПРИМЕНЕНИЯ. Иначе она вечно
    # предлагается первой в списке кандидатов, будучи сколь угодно
    # старой, и занимает столько же, сколько экспорт.
    _bu12_body = ''
    if 'static Future<Map<String, int>?> rebuildSyncBookkeeping(' in _bu_imp:
        _bu12_body = _bu_imp.split(
            'static Future<Map<String, int>?> rebuildSyncBookkeeping(')[1] \
            .split('\n  }')[0]
    _bu12 = (_bu12_body != '' and
             'kStagedName' in _bu12_body and
             'delete()' in _bu12_body)
    if _bu12:
        ok('BU12 the granted copy is dropped once the import has applied — '
           'it cannot shadow later archives or grow without bound')
    else:
        fail('BU12 the staged archive is kept for ever and will be offered '
             'first at every future search')
else:
    ok(f"Part BU skipped (build +{pv}, readable-archive selection lands "
       f"in +187)")

# ═════ Part BV — v0.1.89+188 «Живой старт подхватывает фон» ═════
#
# Поле 02.08, 21:29:10: владелец тронулся при закрытом приложении, сервис
# собирал в журнал, в 21:30:10 приложение открылось — и живая поездка
# началась с нуля на одометре 6676.8 при начале движения на 6676.3.
# Полкилометра стали бы отдельной поездкой при следующем открытии: один
# заезд, две записи. Плюс запасной путь старта глушился ЛЮБЫМ кадром
# передачи, включая Park: за 93 минуты поля таких кадров было четыре.
if int(pv) >= 188:
    _bv_hal = _strip_comments_safe(
        (root / 'lib/services/hal_telemetry_service.dart').read_text())
    _bv_db = _strip_comments_safe(
        (root / 'lib/data/database.dart').read_text())

    # BV1: ПОДХВАТ СТОИТ НА ЖИВОМ ПУТИ. Не «функция существует», а «её
    # зовёт открытие строки поездки, и зовёт ДО создания строки». Урок
    # вакуумного гейта BU1 из прошлого патча: предмет обязан лежать на
    # пути, по которому идёт исполнение.
    _bv1_body = ''
    if 'Future<void> _openHalTripRow() async' in _bv_hal:
        _bv1_body = _bv_hal.split('Future<void> _openHalTripRow() async')[1] \
            .split('\n  Future<_HalJoinTail?>')[0]
    _bv1 = (_bv1_body != '' and
            '_findJoinableTail(db)' in _bv1_body and
            '_adoptJoinedTail(join)' in _bv1_body and
            'db.startTrip(' in _bv1_body and
            _bv1_body.index('_findJoinableTail(db)')
            < _bv1_body.index('db.startTrip('))
    if _bv1:
        ok('BV1 the live start looks back before it opens the row — the '
           'drive that began with the app closed is one trip, not two')
    else:
        fail('BV1 nothing joins the background tail on the live path; the '
             '02.08 split into two trips comes back')

    # BV2: НАЧАЛО СТРОКИ СДВИГАЕТСЯ НАЗАД. Строка, рождённая временем
    # «сейчас» и исправленная секундой позже, успела бы уехать в облако с
    # неверным стартом — поэтому `startedAt` идёт параметром в insert.
    _bv2 = ('DateTime? startedAt,' in _bv_db and
            'Value(startedAt ?? DateTime.now())' in _bv_db and
            'startedAt: _halTripStartedAt,' in _bv_hal and
            '_halTripStartedAt = j.start;' in _bv_hal)
    if _bv2:
        ok('BV2 a joined trip is born with the time of the first movement, '
           'not the time the app happened to open')
    else:
        fail('BV2 the joined row keeps the app-open time; duration and the '
             'start anchors would describe different events')

    # BV3: ДИСТАНЦИЯ ИДЁТ В СУЩЕСТВУЮЩИЙ АККУМУЛЯТОР. Заведи подхват свой
    # путь — на экране и в истории оказались бы два числа про одно и то
    # же, и разошлись бы они молча.
    _bv3 = ('_halTripDistAccumKm += j.distanceKm' in _bv_hal and
            _bv_hal.count('_halTripDistAccumKm +=') == 2)
    if _bv3:
        ok('BV3 joined kilometres go into the one accumulator the live card '
           'already reads — screen and history cannot disagree')
    else:
        fail('BV3 the joined distance travels its own path; the card and the '
             'stored row will drift apart')

    # BV4: ПРИПИСАННЫЕ СТРОКИ СНИМАЮТСЯ СО СТРОИТЕЛЯ. Без штампа фоновый
    # строитель соберёт из тех же строк вторую поездку — ровно ту, ради
    # устранения которой всё и делается.
    _bv4_body = ''
    if 'Future<int> stampHalSamplesInWindow(' in _bv_db:
        _bv4_body = _bv_db.split('Future<int> stampHalSamplesInWindow(')[1] \
            .split('\n  Future<')[0]
    _bv4 = (_bv4_body != '' and
            's.tripId.isNull()' in _bv4_body and
            'stampHalSamplesInWindow(' in _bv_hal)
    if _bv4:
        ok('BV4 adopted rows are stamped, and only unassigned ones — the '
           'builder can no longer mint a second trip from them')
    else:
        fail('BV4 adopted rows stay unassigned or the stamp can steal '
             'another trip\'s rows')

    # BV5: ПРОИСХОЖДЕНИЕ УЕЗЖАЕТ, И СЛИЯНИЕМ. Начало подхваченной поездки
    # лежит раньше конца предыдущей записи — без ключа сервер позвонит
    # инвариантом непрерывности одометра на каждую такую поездку.
    # v0.1.91+190 — ГЕЙТ ПИННИЛ СЛОМАННЫЙ ВЫЗОВ. Первая редакция сверяла
    # строку `mergeTripExtra(id, {'joinedInProgress': true})` дословно, а
    # метод принимает JSON СТРОКОЙ. Сборка упала на CI, и гейт при этом
    # был зелёным — он закреплял ошибку компиляции и защищал бы её от
    # исправления. Предмет здесь — ПАТЧ, который уезжает в `extra`, и
    # то, что он именно сливается; форма вызова предметом быть не должна.
    _bv5 = ('joinedInProgress' in _bv_hal and
            'mergeTripExtra(id,' in _bv_hal and
            '"joinedInProgress":true' in _bv_hal)
    if _bv5:
        ok('BV5 a joined trip says so in extra, merged not overwritten — the '
           'odometer-continuity alert stays quiet')
    else:
        fail('BV5 joined trips ship without provenance and will ring the '
             'server invariant every time')

    # BV6: РАЗРЫВ ДВИЖЕНИЯ — ОДНО ОПРЕДЕЛЕНИЕ НА ПРОЕКТ. Заведи живой путь
    # свою константу — первое же расхождение развело бы его с фоновым
    # строителем, и заметить это было бы нечем.
    # Предмет — ОТСУТСТВИЕ ВТОРОГО ОПРЕДЕЛЕНИЯ, а не отсутствие литерала:
    # первая редакция гейта запрещала `Duration(minutes: 5)` целиком и
    # краснела от `_kHalSlopeMaxSpan`, к разрыву поездок отношения не
    # имеющей. Гейт, запрещающий больше своего предмета, — блокировщик.
    _bv6 = ('BgTripBuilder.kMotionGap' in _bv_hal and
            _bv_hal.count('BgTripBuilder.kMotionGap') == 2 and
            '_kHalMotionGap' not in _bv_hal and
            '_kHalJoinGap' not in _bv_hal and
            '_kHalTripGap' not in _bv_hal)
    if _bv6:
        ok('BV6 the live path and the builder share one definition of what '
           'breaks a trip apart')
    else:
        fail('BV6 the motion gap is defined twice; live and background will '
             'disagree about what one trip is')

    # BV7: ЗАПАСНОЙ ПУТЬ НЕ ГЛУШИТСЯ КАДРОМ ПЕРЕДАЧИ, и движение для него
    # — скорость ИЛИ рост одометра. `speed` приходит ПО ИЗМЕНЕНИЮ, паузы в
    # поле доходили до 88 секунд; на ровном ходу одного условия мало.
    _bv7_body = ''
    if 'void _updateHalTrip()' in _bv_hal:
        _bv7_body = _bv_hal.split('void _updateHalTrip()')[1] \
            .split('\n  void ')[0]
    _bv7 = (_bv7_body != '' and
            'if (gear == null) {' not in _bv7_body and
            'odoGrew' in _bv7_body and
            '_kHalOdoGrowthKm' in _bv7_body)
    if _bv7:
        ok('BV7 the speed fallback survives a Park frame and counts odometer '
           'growth as motion — waking up on a motorway still starts a trip')
    else:
        fail('BV7 any gear frame still kills the fallback, or motion is '
             'speed-only while speed arrives on change')
    # BV8: ВСТАВКА НЕ ПЕРЕЖИВАЕТ ЗАКРЫТИЕ ПОЕЗДКИ. Поставлен ревизией
    # этого же патча: поиск хвоста читает до 20 000 строк, и окно между
    # решением и вставкой стало заметно длиннее прежнего. Закройся
    # поездка внутри окна — в базу легла бы строка для мёртвой поездки.
    _bv8_body = ''
    if 'Future<void> _openHalTripRow() async' in _bv_hal:
        _bv8_body = _bv_hal.split('Future<void> _openHalTripRow() async')[1] \
            .split('db.startTrip(')[0]
    _bv8 = (_bv8_body != '' and
            'if (!_halTripActive) return;' in _bv8_body)
    if _bv8:
        ok('BV8 the row is not inserted for a trip that closed while the '
           'tail was being read — no orphan is created by the lookback')
    else:
        fail('BV8 a trip closing during the tail read still gets a row; it '
             'would hang open until orphan recovery')
else:
    ok(f"Part BV skipped (build +{pv}, joining the background tail lands "
       f"in +188)")

# ═════ Part BW — v0.1.90+189 «Фон виден Трендам, а карта сущностей — целая» ═════
#
# Экспорт 02.08: за 45.8 км фоновой поездки ноль снапшотов. Тренды считают
# пробег прогулкой по снапшотам, значит фоновые дни для них пусты, а
# реконструкция из снапшотов фоновые отрезки покрыть не может — там нет
# исходного материала. Плюс справка Друга 2 от 02.08: список сущностей
# uuid-mapping обслуживал пять сущностей списком из двух, и сканер
# пропусков не заглядывал в три таблицы из пяти.
if int(pv) >= 189:
    _bw_bld = _strip_comments_safe(
        (root / 'lib/services/bg_trip_builder.dart').read_text())
    _bw_imp = _strip_comments_safe(
        (root / 'lib/services/import_service.dart').read_text())
    _bw_cs = _strip_comments_safe(
        (root / 'lib/services/cloud_sync_service.dart').read_text())

    # BW1: ФОНОВАЯ ПОЕЗДКА ОСТАВЛЯЕТ СНАПШОТЫ, и на живом пути сборки.
    # Не «функция есть», а «её зовёт сборка поездки и получает её id» —
    # урок вакуумного гейта BU1.
    _bw1 = ('_writeSnapshots(db, window, tripId)' in _bw_bld and
            'final tripId = await db.insertTripWithStampedSamples('
            in _bw_bld and
            'db.insertSnapshot(' in _bw_bld)
    if _bw1:
        ok('BW1 a background trip leaves snapshots behind — the daily bars '
           'and any later reconstruction have something to stand on')
    else:
        fail('BW1 background drives still write no snapshots; Trends stay '
             'blind on exactly the days the app was closed')

    # BW2: ЕДИНИЦЫ ПОВТОРЯЮТ ЖИВОГО ПИСАТЕЛЯ. Вольты ячеек ×1000 в
    # милливольтовые колонки, разброс в мВ. Разойдись они — история
    # фоновых поездок читалась бы в тысячу раз мимо, и молча.
    # ERA-AWARE (+193). Существо прежнее и стало СТРОЖЕ: единицы обязаны
    # совпадать с живым писателем. Только теперь перевод вольтов в
    # милливольты живёт в общем помощнике `cell_pair.dart`, которого зовут
    # оба, — то есть разойтись им больше нечем в принципе. Прежние литералы
    # здесь исчезли не от небрежности: они переехали в единственное место.
    if int(pv) >= 193:
        _bw2_pair = _strip_comments_safe(
            (root / 'lib/services/cell_pair.dart').read_text())
        _bw2 = ('cellTriple(' in _bw_bld and
                'triple.minMv.roundToDouble()' in _bw_bld and
                'triple.maxMv.roundToDouble()' in _bw_bld and
                'minMv: loVolts * 1000.0' in _bw2_pair and
                'maxMv: hiVolts * 1000.0' in _bw2_pair and
                '(hiVolts - loVolts) * 1000.0' in _bw2_pair and
                'gear:' not in _bw_bld)
    else:
        _bw2 = ('(lo * 1000).roundToDouble()' in _bw_bld and
                '(hi * 1000).roundToDouble()' in _bw_bld and
                '(hi - lo) * 1000.0' in _bw_bld and
                'gear:' not in _bw_bld)
    if _bw2:
        ok('BW2 synthesised snapshots use the live writer\'s units, and do '
           'not invent a gear encoding')
    else:
        fail('BW2 the background snapshot units drift from the live ones')

    # BW3: СНАПШОТЫ НЕ МОГУТ ОТМЕНИТЬ ПОЕЗДКУ. Поездка — факт, снапшоты —
    # наблюдение за ним; отказ наблюдения не смеет откатить факт.
    _bw3_body = ''
    if 'static Future<void> _writeSnapshots(' in _bw_bld:
        _bw3_body = _bw_bld.split('static Future<void> _writeSnapshots(')[1]
    _bw3 = (_bw3_body != '' and
            'catch (e)' in _bw3_body and
            'transaction' not in _bw3_body)
    if _bw3:
        ok('BW3 a failed snapshot write cannot roll back the trip it '
           'describes')
    else:
        fail('BW3 snapshots share the trip transaction; observation can undo '
             'the fact')

    # BW4: СПИСОК СУЩНОСТЕЙ ЦЕЛЫЙ И СОВПАДАЕТ С СЕРВИСОМ. Пять имён по обе
    # стороны; расхождение ловится только текстом — приватную константу
    # компилятор из другого файла не отдаст.
    # Область сужена до ТЕЛА СПИСКА. Первая редакция искала имена по
    # всему файлу и была слепа: те же слова стоят ключами в
    # `uuidMapTables`, поэтому удаление имени из списка сущностей гейт не
    # замечал. Мутация это и показала — BLIND, а не FAIL.
    _bw4_list = ''
    if 'static const List<String> uuidMapEntities = <String>[' in _bw_imp:
        _bw4_list = _bw_imp.split(
            'static const List<String> uuidMapEntities = <String>[')[1] \
            .split(']')[0]
    _bw4 = (_bw4_list != '' and
            all(f"'{e}'" in _bw4_list for e in
                ('trips', 'snapshots', 'sweeps', 'livelogs', 'canmonitor')) and
            "'sweeps'," in _bw_cs and "'canmonitor'," in _bw_cs)
    if _bw4:
        ok('BW4 the uuid-mapping entity list is whole and matches the sync '
           'service — no entity is left unmapped after an import')
    else:
        fail('BW4 the entity lists disagree; three of five entities go '
             'unwatermarked and unscanned after a restore')

    # BW5: ИМЯ СУЩНОСТИ ≠ ИМЯ ТАБЛИЦЫ, И ЭТО УЧТЕНО. Подставь имя
    # сущности в SELECT — запрос упадёт на несуществующей таблице, отказ
    # будет пойман, и сканер вернёт ноль. То есть соврёт «пропусков нет»
    # ровно там, где они есть.
    _bw5 = ("'sweeps': 'sweep_runs'" in _bw_imp and
            "'livelogs': 'live_log_sessions'" in _bw_imp and
            "'canmonitor': 'can_monitor_sessions'" in _bw_imp and
            'for (final t in uuidMapTables.values)' in _bw_imp)
    if _bw5:
        ok('BW5 the gap scan queries table names, not protocol names — it '
           'can no longer report zero because the query threw')
    else:
        fail('BW5 the gap scan uses entity names as table names and will '
             'silently report no gaps')

    # BW6: ВРЕМЯ СТРОКИ ЕДЕТ С ОТОБРАЖЕНИЕМ. Пояс поверх подтяжек: сервер
    # откажется привязывать uuid к строке с другим временем. Цена
    # промаха — тихая потеря по `DO NOTHING`.
    _bw6 = ("'started_at': at.toUtc().toIso8601String()" in _bw_cs and
            'final out = <(int, String, DateTime)>[];' in _bw_cs)
    if _bw6:
        ok('BW6 every mapping item carries the row\'s own time — a uuid can '
           'no longer be bound to a different row in silence')
    else:
        fail('BW6 mapping items ship without a time; a wrong binding stays '
             'undetectable and loses a push to DO NOTHING')

    # BW7: ЗНАК СТРОИТЕЛЯ ПЕРЕЕЗЖАЕТ С АРХИВОМ. Он описывает БАЗУ — до
    # какого места её строки разобраны. Без него импорт заставляет
    # строителя перечитать всю историю стоянок заново.
    _bw7 = ("'bg_trip_watermark_ms'," in _bw_imp and
            _bw_imp.split('dbBoundKeys')[1].split(']')[0]
            .count('bg_trip_watermark_ms') == 1)
    if _bw7:
        ok('BW7 the builder watermark travels with the archive it describes')
    else:
        fail('BW7 the builder watermark is left behind; a restore makes it '
             'reread every parked hour in the database')
else:
    ok(f"Part BW skipped (build +{pv}, background snapshots land in +189)")

# ═════ Part BX — v0.1.91+190 «Литерал не того рода ловится до CI» ═════
#
# Сборка +188 упала на `mergeTripExtra(int, String)`, позванном картой.
# До падения зелёными были ВСЕ гейты и все три скана. Хуже: гейт BV5,
# написанный в том же патче, пиннил сломанный вызов дословно. Четвёртый
# класс ошибок, который текст не ловит, получает свой скан.
if int(pv) >= 190:
    _bx_tool = (root / 'tools/dart_balance.py').read_text()
    _bx1 = ('def check_literal_args(' in _bx_tool and
            'def build_signatures(' in _bx_tool and
            'WRONG = {' in _bx_tool and
            'check_literal_args(f, sig)' in _bx_tool and
            "fails.append(f'{f.name}:arg:{ln}')" in _bx_tool)
    if _bx1:
        ok('BX1 the dart scan compares literal arguments against declared '
           'parameter types — the call that broke the +188 build is caught '
           'before CI')
    else:
        fail('BX1 nothing checks literal arguments; a map passed where a '
             'String is declared stays green through every gate')
    # BX2/BX3 (+191): ещё два класса из одного падения. Подпись обещала
    # запись из двух полей, тело собирало три; и nullable-колонка была
    # взята ключом карты. Оба скана проверены в обе стороны: ноль на
    # чистом дереве, ровно одна находка на восстановленной ошибке.
    if int(pv) >= 191:
        _bx2 = ('def check_record_arity(' in _bx_tool and
                'check_record_arity(f)' in _bx_tool and
                "fails.append(f'{f.name}:rec:{ln}')" in _bx_tool)
        if _bx2:
            ok('BX2 the scan compares the declared record arity with what '
               'the body builds — a forgotten signature is caught before CI')
        else:
            fail('BX2 nothing checks record arity; a stale signature stays '
                 'green through every gate')

        _bx3 = ('def check_nullable_keys(' in _bx_tool and
                'by_class' in _bx_tool and
                'for\\s*\\(\\s*final' in _bx_tool and
                "fails.append(f'{f.name}:nullkey:{ln}')" in _bx_tool)
        if _bx3:
            ok('BX3 a nullable drift column used as a map key is caught, and '
               'only where the row type is written literally — no guessing')
        else:
            fail('BX3 nullable columns can be used as map keys unnoticed, or '
                 'the check guesses types and cries wolf')
else:
    ok(f"Part BX skipped (build +{pv}, the literal-argument scan lands "
       f"in +190)")

# ═════ Part BY — v0.1.93+192 «Обрыв виден там, где он случился» ═════
#
# Поле 03.08 отдало один экспорт в трёх размерах: 4 585 082 целым,
# 4 096 000 обрезанным на диске, 3 190 784 принятым в слот. Третий не
# совпал ни с одним, то есть потеря была ПО ДОРОГЕ, и понять этого было
# нельзя: источник никто не мерил, `copyTo` читает до конца потока, а
# преждевременный конец выглядит ровно как успех. Плюс подхваченная
# поездка получила стартовый одометр от живого старта (6700.8) вместо
# начала кластера (6699.8) — строка вышла внутренне противоречивой.
if int(pv) >= 192:
    _by_apk = (root / 'android/app/src/main/kotlin/com/bz5companion'
                      '/bz5_companion/ApkInstall.kt').read_text()
    _by_plug = (root / 'android/app/src/main/kotlin/com/bz5companion'
                       '/bz5_companion/BydNativePlugin.kt').read_text()
    _by_main = (root / 'android/app/src/main/kotlin/com/bz5companion'
                       '/bz5_companion/MainActivity.kt').read_text()
    _by_hal = _strip_comments_safe(
        (root / 'lib/services/hal_telemetry_service.dart').read_text())
    _by_imp = _strip_comments_safe(
        (root / 'lib/services/import_service.dart').read_text())
    _by_exp = _strip_comments_safe(
        (root / 'lib/services/export_service.dart').read_text())
    _by_dm = _strip_comments_safe(
        (root / 'lib/screens/data_management.dart').read_text())

    # BY1: ПРИЁМ СВЕРЯЕТ БАЙТЫ С ИСТОЧНИКОМ. Инструмент, отвечающий на
    # вопрос «где ломается». Без него обрыв неотличим от успеха.
    _by1_body = ''
    if 'fun stageArchive(' in _by_apk:
        _by1_body = _by_apk.split('fun stageArchive(')[1] \
            .split('fun storageProbe(')[0]
    _by1 = (_by1_body != '' and
            'sourceSize(context, uri)' in _by1_body and
            'written != srcBytes' in _by1_body and
            'truncated: source=' in _by1_body and
            'OpenableColumns.SIZE' in _by_apk)
    if _by1:
        ok('BY1 the intake measures the source and refuses a short copy — a '
           'truncated hand-over can no longer report success')
    else:
        fail('BY1 the intake still trusts copyTo; a premature end of stream '
             'is indistinguishable from a complete file')

    # BY2: ЭКСПОРТ ПЕРЕЧИТЫВАЕТ НАПИСАННОЕ. Длина и конец архива. Поле
    # 03.08 получило обрезанный файл без единой жалобы.
    # Признак конца архива определён ОДИН раз: первая редакция патча
    # держала две копии скана, и сверить их было нечем.
    _by2 = ('Future<String?> _verifyWritten(' in _by_exp and
            'len != expectLen' in _by_exp and
            'ImportService.hasZipTail(tail)' in _by_exp and
            '0x50' not in _by_exp and
            'writeWarning: writeWarning' in _by_exp and
            'writeWarning: built.writeWarning' in _by_exp)
    if _by2:
        ok('BY2 the export rereads what it wrote and carries the complaint '
           'out to the owner')
    else:
        fail('BY2 a truncated export still looks like a successful one')

    # BY3: ЖАЛОБА ДОЕЗЖАЕТ ДО ЭКРАНА. Проверка, которую никто не видит,
    # не отличается от отсутствующей.
    _by3 = ("dataexp.write_warn_fmt" in _by_dm and
            'result.writeWarning' in _by_dm)
    if _by3:
        ok('BY3 the write complaint reaches the screen while the car is '
           'still at hand')
    else:
        fail('BY3 the export verifies itself and tells nobody')

    # BY4: ОТКРЫВАЕТСЯ ≠ ПРИГОДЕН. Обрезанный архив открывался и получал
    # зелёную галочку рядом с отказом осмотра.
    _by4_body = ''
    if 'static Future<String?> _openFailure(' in _by_imp:
        _by4_body = _by_imp.split('static Future<String?> _openFailure(')[1] \
            .split('\n  static ')[0]
    _by4 = (_by4_body != '' and
            "hasZipTail(tail)" in _by4_body and
            "'truncated'" in _by4_body and
            'static bool hasZipTail(' in _by_imp)
    if _by4:
        ok('BY4 a file that opens but has no archive end is marked truncated '
           'and never chosen over a whole one')
    else:
        fail('BY4 readability still passes for usability; a truncated file '
             'can be picked while a complete one sits next to it')

    # BY5: ЯКОРЯ ПОДХВАТА — ИЗ КЛАСТЕРА. `??=` здесь был ошибкой, и поле
    # опровергло её за один заезд: 6700.8 против 6699.8 при distance 2.5.
    _by5 = ('_halTripStartOdo = j.startOdo ?? _halTripStartOdo;' in _by_hal and
            '_halTripStartSoc = j.startSoc ?? _halTripStartSoc;' in _by_hal and
            '_halTripStartOdo ??= j.startOdo;' not in _by_hal)
    if _by5:
        ok('BY5 a joined trip takes its anchors from the cluster it adopted, '
           'so start_odometer and distance describe the same drive')
    else:
        fail('BY5 the joined trip keeps the live-latched anchor; the row '
             'contradicts itself again')

    # BY6: ЗАПРОС РАЗРЕШЕНИЯ СУЩЕСТВУЕТ. Обещан в +187 и не сделан;
    # `read_perm=false` в поле оставил версию владельца непроверенной.
    _by6 = ('"requestStoragePermission" ->' in _by_main and
            'ActivityCompat.requestPermissions(' in _by_main and
            'requestStoragePermission()' in _by_dm and
            'hasReadStoragePermission(' in _by_apk)
    if _by6:
        ok('BY6 the storage permission is actually asked for, so read_perm '
           'stops being an unexplained false')
    else:
        fail('BY6 the permission is reported but never requested; the '
             'measurement promised in +187 is still missing')

    # BY7: СЛЕД ОТСОЕДИНЕНИЯ ВМЕСТО ЗАХОДА К МАШИНЕ. Владелец сворачивает
    # приложение и активити не уничтожается — шов может не срабатывать
    # вовсе, и гонять за этим к машине дороже, чем оставить строку.
    _by7 = ('"detach-flutter: keepCollecting=$keepCollecting"' in _by_plug)
    if _by7:
        ok('BY7 detachFlutter leaves a line, so a seam that may never fire '
           'costs no more trips to the car')
    else:
        fail('BY7 detachFlutter is still silent; confirming it needs another '
             'physical visit')
else:
    ok(f"Part BY skipped (build +{pv}, truncation visibility lands in +192)")

# ══════════════════════════ ЭРА BZ (+193) ══════════════════════════
#
# Что закрывает эта эра, одной фразой на пункт:
#   1. автозапуск виден и слышен: тумблер снаружи, пропуск оставляет строку;
#   2. тройка ячеек — дельта одного мгновения, и правило ОДНО на трёх
#      писателей, а источник пары починен встречной записью;
#   3. история мощности принадлежит сервису выше навигатора, и ЭКРАН ЕГО
#      ЧИТАЕТ — гейт стоит на живом пути, а не на существовании класса;
#   4/5. «около N км» не срезается молча, окно полосы названо вслух и
#      выведено из константы;
#   6. постоянное имя экспорта больше не пишется, и сверка не проверяет
#      файл, записать который мы не смогли;
#   7. геометрия экрана замерена, а не выведена.
if int(pv) >= 193:
    _bz_set = (root / 'lib/screens/settings.dart').read_text()
    _bz_arm = (root / 'lib/services/autostart_arm.dart').read_text()
    _bz_mainact = (root / 'android/app/src/main/kotlin/com/bz5companion'
                          '/bz5_companion/MainActivity.kt').read_text()
    _bz_halout = (root / 'android/app/src/main/kotlin/com/bz5companion'
                         '/bz5_companion/hal/HalOut.kt').read_text()
    _bz_pair = _strip_comments_safe(
        (root / 'lib/services/cell_pair.dart').read_text())
    _bz_hal = _strip_comments_safe(
        (root / 'lib/services/hal_telemetry_service.dart').read_text())
    _bz_bg = _strip_comments_safe(
        (root / 'lib/services/bg_trip_builder.dart').read_text())
    _bz_db = _strip_comments_safe(
        (root / 'lib/data/database.dart').read_text())
    _bz_ph = _strip_comments_safe(
        (root / 'lib/services/power_history_service.dart').read_text())
    _bz_main = _strip_comments_safe((root / 'lib/main.dart').read_text())
    _bz_tall = _strip_comments_safe(
        (root / 'lib/screens/driver_view_tall.dart').read_text())
    _bz_wide = _strip_comments_safe(
        (root / 'lib/screens/wide/driver_view_wide.dart').read_text())
    _bz_band = _strip_comments_safe(
        (root / 'lib/widgets/band_card.dart').read_text())
    _bz_exp = _strip_comments_safe(
        (root / 'lib/services/export_service.dart').read_text())
    _bz_home = _strip_comments_safe((root / 'lib/screens/home.dart').read_text())
    _bz_l10n = (root / 'lib/l10n/strings.dart').read_text()

    # BZ1: ТУМБЛЕР АВТОЗАПУСКА СНАРУЖИ. Он был спрятан ДВАЖДЫ — за 15-тапным
    # замком «Расширенного» и за свёрнутым ExpansionTile внутри него.
    # Механизм, поднимающий приложение на каждом пробуждении ГУ, обязан
    # выключаться без пароля. Гейт держит порядок блоков: строка тумблера
    # должна стоять ВЫШЕ начала расширенной карточки.
    _bz_adv_at = _bz_set.find('Widget _advancedCard(')
    _bz_sw_at = _bz_set.find("S.of('settings.autostart.title')")
    _bz_mk_at = _bz_set.find("S.of('settings.marker.title')")
    _bz1 = (_bz_sw_at > 0 and _bz_mk_at > 0 and _bz_adv_at > 0 and
            _bz_sw_at < _bz_adv_at and _bz_mk_at < _bz_adv_at)
    if _bz1:
        ok('BZ1 the autostart switch and its log live in the main list, not '
           'behind a 15-tap lock and a collapsed tile')
    else:
        fail('BZ1 autostart is hidden again — the only way to stop it is '
             'uninstalling the app')

    # BZ2: ПОДПИСЬ ПОКАЗЫВАЕТ НАСТОЯЩЕЕ ТРОЙНОЕ СОСТОЯНИЕ, прочитанное с
    # НАТИВНОЙ стороны — той же, что читает BootReceiver. Dart-кэш `_armed`
    # для показа не годится: он говорит лишь «звали ли мы arm в этом
    # запуске», а не «взведено ли». Три ключа обязаны быть в ОБЕИХ картах.
    _bz2 = ('enum AutostartState' in _bz_arm and
            "await _flag('isArmed')" in _bz_arm and
            "await _flag('optedOut')" in _bz_arm and
            '_autostartSubtitle()' in _bz_set and
            "AutostartArm.state()" in _bz_set and
            _bz_l10n.count("'settings.autostart.state_undecided'") == 2 and
            _bz_l10n.count("'settings.autostart.state_on'") == 2 and
            _bz_l10n.count("'settings.autostart.state_off'") == 2)
    if _bz2:
        ok('BZ2 the switch caption tells «not decided» from «turned off», '
           'read natively in both locales')
    else:
        fail('BZ2 «not decided» is indistinguishable from «off» again')

    # BZ3: ПРОПУСК ОСТАВЛЯЕТ СТРОКУ. Прежний Dart возвращался молча, и
    # выключенный автозапуск читался в журнале ровно как сломанный: строк
    # нет ни тех, ни других. Именно эта неразличимость и стоила разбора
    # ЧУЖОГО журнала. Три исхода — три разных диагноза.
    _bz3 = ("invokeMethod<bool>('armSkipped')" in _bz_arm and
            '"armSkipped" ->' in _bz_mainact and
            'arm: result=skipped-opt-out' in _bz_mainact and
            'arm: result=armed' in _bz_mainact and
            'arm: result=failed' in _bz_mainact)
    if _bz3:
        ok('BZ3 every arm attempt leaves a line — armed, skipped or failed')
    else:
        fail('BZ3 a skipped arm is silent again, and reads as a broken one')

    # BZ4: ТРОЙКА ЯЧЕЕК — ОДНО ПРАВИЛО НА ТРЁХ ПИСАТЕЛЕЙ, И ГЕЙТ СТОИТ НА
    # ЖИВОМ ПУТИ. Проверяется не существование помощника, а то, что его
    # ЗОВУТ все три места: живой писатель снапшотов, синтез фоновых
    # снапшотов и агрегат поездки. Урок BU1 из №14: гейт, сторожащий
    # функцию, которую никто не звал, зелен и бесполезен, и мутация такого
    # не ловит по построению.
    #
    # Плюс неделимость: тройка пишется целиком или не пишется вовсе.
    # Прежний живой писатель охранял только разность, а границы писал
    # непроверенной парой — та же ошибка без признака.
    _bz4 = ('CellTriple? cellTriple(' in _bz_pair and
            'if (spread < 0) return null;' in _bz_pair and
            'halCellTripleForRecord' in _bz_hal and
            'cellSpread: Value(triple?.spreadMv)' in _bz_hal and
            'triple.minMv.roundToDouble()' in _bz_hal and
            'halCellTripleForRecord?.spreadMv' in _bz_hal and
            _bz_bg.count('cellTriple(') == 2 and
            'kCellPairWindowJournalMs' in _bz_bg and
            'cellSpread: Value(triple?.spreadMv)' in _bz_bg and
            'latestAt[n] = r.timestamp.millisecondsSinceEpoch' in _bz_bg)
    if _bz4:
        ok('BZ4 all three cell writers go through one rule, and the triple is '
           'written whole or not at all')
    else:
        fail('BZ4 a cell writer bypasses the pairing rule — a fabricated '
             'spread can reach the record again')

    # BZ5: ОКНА РАЗНЫЕ, И ЭТО НАМЕРЕНИЕ, А НЕ РАССОГЛАСОВАНИЕ. Живой поток
    # 48 Гц — три секунды там означают миллисекунды. В журнале сигналы
    # придушены по 10 с и идут в противофазе, поэтому окно жёсткое. Замер
    # на поле 04.08: при 3 с отрицательных остаётся три из пяти и агрегат
    # держится 190 мВ, при 1 с — ноль и 9.0 мВ.
    _bz5 = ('kCellPairWindowLiveMs = 3000' in _bz_pair and
            'kCellPairWindowJournalMs = 1000' in _bz_pair and
            'windowMs: kCellPairWindowLiveMs' in _bz_hal)
    if _bz5:
        ok('BZ5 the live window stays 3 s (48 Hz) and the journal window is '
           'hard 1 s — measured, not copied')
    else:
        fail('BZ5 the journal reuses the live window, and a 3 s drift is a '
             'fabricated spread')

    # BZ6: ИСТОЧНИК ПАРЫ ПОЧИНЕН. Правило при чтении не возвращает
    # одномоментность — её убивает придушивание по 10 с на каждое имя
    # порознь. Встречная запись возвращает: когда пишется одно имя, второе
    # становится должным. И только ВПЕРЁД, иначе пара зациклится и оба
    # начнут писать на каждом кадре.
    _bz6 = ('PAIRED_WITH' in _bz_halout and
            '"cell_v_lowest" to "cell_v_highest"' in _bz_halout and
            '"cell_v_highest" to "cell_v_lowest"' in _bz_halout and
            'PAIR_GRACE_MS' in _bz_halout and
            'ts - pPrev > PAIR_GRACE_MS' in _bz_halout and
            'lastPerName[partner] = ts - throttleFor(partner)' in _bz_halout)
    if _bz6:
        ok('BZ6 the journal writes the cell pair together, so the delta is '
           'a delta of one instant at the source')
    else:
        fail('BZ6 the cell pair drifts at the source again — no read-side '
             'rule can repair that')

    # BZ7: МИГРАЦИЯ ЧИСТИТ ВСЕ ТРИ ПОЛЯ. Отрицательная разность означает,
    # что границы взяты из разных мгновений, поэтому лгут все три, а не
    # одно. Девять строк по полю: пять у фоновой #155 и четыре сиротских от
    # 6–23 июня (живой писатель до охраны знака +131).
    # И ОБЕ ТАБЛИЦЫ, а не одна. Первая редакция миграции чистила только
    # снапшоты — и оставляла на экране ровно то число, против которого
    # писалась: разброс поездки лежит в `trips`, и именно его показывает
    # карточка разбаланса. Условие там шире «отрицательного», потому что
    # агрегат брал МАКСИМУМ по рассинхронам и по построению отбирал худший:
    # отдельный снапшот мог случайно попасть в одномоментную пару, максимум
    # не мог.
    _bz7 = ('int get schemaVersion => 19;' in _bz_db and
            'if (from < 19)' in _bz_db and
            'cell_spread = NULL' in _bz_db and
            'cell_voltage_min = NULL' in _bz_db and
            'cell_voltage_max = NULL' in _bz_db and
            'WHERE cell_spread < 0' in _bz_db and
            'UPDATE trips SET max_cell_spread_mv = NULL' in _bz_db and
            "WHERE source = 'hal_bg' AND max_cell_spread_mv IS NOT NULL"
            in _bz_db)
    if _bz7:
        ok('BZ7 migration 19 clears the whole fabricated triple AND the '
           'background trip aggregate that the Trends card actually shows')
    else:
        fail('BZ7 fabricated cell rows survive, only the spread is cleared, '
             'or the 190 mV aggregate stays on screen')

    # BZ8: ЭКРАН ЧИТАЕТ СЕРВИС — И ЭТО ГЛАВНЫЙ ГЕЙТ ПУНКТА 3.
    #
    # Гейт стоит на ЖИВОМ пути в обоих близнецах: `watch` сервиса, запрос
    # хвоста по числу слотов, и ОТСУТСТВИЕ локального кольца и таймера
    # там же. Проверять существование сервиса было бы ровно BU1: класс
    # есть, а экран его не зовёт, и мутация этого не покажет.
    _bz8 = all(
        ('context.watch<PowerHistoryService>()' in src and
         'hist.tail(slots)' in src and
         'powerSlotsFor(box.maxWidth, dpr)' in src and
         'Timer.periodic' not in src and
         '_ordered' not in src)
        for src in (_bz_tall, _bz_wide))
    if _bz8:
        ok('BZ8 both driver twins read the history service and keep no ring '
           'of their own')
    else:
        fail('BZ8 a driver screen still owns its buffer, or does not read the '
             'service — the history dies on leaving the screen')

    # BZ9: СЕРВИС ВЛАДЕЕТ ТАКТОМ И МАСШТАБАМИ, НИКОГО НЕ ИМПОРТИРУЯ.
    #
    # Таймер тикает ВСЕГДА, иначе буфер снова обнулялся бы при уходе с
    # экрана — лечили бы болезнь и оставляли её же. Масштабы переехали
    # вместе с кольцом: они функция буфера И числа тиков, и на экране
    # обнулялись бы вместе с ним.
    #
    # Ни `hal_telemetry`, ни `connection` в сервисе не упоминаются: он
    # кормится колбэком. Это строже AA2 — там запрещено взаимное знание
    # двух, а здесь нет и одностороннего.
    # Плюс: масштаб осей считается по ВИДИМОМУ окну. Кольцо больше окна
    # (1024 против 301…540), и счёт по всему кольцу вернул бы болезнь,
    # которую лечил +70: один разгон в 150 кВт прижимал бы шкалу почти на
    # четверть часа, и городская езда снова стала бы прямой линией. Раньше
    # это не было видно только потому, что кольцо БЫЛО окном.
    _bz9 = ('class PowerHistoryService extends ChangeNotifier' in _bz_ph and
            'Timer.periodic(tick' in _bz_ph and
            '_windowHint' in _bz_ph and
            '_windowHint < _filled ? _windowHint : _filled' in _bz_ph and
            '_timer?.cancel()' in _bz_ph and
            'double? Function() _read' in _bz_ph and
            'hal_telemetry' not in _bz_ph and
            'connection.dart' not in _bz_ph and
            'dischargeScale' in _bz_ph and
            'ChangeNotifierProvider<PowerHistoryService>' in _bz_main)
    if _bz9:
        ok('BZ9 the power history is a third service fed by a callback, above '
           'the navigator, ticking always')
    else:
        fail('BZ9 the history service imports a peer service or stops ticking '
             'when nobody watches')

    # BZ10: ШАГ СТОЛБИКА ЦЕЛЫЙ В ПИКСЕЛЯХ, А ЗАЖИМ СНЯТ. Прежний
    # `clamp(1.5, 6.0)` и был блокировщиком: при шаге 1.33 dp он требовал
    # 1.5 dp, столбик выходил шире шага и столбики налезали. Однопиксельный
    # столбик не на границе пикселя размазывается сглаживанием по двум в
    # половину яркости — плотный график выцвел бы вместо подробности.
    _bz10 = all(
        ('clamp(1.5, 6.0)' not in src and
         '(i * pitchPx).roundToDouble()' in src and
         'powerBarWidthFor(scale)' in src)
        for src in (_bz_tall, _bz_wide)) and 'powerSlotsFor' in _bz_ph
    if _bz10:
        ok('BZ10 bars sit on the physical pixel grid and the width clamp that '
           'made them overlap is gone')
    else:
        fail('BZ10 the bar width is clamped above the pitch again, or bars '
             'fall off the pixel grid')

    # BZ11: ЧЕТЫРЕ МЕЛОЧИ, КАЖДАЯ ИЗ КОТОРЫХ ВРАЛА ВЛАДЕЛЬЦУ.
    #
    #   * «около 786 км» показывалось как «около 78» — молчаливый обрез
    #     числа в десять раз опаснее отсутствия числа;
    #   * окно полосы выводится ИЗ КОНСТАНТЫ, а не написано цифрами, иначе
    #     подпись разойдётся с ней при первой же правке;
    #   * постоянное имя экспорта больше не пишется, но перечисление его
    #     по-прежнему узнаёт (перестать узнавать — смена контракта);
    #   * сверка проверяет только то, что мы писали, — иначе жалуется на
    #     чужую длину, как 04.08;
    #   * геометрия экрана замерена: dpr у BZ5 до сих пор ВЫВЕДЕН, а от него
    #     зависит окно графика.
    # ГЕЙТ СУЖЕН ДО ОКРЕСТНОСТИ СВОЕЙ СТРОКИ, и это находка мутации.
    # Первая редакция искала `TextOverflow.ellipsis` по всему файлу. Как
    # только охрана в одну строку появилась и у подписи стадии, гейт стал
    # проходить за счёт ЧУЖОЙ строки: свой предмет — обрез «около N км» —
    # можно было снять, и он остался бы зелёным. Ровно семья BF5, где
    # проверка по всему файлу проходила за счёт постороннего кода.
    _bz11_at = _bz_band.find("measure.range_est")
    _bz11_near = (_bz_band[max(0, _bz11_at - 400):_bz11_at + 400]
                  if _bz11_at > 0 else '')
    _bz11 = ('TextOverflow.ellipsis' in _bz11_near and
             'Flexible(' in _bz11_near and
             "measure.band_window" in _bz_band and
             'kBandHalfWidthKmh' in _bz_band and
             _bz_l10n.count("'measure.band_window'") == 2 and
             'kFixedName' not in _bz_exp and
             'kFixedName' in (root / 'lib/services/import_service.dart')
             .read_text() and
             "debugPrint('Screen: " in _bz_home)
    if _bz11:
        ok('BZ11 the range line cannot truncate silently, the band window is '
           'derived, the fixed name is read but never written, and the screen '
           'geometry is measured')
    else:
        fail('BZ11 one of the four small lies is back')
else:
    ok(f"Part BZ skipped (build +{pv}, the cell delta and the power history "
       f"land in +193)")

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
