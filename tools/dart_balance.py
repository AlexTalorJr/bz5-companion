#!/usr/bin/env python3
"""Dart-aware bracket balance + missing-import scan (plan §7.2).

Strips comments, strings (incl. raw / multiline / interpolation-aware)
and then checks (), [], {} nesting per file. Interpolation `${...}` is
walked as code, `$ident` is not.

Also reports identifiers that look like top-level symbols used in a file
whose defining library is not imported — a cheap guard for the class of
break that only shows up in kernel_snapshot.
"""
import re
import sys
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent / 'lib'

PAIRS = {')': '(', ']': '[', '}': '{'}
OPEN = set('([{')


def strip_code(src: str) -> str:
    """Return src with comments and string bodies blanked out.

    Interpolated `${ ... }` spans are KEPT (they are code); `$name` is
    dropped. Newlines are preserved so line numbers stay honest.
    """
    out = []
    i, n = 0, len(src)
    # stack of open string delimiters we are inside of
    while i < n:
        c = src[i]
        # ── comments ──
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            depth = 1
            i += 2
            while i < n and depth:
                if src.startswith('/*', i):
                    depth += 1
                    i += 2
                elif src.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    if src[i] == '\n':
                        out.append('\n')
                    i += 1
            continue
        # ── strings ──
        raw = False
        j = i
        if c == 'r' and i + 1 < n and src[i + 1] in '"\'':
            raw = True
            j = i + 1
        q = src[j] if j < n and src[j] in '"\'' else None
        if q:
            triple = src.startswith(q * 3, j)
            delim = q * 3 if triple else q
            k = j + len(delim)
            while k < n:
                if not raw and src[k] == '\\':
                    k += 2
                    continue
                if not raw and src.startswith('${', k):
                    # walk the interpolation as CODE
                    depth = 1
                    k += 2
                    out.append('(')
                    start = k
                    while k < n and depth:
                        if src[k] == '{':
                            depth += 1
                        elif src[k] == '}':
                            depth -= 1
                            if depth == 0:
                                break
                        k += 1
                    out.append(strip_code(src[start:k]))
                    out.append(')')
                    k += 1
                    continue
                if src.startswith(delim, k):
                    k += len(delim)
                    break
                if src[k] == '\n':
                    out.append('\n')
                k += 1
            i = k
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def check_balance(path: Path):
    src = path.read_text(encoding='utf-8')
    code = strip_code(src)
    stack = []
    line = 1
    for ch in code:
        if ch == '\n':
            line += 1
        elif ch in OPEN:
            stack.append((ch, line))
        elif ch in PAIRS:
            if not stack:
                return f'{path.name}: stray {ch!r} at line {line}'
            op, ol = stack.pop()
            if op != PAIRS[ch]:
                return (f'{path.name}: {ch!r} at line {line} closes '
                        f'{op!r} opened at line {ol}')
    if stack:
        op, ol = stack[-1]
        return f'{path.name}: unclosed {op!r} opened at line {ol}'
    return None


# ── missing-import scan ────────────────────────────────────────────
# symbol → the lib-relative file that declares it
DECLARES = {}
DECL_RE = re.compile(
    r'^(?:abstract\s+|sealed\s+|final\s+|base\s+|mixin\s+)*'
    r'(?:class|enum|mixin|extension|typedef)\s+([A-Z]\w*)', re.M)


def build_index(files):
    for f in files:
        for m in DECL_RE.finditer(strip_code(f.read_text(encoding='utf-8'))):
            DECLARES.setdefault(m.group(1), set()).add(f)


