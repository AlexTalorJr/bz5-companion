#!/usr/bin/env python3
"""Зеркало +193: арифметика окна графика мощности.

Чистая математика, данных не требует. Повторяет `powerSlotsFor` и
`powerBarWidthFor` из `lib/services/power_history_service.dart` и проверяет
то, ради чего снят прежний зажим ширины: столбик обязан быть НЕ ШИРЕ шага,
иначе столбики налезают друг на друга, а шаг обязан быть целым в пикселях,
иначе однопиксельный столбик размазывается сглаживанием.
"""
import sys

RING = 1024
FAIL = []


def check(cond, msg):
    print(('  [PASS] ' if cond else '  [FAIL] ') + msg)
    if not cond:
        FAIL.append(msg)


def slots_for(width_dp, dpr):
    s = int(width_dp * dpr / 2)
    return 24 if s < 24 else (RING if s > RING else s)


def bar_width_for(dpr):
    return 1.0 / (1.0 if dpr <= 0 else dpr)


# имя, ширина полосы в dp, dpr, замерен ли dpr
#
# Берутся ДВА края для каждого экрана: вся ширина (потолок запроса) и
# правдоподобная ширина полосы внутри карточки с отступами. Кольцо обязано
# накрывать первый, иначе зажим срабатывает и шаг перестаёт быть двумя
# пикселями.
SCREENS = [
    ('BZ3 вся ширина', 720.0, 1.5, True),
    ('BZ3 полоса', 656.0, 1.5, True),
    ('BZ5 вся ширина', 2175.0, 0.875, False),
    ('BZ5 полоса', 690.0, 0.875, False),
    ('телефон', 412.0, 2.625, True),
]


def main():
    print('экран      ширина dp   dpr     слотов   шаг dp   шаг px  '
          'ширина столбика dp   окно')
    for name, w, dpr, measured in SCREENS:
        n = slots_for(w, dpr)
        pitch_dp = w / n
        pitch_px = pitch_dp * dpr
        bar = bar_width_for(dpr)
        window = n  # 1 Гц → один слот равен секунде
        mm = f'{window // 60} мин {window % 60:02d} с'
        print(f'{name:<10} {w:>9.0f}   {dpr:<6} {n:>6}   {pitch_dp:>6.3f}'
              f'   {pitch_px:>6.2f}   {bar:>16.3f}   {mm}'
              + ('' if measured else '   (dpr выведен)'))
        check(bar < pitch_dp,
              f'{name}: столбик ({bar:.3f} dp) уже шага ({pitch_dp:.3f} dp) — '
              f'столбики не налезают')
        check(abs(pitch_px - 2.0) < 0.01,
              f'{name}: шаг ровно два физических пикселя ({pitch_px:.2f})')
        # ГЛАВНАЯ проверка размера кольца: зажим не должен СРАБАТЫВАТЬ.
        # `n <= RING` выполняется всегда по построению `slots_for` и не
        # доказывает ничего — первая редакция зеркала проверяла именно это и
        # пропустила кольцо в 512, на котором зажим упирался на всех трёх
        # экранах.
        raw = int(w * dpr / 2)
        check(raw <= RING,
              f'{name}: кольцо накрывает запрос без зажима '
              f'({raw} ≤ {RING})')

    print()
    # Прежний зажим clamp(1.5, 6.0) и был блокировщиком: проверяем это
    # числом, а не на слово.
    # Прежний зажим `clamp(1.5, 6.0)` был блокировщиком ТАМ, ГДЕ ШАГ УЖЕ
    # 1.5 dp, — то есть на плотных экранах. Утверждать «перекрытие везде»
    # было бы сильнее данных: на BZ5 при dpr 0.875 шаг широкий, и зажим там
    # не мешал. Проверяем ровно то, что верно.
    for name, w, dpr, _ in SCREENS:
        n = slots_for(w, dpr)
        pitch_dp = w / n
        old_bar = min(max(pitch_dp * 0.7, 1.5), 6.0)
        if pitch_dp < 1.5:
            check(old_bar > pitch_dp,
                  f'{name}: прежний зажим дал бы {old_bar:.2f} dp при шаге '
                  f'{pitch_dp:.3f} — перекрытие, и это был блокировщик')
        else:
            print(f'  [ok  ] {name}: шаг {pitch_dp:.3f} dp широкий, прежний '
                  f'зажим здесь не мешал')

    print()
    check(slots_for(0, 1.5) == 24, 'нулевая ширина не даёт ноль слотов')
    check(slots_for(1e6, 3.0) == RING, 'огромная ширина не превышает кольцо')
    check(bar_width_for(0) == 1.0, 'нулевой dpr не роняет деление')

    print('=' * 60)
    print('MIRROR FAIL' if FAIL else 'MIRROR PASS')
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
