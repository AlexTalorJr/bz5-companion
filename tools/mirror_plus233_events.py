#!/usr/bin/env python3
"""Python mirror of the +233 event-based trip energy (lib/services/energy_split_service.dart:
EventEnergyAccumulator, EventEnergySums, computeEnergySplitEvents).

Why: model v2 integrated over hal_samples (each signal stored every 3-4 s) is not
physical (export 10.11 17:55-18:56: climate 45 %, inverter regen above shaft regen,
board minutes -2.15..+8.19 kW; Friend 3). The live HAL stream carries every event, so
the sums are kept per event in HalTelemetryService and stored in trips.extra.

Rule (agreed 10.11, Friend 1 / Friend 3):
  - time of an event = its HAL timestamp (ms), not the batch arrival;
  - an interval is the time between two neighbouring events of ANY model signal;
    the held values (before the new event) are integrated over it;
  - an interval over GAP_MS is not integrated (a gap, counted); a negative one is not
    integrated (counted); values never expire (the stream pushes on change);
  - V = pack_voltage_fine, else pack_voltage; five sums: pack V*I_bat, inverter
    traction (V*I_inv > 0), inverter regen (|V*I_inv| for I_inv < 0), shaft traction
    and shaft regen (torque * rpm * 2pi/60);
  - coverage = time where V and both currents are known and the interval <= GAP_MS;
  - board power per minute of the trip = (E_pack - E_inv) / covered time of that
    minute; a minute counts with at least MINUTE_MIN_MS covered (the open minute too).
Split (model v2): motion = traction - regen, climate = pack - motion (< 0 -> 0,
motion = pack), other = 0, no scaling. Checks (Friend 3): inverter regen <= shaft
regen * 1.05 + 0.05 kWh; minutes below 0.2 kW <= 10 % and none below -0.3 kW (+235: none
below -0.5 kW and no two neighbouring minutes below -0.3 kW; sums written before +235 carry
no run count and keep the old rule). A failed
check leaves the parts empty, the pack total stays. Sums with coverage below 0.8 of the
trip are not used: the sample-based estimate (v2s) is taken instead.

Battery regen (+234): integral of V*I_bat where it is negative, same intervals.

Reference (recon corpus 09.11 18:10-19:00, tools/data/recon_corpus_20261109_energy6.csv.gz):
pack 3.60, inverter net 2.72, inverter regen 1.75, shaft 3.96 / 1.93, coverage 2966 of
3000 s, 0 negative intervals, 0 gaps; split 2.72 / 0.87.

Usage:
  python3 tools/mirror_plus233_events.py      self-tests + corpus reference (CI-safe)
"""
import gzip, math, pathlib, sys

SIGNALS = ('pack_voltage_fine', 'pack_voltage', 'pack_current', 'inverter_current',
           'motor_torque', 'motor_rpm')
GAP_MS = 5000
MINUTE_MIN_MS = 30000
MIN_TRIP_S, MIN_COVERAGE = 180, 0.8
REGEN_K, REGEN_ABS = 1.05, 0.05
LOW_KW, LOW_SHARE, NEG_KW = 0.2, 0.10, -0.5
RUN_KW, RUN_MINUTES = -0.3, 2  # +235 (Friend 3, 13.11)
WINDOW_KW = -0.3  # +238 (Friend 3, 25.11): two-minute sliding window
PER_MINUTE_CAP, NOISE_CAP = 720, 60
FIXTURE = pathlib.Path(__file__).resolve().parent / 'data' / 'recon_corpus_20261109_energy6.csv.gz'
REF_START_MS, REF_END_MS = 1794237000000, 1794240000000  # 09.11.2026 18:10-19:00 +03:00


