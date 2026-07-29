#!/usr/bin/env python3
"""A1 — тождество «замороженное ⊕ живое == сессионный счётчик».

ЗАЧЕМ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ. Проверка жила не в репозитории, а в голове
Друга 1 и переписывалась ad-hoc на каждом разборе. 29.07 это выстрелило:
на двух дампах подряд она показала расхождение 120 секунд и была подана
как аномалия данных. Данные были в порядке — сломана была проверка.

ЧТО ИМЕННО БЫЛО СЛОМАНО. Тождество связывает две величины с разной
живучестью:

  * `session.bands` — накопление по поездке, ПЕРЕЖИВАЕТ смерть процесса.
  * `atlas.ledger.cells` — поля `fe/fd/ft` (замороженная доля) живут в
    памяти процесса. Когда клетка дозревает, её доля уезжает в
    `atlas_snapshots`, а при следующем рождении процесса леджер
    восстанавливается из базы уже БЕЗ неё.

Пока замороженное лежит в `ft`, суммы сходятся. Как только процесс
перезапустился после заморозки, леджер про эту долю больше не знает, а
счётчик поездки продолжает её считать — и разница равна ровно
сброшенному. Поле 29.07 показало это буквально: два дампа с `Σft=240.5`
сходились до 8.5e-14, следующие два, уже в новом процессе, расходились
на 240.5 с. Данные были целы, снимков стало 19 → 21.

Ловить этот случай по расхождению окон атласной сессии и поездки НЕЛЬЗЯ,
хотя соблазн есть: окна расходятся и там, где тождество прекрасно
держится (дампы 14:54 и 15:25 — расхождение окон 4854 с, суммы сходятся
до 8.5e-14). Такой критерий пропускал бы всё, а инструмент, который
всегда пропускает, бесполезнее отсутствующего.

КРИТЕРИЙ ПРИМЕНИМОСТИ, воспроизводящий все четыре наблюдения. Дампы
группируются по `session.startedAtMs`; самый ранний в группе даёт базовое
число снимков. Дальше:

  сброшено = snapshots_in_db − базовое
  сброшено == 0            → тождество применимо (леджеру нечего забывать)
  сброшено > 0 и Σft > 0    → применимо (сброшенное ещё в памяти)
  сброшено > 0 и Σft == 0   → ПРОПУСК: леджер забыл сброшенное

ОГРАНИЧЕНИЕ, которое надо знать. На ОДИНОЧНОМ дампе базовое число снимков
неизвестно, берётся его же — то есть «сброшено = 0», и забывший леджер
будет ошибочно объявлен нарушением. Нужно минимум два дампа одной
поездки; инструмент об этом предупреждает сам. Полностью снять
ограничение может только сверка со `snapshots.csv` из экспорта, где есть
`steady_seconds` по снимкам, — это следующий шаг, если понадобится.

Запуск: python3 tools/atlas_a1_check.py [файл.md ...]
Без аргументов берёт bz5_companion_diag*.md из /mnt/user-data/uploads.
Код возврата: 0 — нарушений нет, 1 — есть, 2 — нечего проверять.
"""
import json
import re
import sys
from pathlib import Path

UP = Path('/mnt/user-data/uploads')

# Порог, ниже которого расхождение считается арифметикой double, а не
# расхождением. Наблюдённый максимум на честных дампах — 8.5e-14 при
# суммах порядка 150; берём запас, но не бесконечный: 1e-9 всё ещё на
# много порядков меньше любой физически значимой доли секунды.
EPS = 1e-9


def load_dumps(paths):
    out = []
    for p in paths:
        txt = Path(p).read_text()
        for m in re.finditer(r'```json\n(\{.*?\})\n```', txt, re.S):
            try:
                j = json.loads(m.group(1))
            except Exception:
                continue
            if j.get('schema') == 'speed_profile_diag_v1':
                out.append((Path(p).name, j))
    return out


def frozen_in_memory(ledger):
    """Сколько замороженного времени леджер ещё держит в памяти."""
    return sum(c.get('ft', 0.0) for c in ledger['cells'].values())


