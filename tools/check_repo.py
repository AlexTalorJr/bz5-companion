#!/usr/bin/env python3
"""
bz5-companion repository sanity check.

A formalised regression suite. Lives in the repo (not in transient
Claude session context) so it survives sessions and can be run by:

  - The author (anyone) locally before committing:  python3 tools/check_repo.py
  - GitHub Actions (if re-enabled in lint.yml):     python3 tools/check_repo.py
  - Claude before delivering any patch:             python3 tools/check_repo.py

It encodes lessons from the v0.1.29.x series:

  +3   pubspec ↔ imports parity        (silent CI failure)
  +5   null-safety promotion loss      (type-promotion break)
  +9   version triple-sync             (pubspec / cloud_sync / diag)
  +10  Android permission ↔ feature    (silent runtime failure)
  +13  layout math for grid sizing     (catches misconfigured aspect)

It does NOT replicate `flutter analyze` (too noisy, see v0.1.29+12 for
why we disabled the lint workflow). It catches the specific classes
of regression that we've personally been burned by — high signal,
zero noise.

Exit codes:
  0  all checks passed
  1  one or more checks failed (CI should treat as red)
  2  could not run (missing pubspec.yaml — not in a Flutter project root)
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from typing import Callable

# ─────────────────────────────────────────────────────────────────
# Discovery
# ─────────────────────────────────────────────────────────────────


def find_repo_root() -> Path:
    """Walk up from cwd looking for pubspec.yaml. Exit 2 if not found."""
    cur = Path.cwd().resolve()
    for d in (cur, *cur.parents):
        if (d / "pubspec.yaml").is_file():
            return d
    print("ERROR: no pubspec.yaml found from", cur, file=sys.stderr)
    print("       run this from inside the bz5-companion repo", file=sys.stderr)
    sys.exit(2)


# ─────────────────────────────────────────────────────────────────
# Dart text utilities
# ─────────────────────────────────────────────────────────────────


def strip_dart(text: str) -> str:
    """Remove Dart comments and string contents while preserving brackets.

    Used to compute bracket balance without false positives from braces
    inside string literals or comments. Handles `$ {expr}` interpolation
    by counting the contained brackets.
    """
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        # // line comment
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        # /* block comment */
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i < n - 1 and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        # string literal
        if c in "\"'":
            quote = c
            i += 1
            while i < n and text[i] != quote:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == "\n":
                    break
                # ${...} interpolation: keep the inside since it's code
                if text[i] == "$" and i + 1 < n and text[i + 1] == "{":
                    out.append("$")
                    i += 1
                    out.append(text[i])  # {
                    depth = 1
                    i += 1
                    while i < n and depth > 0:
                        if text[i] == "{":
                            depth += 1
                        elif text[i] == "}":
                            depth -= 1
                        out.append(text[i])
                        i += 1
                    continue
                i += 1
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def brace_balance(text: str) -> dict[str, int]:
    """Return delta for each bracket pair after stripping strings/comments."""
    bal = {"()": 0, "[]": 0, "{}": 0}
    for ch in strip_dart(text):
        if ch == "(":
            bal["()"] += 1
        elif ch == ")":
            bal["()"] -= 1
        elif ch == "[":
            bal["[]"] += 1
        elif ch == "]":
            bal["[]"] -= 1
        elif ch == "{":
            bal["{}"] += 1
        elif ch == "}":
            bal["{}"] -= 1
    return bal


# ─────────────────────────────────────────────────────────────────
# Individual checks
# ─────────────────────────────────────────────────────────────────


class CheckResult:
    """One check's outcome: list of error strings + list of info strings."""

    def __init__(self, name: str):
        self.name = name
        self.errors: list[str] = []
        self.info: list[str] = []

    def err(self, msg: str) -> None:
        self.errors.append(msg)

    def ok(self, msg: str) -> None:
        self.info.append(msg)

    @property
    def passed(self) -> bool:
        return not self.errors

    def report(self) -> None:
        glyph = "✓" if self.passed else "✗"
        print(f"  [{glyph}] {self.name}")
        for line in self.info:
            print(f"        {line}")
        for line in self.errors:
            print(f"        ERROR: {line}")