class Acc:
    def __init__(self, start_ms):
        self.start_ms = start_ms
        self.last = {}
        self.t_prev = None
        self.pack = self.trac = self.regen = self.sh_trac = self.sh_regen = 0.0
        self.regen_bat = 0.0  # +234: battery-side regen, V*I_bat < 0
        self.cov_ms = 0
        self.neg = self.gaps = 0
        self.counts = [0] * len(SIGNALS)
        self.m_idx = -1
        self.m_e = 0.0
        self.m_cov = 0
        self.minutes = self.m_low = self.m_neg = 0
        self.m_min = None
        self.m_neg3 = self.run_len = self.run_max = 0  # +235
        self.run_last_idx = -2
        # +238: two-minute windows, noise minutes, per-minute values
        self.w_prev = (-2, 0.0, 0)
        self.w2 = 0
        self.w2_min = None
        self.noise = []
        self.pm = []
        # +237: 12 V board net (dcdc_load_current_a, firehose, no HAL stamp)
        self.b12_a = None
        self.b12_at = None
        self.b12 = 0.0
        self.b12_cov_ms = 0
        self.b12_seen = False

    def add_board12(self, current_a):
        self.b12_a, self.b12_at, self.b12_seen = current_a, self.t_prev, True

    def clear_board12(self):
        self.b12_a = self.b12_at = None

    def _close_minute(self, e, cov):
        if cov < MINUTE_MIN_MS:
            return None
        kw = e / (cov / 3600000.0)
        return kw

    @staticmethod
    def _window_kw(prev, idx, e, cov):
        pidx, pe, pcov = prev
        return (pe + e) / ((pcov + cov) / 3600000.0) if pidx == idx - 1 else None

    def _fold(self, kw):
        self.minutes += 1
        if kw < LOW_KW:
            self.m_low += 1
        if kw < NEG_KW:
            self.m_neg += 1
        self.m_min = kw if self.m_min is None else min(self.m_min, kw)
        if kw < RUN_KW:
            self.m_neg3 += 1
            self.run_len = self.run_len + 1 if self.run_last_idx == self.m_idx - 1 else 1
            self.run_last_idx = self.m_idx
            self.run_max = max(self.run_max, self.run_len)

    def add(self, name, value, ts):
        if name not in SIGNALS:
            return
        self.counts[SIGNALS.index(name)] += 1
        tp = self.t_prev
        if tp is not None:
            dt = ts - tp
            if dt < 0:
                self.neg += 1
            elif dt > GAP_MS:
                self.gaps += 1
            elif dt > 0:
                self._integrate(tp, dt)
        if tp is None or ts >= tp:
            self.t_prev = ts
        self.last[name] = value

    def _integrate(self, tp, dt):
        h = dt / 3600000.0
        v = self.last.get('pack_voltage_fine', self.last.get('pack_voltage'))
        ib, ii = self.last.get('pack_current'), self.last.get('inverter_current')
        if v is not None and ib is not None and ii is not None:
            self.cov_ms += dt
            pb = v * ib / 1000.0
            pi = v * ii / 1000.0
            self.pack += pb * h
            if pb < 0:
                self.regen_bat += -pb * h
            if self.b12_a is not None and self.b12_at is not None and tp - self.b12_at <= B12_FRESH_MS:
                self.b12 += board12_kw(self.b12_a) * h
                self.b12_cov_ms += dt
            if pi > 0:
                self.trac += pi * h
            else:
                self.regen += -pi * h
            idx = max(0, tp - self.start_ms) // 60000
            if idx != self.m_idx:
                if self.m_idx >= 0:
                    kw = self._close_minute(self.m_e, self.m_cov)
                    if kw is not None:
                        self._fold(kw)
                        w = self._window_kw(self.w_prev, self.m_idx, self.m_e, self.m_cov)
                        if w is not None:
                            self.w2 += w < WINDOW_KW
                            self.w2_min = w if self.w2_min is None else min(self.w2_min, w)
                        self.w_prev = (self.m_idx, self.m_e, self.m_cov)
                        if kw < NEG_KW and len(self.noise) < NOISE_CAP:
                            self.noise.append(self.m_idx)
                        if len(self.pm) < PER_MINUTE_CAP:
                            self.pm.append((self.m_idx, kw, self.m_cov / 1000.0))
                self.m_idx, self.m_e, self.m_cov = idx, 0.0, 0
            self.m_e += (pb - pi) * h
            self.m_cov += dt
        tq, n = self.last.get('motor_torque'), self.last.get('motor_rpm')
        if tq is not None and n is not None:
            ps = tq * n * 2 * math.pi / 60 / 1000.0
            if ps > 0:
                self.sh_trac += ps * h
            else:
                self.sh_regen += -ps * h

    def sums(self):
        minutes, low, neg, mn = self.minutes, self.m_low, self.m_neg, self.m_min
        neg3, run_max = self.m_neg3, self.run_max
        w2, w2_min, noise, pm = self.w2, self.w2_min, list(self.noise), list(self.pm)
        if self.m_idx >= 0:
            kw = self._close_minute(self.m_e, self.m_cov)
            if kw is not None:
                minutes += 1
                low += kw < LOW_KW
                neg += kw < NEG_KW
                mn = kw if mn is None else min(mn, kw)
                if kw < RUN_KW:
                    neg3 += 1
                    run = self.run_len + 1 if self.run_last_idx == self.m_idx - 1 else 1
                    run_max = max(run_max, run)
                w = self._window_kw(self.w_prev, self.m_idx, self.m_e, self.m_cov)
                if w is not None:
                    w2 += w < WINDOW_KW
                    w2_min = w if w2_min is None else min(w2_min, w)
                if kw < NEG_KW and len(noise) < NOISE_CAP:
                    noise.append(self.m_idx)
                if len(pm) < PER_MINUTE_CAP:
                    pm.append((self.m_idx, kw, self.m_cov / 1000.0))
        return dict(pack=self.pack, trac=self.trac, regen=self.regen, sh_trac=self.sh_trac,
                    sh_regen=self.sh_regen, regen_bat=self.regen_bat, cov_s=self.cov_ms / 1000.0, neg=self.neg,
                    gaps=self.gaps, counts=list(self.counts), minutes=minutes, m_low=low,
                    m_neg=neg, m_min=mn, m_neg3=neg3, run_max=run_max,
                    w2=w2, w2_min=w2_min, noise=noise, pm=pm,
                    b12=self.b12 if self.b12_seen else None, b12_s=self.b12_cov_ms / 1000.0)