def imported_files(f: Path, files):
    src = f.read_text(encoding='utf-8')
    out = {f}
    for m in re.finditer(r"^(?:import|export|part)\s+'([^']+)'", src, re.M):
        rel = m.group(1)
        if rel.startswith('package:') or rel.startswith('dart:'):
            continue
        t = (f.parent / rel).resolve()
        if t.exists():
            out.add(t)
            # one level of part/export transitivity is enough here
            for m2 in re.finditer(r"^(?:export|part)\s+'([^']+)'",
                                  t.read_text(encoding='utf-8'), re.M):
                t2 = (t.parent / m2.group(1)).resolve()
                if t2.exists():
                    out.add(t2)
    return out


def check_imports(f: Path, files):
    code = strip_code(f.read_text(encoding='utf-8'))
    # drop the import block itself
    code = re.sub(r"^(?:import|export|part(?: of)?)\s+'[^']+'.*$", '',
                  code, flags=re.M)
    seen = imported_files(f, files)
    bad = []
    for sym in set(re.findall(r'\b([A-Z]\w{2,})\b', code)):
        homes = DECLARES.get(sym)
        if not homes:
            continue          # SDK / package symbol, or not project-local
        if homes & seen:
            continue
        bad.append((sym, sorted(h.name for h in homes)[0]))
    return bad


# ── unresolved private call scan (v0.1.84+183) ─────────────────────
#
# Dart privacy is LIBRARY-scoped: a `_name` used in a file that owns no
# `part` directive can only be declared in that same file. So a call to
# `_foo(` with no declaration of `_foo` anywhere in the file is a build
# break — nothing else can supply it. This is the Dart twin of the
# kotlinc unresolved-reference baseline, and it exists because +182
# shipped a call to `_parse` that was never written: 533 substring gates
# and a bracket balance cannot see a missing method, and there is no Dart
# compiler in the sandbox.
#
# Files that own a `part` (database.dart → database.g.dart) and part
# files themselves are SKIPPED, not guessed at: their private symbols may
# legitimately live in the generated half, which CI produces and the repo
# does not carry. Skipping is the honest boundary; pretending to resolve
# across it would fail on every codegen symbol.
CALL_RE = re.compile(r'(?<![\w$.])(_[A-Za-z]\w*)\s*\(')
# tokens that mean the thing in front of `_foo(` is NOT a return type
CALL_CTX = {'await', 'return', 'new', 'throw', 'yield', 'if', 'while',
            'for', 'switch', 'assert', 'else', 'case', 'in', 'is', 'as'}


def check_privates(f: Path):
    src = f.read_text(encoding='utf-8')
    if re.search(r'^part\b', src, re.M):
        return []
    code = strip_code(src)
    bad = []
    for name in sorted(set(CALL_RE.findall(code))):
        esc = re.escape(name)
        found = False
        # a declaration reads `<type> _foo(` — some token that is not a
        # call-context keyword sits immediately before the name. Tuple
        # return types end in ')', generics in '>', nullables in '?'.
        for m in re.finditer(r'(?<![\w$.])' + esc + r'\s*\(', code):
            tok = re.search(r'([\w>?\])]+)$', code[:m.start()].rstrip())
            if tok and tok.group(1) not in CALL_CTX:
                found = True
                break
        # class/enum/mixin/typedef name used as a constructor
        if not found and re.search(
                r'\b(?:class|enum|mixin|typedef|extension)\s+' + esc + r'\b',
                code):
            found = True
        # field or local holding a function: `final _foo = (…) {…}`
        if not found and re.search(r'(?<![\w$.])' + esc + r'\s*=', code):
            found = True
        if not found:
            bad.append(name)
    return bad


# ── await outside an async body (v0.1.87+186) ──────────────────────
#
# Written because it happened, in this very patch: an edit landed in the
# WRONG method — `await` in a body declared without `async`, plus a
# reference to a parameter that method does not have. Both are hard
# compile errors; the brace balance was perfect and every substring gate
# was green. Text gates cannot see scope, so scope needs its own check.
#
# The scan is deliberately narrow: it tracks brace depth and, for each
# `{`, decides whether that brace opens a FUNCTION body and whether the
# body is async, by looking at what sits immediately before it. Plain
# blocks (if/for/try) inherit the enclosing function's async-ness, which
# is exactly Dart's rule. Anything it cannot classify inherits too — the
# check is built to under-report rather than to block on a guess.
CTRL = {'if', 'while', 'for', 'switch', 'catch', 'do', 'else', 'return'}