def check_brace_balance(root: Path) -> CheckResult:
    """All .dart files under lib/ must have balanced brackets.

    Catches truncated edits (a leading char lost during str_replace), missing
    closers, accidental deletions. Cheap to run on every file.
    """
    r = CheckResult("Brace balance on all lib/*.dart files")
    n_files = 0
    for f in sorted((root / "lib").rglob("*.dart")):
        n_files += 1
        bal = brace_balance(f.read_text(encoding="utf-8"))
        if any(v != 0 for v in bal.values()):
            r.err(f"{f.relative_to(root)}: {bal}")
    r.ok(f"checked {n_files} files")
    return r


def check_pubspec_imports_parity(root: Path) -> CheckResult:
    """Every `import 'package:X/...'` must have X in pubspec dependencies.

    Lesson from v0.1.28+1 → v0.1.29+3: CloudSyncService imported
    flutter_secure_storage and http; neither was in pubspec dependencies.
    CI failed silently at kernel snapshot with FileSystemException for
    three consecutive builds before the hotfix landed.
    """
    r = CheckResult("pubspec.yaml ↔ lib/ package imports parity")

    pubspec = (root / "pubspec.yaml").read_text(encoding="utf-8")
    declared: set[str] = set()
    in_deps = False
    for line in pubspec.splitlines():
        if line.startswith("dependencies:"):
            in_deps = True
            continue
        if line.startswith(("dev_dependencies:", "flutter:", "environment:")):
            in_deps = False
            continue
        if in_deps:
            m = re.match(r"  ([a-z][a-z0-9_]*)\s*:", line)
            if m:
                declared.add(m.group(1))
    # flutter is built-in (sdk: flutter)
    declared.add("flutter")

    imports_used: set[str] = set()
    for f in (root / "lib").rglob("*.dart"):
        for line in f.read_text(encoding="utf-8").splitlines():
            m = re.match(r"import\s+'package:([a-z][a-z0-9_]*)/", line)
            if m:
                imports_used.add(m.group(1))

    missing = imports_used - declared
    unused = declared - imports_used - {"flutter"}
    if missing:
        r.err(f"used but not declared: {sorted(missing)}")
    r.ok(f"{len(imports_used)} packages imported, {len(declared) - 1} in pubspec")
    if unused:
        # Not an error, just informational — pubspec drift after refactor.
        r.ok(f"declared but unused (consider removing): {sorted(unused)}")
    return r


def check_version_triple_sync(root: Path) -> CheckResult:
    """pubspec version == cloud_sync._readAppVersion == dashboard._kDiagVersion.

    Lesson from v0.1.29+1: cloud_sync_service.dart `_readAppVersion`
    is a hard-coded string. Bumping pubspec without updating it makes
    the heartbeat report a stale version, polluting bridge admin UI.
    Until package_info_plus is added (see P5 in ROADMAP.md) the three
    locations must be hand-synced.

    `_kDiagVersion` is also hard-coded for the same reason and lives
    in dashboard.dart since v0.1.29+6.
    """
    r = CheckResult("Version triple-sync (pubspec / cloud_sync / _kDiagVersion)")
    pubspec = (root / "pubspec.yaml").read_text(encoding="utf-8")
    m_pub = re.search(r"^version:\s*(\S+)", pubspec, re.M)
    if not m_pub:
        r.err("pubspec.yaml has no `version:` line")
        return r
    ver_pub = m_pub.group(1)

    cs_path = root / "lib" / "services" / "cloud_sync_service.dart"
    if not cs_path.exists():
        r.err("lib/services/cloud_sync_service.dart not found")
        return r
    cs = cs_path.read_text(encoding="utf-8")
    m_cs = re.search(r"_readAppVersion\(\)\s*async\s*=>\s*'([0-9.+]+)'", cs)
    if not m_cs:
        r.err("cloud_sync_service.dart: cannot find _readAppVersion return string")
        return r
    ver_cs = m_cs.group(1)

    # _kDiagVersion is optional (only present since v0.1.29+6). If it's
    # there, it should match (after stripping the leading 'v' prefix
    # that's added for UI readability).
    dash_path = root / "lib" / "screens" / "dashboard.dart"
    ver_diag: str | None = None
    if dash_path.exists():
        m_diag = re.search(
            r"_kDiagVersion\s*=\s*'([^']+)'", dash_path.read_text(encoding="utf-8")
        )
        if m_diag:
            ver_diag = m_diag.group(1).lstrip("v")

    r.ok(f"pubspec={ver_pub}  cloud_sync={ver_cs}  diag={ver_diag or '(not present)'}")
    if ver_pub != ver_cs:
        r.err(f"pubspec '{ver_pub}' != cloud_sync._readAppVersion '{ver_cs}'")
    if ver_diag is not None and ver_pub != ver_diag:
        r.err(f"pubspec '{ver_pub}' != _kDiagVersion '{ver_diag}'")
    return r


