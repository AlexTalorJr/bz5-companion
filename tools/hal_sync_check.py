#!/usr/bin/env python3
"""HAL shared-code sync check (v0.1.29+61).

Two jobs:

  1. Validate the vendoring contract for the 5 files copied from bz5_recon.
     The manifest (android/.../hal/HAL_SYNC.manifest) lists the version and
     the 5 recon-source SHAs. For each file:
       - ABSENT  → WARN "not yet vendored" (so this passes in a clone that
                   hasn't copied them; the human vendors per the manifest)
       - PRESENT → its checksum header must declare the manifest version
                   and the manifest SHA, and the package line must match.
     Note: the header SHA is the recon SOURCE hash (provenance), not a hash
     of the companion copy (which has a different package line + header), so
     we verify the DECLARED SHA against the manifest, not a recomputed one.

  2. Validate the companion-authored glue contract that doesn't depend on
     the vendored bodies being present:
       - DecodedStreamSink: onDataChanged-only note, no manual pack_current
         arithmetic, drain off the binder thread (main-looper post).
       - Plugin: dedicated HAL EventChannel, start requires a sink,
         streamingTargets() used (8 targets, not take(64)).
       - Dart wrapper: listen-before-start contract, batch flattening.

Run from repo root: python3 tools/hal_sync_check.py
Exit 1 on any FAIL. WARNs do not fail (pre-vendor state is legal).
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HAL_DIR = ROOT / 'android/app/src/main/kotlin/com/bz5companion/bz5_companion/hal'
MANIFEST = HAL_DIR / 'HAL_SYNC.manifest'
PLUGIN = (ROOT /
          'android/app/src/main/kotlin/com/bz5companion/bz5_companion/BydNativePlugin.kt')
SINK = HAL_DIR / 'DecodedStreamSink.kt'
DART = ROOT / 'lib/services/hal_telemetry_channel.dart'
PKG = 'package com.bz5companion.bz5_companion.hal'

_fail = []
_warn = []
_ok = 0


def _strip_comments(src):
    """Drop // line comments and /* */ blocks so a literal mentioned in a
    comment (e.g. 'no (raw-5018)*0.1021') doesn't trip an arithmetic-leak
    scan. Crude but sufficient — we only need it for substring checks."""
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'//[^\n]*', '', src)
    return src


def ok(m):
    global _ok
    _ok += 1


def warn(m):
    _warn.append(m)


def fail(m):
    _fail.append(m)


def parse_manifest():
    """Return (default_version, {filename: (sha, version)}).

    v0.1.29+107: each file line may carry its OWN version string after the
    SHA — `<file>.kt  <sha64>  <version...>`. This is required because the
    vendored files no longer share a single recon version (the 5 original
    files are p078; the BZ3 engine is p100/v0.10.79). A line WITHOUT a
    trailing version falls back to the manifest-wide `version:` line, so the
    older 5-line format still parses unchanged.
    """
    if not MANIFEST.exists():
        fail("HAL_SYNC.manifest missing")
        return None, {}
    default_version = None
    files = {}
    for ln in MANIFEST.read_text().splitlines():
        ln = ln.strip()
        if not ln or ln.startswith('#'):
            continue
        if ln.startswith('version:'):
            default_version = ln.split(':', 1)[1].strip()
            continue
        if ln.startswith('commit:'):
            continue
        # <file>.kt  <sha64>  [optional per-line version string]
        m = re.match(r'^(\S+\.kt)\s+([0-9a-f]{64})(?:\s+(.+))?$', ln)
        if m:
            per_line_ver = m.group(3).strip() if m.group(3) else None
            files[m.group(1)] = (m.group(2), per_line_ver)
    return default_version, files


def check_vendoring():
    default_version, files = parse_manifest()
    if default_version is None:
        fail("manifest has no version: line")
        return
    # v0.1.29+107: 6 vendored files — the original 5 (recon p078) plus the
    # BZ3 engine Bz3TelemetrySubscriber.kt (recon p100 / v0.10.79).
    if len(files) != 6:
        fail(f"manifest lists {len(files)} files, expected 6")
        return
    ok(f"manifest: default version {default_version}, 6 files")

    for fname, (sha, per_line_ver) in files.items():
        # the version this file's header must declare: its own if given,
        # else the manifest-wide default.
        ver = per_line_ver or default_version
        path = HAL_DIR / fname
        if not path.exists():
            warn(f"{fname} not yet vendored — copy per HAL_SYNC.manifest")
            continue
        body = path.read_text()
        # header must declare this file's version and SHA, package must match
        if ver not in body:
            fail(f"{fname} header missing version '{ver}'")
        elif f"SHA256: {sha}" not in body:
            fail(f"{fname} header SHA mismatch (expected manifest {sha[:12]}…)")
        elif PKG not in body:
            fail(f"{fname} wrong package (expected {PKG})")
        else:
            ok(f"{fname} vendored with matching header ({ver})")


def check_sink():
    if not SINK.exists():
        fail("DecodedStreamSink.kt missing")
        return
    s = SINK.read_text()
    # onDataChanged-only contract documented
    if 'onDataChanged' in s and 'de-dupe' in s.lower() or 'dedup' in s.lower():
        ok("sink documents the onDataChanged-only / no-dedup contract")
    else:
        warn("sink: onDataChanged-only contract note not found")
    # no manual pack_current arithmetic on the HAL path (ignore comments —
    # the contract note literally spells out the forbidden formula)
    _code = _strip_comments(s)
    if '5018' in _code or '0.1021' in _code:
        fail("sink applies OBD2 arithmetic on HAL path (must NOT — HAL is "
             "pre-decoded)")
    else:
        ok("sink: no manual pack_current arithmetic on HAL path")
    # must not block binder thread — drains via main looper
    if 'Handler(Looper.getMainLooper())' in s and '.post' in s:
        ok("sink drains on the main looper (binder thread not blocked)")
    else:
        fail("sink: no main-looper drain — binder thread may block / "
             "EventSink touched off-main")
    # detach makes late callbacks no-op
    if 'fun detach()' in s and 'sink = null' in s:
        ok("sink: detach() nulls the sink (late binder callbacks no-op)")
    else:
        fail("sink: no detach() guard")
    # DecodedValue mapping resolved against the real shape (Q4 closed):
    # key built via the table's public helpers, no stale dv.key access.
    if 'TelemetryDecoderTable.key(' in s and 'normalizeTargetKey(' in s:
        ok("sink: DecodedValue mapping resolved (canonical key via helpers)")
    elif 'VERIFY-ON-VENDOR' in s:
        warn("sink: DecodedValue still flagged VERIFY-ON-VENDOR (unresolved)")
    else:
        warn("sink: DecodedValue mapping not confirmed")

    # sink override signatures must match the vendored TelemetrySink — a
    # guessed signature compiles to "overrides nothing" and breaks CI (this
    # is exactly what bit onTargetEvent first time). Only enforce once the
    # interface is actually vendored.
    sink_iface = HAL_DIR / 'TelemetrySink.kt'
    if sink_iface.exists():
        iface = sink_iface.read_text()
        iface_funs = dict(re.findall(r'fun\s+(\w+)\s*\(([^)]*)\)', iface, re.S))
        sink_funs = dict(
            re.findall(r'override\s+fun\s+(\w+)\s*\(([^)]*)\)', s, re.S))

        def _norm(p):
            return re.sub(r'\s+', ' ', p).strip().rstrip(',').strip()

        bad = []
        for fn, params in sink_funs.items():
            if fn not in iface_funs:
                bad.append(f"{fn} (not on interface)")
            elif _norm(params) != _norm(iface_funs[fn]):
                bad.append(f"{fn} params differ")
        if bad:
            fail(f"sink override mismatch vs TelemetrySink: {bad}")
        else:
            ok("sink: overrides match the vendored TelemetrySink signatures")


def check_plugin():
    if not PLUGIN.exists():
        fail("BydNativePlugin.kt missing")
        return
    s = PLUGIN.read_text()
    if 'CHANNEL_HAL_EVENTS = "bz5_companion/hal_telemetry/events"' in s:
        ok("plugin: dedicated HAL event channel constant")
    else:
        fail("plugin: HAL event channel constant missing")
    if '"halStreamStart"' in s and '"halStreamStop"' in s:
        ok("plugin: halStreamStart/Stop dispatch wired")
    else:
        fail("plugin: halStream dispatch missing")
    if 'HAL_NO_SINK' in s:
        ok("plugin: start requires a listening sink (HAL_NO_SINK guard)")
    else:
        fail("plugin: no HAL_NO_SINK guard")
    # v0.1.83+182: ПРЕДМЕТ ПЕРЕЕХАЛ, И ГЕЙТ ПЕРЕЕХАЛ ЗА НИМ.
    #
    # Сборка набора целей ушла из плагина в HalStreamOwner — ровно затем,
    # чтобы сервис автозапуска не держал свою копию. Гейт по-прежнему
    # проверяет то же самое утверждение («восемь целей, а не take(64)»),
    # но в том файле, где оно теперь живёт. Ослабить его до «где-нибудь в
    # дереве» было бы нельзя: это тот самый класс, что мутационный
    # харнесс поймал у BF5 — проверка, проходящая за счёт постороннего
    # кода.
    _own_p = (ROOT / 'android/app/src/main/kotlin/com/bz5companion/'
              'bz5_companion/hal/HalStreamOwner.kt')
    _own = _own_p.read_text() if _own_p.exists() else ''
    if 'TargetRegistry.streamingTargets(ctx)' in _own:
        ok("owner: uses streamingTargets() (8 targets, not take(64))")
    else:
        fail("owner: streamingTargets() not used")
    # teardown on cancel + detach
    if 'stopHalStream()' in s and 'fun stopHalStream()' in s:
        ok("plugin: stopHalStream teardown present")
    else:
        fail("plugin: stopHalStream teardown missing")


def check_dart():
    if not DART.exists():
        fail("hal_telemetry_channel.dart missing")
        return
    s = DART.read_text()
    if "EventChannel('bz5_companion/hal_telemetry/events')" in s:
        ok("dart: subscribes to the dedicated HAL event channel")
    else:
        fail("dart: wrong/missing HAL event channel")
    if 'listen FIRST' in s or 'after a listener' in s.lower() or \
       'after attaching a listener' in s.lower():
        ok("dart: listen-before-start contract documented")
    else:
        warn("dart: listen-before-start contract note not found")
    if '.expand<HalEvent>' in s:
        ok("dart: flattens platform batches to a flat HalEvent stream")
    else:
        fail("dart: batch flattening missing")
    _dcode = _strip_comments(s)
    if '5018' in _dcode or '0.1021' in _dcode:
        fail("dart: OBD2 arithmetic leaked onto the HAL path")
    else:
        ok("dart: no OBD2 arithmetic on HAL path")


def main():
    check_vendoring()
    check_sink()
    check_plugin()
    check_dart()
    for w in _warn:
        print(f"  [WARN] {w}")
    for f in _fail:
        print(f"  [FAIL] {f}")
    print(f"HAL sync: PASS {_ok} · WARN {len(_warn)} · FAIL {len(_fail)}")
    sys.exit(1 if _fail else 0)


if __name__ == '__main__':
    main()
