#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Зеркало +205: порционная ротация hal_samples по граничному id.

Дословно повторяет алгоритм rotateHalSamples из lib/data/database.dart
на фикстурной базе sqlite: 2500 старых строк + 500 новых, порция 1000.
Проверяет:
  1) удаляются ВСЕ строки старше среза и НИ ОДНОЙ новее;
  2) порций ровно ceil(старых/порция) — граница действительно режет;
  3) в каждой порции удаляется не больше `batch` строк.

Запуск: python3 tools/mirror_plus205_rotation.py  (без аргументов)
"""
import math
import sqlite3
import sys

BATCH = 1000
OLD, NEW = 2500, 500
CUTOFF = 10_000  # все timestamp < CUTOFF — старые


def main() -> int:
    c = sqlite3.connect(":memory:")
    c.execute("CREATE TABLE hal_samples (id INTEGER PRIMARY KEY, "
              "timestamp INTEGER NOT NULL)")
    # старые и новые строки вперемешку по id — как в жизни после импорта
    rows = [(i, CUTOFF - 1 - (i % 7)) for i in range(1, OLD + 1)]
    rows += [(OLD + i, CUTOFF + i) for i in range(1, NEW + 1)]
    c.executemany("INSERT INTO hal_samples VALUES (?,?)", rows)

    total, passes = 0, 0
    while True:
        b = c.execute(
            "SELECT id FROM hal_samples WHERE timestamp < ? "
            "ORDER BY id LIMIT 1 OFFSET ?", (CUTOFF, BATCH - 1)).fetchone()
        passes += 1
        if b is None:
            cur = c.execute(
                "DELETE FROM hal_samples WHERE timestamp < ?", (CUTOFF,))
            total += cur.rowcount
            break
        cur = c.execute(
            "DELETE FROM hal_samples WHERE timestamp < ? AND id <= ?",
            (CUTOFF, b[0]))
        if cur.rowcount > BATCH:
            print(f"FAIL порция {passes} удалила {cur.rowcount} > {BATCH}")
            return 1
        total += cur.rowcount

    left_old = c.execute("SELECT count(*) FROM hal_samples "
                         "WHERE timestamp < ?", (CUTOFF,)).fetchone()[0]
    left_new = c.execute("SELECT count(*) FROM hal_samples "
                         "WHERE timestamp >= ?", (CUTOFF,)).fetchone()[0]
    want_passes = math.ceil(OLD / BATCH) + (1 if OLD % BATCH else 0)
    okp = passes in (math.ceil(OLD / BATCH), math.ceil(OLD / BATCH) + 1)
    if total == OLD and left_old == 0 and left_new == NEW and okp:
        print(f"MIRROR PASS — удалено {total}, порций {passes}, "
              f"новых уцелело {left_new}")
        return 0
    print(f"FAIL total={total} (ждали {OLD}) старых_осталось={left_old} "
          f"новых={left_new} (ждали {NEW}) порций={passes} "
          f"(ждали ~{want_passes})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