def baselines(dumps):
    """Базовое число снимков на начало каждой поездки.

    Ключ — `session.startedAtMs`: он переживает смерть процесса, поэтому
    дампы одной поездки группируются им надёжно. Базовым берём самый
    ранний дамп группы по `dumped_at`.
    """
    best = {}
    for _, j in dumps:
        key = int(j['session']['startedAtMs'])
        when = j.get('dumped_at', '')
        if key not in best or when < best[key][0]:
            best[key] = (when, j['atlas']['snapshots_in_db'])
    return {k: v[1] for k, v in best.items()}, {
        k: sum(1 for _, j in dumps
               if int(j['session']['startedAtMs']) == k)
        for k in best
    }


def aggregate(cells):
    """Свернуть клетки в полосы: живое ⊕ замороженное."""
    agg = {}
    for key, c in cells.items():
        band = int(key.split(':')[0])
        e, d, t = agg.get(band, (0.0, 0.0, 0.0))
        agg[band] = (
            e + c['e'] + c.get('fe', 0.0),
            d + c['d'] + c.get('fd', 0.0),
            t + c['t'] + c.get('ft', 0.0),
        )
    return agg


def check_dump(name, j, base_snapshots, group_size):
    """→ (статус, худшее расхождение, текст). Статус: ok|skip|fail."""
    session, atlas = j['session'], j['atlas']
    ledger = atlas.get('ledger')
    when = j.get('dumped_at', '?')[11:19]
    if not ledger or not ledger.get('cells'):
        return 'skip', 0.0, f'{name} {when}: леджер пуст — нечего сверять'

    flushed = atlas['snapshots_in_db'] - base_snapshots
    held = frozen_in_memory(ledger)
    if flushed > 0 and held == 0.0:
        return 'skip', 0.0, (
            f'{name} {when}: ПРОПУСК — за поездку сброшено {flushed} '
            f'снимков, а в леджере ft=0: процесс перезапускался, и о '
            f'сброшенном времени леджер больше не знает. Счётчик поездки '
            f'его считает, леджер нет — тождество к этой паре не '
            f'относится'
        )

    agg = aggregate(ledger['cells'])
    worst, worst_txt = 0.0, ''
    for band in sorted(agg):
        counter = session['bands'].get(str(band))
        if counter is None:
            return 'fail', float('inf'), (
                f'{name} {when}: полоса {band} есть в леджере, но её нет '
                f'в сессионном счётчике'
            )
        e, d, t = agg[band]
        for label, got, want in (('t', t, counter['t']),
                                 ('e', e, counter['e']),
                                 ('d', d, counter['d'])):
            delta = abs(got - want)
            if delta > worst:
                worst, worst_txt = delta, f'полоса {band}, {label}'
    if worst > EPS:
        note = ''
        if group_size < 2:
            note = (' · ВНИМАНИЕ: дамп этой поездки один, базовое число '
                    'снимков неизвестно — возможен ложный вердикт, '
                    'нужен второй дамп')
        return 'fail', worst, (
            f'{name} {when}: A1 НАРУШЕН — {worst_txt}, расхождение '
            f'{worst:.3e} при допуске {EPS:.0e}{note}'
        )
    return 'ok', worst, (
        f'{name} {when}: A1 точен по {len(agg)} полосам, худшее '
        f'{worst:.1e}'
    )


def main():
    args = sys.argv[1:]
    paths = args or sorted(str(p) for p in UP.glob('bz5_companion_diag*.md'))
    if not paths:
        print('нет дампов для проверки — укажи файл аргументом')
        return 2
    dumps = load_dumps(paths)
    if not dumps:
        print('в указанных файлах нет замерных дампов')
        return 2

    print(f'замерных дампов: {len(dumps)}')
    base, sizes = baselines(dumps)
    counts = {'ok': 0, 'skip': 0, 'fail': 0}
    for name, j in dumps:
        key = int(j['session']['startedAtMs'])
        status, _, text = check_dump(name, j, base[key], sizes[key])
        counts[status] += 1
        mark = {'ok': '[OK]  ', 'skip': '[SKIP]', 'fail': '[FAIL]'}[status]
        print(f'  {mark} {text}')

    print()
    print(f"A1: точно {counts['ok']} · пропущено {counts['skip']} · "
          f"нарушено {counts['fail']}")
    if counts['fail']:
        print('РАСХОЖДЕНИЕ РЕАЛЬНОЕ — это не область применения, это данные')
        return 1
    if not counts['ok']:
        print('ни один дамп не попал в область применения — тождество '
              'не проверено ни разу')
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
