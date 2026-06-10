#!/usr/bin/env python3
"""v0.1.29+60: find `S.of(` calls that sit inside a `const Constructor(...)`
span — a guaranteed Dart compile error ("Invalid constant value") that the
sandbox can't catch because Dart isn't available here. Walks every
`const Identifier(` occurrence, finds the matching close paren (with
string literals masked so parens inside strings don't break matching),
and flags any `S.of(` inside the span. Also flags `S.of(` inside
`children: const [ ... ]` style const list literals.

Run from repo root: python3 tools/const_l10n_check.py  → exit 1 on hits.
"""
import re
import sys
import pathlib


def mask_strings_and_comments(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j == -1 else j
            out.append(' ' * (j - i))
            i = j
        elif c in ("'", '"'):
            q = c
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == q:
                    j += 1
                    break
                j += 1
            out.append(q + ' ' * (j - i - 2) + q if j - i >= 2 else src[i:j])
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def find_close(masked: str, open_idx: int, open_ch: str, close_ch: str) -> int:
    depth = 0
    for j in range(open_idx, len(masked)):
        if masked[j] == open_ch:
            depth += 1
        elif masked[j] == close_ch:
            depth -= 1
            if depth == 0:
                return j
    return -1


def check_file(path: pathlib.Path):
    src = path.read_text()
    if 'S.of(' not in src:
        return []
    masked = mask_strings_and_comments(src)
    hits = []
    # const Constructor( ... )
    for m in re.finditer(r'\bconst\s+[A-Z][A-Za-z0-9_]*(?:<[^>(]*>)?\s*\(', masked):
        close = find_close(masked, m.end() - 1, '(', ')')
        if close == -1:
            continue
        if 'S.of(' in masked[m.end():close]:
            line = src.count('\n', 0, m.start()) + 1
            hits.append((line, src[m.start():m.start() + 40].split('\n')[0]))
    # const [ ... ]  (const list literals, e.g. children: const [)
    for m in re.finditer(r'\bconst\s*\[', masked):
        close = find_close(masked, m.end() - 1, '[', ']')
        if close == -1:
            continue
        if 'S.of(' in masked[m.end():close]:
            line = src.count('\n', 0, m.start()) + 1
            hits.append((line, 'const [ ...'))
    return hits


def main():
    root = pathlib.Path('lib')
    bad = False
    for f in sorted(root.rglob('*.dart')):
        hits = check_file(f)
        for line, ctx in hits:
            print(f"FAIL {f}:{line}: S.of inside const span: {ctx}")
            bad = True
    if not bad:
        print("OK: no S.of calls inside const spans")
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
