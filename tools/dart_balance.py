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


# ─────────────────── арность записей и nullable-ключи ───────────────
#
# v0.1.92+191 — ПЯТЫЙ И ШЕСТОЙ КЛАССЫ, ОБА ИЗ ОДНОГО ПАДЕНИЯ CI.
#
# Сборка +189 упала четырьмя ошибками, и ни одну не видел ни один текст:
#
#   • подпись `Future<List<(int, String)>>` осталась парой, когда тело
#     стало собирать тройку. Дальше по коду разбор `(id, uuid, at)`
#     пошёл против объявленного, и одна забытая строка дала три ошибки;
#   • `HalSample.name` объявлена `text().nullable()`, то есть `String?`,
#     и была взята ключом карты `Map<String, double>`.
#
# Оба класса узкие и проверяемые без вывода типов. Первый — сравнение
# арности записи в подписи и в типизированном литерале списка внутри
# того же тела. Второй — обращение к полю, чья колонка объявлена
# `.nullable()`, в позиции ключа карты.
REC_RE = re.compile(r'List<\(([^()]*)\)>')
LIT_LIST_RE = re.compile(r'<\(([^()]*)\)>\s*\[\]')


def _arity(inner: str) -> int:
    return len(_split_top(inner))


def check_record_arity(f: Path):
    """Подпись обещает запись одной арности, тело собирает другой."""
    bad = []
    code = strip_code(f.read_text())
    for m in re.finditer(r'^\s*(?:static\s+)?[\w<>,\s?]*?'
                         r'List<\(([^()]*)\)>>?\s+(\w+)\(', code,
                         re.MULTILINE):
        want = _arity(m.group(1))
        # тело — до следующего объявления такого же уровня; берём с
        # запасом и режем по балансу фигурных скобок
        i = code.find('{', m.end())
        if i < 0:
            continue
        depth, j = 0, i
        while j < len(code):
            if code[j] == '{':
                depth += 1
            elif code[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        body = code[i:j]
        for lit in LIT_LIST_RE.finditer(body):
            got = _arity(lit.group(1))
            if got != want:
                ln = code[:i + lit.start()].count('\n') + 1
                bad.append((ln, m.group(2), want, got))
    return bad


def nullable_columns(db: Path):
    """Класс строки drift → имена колонок, объявленных `.nullable()`.

    ПЕРВАЯ РЕДАКЦИЯ СОБИРАЛА ПРОСТО МНОЖЕСТВО ИМЁН и дала три ложных
    срабатывания на `e.name`, где `e` — это `HalEvent` с НЕ-nullable
    полем `name`. Скан сцепился на имени поля, ничего не зная о типе.
    Шумный скан хуже отсутствующего: он учит не доверять отчёту. Поэтому
    имена теперь привязаны к классу строки, а класс — выводится только
    там, где он написан буквально.
    """
    out = {}
    if not db.exists():
        return out
    src = db.read_text()
    for tbl in re.finditer(r'class\s+(\w+)\s+extends\s+Table\s*\{', src):
        name = tbl.group(1)
        i = src.index('{', tbl.start())
        depth, j = 0, i
        while j < len(src):
            if src[j] == '{':
                depth += 1
            elif src[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        body = src[i:j]
        cols = {m.group(1) for m in
                re.finditer(r'get\s+(\w+)\s*=>[^;]*\.nullable\(\)', body)}
        if cols:
            # drift даёт классу строки имя таблицы без конечной `s`
            out[name[:-1] if name.endswith('s') else name] = cols
    return out


def check_nullable_keys(f: Path, by_class):
    """Поле nullable-колонки взято ключом карты.

    Судим ТОЛЬКО когда тип переменной написан рядом буквально: в теле
    есть `List<RowClass> имя` (параметром или локально) и цикл
    `for (final v in имя)`. Всё остальное — не наше дело: гадать о типе
    здесь означает вернуть те самые ложные срабатывания.
    """
    bad = []
    code = strip_code(f.read_text())
    known = {}
    for m in re.finditer(r'List<(\w+)>\s+(\w+)', code):
        if m.group(1) in by_class:
            known[m.group(2)] = m.group(1)
    var_type = {}
    for m in re.finditer(r'for\s*\(\s*final\s+(\w+)\s+in\s+(\w+)\s*\)', code):
        cls = known.get(m.group(2))
        if cls:
            var_type[m.group(1)] = cls
    for m in re.finditer(r'\w+\[\s*(\w+)\.(\w+)\s*\]\s*=', code):
        cls = var_type.get(m.group(1))
        if cls and m.group(2) in by_class.get(cls, ()):
            ln = code[:m.start()].count('\n') + 1
            bad.append((ln, m.group(1), m.group(2)))
    return bad


def _method_bodies(src):
    """Тела методов класса: (имя_класса, имя_метода, текст) по фигурным скобкам.

    Метод опознаётся по объявлению на отступе в два пробела — так устроены
    все наши классы. Точность здесь важнее полноты: пропустить метод значит
    не проверить его, а ошибиться границей значит соврать.
    """
    out = []
    for cm in re.finditer(r'\nclass\s+(\w+)', src):
        cstart = cm.start()
        nxt = re.search(r'\nclass\s+\w+', src[cstart + 1:])
        cend = cstart + 1 + nxt.start() if nxt else len(src)
        body = src[cstart:cend]
        # Объявление метода: отступ ровно два пробела, СИГНАТУРА В ОДНОЙ
        # СТРОКЕ (без переносов и вложенных скобок в параметрах), имя с
        # маленькой буквы или подчёркивания.
        #
        # Первая редакция допускала переносы в типе и параметрах — и
        # регулярка поймала `Card(` внутри чужого тела, приняв вызов
        # виджета за метод. Границы поехали, скан сообщил о переменной
        # `bins` из другого класса. Метод с многострочной сигнатурой теперь
        # просто пропускается: недосмотреть безопаснее, чем соврать.
        for mm in re.finditer(
                r'\n  (?:[\w<>?,\[\]]+\s+)?([a-z_]\w*)'
                r'\([^;{()\n]*\)\s*(?:async\s*)?\{',
                body):
            i = body.index('{', mm.end() - 1)
            depth, j = 0, i
            while j < len(body):
                if body[j] == '{':
                    depth += 1
                elif body[j] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            # Параметры метода связаны в его теле наравне с локальными.
            # Без них скан обвиняет `rows` и `auth`, пришедшие аргументами.
            sig = body[mm.start():i]
            out.append((cm.group(1), mm.group(1), sig, body[i:j + 1]))
    return out


# Имена, которые объявляет не `final x =`, а сам язык или сборка.
_SCOPE_FREE = {
    'context', 'this', 'super', 'widget', 'mounted', 'setState', 'build',
}


def check_local_scope(path):
    """Восьмой скан (+195): имя от провайдера, использованное НЕ В СВОЁМ методе.

    ПОВОД, И ОН ДОРОГОЙ. В +193 объявление `final hist =
    context.watch<PowerHistoryService>()` легло в build ЧУЖОГО класса, а
    использовалось в шести местах другого: правка шла текстовой заменой, и
    `replace(..., 1)` взял первое вхождение якоря. Сборка упала девятью
    ошибками на CI — после того, как ПОЛНАЯ церемония дала зелёный свет.

    Ни один инструмент такого не видел ПО ПОСТРОЕНИЮ. Гейты ищут подстроку в
    ФАЙЛЕ и подтверждают, что объявление и обращение оба присутствуют, — про
    области видимости текст не знает ничего. Мутации доказывают, что гейт
    реагирует на свой предмет, а не что предмет осмыслен. Компилятора Dart в
    песочнице нет и взять негде: `dart` не ставится ни из apt, ни из
    доступных зеркал.

    ПОЧЕМУ СКАН УЗКИЙ. Первая редакция проверяла ЛЮБУЮ локальную переменную
    и утонула в ложных срабатываниях: границы методов текут на многострочных
    сигнатурах, имена связываются деструктуризацией, параметрами, циклами,
    `catch`, замыканиями — каждая пропущенная форма превращается в обвинение
    невиновного. Пять правок подряд убирали одно семейство ложных и
    открывали следующее.

    Поэтому предмет сужен до формы, которая и сломалась: имя, связанное
    через `context.watch<...>()` или `context.read<...>()`. Такое имя всегда
    局 локально, всегда используется через точку и никогда не бывает полем
    класса. Ложных срабатываний тут ждать неоткуда, а именно эта форма
    множится по экранам при каждой перестройке виджетов — то есть ровно там,
    где текстовая правка и промахивается.

    Скан НЕ заменяет компилятор и не претендует на это. Он закрывает один
    класс ошибок — тот, что уже стоил сборки.
    """
    src = strip_code(path.read_text(encoding='utf-8'))
    bodies = _method_bodies(src)
    if not bodies:
        return []

    prov_re = re.compile(r'(?:final|var)\s+(\w+)\s*=\s*context\s*\.\s*'
                         r'(?:watch|read)\s*<')
    decl_re = re.compile(r'(?:final|var|const)\s+(?:[\w<>?,\[\]]+\s+)?(\w+)\s*=')

    # Поля и геттеры класса видны во всех его методах. `(?! )` после двух
    # пробелов обязателен: без него шаблон принимал за поле любое локальное
    # объявление с отступом в четыре, то есть ровно те имена, ради которых
    # скан и написан.
    fields = set(re.findall(
        r'\n  (?! )(?:static\s+)?(?:final\s+|late\s+|const\s+)?'
        r'[\w<>?,\[\]]+\s+(\w+)\s*[=;]', src))
    fields |= set(re.findall(r'\bget\s+(\w+)', src))

    home = {}
    for cls, meth, _sig, body in bodies:
        for name in prov_re.findall(body):
            home.setdefault(name, []).append((cls, meth))

    def params_of(sig):
        # Параметры связаны в теле наравне с локальными: без них скан
        # обвиняет `_errorText(AccountAuthService auth)` в использовании
        # чужого `auth`.
        inner = sig[sig.find('(') + 1:sig.rfind(')')]
        return set(re.findall(r'(\w+)\s*(?:,|$|\}|\])', inner))

    bad = []
    for cls, meth, _sig, body in bodies:
        bound = (set(prov_re.findall(body)) | set(decl_re.findall(body))
                 | params_of(_sig))
        for name, where in home.items():
            if name in bound or name in fields:
                continue
            if re.search(r'(?<![\w$.])' + re.escape(name) + r'\s*\.', body):
                bad.append((cls, meth, name, where[0]))
    return bad


def check_private_fields(path):
    """Девятый скан (+195): приватное ПОЛЕ, которого больше нет.

    Вторая половина той же упавшей сборки. В +193 из состояния карточки
    удалили `_dischargeScale` и `_regenScale`, а строка `scaleLabel` в
    вертикальном экране осталась на них — в широком остаток проверили, в
    вертикальном нет.

    `check_privates` этого не видит: он опознаёт вызов по круглой скобке и
    работает с приватными ФУНКЦИЯМИ. Обращение к полю выглядит иначе, и
    целый класс «удалили поле, забыли потребителя» проходил мимо всех
    инструментов сразу.

    Правило: приватное имя, использованное через точку, обязано быть
    где-то в этом же файле ОБЪЯВЛЕНО. Приватные имена в Дарте видны в
    пределах библиотеки, а наши экраны — по файлу на библиотеку, поэтому
    файла достаточно.
    """
    src = path.read_text(encoding='utf-8')
    if re.search(r'^part\b', src, re.M):
        return []
    code = strip_code(src)
    bad = []
    used = set(re.findall(r'(?<![\w$.])(_[A-Za-z]\w*)\s*\.', code))
    for name in sorted(used):
        esc = re.escape(name)
        declared = (
            # Поле или локальная. Тип не перечисляется посимвольно: у нас
            # встречается `Map<String, ({double value, DateTime at})> _latest`,
            # и любой список допустимых символов такой тип отсекает, объявляя
            # объявленное необъявленным. Достаточно, что имени предшествует
            # конец типа, а следом идёт присваивание или точка с запятой.
            re.search(r'[)>\]}\w]\s+' + esc + r'\s*(?:=|;)', code)
            # геттер
            or re.search(r'\bget\s+' + esc + r'\b', code)
            # поле, инициализируемое конструктором
            or re.search(r'\bthis\.' + esc + r'\b', code)
            # объявление типа с приватным именем
            or re.search(r'\b(?:class|enum|mixin|typedef|extension)\s+'
                         + esc + r'\b', code)
            # функция/метод
            or re.search(r'(?<![\w$.])' + esc + r'\s*\([^)]*\)\s*(?:async\s*)?\{',
                         code)
            # объявление без инициализации: `late final Foo _bar`
            or re.search(r'(?:late|final|static|const)\s+[\w<>?,\[\]]*\s*'
                         + esc + r'\b', code)
        )
        if not declared:
            bad.append(name)
    return bad


def provider_owned_classes():
    """Кого уничтожает провайдер — и, значит, кто ОБЯЗАН убирать за собой.

    Разница не косметическая. `ChangeNotifierProvider<X>(create: ...)` владеет
    объектом и зовёт ему `dispose`, а `.value(value: ...)` — не владеет:
    объект создан до `runApp` и живёт всё время работы приложения. Требовать
    `dispose` от второго бессмысленно (его никто не позовёт), а от первого
    обязательно.

    Гейт стоит на ЖИВОМ пути: список читается из фактического дерева
    провайдеров в main.dart. Зарегистрируй кто-нибудь долгожителя через
    `create:` — скан начнёт требовать уборку с него, и правильно сделает.
    """
    src = strip_code((LIB / 'main.dart').read_text(encoding='utf-8'))
    owned = set()
    for m in re.finditer(r'ChangeNotifierProvider<(\w+)>(\s*\.value)?', src):
        if not m.group(2):
            owned.add(m.group(1))
    return owned


def check_timer_dispose(path, owned):
    """Седьмой скан (+193): периодический таймер обязан сниматься в dispose.

    ПОВОД. +193 заводит `PowerHistoryService` — первый у нас уведомитель,
    который сам держит `Timer.periodic`. Забыть `cancel()` компилятор не
    мешает, подстрочные гейты не видят, а мутация не ловит ПО ПОСТРОЕНИЮ:
    она доказывает реакцию гейта на свой предмет, но не то, что предмет
    лежит на живом пути.

    Симптом же из самых дорогих: при hot restart или пересоздании провайдера
    таймеров становится два, кольцо прокручивается вдвое быстрее, и окно
    графика молча перестаёт равняться заявленному времени. Ни один счётчик
    при этом не краснеет.

    Проверяются только классы, которыми провайдер ВЛАДЕЕТ (см.
    provider_owned_classes) — остальным dispose никто не позовёт.
    """
    src = strip_code(path.read_text(encoding='utf-8'))
    out = []
    marks = [(m.start(), m.group(1)) for m in
             re.finditer(r'\nclass\s+(\w+)', src)]
    for i, (pos, name) in enumerate(marks):
        if name not in owned:
            continue
        end = marks[i + 1][0] if i + 1 < len(marks) else len(src)
        body = src[pos:end]
        if 'Timer.periodic' not in body:
            continue
        m = re.search(r'void\s+dispose\s*\(', body)
        if not m:
            out.append((name, 'нет dispose'))
            continue
        tail = body[m.start():]
        stop = re.search(r'\n  [A-Za-z@]', tail[1:])
        scope = tail[:stop.start()] if stop else tail
        if 'cancel' not in scope:
            out.append((name, 'dispose не снимает таймер'))
    return out


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

    rec = 0
    for f in files:
        for ln, name, want, got in check_record_arity(f):
            print(f'    [FAIL] {f.relative_to(LIB)}:{ln}: {name}() declares a '
                  f'{want}-field record, the body builds {got}')
            rec += 1
            fails.append(f'{f.name}:rec:{ln}')
    print(f'  record arity: {rec} mismatched')

    nk = 0
    nullable = nullable_columns(LIB / 'data' / 'database.dart')
    for f in files:
        for ln, obj, fld in check_nullable_keys(f, nullable):
            print(f'    [FAIL] {f.relative_to(LIB)}:{ln}: {obj}.{fld} is a '
                  f'nullable column and is used as a map key')
            nk += 1
            fails.append(f'{f.name}:nullkey:{ln}')
    print(f'  nullable keys: {nk} unguarded')

    td = 0
    owned = provider_owned_classes()
    for f in files:
        for cls, why in check_timer_dispose(f, owned):
            print(f'    [FAIL] {f.relative_to(LIB)}: {cls} держит '
                  f'Timer.periodic — {why}')
            td += 1
            fails.append(f'{f.name}:timer:{cls}')
    print(f'  timer dispose: {td} leaking')

    ls = 0
    for f in files:
        for cls, meth, name, where in check_local_scope(f):
            print(f'    [FAIL] {f.relative_to(LIB)}: {cls}.{meth}() использует '
                  f'«{name}», объявленное в {where[0]}.{where[1]}()')
            ls += 1
            fails.append(f'{f.name}:scope:{name}')
    print(f'  local scope: {ls} out of scope')

    pf = 0
    for f in files:
        for name in check_private_fields(f):
            print(f'    [FAIL] {f.relative_to(LIB)}: {name} используется, '
                  f'но нигде в файле не объявлено')
            pf += 1
            fails.append(f'{f.name}:field:{name}')
    print(f'  private fields: {pf} unresolved')

    print('=' * 56)
    print('DART SCAN ' + ('FAIL' if fails else 'PASS'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