def _opens_function(code: str, brace: int):
    """(is_function_body, is_async) for the `{` at index `brace`.

    Returns (False, _) for a plain block — those inherit the enclosing
    async-ness, which is Dart's own rule. The discriminator is the token
    before the parameter list: `if (...) {` and `foo(...) {` both end in
    `)`, and only the second opens a body.
    """
    i = brace - 1
    while i >= 0 and code[i] in ' \t\n':
        i -= 1
    is_async = False
    for kw in ('async*', 'sync*', 'async'):
        if code.endswith(kw, 0, i + 1):
            is_async = True
            i -= len(kw)
            while i >= 0 and code[i] in ' \t\n':
                i -= 1
            break
    if i < 0 or code[i] != ')':
        return (False, False)
    depth = 0
    while i >= 0:
        if code[i] == ')':
            depth += 1
        elif code[i] == '(':
            depth -= 1
            if depth == 0:
                break
        i -= 1
    if i < 0:
        return (False, False)
    j = i - 1
    while j >= 0 and code[j] in ' \t\n':
        j -= 1
    k = j
    while k >= 0 and (code[k].isalnum() or code[k] == '_' or code[k] == '$'):
        k -= 1
    word = code[k + 1:j + 1]
    if word in CTRL:
        return (False, False)
    return (True, is_async)


def check_await_scope(f: Path):
    code = strip_code(f.read_text(encoding='utf-8'))
    stack = [True]
    bad = []
    line = 1
    i = 0
    while i < len(code):
        c = code[i]
        if c == '\n':
            line += 1
        elif c == '{':
            isfn, isasync = _opens_function(code, i)
            stack.append(isasync if isfn else stack[-1])
        elif c == '}':
            if len(stack) > 1:
                stack.pop()
        elif code.startswith('await ', i) and (i == 0 or
                                               not (code[i - 1].isalnum() or
                                                    code[i - 1] == '_')):
            if not stack[-1]:
                bad.append(line)
            i += 5
        i += 1
    return bad


# ─────────────────────── литеральные аргументы ──────────────────────
#
# v0.1.91+190 — ЧЕТВЁРТЫЙ КЛАСС, КОТОРЫЙ ТЕКСТОВЫЕ ГЕЙТЫ НЕ ЛОВЯТ.
#
# Повод: `mergeTripExtra(int, String)` был позван картой вместо строки.
# Сборка упала на CI, а до неё зелёными были ВСЕ гейты, баланс скобок,
# скан импортов, скан приватных и скан области `await`. Хуже: гейт BV5,
# написанный в том же патче, пиннил вызов ДОСЛОВНО — то есть закрепил
# ошибку компиляции и защищал бы её от исправления.
#
# Полного вывода типов здесь не будет и не должно быть. Ловим узкое и
# частое: аргумент записан ЛИТЕРАЛОМ, а объявленный тип параметра —
# заведомо другого рода. Литерал видно без анализа: `{` это карта или
# множество, `[` список, кавычка строка, цифра число. Сомнительное не
# трогаем — ложное срабатывание здесь дороже пропуска, потому что оно
# учит не доверять скану.
LIT_KIND = {'{': 'map', '[': 'list', "'": 'string', '"': 'string'}

# Пары «объявленный тип → какие литералы для него заведомо чужие».
WRONG = {
    'String': ('map', 'list'),
    'int': ('map', 'list', 'string'),
    'double': ('map', 'list', 'string'),
    'bool': ('map', 'list', 'string'),
    'DateTime': ('map', 'list', 'string'),
}

