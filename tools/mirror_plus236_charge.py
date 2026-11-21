#!/usr/bin/env python3
"""Python mirror of the +236 charge logic (lib/services/charge_state.dart) and of the
atlas provisional-share transfer (SpeedProfileService._settleProvisional).

Rules (recon v0.10.159, Friend 3; AC 13-14.11 and DC 20.11):
  - CHARGING_BATTERRY_DEVICE_STATE: 15 rest, 0 starting, 1 charging, 2 stopping.
  - gun on the HAL scale: 1 none, 2 AC, 3 DC (firehose value + 1).
  - stage (Friend 3's table, 21.11): unknown device state -> None (the fallback
    decides); gun 1 -> none whatever the state; 0 handshake, 1 charging, 2 finished;
    15 with the gun in -> plugged, or finished when a charge already ran in this
    plug-in; 15 with no gun value -> none. State 15 is NOT "no session": on DC 20.11 it
    stayed 15 for 135 s after plug-in, and after a charge 2 lasts seconds, then 15.
  - "charged in this plug-in" is set by state 1 or 2 and cleared only by gun 1.
  - charged energy: sum of increments of gb_cycle_regen_kwh (0x2D0, step 0.1 kWh, one
    frame per 30 s) since the session opened; a drop is a reset: new base, nothing added.
  - control: integral of battery power into the pack between HAL events, gaps over
    120 s skipped; "diverged" = more than 0.5 kWh and more than 15 % apart.
  - outside temperature check: after a HAL ac_temp_out event the firehose value must
    show the same number within 10 s, otherwise untrusted until the next trip.
  - atlas: the provisional share of a cell (first 600 s of movement of a session) moves
    to the cell of the same band in the settled window; totals are conserved.

Usage:
  python3 tools/mirror_plus236_charge.py      self-tests (CI-safe)
"""
import sys

NONE, PLUGGED, HANDSHAKE, CHARGING, FINISHED = 'none', 'plugged', 'handshake', 'charging', 'finished'
INTEGRAL_MAX_GAP_S = 120.0
HOLD_MS = 10000
SETTLE_S = 600.0
BAND_MIN_S = 180.0


def stage_of(ds=None, gun=None, charged=False):
    if ds is None:
        return None
    d = round(ds)
    if d not in (0, 1, 2, 15):
        return None
    if gun is not None and round(gun) == 1:
        return NONE
    if d == 15:
        if gun is None:
            return NONE
        return FINISHED if charged else PLUGGED
    return {0: HANDSHAKE, 1: CHARGING, 2: FINISHED}[d]


def next_charged(prev, ds=None, gun=None):
    if gun is not None and round(gun) == 1:
        return False
    if ds is not None and round(ds) in (1, 2):
        return True
    return prev


def type_of(gun=None, fh_type=None):
    if gun is not None:
        g = round(gun)
        if g == 3:
            return 'DC'
        if g == 2:
            return 'AC'
    if fh_type is not None:
        t = round(fh_type)
        if t == 11:
            return 'DC'
        if t == 9:
            return 'AC'
    return None


class Counter:
    def __init__(self):
        self.last = None
        self.is_open = False
        self.has_base = False
        self.sum = 0.0
        self.from_start = False
        self.resets = 0
        self.integral = 0.0

    @property
    def kwh(self):
        return self.sum if self.is_open and self.has_base else None

    def feed(self, v):
        last, self.last = self.last, v
        if not self.is_open:
            return
        if not self.has_base:
            self.has_base = True
            return
        if last is None:
            return
        if v >= last:
            self.sum += v - last
        else:
            self.resets += 1

    def open(self, before_charging):
        if self.is_open:
            return
        self.is_open = True
        self.sum, self.resets, self.integral = 0.0, 0, 0.0
        self.has_base = self.last is not None
        self.from_start = self.has_base or before_charging

    def close(self):
        self.is_open = False

    def forget(self):
        self.is_open, self.has_base, self.last = False, False, None

    def add_integral(self, kw, dt_s):
        if not self.is_open or kw is None:
            return
        if dt_s <= 0 or dt_s > INTEGRAL_MAX_GAP_S:
            return
        if kw < 0:
            self.integral += -kw * dt_s / 3600.0

    @property
    def diverged(self):
        c = self.kwh
        if c is None:
            return False
        hi = max(c, self.integral)
        if hi < 2.0:
            return False
        d = abs(c - self.integral)
        return d > 0.5 and d > 0.15 * hi