def check_android_permissions_vs_features(root: Path) -> CheckResult:
    """Specific feature ↔ permission pairings the project depends on.

    Lesson from v0.1.28+1 → v0.1.29+10: CloudSyncService used package:http
    without INTERNET permission in AndroidManifest. APK built, installed,
    and ran fine — until the first network call returned errno=7 host
    lookup failed. Nine versions shipped broken before field discovery.

    We hard-code the known pairings rather than trying to infer them from
    code (which would be unreliable). When adding a new system-resource
    feature, add an entry here.
    """
    r = CheckResult("Android permissions ↔ Flutter features pairings")
    manifest_path = root / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    if not manifest_path.exists():
        r.ok("no AndroidManifest.xml — skip (running outside Android project?)")
        return r
    manifest = manifest_path.read_text(encoding="utf-8")

    # Each entry: (feature_present_check, required_permissions, why)
    pairings = [
        (
            "package:http",
            ["android.permission.INTERNET"],
            "package:http needs INTERNET — without it: errno=7 host lookup failed",
        ),
        (
            "package:flutter_blue_plus",
            [
                "android.permission.BLUETOOTH_SCAN",
                "android.permission.BLUETOOTH_CONNECT",
            ],
            "flutter_blue_plus on Android 12+ needs BLUETOOTH_SCAN + BLUETOOTH_CONNECT",
        ),
    ]

    any_feature_seen = False
    for needle, perms, why in pairings:
        feature_used = False
        for f in (root / "lib").rglob("*.dart"):
            if needle in f.read_text(encoding="utf-8"):
                feature_used = True
                break
        if not feature_used:
            continue
        any_feature_seen = True
        for p in perms:
            if p not in manifest:
                r.err(f"feature '{needle}' is used but '{p}' missing — {why}")
            else:
                r.ok(f"'{needle}' present → '{p.split('.')[-1]}' declared")
    if not any_feature_seen:
        r.ok("no networking/BLE features detected (or none of the known pairs)")
    return r