def check(s):
    """None when the checks pass, else the reason (same words as the Dart side)."""
    if s['regen'] > s['sh_regen'] * REGEN_K + REGEN_ABS:
        return 'regen_above_shaft'
    run = s.get('run_max')  # None: sums written before +235, old rule
    w2 = s.get('w2')  # None: sums written before +238, rule by run
    if w2 is not None:
        bad_neg = w2 > 0
    else:
        bad_neg = s['m_neg3'] > 0 if run is None else (s['m_neg'] > 0 or run >= RUN_MINUTES)
    if s['minutes'] > 0 and (s['m_low'] > LOW_SHARE * s['minutes'] or bad_neg):
        return 'board_minutes'
    return None


def split_events(s, start_ms, end_ms):
    """Returns dict or None (None: sums do not cover the trip, take v2s)."""
    dur = (end_ms - start_ms) / 1000.0
    cov = min(1.0, s['cov_s'] / dur) if dur > 0 else 0.0
    if cov < MIN_COVERAGE:
        return None
    out = dict(model='v2', pack=s['pack'], coverage=cov, motion=None, climate=None,
               other=None, rejected=None)
    if dur < MIN_TRIP_S or s['pack'] <= 0:
        return out
    why = check(s)
    if why is not None:
        out['rejected'] = why
        return out
    motion = s['trac'] - s['regen']
    climate = s['pack'] - motion
    if climate < 0:
        climate, motion = 0.0, s['pack']
    other = board12_share(s, climate)
    out.update(motion=motion, climate=climate - other, other=other)
    return out


# +237 (recon v0.10.160): 12 V load current at the DC-DC output -> battery side.
B12_RAIL_V = 13.3
DCDC_EFF = 0.9
B12_FRESH_MS = 10000


def board12_kw(current_a):
    return current_a * B12_RAIL_V / DCDC_EFF / 1000.0


def board12_share(s, climate):
    """Part of 'climate and board net' that is the 12 V board net ('other')."""
    b = s.get('b12')
    if b is None or b <= 0 or climate <= 0 or s['cov_s'] <= 0:
        return 0.0
    if s.get('b12_s', 0.0) / s['cov_s'] < MIN_COVERAGE:
        return 0.0
    return min(b, climate)


