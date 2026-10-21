#!/usr/bin/env python3
"""Зеркало +220: канал BLE и повтор DID, без машины.

Воспроизводит на Python (asyncio) три решения патча и прогоняет их на
сценариях из экспорта sweep_8 (21.10):

  1. Один запрос за раз: вызывающий бросил запрос по своему таймауту
     1,5 с, транспорт ждал до 4 с. Раньше поздний ответ попадал в буфер
     следующего запроса (TIMEOUT + 2×NULL_RESPONSE на 01F0/025A). Теперь
     следующий запрос ждёт завершения предыдущего.
  2. Предел на платформенную запись: зависшая запись помечает транспорт
     «заклиненным», следующие запросы падают сразу, connect() снимает флаг.
  3. Повтор DID: один раз после TIMEOUT / NULL_RESPONSE / MISALIGNED,
     никогда после 7F / NO_DATA / EMPTY; клин завершает прогон.

Константы читаются из исходников Dart.
Запуск из корня репозитория: python3 tools/mirror_plus220_channel.py
"""
import asyncio
import pathlib
import re
import sys

ROOT = pathlib.Path('.')
BLE = (ROOT / 'lib/ble/elm327_ble.dart').read_text()
CONN = (ROOT / 'lib/services/connection.dart').read_text()
WRITE_TIMEOUT = int(re.search(r'kWriteTimeout = Duration\(seconds: (\d+)\)', BLE).group(1))
SILENT = int(re.search(r'kSweepSilentEcuProbes = (\d+);', CONN).group(1))

fails = []


def check(name, cond):
    print(f"  [{'OK' if cond else 'FAIL'}] {name}")
    if not cond:
        fails.append(name)


# ── модель транспорта (elm327_ble.dart) ──
class Wedged(Exception):
    pass


class Transport:
    """Время в модели — секунды asyncio; адаптер отвечает через delay."""

    def __init__(self, serialize=True, bounded=True):
        self.serialize = serialize
        self.bounded = bounded
        self.inflight = None
        self.buffer = []
        self.wedged = False
        self.adapter_tasks = []
        self.write_hang = False

    def connect(self):
        self.wedged = False

    async def _adapter(self, payload, delay):
        await asyncio.sleep(delay)
        self.buffer.append(f'RESP({payload})')
        self.buffer.append('>')

    async def _send_now(self, payload, delay, timeout):
        if self.wedged:
            raise Wedged()
        self.buffer.clear()
        # платформенная запись
        if self.write_hang:
            if self.bounded:
                await asyncio.sleep(WRITE_TIMEOUT)
                self.wedged = True
                raise Wedged()
            await asyncio.sleep(10_000)
        self.adapter_tasks.append(asyncio.create_task(self._adapter(payload, delay)))
        waited = 0.0
        while '>' not in self.buffer:
            await asyncio.sleep(0.05)
            waited += 0.05
            if waited >= timeout:
                raise asyncio.TimeoutError()
        return [b for b in self.buffer if b != '>']

    def send_raw(self, payload, delay, timeout=4.0):
        prev = self.inflight  # хвост на момент вызова — как _inflight в Dart

        async def run():
            if self.serialize and prev is not None:
                try:
                    await prev
                except Exception:
                    pass
            return await self._send_now(payload, delay, timeout)
        task = asyncio.create_task(run())

        async def done():
            try:
                await task
            except Exception:
                pass
        self.inflight = asyncio.create_task(done())
        return task

    async def wait_idle(self, timeout=5.0):
        if self.inflight is None:
            return
        try:
            await asyncio.wait_for(asyncio.shield(self.inflight), timeout)
        except Exception:
            pass


async def caller(tr, payload, delay):
    """Sweep-подобный вызывающий: свой таймаут 1,5 с."""
    try:
        return await asyncio.wait_for(asyncio.shield(tr.send_raw(payload, delay)), 1.5)
    except asyncio.TimeoutError:
        return 'TIMEOUT'
    except Wedged:
        return 'WEDGED'


async def scenario_desync(serialize):
    tr = Transport(serialize=serialize)
    a = await caller(tr, 'A', 1.6)   # ECU медлит → вызывающий бросает в 1,5 с
    if serialize:
        await tr.wait_idle()
    b = await caller(tr, 'B', 0.2)
    c = await caller(tr, 'C', 0.2)
    for t in tr.adapter_tasks:
        t.cancel()
    return a, b, c


async def scenario_wedge():
    tr = Transport()
    tr.write_hang = True
    a = await caller(tr, 'A', 0.1)
    await tr.wait_idle()
    wedged_after = tr.wedged
    b = await caller(tr, 'B', 0.1)
    tr.connect()
    tr.write_hang = False
    c = await caller(tr, 'C', 0.1)
    return a, wedged_after, b, c


async def run_async():
    print(f'mirror +220 (предел записи {WRITE_TIMEOUT} с, порог молчания {SILENT})')
    old = await scenario_desync(serialize=False)
    check('1a без сериализации: B получает ответ A, C — ответ B (сдвиг sweep_8 воспроизведён)',
          old[0] == 'TIMEOUT' and old[1] == ['RESP(A)'] and old[2] == ['RESP(B)'])
    new = await scenario_desync(serialize=True)
    check('1b с сериализацией: после TIMEOUT и waitIdle B и C получают свои ответы',
          new[0] == 'TIMEOUT' and new[1] == ['RESP(B)'] and new[2] == ['RESP(C)'])
    w = await scenario_wedge()
    check('2a зависшая запись: вызывающий видит TIMEOUT, транспорт заклинен после waitIdle',
          w[0] == 'TIMEOUT' and w[1] is True)
    check('2b следующий запрос падает сразу как WEDGED', w[2] == 'WEDGED')
    check('2c connect() снимает клин', w[3] == ['RESP(C)'])


asyncio.run(run_async())


# ── повтор DID (connection.dart, цикл попыток) ──
def retryable(code):
    return code in ('TIMEOUT', 'NULL_RESPONSE') or (code or '').startswith('MISALIGNED:')


def probe(attempts, wedged_after_first=False):
    """attempts: исходы попыток; возвращает (записанный код, причина выхода)."""
    for i, code in enumerate(attempts[:2]):
        if wedged_after_first and i == 0:
            return 'BLE_WEDGED', 'ble_wedged'
        if i == 0 and retryable(code) and len(attempts) > 1:
            continue
        return code, None
    return attempts[0], None


check('3a TIMEOUT, затем 7F2231 → записан 7F2231', probe(['TIMEOUT', '7F2231']) == ('7F2231', None))
check('3b NULL_RESPONSE, затем OK → записан OK', probe(['NULL_RESPONSE', None]) == (None, None))
check('3c MISALIGNED, затем OK → записан OK', probe(['MISALIGNED:2795≠000D:62279501', None]) == (None, None))
check('3d TIMEOUT дважды → TIMEOUT (считается молчанием)', probe(['TIMEOUT', 'TIMEOUT']) == ('TIMEOUT', None))
check('3e 7F2231 не повторяется', probe(['7F2231', None]) == ('7F2231', None))
check('3f NO_DATA не повторяется', probe(['NO_DATA', None]) == ('NO_DATA', None))
check('3g клин после первой попытки → exit=ble_wedged без второй',
      probe(['TIMEOUT', None], wedged_after_first=True) == ('BLE_WEDGED', 'ble_wedged'))

print(f'{"PASS" if not fails else "FAIL"} — {len(fails)} failed')
sys.exit(1 if fails else 0)