def check_null_safety_guard_hazard(root: Path) -> CheckResult:
    """Heuristic: `final hasX = Y != null; ... hasX ? ... Y.method() ...`

    Lesson from v0.1.29+4 → v0.1.29+5: the dashboard_wide.dart had
    `final hasTemp = temp != null;` then someone changed it to
    `final hasTemp = tempForColor != null;`. Downstream code did
    `hasTemp ? ... temp.toStringAsFixed(0) ...` which used to be safe
    via Dart's type promotion but lost that property when the guard
    changed which variable it was checking. CI build #76 failed at
    kernel snapshot.

    Heuristic: when a `final hasX = Y != null;` exists, and the guard
    variable name (`hasX`) doesn't relate to the checked variable
    (`Y`) — flag any downstream `hasX ? ... Y.something ...` pattern.

    Excludes the safe `final hasX = Y != null && Y.method != null`
    chain pattern, where the guard explicitly null-checks Y itself.
    """
    r = CheckResult("Null-safety guard variable / checked variable hazard")
    n_files = 0
    for f in (root / "lib").rglob("*.dart"):
        n_files += 1
        text = f.read_text(encoding="utf-8")
        # Match the full guard line so we can inspect everything on its RHS.
        for guard_m in re.finditer(
            r"final\s+(\w+)\s*=\s*(\w+)\s*!=\s*null([^;]*);",
            text,
        ):
            guard_name = guard_m.group(1)
            guarded_var = guard_m.group(2)
            guard_tail = guard_m.group(3)  # rest of the RHS expression
            # Skip if the names obviously align
            if guard_name == guarded_var:
                continue
            stripped = guard_name.removeprefix("has").removeprefix("is")
            if stripped.lower() == guarded_var.lower():
                continue
            # Safe pattern: `Y != null && Y.something ...` — the guard
            # also null-checks the same variable used downstream. Dart's
            # flow analysis handles this correctly.
            if re.search(rf"&&\s*{re.escape(guarded_var)}\.", guard_tail):
                continue
            # Now look for ` guard_name ? ... guarded_var.method ` pattern
            # within a reasonable distance — typical Dart guard usage is
            # inside the same expression / few lines.
            for m in re.finditer(
                rf"\b{re.escape(guard_name)}\s*\?[^:]{{0,300}}?\b{re.escape(guarded_var)}\.",
                text,
            ):
                snippet = m.group(0).replace("\n", " ")[:80]
                r.err(
                    f"{f.relative_to(root)}: `{guard_name}` guards `{guarded_var} != null` "
                    f"but downstream deref `{guarded_var}.` is reachable: '{snippet}…'"
                )
    r.ok(f"checked {n_files} files")
    return r


def check_layout_math_bz3(root: Path) -> CheckResult:
    """Verify the BZ3 tall-portrait grid sizing makes physical sense.

    Lesson from v0.1.29+1 → v0.1.29+7 → v0.1.29+13: layout sizing
    was wrong twice. First the threshold for "tall portrait" didn't
    fire at all (wrong dpr assumption). Then the grid was too tall
    (wrong aspect ratio assumption).

    The current threshold is `width >= 720 && height >= 1000`.
    The current grid aspect ratio is 4.5 on 3-col (tall).
    The current _MetricCard compact mode trigger is maxHeight < 70.

    Math (BZ3 reports 720×1106 dp):
      Card width = (720 - 2×16 list padding - 2×8 grid gap) / 3 = 224 dp
      Card height @ aspect 4.5 = 224 / 4.5 ≈ 49.8 dp
      Compact threshold = 70 dp, so 49.8 < 70 → compact fires ✓
    """
    r = CheckResult("BZ3 tall-portrait layout math")
    dash_path = root / "lib" / "screens" / "dashboard.dart"
    if not dash_path.exists():
        r.ok("dashboard.dart not found — skip")
        return r
    dash = dash_path.read_text(encoding="utf-8")

    # Tall portrait detector thresholds
    m_h = re.search(r"mq\.size\.height\s*>=\s*(\d+)", dash)
    m_w = re.search(r"mq\.size\.width\s*>=\s*(\d+)", dash)
    if not (m_h and m_w):
        r.err("can't find tall-portrait detector in dashboard.dart")
        return r
    thr_h = int(m_h.group(1))
    thr_w = int(m_w.group(1))
    r.ok(f"detector: width >= {thr_w}, height >= {thr_h}")
    # BZ3 measured: 720 × 1106
    if not (720 >= thr_w and 1106 >= thr_h):
        r.err(f"BZ3 (720×1106) fails detector — tall layout would NOT fire")

    # Grid aspect ratio for 3-col (tall portrait)
    m_aspect = re.search(
        r"childAspectRatio:\s*crossAxisCount\s*==\s*3\s*\?\s*([\d.]+)\s*:\s*([\d.]+)",
        dash,
    )
    if not m_aspect:
        r.err("can't find 3-col vs 2-col aspect ratio expression")
        return r
    aspect_3col = float(m_aspect.group(1))
    aspect_2col = float(m_aspect.group(2))
    r.ok(f"aspect ratios: 3-col={aspect_3col}, 2-col={aspect_2col}")

    # Compute card height on BZ3
    card_w = (720 - 32 - 16) / 3  # 224
    card_h = card_w / aspect_3col
    r.ok(f"BZ3 3-col card: {card_w:.0f}×{card_h:.1f} dp")

    # Compact threshold
    m_thr = re.search(r"constraints\.maxHeight\s*<\s*(\d+)", dash)
    if m_thr:
        compact_thr = int(m_thr.group(1))
        r.ok(f"_MetricCard compact threshold: maxHeight < {compact_thr}")
        # Sanity: BZ3 card height must trigger compact, phone must not
        if card_h >= compact_thr:
            r.err(
                f"BZ3 card height {card_h:.1f} >= compact threshold {compact_thr} — "
                "compact mode WILL NOT fire, grid will be too tall"
            )
        phone_w = (412 - 32 - 8) / 2  # ~186
        phone_h = phone_w / aspect_2col
        if phone_h < compact_thr:
            r.err(
                f"Phone card height {phone_h:.1f} < compact threshold {compact_thr} — "
                "compact mode WOULD fire on phone (unintended)"
            )
        else:
            r.ok(f"phone card height {phone_h:.1f} > {compact_thr} → compact stays off ✓")

    return r


