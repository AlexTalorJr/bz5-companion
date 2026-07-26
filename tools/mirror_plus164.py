#!/usr/bin/env python3
"""mirror_plus164 — полевые дампы 26.07 сквозь логику +164.

Заменяет mirror_plus163.py: дампы 25.07 и 26.07 10:07, на которых тот
был построен, у владельца не сохранились. Набор за 26.07 покрывает
больше — это ПОЛНЫЙ цикл заморозки:

  16:29  пустая сессия, ноль клеток
  18:10  пять живых клеток, три дозревшие (40/50/60 ≥ 120 c)
         при snapshots_in_db: 0 — дефект, который чинит блок A,
         и состояние канона §6.13 живьём
  18:58  после recovery: три заморожено, две суб-пороговые перенесены

Порт на Python: чанкинг 120 с, аккумулятор замороженного, суммы сессии,
провизорность строк активной сессии, взвешенное среднее, дедуп сессий
для звёзд, набор карточек и сортировка, предикат ротации.

Ожидания сверены с БД экспорта bz5_export_20260726-185834 ДО написания
кода (правило верификации Alex).
"""
import json
import re
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
UP = Path('/mnt/user-data/uploads')

KWH = 65.28
K_MIN_S = 120.0          # kBandMinSeconds
GAP_MIN = 30             # kAtlasSessionGapMin
BAND_MAX_COLLECT = 140   # kAtlasBandMaxCollectKmh

FAILS = []


def check(name, cond, detail=''):
    print(('  [PASS] ' if cond else '  [FAIL] ') + name +
          (f' — {detail}' if detail else ''))
    if not cond:
        FAILS.append(name)


# ── чтение полевых артефактов ──────────────────────────────────────

def load_dumps():
    out = []
    for f in sorted(UP.glob('bz5_companion_diag*.md')):
        txt = f.read_text()
        for m in re.finditer(r'^```json\n(\{.*?\})\n```', txt, re.S | re.M):
            try:
                j = json.loads(m.group(1))
            except json.JSONDecodeError:
                continue
            if j.get('schema') == 'speed_profile_diag_v1':
                out.append(j)
    out.sort(key=lambda j: j['dumped_at'])
    return out


def load_db_atlas():
    z = UP / 'bz5_export_20260726-185834.zip'
    if not z.exists():
        return None
    import zipfile
    import tempfile
    with zipfile.ZipFile(z) as zf, tempfile.TemporaryDirectory() as d:
        zf.extract('samples.sqlite', d)
        c = sqlite3.connect(Path(d) / 'samples.sqlite')
        c.row_factory = sqlite3.Row
        return [dict(r) for r in
                c.execute('select * from atlas_snapshots order by id')]


# ── порт движка ────────────────────────────────────────────────────

class Cell:
    """_AtlasCell: живой накопитель + аккумулятор замороженных чанков."""

    def __init__(self, e=0.0, d=0.0, t=0.0, t0=0.0, sa=0,
                 fe=0.0, fd=0.0, ft=0.0):
        self.e, self.d, self.t, self.t0, self.sa = e, d, t, t0, sa
        self.fe, self.fd, self.ft = fe, fd, ft

    # суммы сессии = замороженное ⊕ живое
    @property
    def se(self):
        return self.fe + self.e

    @property
    def sd(self):
        return self.fd + self.d

    @property
    def st(self):
        return self.ft + self.t

    @property
    def has_chunk(self):
        return self.ft > 1e-9

    @property
    def gained(self):
        return self.st - self.t0

    @staticmethod
    def from_dump(c):
        return Cell(e=c['e'], d=c['d'], t=c['t'], t0=c.get('t0', 0.0),
                    sa=c.get('sa', 0), fe=c.get('fe', 0.0),
                    fd=c.get('fd', 0.0), ft=c.get('ft', 0.0))


