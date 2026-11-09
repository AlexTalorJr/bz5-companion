#!/usr/bin/env python3
"""Python mirror of the +222 trip energy split (lib/services/energy_split.dart).

Model by Friend 3 (05.11.2026, trip 399), agreed with Friend 1. Coefficients
are the per-second fit (the first 1.096 / 0.661 were fitted by window sign and
do not apply to a per-second split; reconciled 05.11):
  P_pack = V * I            V = pack_voltage_fine, else pack_voltage; I discharge-positive
  P_mech = torque * rpm * 2*pi/60
  motion = K_T * P_mech+ + K_R * P_mech-        (net: traction minus regen recovered)
  integrated per second with hold-last from each signal's first sample
  (summing per-second steps equals summing 60-s windows; windows only
  define the coverage grain);
  residual = E_pack - E_motion   (trip level, never clipped per window)
  other    = BASE_KW * covered time
  climate  = residual - other; if < 0 -> climate = 0, other = residual.
  Shown only if trip >= 3 min (10 min before +229), coverage >= 0.8 and E_pack > 0.

Model v2 (+230, Friend 3 letter 09.11), used when the trip has inverter_current:
  E_bat = integral V * I_bat, E_inv = integral V * I_inv, each with hold-last,
  subtracted only at the end (per-frame difference is noise down to -8.6 kW);
  motion = E_inv, climate_and_board = E_bat - E_inv, other = 0;
  climate < 0 -> climate = 0, motion = E_bat; motion < 0 -> motion = 0,
  climate = E_bat. Same threshold and coverage as v1.

Usage:
  python3 tools/mirror_plus222_split.py               self-tests (CI-safe)
  python3 tools/mirror_plus222_split.py EXPORT_DIR    every trip in an export
"""
import csv, math, sys
from datetime import datetime

K_T, K_R, BASE_KW = 1.030, 0.835, 0.65
MIN_TRIP_S, MIN_COVERAGE = 180, 0.8  # +229: 600 -> 180
NAMES = ('pack_voltage_fine', 'pack_voltage', 'pack_current', 'motor_torque', 'motor_rpm',
         'inverter_current')


def split(events, start_s, end_s):
    """events: sorted (t_seconds, name, value). Returns dict."""
    last = {}
    i = 0
    covered = 0
    e_pack = e_motion = 0.0
    s = math.ceil(start_s)
    while s < end_s:
        while i < len(events) and events[i][0] <= s:
            last[events[i][1]] = events[i][2]
            i += 1
        v = last.get('pack_voltage_fine', last.get('pack_voltage'))
        cur, tq, n = last.get('pack_current'), last.get('motor_torque'), last.get('motor_rpm')
        if None not in (v, cur, tq, n):
            covered += 1
            p_pack = v * cur / 1000.0
            p_mech = tq * n * 2 * math.pi / 60 / 1000.0
            motion = K_T * max(p_mech, 0.0) + K_R * min(p_mech, 0.0)
            e_pack += p_pack / 3600.0
            e_motion += motion / 3600.0
        s += 1
    dur = end_s - start_s
    cov = covered / dur if dur > 0 else 0.0
    out = dict(pack=e_pack, coverage=cov, covered_s=covered, motion=None, climate=None, other=None)
    if dur < MIN_TRIP_S or cov < MIN_COVERAGE or e_pack <= 0:
        return out
    residual = e_pack - e_motion
    other = BASE_KW * covered / 3600.0
    climate = residual - other
    if climate < 0:
        climate, other = 0.0, residual
    out.update(motion=e_motion, climate=climate, other=other)
    return out