def _selftest_board12():
    """True on failure. 400 V, battery 10 A, inverter 8 A, 12 V load 30 A, 600 s."""
    def run(board_until_ms):
        a = Acc(0)
        a.add('pack_voltage_fine', 400.0, 0)
        a.add('inverter_current', 8.0, 0)
        a.add('pack_current', 10.0, 0)
        for t in range(1000, 600001, 1000):
            if t <= board_until_ms:
                a.add_board12(30.0)
            a.add('pack_current', 10.0, t)
        return a.sums()
    bad = False
    s = run(600000)
    r = split_events(s, 0, 600000)
    exp_b = board12_kw(30.0) * 600 / 3600.0
    checks = [
        ('b12 energy', abs(s['b12'] - exp_b) < 1e-6),
        ('b12 coverage', abs(s['b12_s'] - 600.0) < 1e-6),
        ('other = 12 V', abs(r['other'] - exp_b) < 1e-6),
        ('climate = residual - other', abs(r['climate'] - (0.8 * 600 / 3600.0 - exp_b)) < 1e-6),
        ('sum = pack', abs(r['motion'] + r['climate'] + r['other'] - s['pack']) < 1e-9),
    ]
    s2 = run(100000)
    r2 = split_events(s2, 0, 600000)
    checks += [
        ('stale 12 V current is not held', abs(s2['b12_s'] - 110.0) < 1e-6),
        ('low 12 V coverage -> other 0', r2['other'] == 0.0),
        ('low 12 V coverage -> climate whole', abs(r2['climate'] - 0.8 * 600 / 3600.0) < 1e-6),
    ]
    s3 = dict(s, b12=5.0)
    r3 = split_events(s3, 0, 600000)
    checks += [('other never above the residual', abs(r3['other'] - 0.8 * 600 / 3600.0) < 1e-6 and r3['climate'] == 0.0)]
    s4 = dict(s)
    s4.pop('b12'); s4.pop('b12_s')
    checks += [('sums before +237 -> other 0', split_events(s4, 0, 600000)['other'] == 0.0)]
    for what, ok in checks:
        if not ok:
            print('FAIL board12:', what)
            bad = True
    if not bad:
        print(f'board12: {len(checks)} checks OK')
    return bad


def load_fixture():
    t = None
    sig = None
    ev = []
    with gzip.open(FIXTURE, 'rt') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('#'):
                if line.startswith('#t0='):
                    t = int(line[4:])
                elif line.startswith('#signals='):
                    sig = line[len('#signals='):].split(',')
                continue
            dt, i, v = line.split(',')
            t += int(dt)
            ev.append((t, sig[int(i)], float(v)))
    return ev