DECL_RE = re.compile(
    r'(?:Future<[^>]*>|void|int|double|bool|String|DateTime)\s+'
    r'(\w+)\(([^)]*)\)\s*(?:async\s*)?[{=]')


def _split_top(s: str):
    """Разбить по запятым верхнего уровня."""
    out, depth, cur, quote = [], 0, '', None
    for ch in s:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            cur += ch
            continue
        if ch in '([{<':
            depth += 1
        elif ch in ')]}>':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def build_signatures(files):
    """имя метода → список типов позиционных параметров (или None)."""
    sig = {}
    for f in files:
        code = strip_code(f.read_text())
        for m in DECL_RE.finditer(code):
            name, params = m.group(1), m.group(2)
            if '{' in params or '[' in params:
                continue          # именованные/необязательные — пропускаем
            types = []
            ok = True
            for prm in _split_top(params):
                parts = prm.split()
                if len(parts) < 2:
                    ok = False
                    break
                types.append(parts[-2].rstrip('?'))
            if not ok:
                continue
            if name in sig and sig[name] != types:
                sig[name] = None   # перегрузка/тёзка — судить не беремся
            else:
                sig.setdefault(name, types)
    return sig


def check_literal_args(f: Path, sig):
    bad = []
    code = strip_code(f.read_text())
    for m in re.finditer(r'\.(\w+)\(', code):
        name = m.group(1)
        types = sig.get(name)
        if not types:
            continue
        i, depth = m.end(), 1
        while i < len(code) and depth:
            if code[i] in '([{':
                depth += 1
            elif code[i] in ')]}':
                depth -= 1
            i += 1
        args = _split_top(code[m.end():i - 1])
        if len(args) != len(types):
            continue              # именованные/пропуски — не наше дело
        for a, t in zip(args, types):
            kind = LIT_KIND.get(a[:1] if a else '')
            if kind is None and re.match(r'^\d', a or ''):
                kind = 'number'
            if kind and kind in WRONG.get(t, ()):
                ln = code[:m.start()].count('\n') + 1
                bad.append((ln, name, t, kind))
    return bad


def main():
    files = sorted(LIB.rglob('*.dart'))
    print(f'scanning {len(files)} files under lib/')
    fails = []

    for f in files:
        err = check_balance(f)
        if err:
            fails.append(err)
    print(f'  balance: {len(files) - len(fails)}/{len(files)} OK')
    for e in fails:
        print('    [FAIL] ' + e)

    build_index(files)
    miss = 0
    for f in files:
        bad = check_imports(f, files)
        for sym, home in bad:
            print(f'    [FAIL] {f.relative_to(LIB)}: {sym} used but '
                  f'{home} not imported')
            miss += 1
            fails.append(f'{f.name}:{sym}')
    print(f'  imports: {miss} missing')

    priv = 0
    for f in files:
        for name in check_privates(f):
            print(f'    [FAIL] {f.relative_to(LIB)}: {name}() called but '
                  f'never declared in this library')
            priv += 1
            fails.append(f'{f.name}:{name}')
    print(f'  privates: {priv} unresolved')

    aw = 0
    for f in files:
        for ln in check_await_scope(f):
            print(f'    [FAIL] {f.relative_to(LIB)}:{ln}: await inside a '
                  f'body that is not declared async')
            aw += 1
            fails.append(f'{f.name}:await:{ln}')
    print(f'  await scope: {aw} misplaced')

    lit = 0
    sig = build_signatures(files)
    for f in files:
        for ln, name, t, kind in check_literal_args(f, sig):
            print(f'    [FAIL] {f.relative_to(LIB)}:{ln}: {name}() expects '
                  f'{t} here, a {kind} literal is passed')
            lit += 1
            fails.append(f'{f.name}:arg:{ln}')
    print(f'  literal args: {lit} mismatched')

    print('=' * 56)
    print('DART SCAN ' + ('FAIL' if fails else 'PASS'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