def split_v2(events, start_s, end_s):
    """Model v2 (+230). events: sorted (t_seconds, name, value)."""
    last = {}
    i = 0
    covered = 0
    e_pack = e_inv = 0.0
    s = math.ceil(start_s)
    while s < end_s:
        while i < len(events) and events[i][0] <= s:
            last[events[i][1]] = events[i][2]
            i += 1
        v = last.get('pack_voltage_fine', last.get('pack_voltage'))
        ib, ii = last.get('pack_current'), last.get('inverter_current')
        if None not in (v, ib, ii):
            covered += 1
            e_pack += v * ib / 1000.0 / 3600.0
            e_inv += v * ii / 1000.0 / 3600.0
        s += 1
    dur = end_s - start_s
    cov = covered / dur if dur > 0 else 0.0
    out = dict(pack=e_pack, inv=e_inv, coverage=cov, covered_s=covered,
               motion=None, climate=None, other=None, model='v2')
    if dur < MIN_TRIP_S or cov < MIN_COVERAGE or e_pack <= 0:
        return out
    motion, climate = e_inv, e_pack - e_inv
    if climate < 0:
        climate, motion = 0.0, e_pack
    elif motion < 0:
        motion, climate = 0.0, e_pack
    out.update(motion=motion, climate=climate, other=0.0)
    return out


def split_auto(events, start_s, end_s):
    """Model choice, same rule as computeEnergySplitAuto in Dart."""
    if any(e[1] == 'inverter_current' for e in events):
        return split_v2(events, start_s, end_s)
    r = split(events, start_s, end_s)
    r['model'] = 'v1'
    return r


def scaled(r, energy_used):
    """Parts as stored: share of the battery integral times energy_used_kwh."""
    if r['motion'] is None:
        return None
    k = (energy_used / r['pack']) if energy_used is not None else 1.0
    return tuple(x * k for x in (r['motion'], r['climate'], r['other']))


def _selftest():
    fails = 0
    def check(name, cond):
        nonlocal fails
        print(('  [PASS] ' if cond else '  [FAIL] ') + name)
        fails += 0 if cond else 1
    # 1. Parked 20 min, 0.65 kW load exactly the base -> climate 0, other = pack.
    ev = [(0, 'pack_voltage_fine', 400.0), (0, 'pack_current', 1.625),
          (0, 'motor_torque', 0.0), (0, 'motor_rpm', 0.0)]
    r = split(ev, 0, 1200)
    check('base load only: no climate', r['climate'] == 0.0 and abs(r['other'] - r['pack']) < 1e-9)
    # 2. Parked with A/C: 1.45 kW -> climate = 0.8 kW * time.
    ev2 = [(0, 'pack_voltage_fine', 400.0), (0, 'pack_current', 3.625),
           (0, 'motor_torque', 0.0), (0, 'motor_rpm', 0.0)]
    r = split(ev2, 0, 1200)
    check('A/C on: climate = 0.8 kW', abs(r['climate'] - 0.8 * 1200 / 3600) < 1e-9)
    # 3. Parts always sum to the pack integral.
    ev3 = ev2 + [(300, 'motor_torque', 100.0), (300, 'motor_rpm', 3000.0),
                 (300, 'pack_current', 90.0), (900, 'motor_torque', -50.0),
                 (900, 'pack_current', -20.0)]
    ev3.sort()
    r = split(ev3, 0, 1200)
    check('parts sum to pack', abs(r['motion'] + r['climate'] + r['other'] - r['pack']) < 1e-9)
    # 4. Hold-last: one sample at t=0 covers a 20-min park (Friend 3 rule).
    check('hold-last covers a sparse park', r['coverage'] == 1.0)
    # 5. Nothing before every signal's first sample counts.
    ev5 = [(0, 'pack_voltage', 400.0), (0, 'pack_current', 2.0),
           (0, 'motor_rpm', 0.0), (400, 'motor_torque', 0.0)]
    r = split(ev5, 0, 1200)
    check('coverage starts at the last first sample', r['covered_s'] == 800 and r['motion'] is None)
    # 6. Short trip: no split below the threshold, split at it (+229: 3 min).
    check('trip under 3 min: no split', split(ev, 0, 179)['motion'] is None)
    check('trip of 3 min: split', split(ev, 0, 180)['motion'] is not None)
    # 7. Scaling to energy_used_kwh keeps the shares and sums to it.
    r = split(ev3, 0, 1200)
    m, c, o = scaled(r, 2.0)
    check('scaled parts sum to energy_used', abs(m + c + o - 2.0) < 1e-9)
    # 8. v2: parked with A/C, inverter 0 in P -> everything is climate+board.
    evp = [(0, 'pack_voltage_fine', 400.0), (0, 'pack_current', 3.0),
           (0, 'inverter_current', 0.0)]
    r = split_v2(evp, 0, 600)
    check('v2 parked: motion 0, climate = pack',
          r['motion'] == 0.0 and abs(r['climate'] - r['pack']) < 1e-12 and r['other'] == 0.0)
    # 9. v2 driving: I_bat 20 A, I_inv 15 A at 400 V for 1 h -> 8 / 6 / 2 kWh.
    evd = [(0, 'pack_voltage_fine', 400.0), (0, 'pack_current', 20.0),
           (0, 'inverter_current', 15.0)]
    r = split_v2(evd, 0, 3600)
    check('v2 driving: motion = E_inv, climate = E_bat - E_inv',
          abs(r['pack'] - 8.0) < 1e-9 and abs(r['motion'] - 6.0) < 1e-9
          and abs(r['climate'] - 2.0) < 1e-9)
    # 10. v2 integrates each current separately with hold (no per-frame
    # difference): a lagging inverter sample does not create negative climate.
    evl = [(0, 'pack_voltage_fine', 400.0), (0, 'pack_current', 10.0),
           (0, 'inverter_current', 0.0), (100, 'pack_current', 60.0),
           (103, 'inverter_current', 55.0), (400, 'pack_current', 10.0),
           (403, 'inverter_current', 0.0)]
    r = split_v2(evl, 0, 900)
    check('v2 parts sum to pack', abs(r['motion'] + r['climate'] - r['pack']) < 1e-12)
    # 11. v2 clamp: inverter integral above the battery's -> climate 0.
    evc = [(0, 'pack_voltage_fine', 400.0), (0, 'pack_current', 10.0),
           (0, 'inverter_current', 12.0)]
    r = split_v2(evc, 0, 600)
    check('v2 clamp: climate 0, motion = pack', r['climate'] == 0.0 and r['motion'] == r['pack'])
    # 12. v2 clamp: regen-dominated -> motion 0, climate = pack.
    evr = [(0, 'pack_voltage_fine', 400.0), (0, 'pack_current', 1.0),
           (0, 'inverter_current', -5.0)]
    r = split_v2(evr, 0, 600)
    check('v2 clamp: motion 0, climate = pack', r['motion'] == 0.0 and r['climate'] == r['pack'])
    # 13. Model choice: inverter_current present -> v2, absent -> v1.
    check('auto picks v2 with inverter current', split_auto(evd, 0, 3600)['model'] == 'v2')
    check('auto keeps v1 without it', split_auto(ev, 0, 1200)['model'] == 'v1')
    # 14. v2 needs all three signals: no inverter sample before t=400.
    ev14 = [(0, 'pack_voltage', 400.0), (0, 'pack_current', 2.0),
            (400, 'inverter_current', 0.0)]
    check('v2 coverage starts at the inverter first sample',
          split_v2(ev14, 0, 1200)['covered_s'] == 800)
    print(f'mirror +222: {"PASS" if fails == 0 else "FAIL"} ({fails} failed)')
    return fails