def _selftest():
    fails = []

    def ok(name, cond):
        print(f"  [{'PASS' if cond else 'FAIL'}] {name}")
        if not cond:
            fails.append(name)

    # 1. Hold and integrate: 100 s of 400 V x 10 A on the pack, inverter 0.
    a = Acc(0)
    for t in range(0, 100001, 1000):
        a.add('pack_voltage_fine', 400.0, t)
        a.add('pack_current', 10.0, t)
        a.add('inverter_current', 0.0, t)
    s = a.sums()
    ok('hold-and-integrate: 4 kW x 100 s', abs(s['pack'] - 4.0 * 100 / 3600) < 1e-9)
    ok('coverage counts held intervals', abs(s['cov_s'] - 100.0) < 1e-9)
    # 2. Gap over 5 s is not integrated, counted.
    a = Acc(0)
    for t, n, v in [(0, 'pack_voltage', 400), (0, 'pack_current', 10), (0, 'inverter_current', 0),
                    (6000, 'pack_current', 10), (7000, 'pack_current', 10)]:
        a.add(n, float(v), t)
    s = a.sums()
    ok('gap > 5 s skipped and counted', s['gaps'] == 1 and abs(s['cov_s'] - 1.0) < 1e-9)
    # 3. Negative interval counted, not integrated, clock does not go back.
    a = Acc(0)
    for t, n, v in [(0, 'pack_voltage', 400), (0, 'pack_current', 10), (0, 'inverter_current', 0),
                    (2000, 'pack_current', 10), (1500, 'pack_current', 10), (3000, 'pack_current', 10)]:
        a.add(n, float(v), t)
    s = a.sums()
    ok('negative interval counted, clock kept', s['neg'] == 1 and abs(s['cov_s'] - 3.0) < 1e-9)
    # 4. Fine voltage preferred over the coarse one.
    a = Acc(0)
    for t, n, v in [(0, 'pack_voltage', 300), (0, 'pack_voltage_fine', 400), (0, 'pack_current', 10),
                    (0, 'inverter_current', 0), (3600, 'pack_current', 10)]:
        a.add(n, float(v), t)
    ok('pack_voltage_fine preferred', abs(a.sums()['pack'] - 4.0 * 3.6 / 3600) < 1e-9)
    # 5. Traction / regen and shaft sums separate, by sign.
    a = Acc(0)
    a.add('pack_voltage', 400.0, 0); a.add('pack_current', 0.0, 0)
    a.add('motor_torque', 100.0, 0); a.add('motor_rpm', 1000.0, 0)
    a.add('inverter_current', 50.0, 0)
    a.add('inverter_current', -25.0, 3600)
    a.add('motor_torque', -100.0, 7200)
    a.add('pack_current', 0.0, 10800)
    s = a.sums()
    ok('traction and regen by sign',
       abs(s['trac'] - 20 * 3.6 / 3600) < 1e-9 and abs(s['regen'] - 10 * 3.6 / 3600 * 2) < 1e-9)
    pm = 100 * 1000 * 2 * math.pi / 60 / 1000
    ok('shaft traction and regen by sign',
       abs(s['sh_trac'] - pm * 7.2 / 3600) < 1e-9 and abs(s['sh_regen'] - pm * 3.6 / 3600) < 1e-9)
    # 6. Split and checks on synthetic sums.
    base = dict(pack=3.0, trac=3.0, regen=1.0, sh_trac=3.0, sh_regen=1.2, cov_s=1000.0,
                neg=0, gaps=0, counts=[], minutes=16, m_low=1, m_neg=0, m_min=0.1,
                m_neg3=0, run_max=0)
    r = split_events(base, 0, 1000000)
    ok('split: motion = traction - regen, climate = pack - motion, other 0',
       abs(r['motion'] - 2.0) < 1e-12 and abs(r['climate'] - 1.0) < 1e-12 and r['other'] == 0.0)
    r = split_events(dict(base, regen=1.4), 0, 1000000)
    ok('regen above shaft x 1.05 + 0.05 rejected', r['motion'] is None and r['rejected'] == 'regen_above_shaft'
       and r['pack'] == 3.0)
    r = split_events(dict(base, m_low=2), 0, 1000000)
    ok('more than 10 % low minutes rejected', r['rejected'] == 'board_minutes')
    r = split_events(dict(base, m_neg=1, m_neg3=1, run_max=1), 0, 1000000)
    ok('a minute below -0.5 kW rejected', r['rejected'] == 'board_minutes')
    r = split_events(dict(base, m_neg3=1, run_max=1), 0, 1000000)
    ok('+235: one minute between -0.5 and -0.3 kW passes', r['rejected'] is None)
    r = split_events(dict(base, m_neg3=2, run_max=2), 0, 1000000)
    ok('+235: two neighbouring minutes below -0.3 kW rejected', r['rejected'] == 'board_minutes')
    r = split_events(dict(base, m_neg3=2, run_max=1), 0, 1000000)
    ok('+235: two separate minutes below -0.3 kW pass', r['rejected'] is None)
    r = split_events(dict(base, m_neg3=1, run_max=None), 0, 1000000)
    ok('+235: sums before +235 keep the old rule', r['rejected'] == 'board_minutes')
    # +235: run counting on the accumulator. Board power per minute is
    # (E_pack - E_inv) / covered time; inverter 0, pack current sets it.
    def minutes_acc(kws):
        a = Acc(0)
        t = 0
        for kw in kws:
            for k in range(0, 60000, 1000):
                a.add('pack_voltage', 400.0, t + k)
                a.add('inverter_current', 0.0, t + k)
                a.add('pack_current', kw * 1000.0 / 400.0, t + k)
            t += 60000
        a.add('pack_current', 0.0, t)
        return a.sums()
    s2 = minutes_acc([1.0, -0.4, 1.0, -0.4, 1.0])
    ok('+235: separate minutes below -0.3 kW: run 1', s2['m_neg3'] == 2 and s2['run_max'] == 1 and s2['m_neg'] == 0)
    s2 = minutes_acc([1.0, -0.4, -0.4, 1.0])
    ok('+235: neighbouring minutes below -0.3 kW: run 2', s2['m_neg3'] == 2 and s2['run_max'] == 2)
    s2 = minutes_acc([1.0, -0.6])
    ok('+235: open last minute counted in the run and below -0.5', s2['m_neg'] == 1 and s2['run_max'] == 1)
    # +238: two-minute windows decide; a single noise minute does not reject.
    s2 = minutes_acc([1.0, -1.29, 1.0, 1.0])
    ok('+238: one minute -1.29 kW between 1.0 kW minutes: window above -0.3, noise listed',
       s2['w2'] == 0 and s2['noise'] == [1] and s2['m_neg'] == 1 and abs(s2['w2_min'] - (-0.145)) < 1e-9)
    ok('+238: that trip passes the check',
       check(dict(base, m_neg=s2['m_neg'], m_neg3=s2['m_neg3'], run_max=s2['run_max'], w2=s2['w2'])) is None)
    s2 = minutes_acc([1.0, -0.2, -0.5, 1.0])
    ok('+238: two neighbours averaging -0.35 kW: one window below -0.3', s2['w2'] == 1 and abs(s2['w2_min'] - (-0.35)) < 1e-9)
    ok('+238: window below -0.3 rejected', check(dict(base, w2=1)) == 'board_minutes')
    s2 = minutes_acc([1.0, -0.4, 1.0, -0.4])
    ok('+238: separate minutes do not form a window', s2['w2'] == 0 and len(s2['pm']) == 4 and s2['pm'][1][0] == 1)
    ok('+238: sums before +238 keep the run rule', check(dict(base, m_neg=1, m_neg3=1, run_max=1)) == 'board_minutes')
    r = split_events(dict(base, trac=4.0, regen=0.5, sh_regen=1.0), 0, 1000000)
    ok('climate below 0 -> 0, motion = pack', r['climate'] == 0.0 and r['motion'] == 3.0)
    ok('low coverage -> sample estimate', split_events(base, 0, 1300000) is None)
    ok('trip under 3 min: no parts', split_events(dict(base, cov_s=170.0), 0, 170000)['motion'] is None)

    # 7. Corpus reference.
    ev = [e for e in load_fixture() if REF_START_MS <= e[0] <= REF_END_MS]
    a = Acc(REF_START_MS)
    for t, n, v in ev:
        a.add(n, v, t)
    s = a.sums()
    print(f"  corpus: pack={s['pack']:.3f} trac={s['trac']:.3f} regen={s['regen']:.3f} "
          f"net={s['trac'] - s['regen']:.3f} shaft={s['sh_trac']:.3f}/{s['sh_regen']:.3f} "
          f"cov={s['cov_s']:.0f}s neg={s['neg']} gaps={s['gaps']} minutes={s['minutes']} "
          f"low={s['m_low']} neg03={s['m_neg3']} neg05={s['m_neg']} run={s['run_max']} min={s['m_min']:.2f}")
    ok('corpus pack 3.60', abs(s['pack'] - 3.60) < 0.01)
    ok('corpus inverter net 2.72', abs(s['trac'] - s['regen'] - 2.72) < 0.01)
    ok('corpus inverter regen 1.75', abs(s['regen'] - 1.75) < 0.01)
    ok('corpus shaft 3.96 / 1.93', abs(s['sh_trac'] - 3.96) < 0.01 and abs(s['sh_regen'] - 1.93) < 0.01)
    ok('corpus coverage 2966 s, no negative intervals, no gaps',
       abs(s['cov_s'] - 2966) < 1 and s['neg'] == 0 and s['gaps'] == 0)
    ok('corpus minutes: min >= 0.15 kW, at most one below 0.2, none below -0.3',
       s['m_min'] >= 0.149 and s['m_low'] <= 1 and s['m_neg'] == 0 and s['m_neg3'] == 0 and s['run_max'] == 0)
    ok('+238: corpus has no window below -0.3 and one value per minute',
       s['w2'] == 0 and s['noise'] == [] and len(s['pm']) == s['minutes'])
    r = split_events(s, REF_START_MS, REF_END_MS)
    ok('corpus split 2.72 / 0.87, checks pass',
       r['rejected'] is None and abs(r['motion'] - 2.72) < 0.01 and abs(r['climate'] - 0.87) < 0.01)
    ok('corpus parts sum to pack', abs(r['motion'] + r['climate'] - r['pack']) < 1e-9)
    # +234: battery-side regen. Below inverter regen by the on-board load in
    # those seconds (Friend 3); recon 09.11 counter 0x2D0 +1.6 vs 1.57.
    print(f"  corpus +234: regen_bat={s['regen_bat']:.3f}")
    ok('corpus battery regen below inverter regen, near counter 1.6',
       0 < s['regen_bat'] < s['regen'] and abs(s['regen_bat'] - 1.57) < 0.06)
    print(f"mirror +233: {'PASS' if not fails else 'FAIL'} ({len(fails)} failed)")
    return fails


if __name__ == '__main__':
    _bad = _selftest()
    _bad = _selftest_board12() or _bad
    sys.exit(1 if _bad else 0)