def check_no_protected_file_modification(root: Path) -> CheckResult:
    """Reminder check — protected files should only change with explicit user OK.

    This is the closest we can get to enforcing the CLAUDE.md rule. We
    don't have git history available here; instead we flag protected
    files only if they appear corrupted in obvious ways (zero size,
    leading whitespace before class keyword, etc.).

    Real defence is: read CLAUDE.md, ask before touching them. This
    check is just a last-line tripwire.
    """
    r = CheckResult("Protected files structural sanity")
    protected = [
        "lib/services/connection.dart",
        "lib/services/elm327_ble.dart",
        "lib/data/database.dart",
    ]
    for p in protected:
        path = root / p
        if not path.exists():
            r.ok(f"{p}: not present (skipped)")
            continue
        text = path.read_text(encoding="utf-8")
        if len(text) < 100:
            r.err(f"{p}: suspiciously small ({len(text)} chars) — corruption?")
            continue
        # Must contain at least one class declaration
        if "class " not in text:
            r.err(f"{p}: no class declarations found — likely truncated")
            continue
        r.ok(f"{p}: looks structurally intact ({len(text)} chars)")
    return r


# ─────────────────────────────────────────────────────────────────
# Driver
# ─────────────────────────────────────────────────────────────────


CHECKS: list[Callable[[Path], CheckResult]] = [
    check_brace_balance,
    check_pubspec_imports_parity,
    check_version_triple_sync,
    check_android_permissions_vs_features,
    check_null_safety_guard_hazard,
    check_layout_math_bz3,
    check_no_protected_file_modification,
]


def main() -> int:
    root = find_repo_root()
    print(f"bz5-companion check_repo.py — root: {root}")
    print()

    results: list[CheckResult] = []
    for fn in CHECKS:
        try:
            res = fn(root)
        except Exception as e:
            res = CheckResult(fn.__name__)
            res.err(f"check raised {type(e).__name__}: {e}")
        results.append(res)
        res.report()
        print()

    n_fail = sum(1 for r in results if not r.passed)
    if n_fail:
        print(f"FAIL — {n_fail} of {len(results)} checks did not pass")
        return 1
    print(f"PASS — all {len(results)} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