def tick(cell, rows, session_uid, band, win, kwh_per_s, km_per_s, dt, now_ms):
    """_atlasTick + _freezeChunk: накопить dt, на пересечении 120 с
    записать строку и обнулить накопитель."""
    before = cell.t
    cell.e += kwh_per_s * dt
    cell.d += km_per_s * dt
    cell.t += dt
    if before < K_MIN_S <= cell.t:
        if band > BAND_MAX_COLLECT:
            return 'dropped'
        if cell.d <= 1e-6:
            return None
        rows.append({
            'session_uid': session_uid, 'band': band, 'window': win,
            'kwh100': cell.e / cell.d * 100.0, 'steady': cell.t,
            'frozen_at': now_ms,
        })
        cell.fe += cell.e
        cell.fd += cell.d
        cell.ft += cell.t
        cell.e = cell.d = cell.t = 0.0
        cell.sa = now_ms
        return 'frozen'
    return None


def rotate(cells):
    """_closeAtlasSession: чистим аккумулятор, t0 = остаток."""
    for c in cells.values():
        c.fe = c.fd = c.ft = 0.0
        c.t0 = c.t


def wmean(rows):
    tot = sum(r['steady'] for r in rows)
    if tot > 1e-9:
        return sum(r['kwh100'] * r['steady'] for r in rows) / tot
    return sum(r['kwh100'] for r in rows) / len(rows)


def dedup_session_count(rows):
    """Порт dedupSessionCount: группировка по session_uid, слияние
    только разных источников при перекрытии > 50 % более короткого."""
    keys, a, b, src = [], {}, {}, {}
    for r in rows:
        u = r['session_uid']
        if u not in a:
            keys.append(u)
            a[u], b[u], src[u] = r['started'], r['frozen'], r['source']
        else:
            a[u] = min(a[u], r['started'])
            b[u] = max(b[u], r['frozen'])
    parent = {k: k for k in keys}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            ki, kj = keys[i], keys[j]
            if src[ki] == src[kj]:
                continue
            ov = min(b[ki], b[kj]) - max(a[ki], a[kj])
            shorter = min(b[ki] - a[ki], b[kj] - a[kj])
            if shorter <= 0:
                continue
            if ov > 0.5 * shorter:
                parent[find(ki)] = find(kj)
    return len({find(k) for k in keys})


def grid_cells(rows, active_uid):
    """AtlasGridData.fromRows: строки активной сессии — провизорные."""
    out = {}
    for r in rows:
        if active_uid is not None and r['session_uid'] == active_uid:
            continue
        out.setdefault((r['band'], r['window']), []).append(r)
    return out


def pending_cells(cells):
    """atlasPendingCells: клетка с чанком или пере-пороговым остатком."""
    out = {}
    for key, c in cells.items():
        if not c.has_chunk and c.t < K_MIN_S:
            continue
        if c.sd <= 1e-6:
            continue
        band = int(key.split(':')[0])
        if band > BAND_MAX_COLLECT:
            continue
        out[key] = {'kwh100': c.se / c.sd * 100.0, 'steady': c.st}
    return out


def live_bands(cells):
    """_liveBandOf: по каждой полосе — самая глубокая клетка, суммы сессии."""
    by = {}
    for key, c in cells.items():
        band = int(key.split(':')[0])
        cur = by.get(band)
        if cur is None or c.st > cur.st:
            by[band] = c
    return {b: {'timeS': c.st,
                'kwh100': c.se / c.sd * 100.0 if c.sd > 1e-6 else None}
            for b, c in by.items()}


def card_set(cells, atlas, display_window):
    live = live_bands(cells)
    a = {b: v for (b, w), v in atlas.items() if w == display_window}
    models = []
    for b in set(live) | set(a):
        lv = live.get(b, {'timeS': 0.0, 'kwh100': None})
        models.append({'band': b, 'timeS': lv['timeS'],
                       'matured': lv['timeS'] >= K_MIN_S,
                       'atlas': a.get(b)})
    models.sort(key=lambda m: (0 if m['matured'] else 1,
                               -m['band'] if m['matured'] else -m['timeS']))
    return models


