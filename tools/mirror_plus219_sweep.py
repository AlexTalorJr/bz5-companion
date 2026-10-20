#!/usr/bin/env python3
"""Зеркало +219: логика стоянки «компрессор» без машины и без Dart.

Повторяет на Python четыре решения патча и прогоняет их на сценариях,
которые иначе проверяются только в машине:

  1. Разбор ответа ELM: кадр `7F xx 78` (подожди) перед настоящим
     ответом снимается, одиночный `7F xx 78` остаётся.
  2. parseTxList: список TX через запятую/пробел, 700..7FF, без повторов.
  3. Пропуск молчащего ECU: 16 молчаний (NO_DATA или TIMEOUT) подряд,
     любой ответ ECU, включая 7F, обнуляет счёт.
  4. Пресеты имён ECU: строятся из реестра, 24 ECU → 10 + 10 + 4.

Константы (порог 16, лимит 10) и реестр читаются из исходников Dart,
поэтому зеркало ломается, если исходник разошёлся с ним.

Запуск из корня репозитория: python3 tools/mirror_plus219_sweep.py
Код возврата 0 — все сценарии сошлись.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path('.')
CONN = (ROOT / 'lib/services/connection.dart').read_text()
REG = (ROOT / 'lib/data/ecu_registry.dart').read_text()

SILENT = int(re.search(r'kSweepSilentEcuProbes = (\d+);', CONN).group(1))
LL_MAX = int(re.search(r'kLiveLogMaxDids = (\d+);', CONN).group(1))

fails = []


def check(name, cond):
    print(f"  [{'OK' if cond else 'FAIL'}] {name}")
    if not cond:
        fails.append(name)


# ── 1. разбор ответа (elm327_client.dart _parse + _assembleIsoTp) ──
def is_pending(frame):
    return (len(frame) >= 8 and frame.startswith('03')
            and frame[2:4] == '7F' and frame[6:8] == '78')


def assemble(frames):
    if not frames:
        return ''
    first = frames[0]
    if first[0] == '0':
        n = int(first[1], 16)
        return first[2:2 + n * 2]
    if first[0] == '1':
        total = int(first[1:4], 16)
        data = first[4:]
        for cf in frames[1:]:
            if cf[:1] == '2':
                data += cf[2:]
        return data[:total * 2]
    return ''.join(frames)


def parse(raw):
    groups = {}
    for line in raw.upper().split('\n'):
        clean = re.sub(r'\s', '', line)
        m = re.match(r'^([0-9A-F]{3})([0-9A-F]+)$', clean)
        if m:
            groups.setdefault(m.group(1), []).append(m.group(2))
    out = {}
    for rx, frames in groups.items():
        while len(frames) > 1 and is_pending(frames[0]):
            frames.pop(0)
        out[rx] = assemble(frames)
    return out


print(f'mirror +219 (порог молчания {SILENT}, лимит Live Log {LL_MAX})')
check('1a pending then answer → answer kept',
      parse('7A3037F2278\n7A305620102A1B3')['7A3'] == '620102A1B3')
check('1b two pendings then answer → answer kept',
      parse('7A3037F2278\n7A3037F2278\n7A3046201021F')['7A3'] == '6201021F')
check('1c pending alone → recorded as 7F2278',
      parse('7A3037F2278')['7A3'] == '7F2278')
check('1d plain NRC 31 untouched',
      parse('7A3037F2231')['7A3'] == '7F2231')
check('1e multi-frame after pending (0105 text) assembled',
      parse('7A3037F2278\n7A3100A6201054142\n7A32143444546474849')['7A3']
      == '62010541424344454647')


# ── 2. parseTxList ──
def parse_tx_list(text):
    items = [t.strip().upper() for t in re.split(r'[\s,;]+', text) if t.strip()]
    if not items:
        return None
    out = []
    for t in items:
        if len(t) != 3:
            return None
        try:
            n = int(t, 16)
        except ValueError:
            return None
        if n < 0x700 or n > 0x7FF:
            return None
        if t not in out:
            out.append(t)
    return out


check('2a mixed separators', parse_tx_list('732, 760 777;786') ==
      ['732', '760', '777', '786'])
check('2b duplicates dropped, order kept',
      parse_tx_list('7f1,701,7F1') == ['7F1', '701'])
check('2c out of range rejected', parse_tx_list('732, 690') is None)
check('2d 4-digit rejected', parse_tx_list('0732') is None)
check('2e empty rejected', parse_tx_list(' , ') is None)


# ── 3. пропуск молчащего ECU ──
def run(codes):
    n = 0
    for i, c in enumerate(codes):
        n = n + 1 if c in ('NO_DATA', 'TIMEOUT') else 0
        if n >= SILENT:
            return 'silent_ecu', i + 1
    return 'completed', len(codes)


check('3a all 7F2231 → completed over full range',
      run(['7F2231'] * 256) == ('completed', 256))
check(f'3b dead ECU → stop after {SILENT} rows',
      run(['TIMEOUT'] * 256) == ('silent_ecu', SILENT))
check('3c sparse timeouts never stop',
      run((['TIMEOUT'] * (SILENT - 1) + ['7F2231']) * 20)[0] == 'completed')
check(f'3e NO_DATA (usual silence) → stop after {SILENT} rows',
      run(['NO_DATA'] * 256) == ('silent_ecu', SILENT))
check('3f NO_DATA and TIMEOUT mixed still count as one run',
      run(['NO_DATA', 'TIMEOUT'] * 128) == ('silent_ecu', SILENT))
check('3d EMPTY resets the count',
      run((['TIMEOUT'] * (SILENT - 1) + ['EMPTY']) * 20)[0] == 'completed')

# ── 4. пресеты имён из реестра ──
entries = re.findall(
    r"EcuRegistryEntry\(txId: '([0-9A-F]{3})', rxId: '([0-9A-F]{3})', "
    r"label: '[^']*'(, detailed: \w+)?\)", REG)
unnamed = [(tx, rx) for tx, rx, d in entries if not d]
chunks = [unnamed[i:i + LL_MAX] for i in range(0, len(unnamed), LL_MAX)]
check('4a registry has 30 ECUs, 24 unnamed',
      len(entries) == 30 and len(unnamed) == 24)
check('4b chunks 10 + 10 + 4', [len(c) for c in chunks] == [10, 10, 4])
check('4c every RX = TX + 8',
      all(int(rx, 16) == int(tx, 16) + 8 for tx, rx in unnamed))
for i, c in enumerate(chunks):
    print(f'     identity {i + 1}/3: {" ".join(tx for tx, _ in c)}')

print(f'{"PASS" if not fails else "FAIL"} — {len(fails)} failed')
sys.exit(1 if fails else 0)