def _ts(s):
    return datetime.fromisoformat(s.replace('Z', '')).timestamp()


def _export(d):
    trips = list(csv.DictReader(open(f'{d}/trips.csv')))
    by = [(_ts(r['timestamp']), r['name'], float(r['numeric']))
          for r in csv.DictReader(open(f'{d}/hal_samples.csv'))
          if r['name'] in NAMES and r['numeric'] not in ('', None)]
    by.sort()
    first = by[0][0] if by else None
    for t in trips:
        if not t.get('ended_at'):
            continue
        a, b = _ts(t['started_at']), _ts(t['ended_at'])
        if first is None or b < first:
            continue
        ev = [e for e in by if a <= e[0] <= b]
        if not ev:
            continue
        r = split_auto(ev, a, b)
        eu = float(t['energy_used_kwh']) if t.get('energy_used_kwh') else None
        sc = scaled(r, eu)
        print(f"trip {t['id']} {r['model']}: {(b-a)/60:.1f} min pack={r['pack']:.3f} kWh "
              f"used={eu} coverage={r['coverage']:.2f} "
              + ('no split' if sc is None else
                 'move=%.3f climate=%.3f other=%.3f' % sc))


if __name__ == '__main__':
    if len(sys.argv) > 1:
        _export(sys.argv[1])
    else:
        sys.exit(1 if _selftest() else 0)