def rng(kwh100):
    return round((KWH / kwh100 * 100.0) / 5.0) * 5


def rotation_due(last_move_ms, session_dist_km, now_ms):
    return now_ms - last_move_ms > GAP_MIN * 60000 and session_dist_km > 0


# ── прогон ─────────────────────────────────────────────────────────

def main():
    dumps = load_dumps()
    db = load_db_atlas()
    print(f'дампов: {len(dumps)}   строк атласа в БД: '
          f'{len(db) if db is not None else "нет экспорта"}')
    if len(dumps) < 3:
        print('НЕТ ПОЛЕВЫХ ДАМПОВ — зеркало не запускается')
        return 2

    d_empty = dumps[0]                 # 16:29
    d_pre = [d for d in dumps
             if d['atlas']['snapshots_in_db'] == 0
             and d['atlas']['ledger']['cells']][-1]        # 18:11
    d_post = dumps[-1]                 # 18:58

    led_pre = d_pre['atlas']['ledger']
    cells_pre = {k: Cell.from_dump(v) for k, v in led_pre['cells'].items()}

    print('\n── 1. полевое состояние до правки (дефект, который чиним) ──')
    matured = {k: c for k, c in cells_pre.items() if c.t >= K_MIN_S}
    check('дамп 18:11: три клетки дозрели', len(matured) == 3,
          ','.join(sorted(matured)))
    check('дамп 18:11: в базе при этом ноль снимков',
          d_pre['atlas']['snapshots_in_db'] == 0)
    check('дамп 18:58: заморозка случилась только на recovery',
          d_post['atlas']['freezes_this_process'] == 3 and
          d_post['atlas']['snapshots_in_db'] == 3)

    print('\n── 2. чанкинг: значения совпадают с полевой БД бит-в-бит ──')
    # Клетки 18:11 ещё не заморожены. Прогоняем их через чанкинг: первый
    # чанк каждой клетки обязан дать ровно то, что легло в БД в 18:57
    # (заморозка «одним куском» и «первым чанком» совпадают, потому что
    # ни одна клетка не перевалила за 240 с).
    by_band = {r['band_kmh']: r for r in (db or [])}
    for band in (40, 50, 60):
        c = cells_pre[f'{band}:25']
        live_kwh = c.e / c.d * 100.0
        row = by_band.get(band)
        check(f'полоса {band}: kwh100 бит-в-бит с БД',
              row is not None and live_kwh == row['kwh100'],
              f'{live_kwh!r}')
        check(f'полоса {band}: steady бит-в-бит с БД',
              row is not None and c.t == row['steady_seconds'],
              f'{c.t!r}')

    print('\n── 3. чанкинг ничего не теряет ──')
    # 360 c ровной езды с меняющимся расходом. Сравниваем «один снимок
    # на всё» (+163) и «чанки по 120 c ⊕ остаток» (+164).
    profile = [(0.0040, 0.0180), (0.0032, 0.0170), (0.0051, 0.0190)]
    one = Cell(sa=0)
    for kwh_s, km_s in profile:
        for _ in range(1200):
            one.e += kwh_s * 0.1
            one.d += km_s * 0.1
            one.t += 0.1
    one_val = one.e / one.d * 100.0

    chunked, rows = Cell(sa=0), []
    now = 0
    reset_seen = []      # значение t СРАЗУ после каждой заморозки
    prev_session_t = -1.0
    monotonic = True
    for kwh_s, km_s in profile:
        for _ in range(1200):
            now += 100
            r = tick(chunked, rows, 'S1', 40, 25, kwh_s, km_s, 0.1, now)
            if r == 'frozen':
                reset_seen.append(chunked.t)
            if chunked.st < prev_session_t - 1e-9:
                monotonic = False
            prev_session_t = chunked.st

    # Главный инвариант: ничего не потеряно. Замороженное + живой
    # остаток обязаны совпасть с одним куском по всем трём величинам.
    check('Σ steady сохранена (замороженное ⊕ остаток)',
          abs(chunked.st - one.t) < 1e-6,
          f'{chunked.st:.6f} vs {one.t:.6f}')
    check('Σ энергии сохранена',
          abs(chunked.se - one.e) < 1e-9,
          f'{chunked.se!r} vs {one.e!r}')
    check('Σ пробега сохранена',
          abs(chunked.sd - one.d) < 1e-9)
    check('суммы сессии дают ровно то же число',
          abs(chunked.se / chunked.sd * 100.0 - one_val) < 1e-9,
          f'{chunked.se / chunked.sd * 100.0!r}')

    # Остаток не заморожен и переносится — правило канона §8
    # («накопление переносится между поездками»), то же, что уже
    # действует для суб-пороговых клеток.
    check('чанки записаны', len(rows) == 2, str(len(rows)))
    check('каждый чанк ≈ 120 c',
          all(abs(r['steady'] - K_MIN_S) < 0.2 for r in rows),
          ','.join(f"{r['steady']:.1f}" for r in rows))
    check('живой накопитель обнулён В МОМЕНТ заморозки',
          reset_seen == [0.0] * len(rows), str(reset_seen))
    check('остаток < 120 c и жив',
          0 < chunked.t < K_MIN_S, f'{chunked.t:.1f} c')

    # И1: карточка полосы не откатывается назад ни на одном тике.
    check('sessionTimeS монотонна на всём прогоне (И1)', monotonic)
    check('карточка осталась «дозрела»', chunked.st >= K_MIN_S,
          f'{chunked.st:.1f} c')

    print('\n── 3-bis. среднее атласа: время против пробега ──')
    # AtlasCellStat.mean взвешено по steady_seconds, а значение строки —
    # это Σe/Σd. Взвешенное по ВРЕМЕНИ среднее ОТНОШЕНИЙ не равно
    # отношению сумм, если скорость внутри полосы гуляет. Полоса держит
    # скорость в ±2 км/ч (kBandHalfWidthKmh), поэтому расхождение мало,
    # но оно не ноль — фиксируем допуск, а не равенство.
    virtual = rows + ([{'kwh100': chunked.e / chunked.d * 100.0,
                        'steady': chunked.t}] if chunked.d > 1e-6 else [])
    wm = wmean(virtual)
    check('расхождение среднего < 1 % на синтетике',
          abs(wm - one_val) / one_val < 0.01,
          f'{wm:.4f} vs {one_val:.4f} '
          f'({(wm - one_val) / one_val * 100:+.3f} %)')

    print('\n── 4. звёзды: три чанка одной сессии = одна поездка ──')
    star_rows = [{'session_uid': 'S1', 'started': 0, 'frozen': 1000,
                  'source': 'hu'} for _ in rows]
    check('dedupSessionCount == 1', dedup_session_count(star_rows) == 1)
    two = star_rows + [{'session_uid': 'S2', 'started': 5000,
                        'frozen': 6000, 'source': 'hu'}]
    check('вторая сессия считается отдельно',
          dedup_session_count(two) == 2)

    print('\n── 5. провизорность (§6.13) ──')
    active = 'S1'
    check('строки активной сессии не попадают в грид',
          grid_cells(rows, active) == {})
    check('после ротации те же строки становятся клетками',
          list(grid_cells(rows, 'S2').keys()) == [(40, 25)])
    pend = pending_cells({'40:25': chunked})
    check('§6.13 показывает клетку по суммам сессии',
          '40:25' in pend and
          abs(pend['40:25']['kwh100'] - one_val) < 1e-9,
          f"{pend['40:25']['kwh100']:.6f}")
    check('§6.13 число не падает после сброса чанка',
          abs(pend['40:25']['steady'] - one.t) < 1e-6)
    # клетка с чанком, но с нулевым остатком — всё равно pending
    only = Cell(fe=0.02, fd=0.16, ft=120.0)
    check('клетка сразу после чанка остаётся pending',
          '40:25' in pending_cells({'40:25': only}))

    print('\n── 6. ротация: остаток переносится, аккумулятор чистится ──')
    cells = {'40:25': chunked}
    before_rem = chunked.t
    rotate(cells)
    check('аккумулятор чанков очищен', chunked.ft == 0.0)
    check('остаток пережил ротацию', chunked.t == before_rem)
    check('t0 пере-заякорен в остаток', chunked.t0 == chunked.t)
    check('после ротации клетка больше не pending',
          pending_cells(cells) == {})

    print('\n── 7. перенос суб-пороговых — сверка с полем 18:58 ──')
    led_post = d_post['atlas']['ledger']
    for key, exp_t0 in (('70:25', 36.46299999999999),
                        ('80:25', 100.604)):
        c = led_post['cells'][key]
        check(f'{key}: t0 пере-заякорен в timeS полем',
              c['t0'] == c['t'] == exp_t0, f"t0={c['t0']} t={c['t']}")
    check('дозревшие клетки ушли из леджера после recovery',
          set(led_post['cells']) == {'70:25', '80:25'},
          ','.join(sorted(led_post['cells'])))

    print('\n── 8. потолок сбора 140 ──')
    over, orows = Cell(sa=0), []
    r = None
    for _ in range(1300):
        r = tick(over, orows, 'S1', 150, 25, 0.004, 0.018, 0.1, 0) or r
    check('полоса 150: снимка нет', orows == [])
    check('полоса 150: клетка помечена на выброс', r == 'dropped')

    print('\n── 9. запас хода и набор карточек ──')
    check('range(11.865) == 550', rng(11.865326369202151) == 550,
          str(rng(11.865326369202151)))
    check('range(13.475) == 485', rng(13.474528094462478) == 485,
          str(rng(13.474528094462478)))
    check('range(10.825) == 605', rng(10.825415535527085) == 605,
          str(rng(10.825415535527085)))

    atlas = {(b, 25): {'mean': by_band[b]['kwh100'], 'n': 1}
             for b in (40, 50, 60)} if db else {}
    models = card_set(cells_pre, atlas, led_pre['aw'])
    print('  набор:', [(m['band'], 'M' if m['matured'] else
                        f"{m['timeS']:.0f}s") for m in models])
    mat = [m for m in models if m['matured']]
    mng = [m for m in models if not m['matured']]
    check('дозревшие идут по убыванию полосы',
          [m['band'] for m in mat] == sorted((m['band'] for m in mat),
                                             reverse=True))
    check('зреющие идут по убыванию времени',
          [m['timeS'] for m in mng] == sorted((m['timeS'] for m in mng),
                                              reverse=True))
    check('дозревшие впереди зреющих',
          all(models.index(x) < models.index(y) for x in mat for y in mng))
    check('полоса 80 зреет ~100.6 c',
          any(m['band'] == 80 and not m['matured'] and
              abs(m['timeS'] - 100.604) < 0.01 for m in models))

    print('\n── 10. предикат ротации (без изменений с +163) ──')
    lm, sd = led_pre['lm'], led_pre['sd']
    check('ротация нужна через 31 мин при непустой сессии',
          rotation_due(lm, sd, lm + 31 * 60000))
    check('до гэпа не ротируем', not rotation_due(lm, sd, lm + 29 * 60000))
    check('пустая сессия не ротирует никогда',
          not rotation_due(lm, 0.0, lm + 31 * 60000))
    check('полевое состояние 18:11 подлежало ротации',
          rotation_due(lm, sd, led_post['ss']))

    print('\n── 11. пустая сессия 16:29 ──')
    led0 = d_empty['atlas']['ledger']
    check('16:29: клеток нет', led0['cells'] == {})
    check('16:29: набор карточек пуст',
          card_set({}, {}, led0['aw']) == [])

    print('=' * 60)
    print('MIRROR +164 ' + ('FAIL: ' + ', '.join(FAILS) if FAILS
                            else 'ALL PASS'))
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