class TempCheck:
    def __init__(self):
        self.untrusted = False
        self.expect = None
        self.since = None

    def feed_hal(self, c, now_ms):
        self.expect, self.since = c, now_ms

    def feed_firehose(self, c, now_ms):
        if self.expect is None or self.since is None:
            return False
        if abs(c - self.expect) < 0.5:
            self.expect = self.since = None
            return False
        if self.untrusted or now_ms - self.since < HOLD_MS:
            return False
        self.untrusted = True
        return True

    def reset_for_trip(self):
        self.untrusted, self.expect, self.since = False, None, None


def window_of(t):
    if t < -20:
        return -20
    if t >= 40:
        return 35
    return int(t // 5) * 5


def settle(cells, temp_c):
    """cells: {(band, window): {'e','d','t','pe','pd','pt'}}; returns moved count."""
    win = None if temp_c is None else window_of(temp_c)
    moved = 0
    for key in list(cells):
        src = cells[key]
        if src['pt'] <= 1e-9:
            continue
        band, src_win = key
        if src_win == win:
            src['pe'] = src['pd'] = src['pt'] = 0.0
            continue
        dest = cells.setdefault((band, win), dict(e=0.0, d=0.0, t=0.0, pe=0.0, pd=0.0, pt=0.0))
        for a, b in (('e', 'pe'), ('d', 'pd'), ('t', 'pt')):
            dest[a] += src[b]
            src[a] -= src[b]
        src['pe'] = src['pd'] = src['pt'] = 0.0
        if src['t'] <= 1e-6:
            del cells[key]
        moved += 1
    return moved


def _tests():
    n = [0]

    def eq(a, b, what):
        ok = abs(a - b) < 1e-9 if isinstance(a, float) and isinstance(b, (int, float)) else a == b
        if not ok:
            print(f'FAIL {what}: {a!r} != {b!r}')
            sys.exit(1)
        n[0] += 1

    # stage
    eq(stage_of(1, 2), CHARGING, 'charging')
    eq(stage_of(0, 3), HANDSHAKE, 'handshake')
    eq(stage_of(2, 2), FINISHED, 'finished')
    eq(stage_of(15, 2), PLUGGED, 'rest with the gun in, no charge yet')
    eq(stage_of(15, 2, True), FINISHED, 'rest with the gun in after a charge')
    eq(stage_of(15, 1, True), NONE, 'gun out after a charge')
    eq(stage_of(15), NONE, 'rest, gun unknown')
    # DC 20.11 end to end
    ch = False
    seq = []
    for ds, gun in ((15, 1), (15, 3), (0, 3), (1, 3), (2, 3), (15, 3), (15, 1), (15, 2)):
        ch = next_charged(ch, ds, gun)
        seq.append(stage_of(ds, gun, ch))
    eq(seq, [NONE, PLUGGED, HANDSHAKE, CHARGING, FINISHED, FINISHED, NONE, PLUGGED], 'DC 20.11 sequence')
    eq(next_charged(True, 15, None), True, 'memory holds without a gun value')
    eq(next_charged(False, 0, 2), False, 'handshake does not set the memory')
    eq(stage_of(1, 1), NONE, 'gun out closes while charging')
    eq(stage_of(2, 1), NONE, 'gun out closes while stopping')
    eq(stage_of(None, 2), None, 'unknown state')
    eq(stage_of(7, 2), None, 'state outside the table')
    eq(stage_of(1), CHARGING, 'no gun value')
    # type
    eq(type_of(2), 'AC', 'gun AC')
    eq(type_of(3), 'DC', 'gun DC')
    eq(type_of(1, 8), None, 'no gun, not charging')
    eq(type_of(None, 9), 'AC', 'type AC')
    eq(type_of(None, 11), 'DC', 'type DC')
    eq(type_of(3, 9), 'DC', 'gun first')
    # counter: DC 20.11 (export 21.11)
    c = Counter()
    c.feed(1.3)
    c.open(True)
    eq(c.kwh, 0.0, 'base before plug-in')
    for v in (1.3, 1.7, 2.1, 6.5, 12.9, 14.0, 14.0):
        c.feed(v)
    eq(c.kwh, 12.7, 'DC 20.11 +12.7')
    eq(c.from_start, True, 'from start')
    c.close()
    eq(c.kwh, None, 'closed')
    c = Counter()
    c.feed(5.0)
    c.open(True)
    for v in (6.0, 0.4, 1.0):
        c.feed(v)
    eq(c.resets, 1, 'one reset')
    eq(c.kwh, 1.6, 'reset: new base, nothing added')
    c = Counter()
    c.open(False)
    eq(c.kwh, None, 'no base yet')
    eq(c.from_start, False, 'picked up mid-charge')
    c.feed(8.0)
    eq(c.kwh, 0.0, 'first frame is the base')
    c.feed(8.4)
    eq(c.kwh, 0.4, 'then it counts')
    c = Counter()
    c.feed(3.0)
    c.forget()
    c.open(False)
    eq(c.kwh, None, 'forget drops the base')
    c = Counter()
    c.feed(1.0)
    c.open(True)
    c.add_integral(-48.0, 60)
    c.add_integral(2.0, 60)
    c.add_integral(-48.0, 300)
    c.add_integral(None, 10)
    eq(c.integral, 0.8, 'integral: into the pack only, gaps skipped')
    c = Counter()
    c.feed(0.0)
    c.open(True)
    c.feed(10.0)
    for _ in range(10):
        c.add_integral(-36.0, 100)
    eq(c.diverged, False, 'counter 10 vs integral 10')
    c.feed(13.0)
    eq(c.diverged, True, 'counter 13 vs integral 10')
    # outside temperature check
    k = TempCheck()
    k.feed_hal(0, 1000)
    eq(k.feed_firehose(1, 1500), False, 'one sample behind')
    eq(k.feed_firehose(0, 2500), False, 'matched')
    eq(k.feed_firehose(5, 60000), False, 'check closed')
    eq(k.untrusted, False, 'trusted')
    k = TempCheck()
    k.feed_hal(4, 1000)
    eq(k.feed_firehose(14, 5000), False, 'inside the hold')
    eq(k.feed_firehose(14, 11000), True, 'hold over')
    eq(k.untrusted, True, 'untrusted')
    k.reset_for_trip()
    eq(k.untrusted, False, 'reset per trip')
    # atlas transfer: garage exit, 14 -> 4 degrees
    cells = {
        (60, 10): dict(e=0.50, d=3.0, t=180.0, pe=0.50, pd=3.0, pt=180.0),
        (60, 0): dict(e=1.10, d=6.6, t=400.0, pe=1.10, pd=6.6, pt=400.0),
        (80, 10): dict(e=0.90, d=4.0, t=250.0, pe=0.30, pd=1.3, pt=80.0),
    }
    tot = sum(v['t'] for v in cells.values()), sum(v['e'] for v in cells.values())
    eq(settle(cells, 4.0), 2, 'two cells moved')
    eq((60, 10) in cells, False, 'provisional-only cell is gone')
    eq(cells[(60, 0)]['t'], 580.0, 'band 60 lands in window 0')
    eq(cells[(80, 10)]['t'], 170.0, 'carried part of band 80 stays in window 10')
    eq(cells[(80, 0)]['t'], 80.0, 'provisional part of band 80 moves')
    eq(sum(v['t'] for v in cells.values()), tot[0], 'time conserved')
    eq(sum(v['e'] for v in cells.values()), tot[1], 'energy conserved')
    eq(sum(v['pt'] for v in cells.values()), 0.0, 'no provisional share left')
    cells = {(60, 10): dict(e=0.5, d=3.0, t=180.0, pe=0.5, pd=3.0, pt=180.0)}
    eq(settle(cells, None), 1, 'no temperature: moved to unknown')
    eq(cells[(60, None)]['t'], 180.0, 'unknown window holds it')
    eq(window_of(-7.3), -10, 'window of -7.3')
    eq(window_of(4.0), 0, 'window of 4')
    eq(window_of(14.0), 10, 'window of 14')
    print(f'mirror +236: {n[0]} checks OK')


if __name__ == '__main__':
    _tests()
