#!/usr/bin/env python3
"""Мутационная проверка гейтов regress_plus35.py.

ЗАЧЕМ ЭТОТ ИНСТРУМЕНТ СУЩЕСТВУЕТ. Зелёный гейт не значит ничего, пока
не показано, что он умеет краснеть. За окно №8 эта проверка поймала три
вещи, которых не видел никто другой: гейт, проходивший на пустом месте
(вакуумный), гейт, ронявший ВЕСЬ прогон исключением через `.index()`, и
пять гейтов, читавших собственные пояснения вместо кода. Ни один из
трёх не отличался от исправного, пока предмет проверки стоял на месте.

Правило, которое инструмент реализует: **каждый гейт обязан упасть от
отката своего предмета — и упасть именно он**.

ПОЧЕМУ ОН ЛЕЖИТ В РЕПОЗИТОРИИ, А НЕ В ПЕСОЧНИЦЕ. Первая редакция жила
в `/home/claude/mutate.py` и умерла вместе с окном №8 — 39 мутаций,
покрывавших эры BF–BK, пришлось восстанавливать с нуля по телам гейтов
(7206 строк). Дыра в передаче стоила дороже самого инструмента: без
него нельзя выполнить правило выше, а именно оно и держит качество
харнесса. Больше он из репозитория не уходит.

ДВА ПРЕДОХРАНИТЕЛЯ, И ОБА ВЫСТРЕЛИЛИ В ОКНЕ №8.

  1. **Анкер обязан встречаться РОВНО ОДИН РАЗ.** Иначе `str.replace`
     молча правит несколько мест, мутация оказывается шире задуманной,
     и красный гейт ничего не доказывает — он мог упасть от чужой
     правки. Ноль вхождений хуже вдвое: правка не применяется вообще,
     гейт остаётся зелёным, и это читается как «гейт слепой», хотя
     слепа была мутация. Оба случая → `SETUP-FAIL`, а не `FAIL`.

  2. **Падение прогона целиком — это CRASH, а не FAIL.** Гейт, роняющий
     `regress_plus35.py` исключением, не даёт НИ ОДНОЙ строки отчёта, и
     снаружи это выглядит точно как «предмет удалён, гейт покраснел».
     Разница принципиальная: в первом случае сломан инструмент, во
     втором он сработал. Именно так в +170 нашёлся гейт с `.index()`.

Мутации намеренно НЕ обязаны оставлять код компилируемым: копия живёт
в /tmp секунды, и её читает только текстовый харнесс. Обязаны они
другое — откатывать ПРЕДМЕТ гейта, а не косметику вокруг него. Правка
пробела сломала бы совпадение подстроки и дала бы зелёный отчёт о
красном гейте, ничего не проверив: это доказывает хрупкость проверки,
а не её зоркость.

Запуск из корня репозитория:
    python3 tools/mutate_gates.py            # все мутации
    python3 tools/mutate_gates.py BH BI      # только эры BH и BI
    python3 tools/mutate_gates.py BL3        # одна мутация

Код возврата 0 — все мутации подтвердились, 1 — есть подтверждённо
слепой гейт, SETUP-FAIL или CRASH.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path('.').resolve()

KT = 'android/app/src/main/kotlin/com/bz5companion/bz5_companion/'
AS_ = KT + 'AutostartService.kt'
BR = KT + 'BootReceiver.kt'
MK = KT + 'AutostartMarker.kt'
PF = KT + 'AutostartPrefs.kt'
MA = KT + 'MainActivity.kt'
AI = KT + 'ApkInstall.kt'
FP = KT + 'ApkFileProvider.kt'
MF = 'android/app/src/main/AndroidManifest.xml'
ES = 'lib/services/export_service.dart'
AG = 'lib/widgets/atlas_grid.dart'
DP = 'lib/widgets/driver_panels.dart'
SC = 'lib/screens/install_update.dart'
ST = 'lib/screens/settings.dart'
L10 = 'lib/l10n/strings.dart'
ARM = 'lib/services/autostart_arm.dart'
A1 = 'tools/atlas_a1_check.py'
CH = 'lib/services/apk_install_channel.dart'

# (гейт, файл, анкер, замена, что откатывает)
#
# Замена откатывает ПРЕДМЕТ гейта. Где предмет — отсутствие чего-то
# (BF1 «нет фонового startActivity», BJ5 «ложного обоснования нет»),
# мутация это что-то возвращает; где предмет — наличие, убирает.
MUTATIONS = [
    # ─── эра BF (+169) «Автостарт, шаг 1» ───────────────────────────
    ('BF1', AS_,
     '            stopSelf()',
     '            startActivity(Intent(this, MainActivity::class.java))\n'
     '            stopSelf()',
     'вернуть фоновый запуск активити, который BAL режет молча'),
    ('BF2', AS_,
     '"resurrected: headless flags=$flags · ${ident()}"',
     '"resurrected: launch=attempted-no-throw · ${ident()}"',
     'вернуть маркеру ложное утверждение о попытке запуска'),
    ('BF3', AS_,
     'buildNotification(resurrected || bridged)',
     'buildNotification(resurrected)',
     'отрезать путь моста от нотификации'),
    ('BF4', AS_,
     'buildNotification(headless: Boolean = false)',
     'buildNotification(resurrected: Boolean = false)',
     'вернуть имя признака, описывавшее один путь из двух'),
    ('BF5', MK,
     'getPackageInfo(context.packageName, 0).versionName',
     'packageName.let { null }',
     'снять чтение versionName — строки станут не привязаны к сборке'),

    # ─── эра BG (+170) «Маркер доезжает» ────────────────────────────
    ('BG1', MK,
     'File(context.filesDir, FILE_NAME).appendText(text)',
     'File("/sdcard/Download/$FILE_NAME").appendText(text)',
     'убрать вторую ступень записи — журнал снова в одном мёртвом месте'),
    ('BG2', ES,
     "ArchiveFile('autostart_marker.txt'",
     "ArchiveFile('autostart_marker_off.txt'",
     'разорвать пару имён — приватная копия не доедет экспортом'),
    ('BG3', AG,
     'Icon(Icons.star,\n                    size: m.starSize,',
     'Icon(Icons.circle,\n                    size: m.starSize,',
     'убрать звезду покрытия из клетки атласа'),
    ('BG4', DP,
     '    return FittedBox(',
     '    return Column(  // FittedBox снят\n    if (false) FittedBox(',
     'снять масштабирование ячейки — подпись поедет на разделитель'),

    # ─── эра BH (+171) «Мост автозапуска» ───────────────────────────
    ('BH1', MF,
     'android:name=".BootReceiver"',
     'android:name=".BootReceiverOff"',
     'убрать объявление ресивера из манифеста'),
    ('BH2', BR,
     '            raiseService(context, action)',
     '            scheduleBridge(context, action)',
     'сломать двухступенчатость: alarm-ветка больше не поднимает сервис'),
    ('BH3', AS_,
     '"bridged: $ACTION_BRIDGE',
     '"armed: $ACTION_BRIDGE',
     'сделать подъём мостом неотличимым от открытого владельцем'),
    ('BH4', BR,
     'result=NOT_ARMED',
     'result=IDLE',
     'снять след отказа по флагу взвода'),
    ('BH5', AS_,
     'private fun marker(line: String) = AutostartMarker.write(this, line)',
     'private fun marker(line: String) =\n'
     '        java.io.File(filesDir, "svc.txt").appendText(line)',
     'вернуть сервису свою лестницу записи — журнал раздваивается'),
    ('BH6', AS_,
     'marker("born: ${ident()} build=${appVersion()}")',
     'marker("born: up=${android.os.SystemClock.uptimeMillis()}'
     ' ${ident()} build=${appVersion()}")',
     'вернуть дубль пары up/el в строку born'),
    ('BH7', BR,
     'exact=${if (exact) "yes" else "no"}',
     'exact=yes',
     'сделать потерю точного будильника молчаливой'),
    ('BH8', MF,
     '    <uses-permission android:name='
     '"android.permission.RECEIVE_BOOT_COMPLETED" />',
     '    <!-- proven wall on this firmware -->\n'
     '    <uses-permission android:name='
     '"android.permission.RECEIVE_BOOT_COMPLETED" />',
     'вернуть в манифест снятое утверждение про стену boot-пути'),

    # ─── эра BI (+172) «Путь установки» ─────────────────────────────
    ('BI1', MF,
     'android:grantUriPermissions="true"',
     'android:grantUriPermissions="false"',
     'снять грант URI — установщик не сможет прочитать файл'),
    ('BI2', MF,
     '<package android:name="com.android.permissioncontroller" />',
     '<package android:name="com.android.permissioncontroller.off" />',
     'выбить запись видимости — проба соврёт в опасную сторону'),
    ('BI3', AI,
     'out["staged_bytes"] = if (staged.exists()) staged.length() else 0L',
     'out["staged_bytes"] = if (staged.exists()) staged.length() else 0L\n'
     '        context.startActivity(Intent(Intent.ACTION_VIEW))',
     'дать пробе побочное действие'),
    ('BI4', AI,
     'Intent.ACTION_VIEW, Intent.ACTION_INSTALL_PACKAGE',
     'Intent.ACTION_VIEW',
     'оставить одну попытку установки вместо двух'),
    ('BI5', FP,
     'values: ContentValues?): Uri? = null',
     'values: ContentValues?): Uri? = uri',
     'сделать провайдер записываемым'),
    ('BI6', SC,
     '    context.watch<LocaleService>();',
     '    // подписка на LocaleService снята',
     'снять подписку на смену языка (правило X4)'),
    ('BI7', L10,
     "'install.exported': 'Written to',",
     "'install.exported_gone': 'Written to',",
     'выбить ключ из английской карты — паритет l10n нарушен'),
    ('BI8', MA,
     '"ok" to false, "error" to "pick already in flight"',
     '"ok" to false, "error" to "busy"',
     'снять защиту от двух параллельных выборов файла'),

    # ─── эра BJ (+173) «Выключатель и правки по ревизии» ────────────
    ('BJ1', ST,
     'onChanged: _setAutostart',
     'onChanged: null',
     'сделать выключатель автозапуска недостижимым'),
    ('BJ2', PF,
     '                .putBoolean(KEY_OPT_OUT, !armed)',
     '',
     'перестать запоминать отказ — следующий запуск взведёт поверх'),
    ('BJ3', AS_,
     '"автозапуск сработал — сбор начнётся при открытии"',
     '"нажмите, чтобы записывать"',
     'вернуть нотификации обещание записи, которой нет'),
    ('BJ4', MK,
     '        if (!pubDead) {',
     '        if (true) {',
     'вернуть обречённое обращение к мёртвому пути на каждую строку'),
    ('BJ5', FP,
     ' * ПОПРАВКА v0.1.74+173.',
     ' * Проверить наличие androidx.core в classpath нечем.',
     'вернуть ложное обоснование своего провайдера'),
    ('BJ6', ST,
     '    // иначе он покажет состояние, которого нет.\n'
     '    final on = await AutostartArm.isArmed();',
     '    // иначе он покажет состояние, которого нет.\n'
     '    final on = value;',
     'заставить переключатель верить своему намерению'),

    # ─── эра BK (+174) «Четыре долга по полю 29.07» ─────────────────
    ('BK1', ST,
     'onTap: _dumpMarker',
     'onTap: null',
     'отрезать маркер от диаг-дампа — остаётся только хрупкий ZIP'),
    ('BK2', MK,
     'raf.seek(total - maxBytes)',
     'raf.seek(0)',
     'снять границу чтения — журнал поедет в память целиком'),
    ('BK3', BR,
     '                "START action=$action result=OK" +\n'
     '                    " · ${AutostartMarker.ident()}"',
     '                "START action=$action result=OK"',
     'убрать ident() из одной строки ресивера'),
    ('BK4', BR,
     ' * ПОПРАВКА',
     ' * Второй мост заменяет первый.',
     'вернуть ложное утверждение «дублей не бывает»'),
    ('BK5', A1,
     'def check_dump(',
     'def check_dump_off(',
     'убрать у инструмента A1 критерий применимости'),

    # ─── перепин BI2/BI4 (+176) ─────────────────────────────────────
    #
    # BI2 переписан ПО СЛЕДАМ ЭТОЙ САМОЙ МУТАЦИИ: в прежней редакции она
    # гейт не роняла — имя с суффиксом содержит имя без суффикса, и `in`
    # этого не различает. Мутация оставлена дословно как была: теперь она
    # обязана валить гейт, и это доказательство, что слепота закрыта.
    ('BI2', MF,
     '<package android:name="com.android.permissioncontroller" />',
     '<package android:name="com.android.permissioncontroller.off" />',
     'подменить имя пакета на несуществующее — видимость снова выключена'),
    ('BI4', AI,
     'Intent.ACTION_VIEW, Intent.ACTION_INSTALL_PACKAGE',
     'Intent.ACTION_VIEW',
     'оставить одну попытку установки вместо двух'),
    ('BI4', AI,
     '        activity.startActivityForResult(i, REQ_INSTALL)',
     '        activity.startActivity(i)',
     'лишить попытку возможности вернуть resultCode'),

    # ─── эра BL (+176) «Установка поверх» ───────────────────────────
    ('BL1', MF,
     'android:name=".StageActivity"',
     'android:name=".StageActivityOff"',
     'убрать из манифеста тонкую activity приёма файла'),
    ('BL2', AI,
     '        out["tree_doc_resolvers"] = resolvers(',
     '        context.startActivity(Intent(Intent.ACTION_VIEW))\n'
     '        out["tree_doc_resolvers"] = resolvers(',
     'дать расширенной пробе побочное действие'),
    ('BL3', AI,
     'ACT_SECURITY to Intent(ACT_SECURITY)',
     '"android.settings.UNUSED_DOOR" to Intent("android.settings.UNUSED")',
     'потерять одну из девяти дверей к разрешению'),
    # Вторая половина перепина +177: дверь, забытая в <queries>, отдаёт
    # пустой список резолверов при живом экране — проба врёт в самую
    # опасную сторону. Раньше эту половину не держал никто.
    ('BL3', MF,
     '<action android:name="android.settings.SECURITY_SETTINGS" />',
     '<action android:name="android.settings.SECURITY_SETTINGS_OFF" />',
     'объявить дверь в коде, но забыть её в <queries> манифеста'),
    ('BL4', AI,
     'out["exception"] = "${t.javaClass.simpleName}: ${t.message}"',
     'out["exception"] = "failed"',
     'дать попытке проглотить класс исключения'),
    ('BL5', AI,
     '    fun listApks(context: Context): Map<String, Any?> {',
     '    fun listApks(context: Context): Map<String, Any?> {\n'
     '        if (!Environment.isExternalStorageManager()) {\n'
     '            return mapOf("ok" to false, "error" to "need MANAGE")\n'
     '        }',
     'сделать MANAGE_EXTERNAL_STORAGE обязательным условием обзора'),
    ('BL6', CH,
     'available > installed && installed > 0 && available > 0',
     'available >= 0',
     'разрешить откат версии при скачивании'),
    ('BL7', MK,
     '            where = "priv"',
     '            where = "priv"\n            rotateIfHuge(context)',
     'позвать ротацию из write(), то есть и из boot-контекста'),
    ('BL8', AI,
     '        val tree = Uri.parse(treeUri)',
     '        if (!Environment.isExternalStorageManager()) '
     'return emptyList()\n'
     '        val tree = Uri.parse(treeUri)',
     'сделать SAF-обход зависимым от разрешения на хранилище'),
]

FOOTER = 'PASS '


def run_regress(cwd):
    """Прогон харнесса. Возвращает (вердикт, набор упавших гейтов, вывод).

    Вердикт `crash` отделён от `ok` намеренно: гейт, роняющий прогон,
    снаружи неотличим от сработавшего, а это разные события.
    """
    try:
        p = subprocess.run(
            [sys.executable, 'tools/regress_plus35.py'],
            cwd=cwd, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return 'crash', set(), '(timeout)'
    out = (p.stdout or '') + (p.stderr or '')
    # Отчёт с итоговой строкой — единственное доказательство, что
    # харнесс дошёл до конца, а не умер на середине.
    if p.returncode not in (0, 1) or FOOTER not in out:
        return 'crash', set(), out
    failed = set()
    for line in out.split('\n'):
        line = line.strip()
        if line.startswith('[FAIL]'):
            rest = line[len('[FAIL]'):].strip()
            failed.add(rest.split()[0] if rest else '?')
    return 'ok', failed, out


def main():
    wanted = [a.upper() for a in sys.argv[1:]]
    picked = [m for m in MUTATIONS
              if not wanted or any(m[0] == w or m[0].startswith(w)
                                   for w in wanted)]
    if not picked:
        print(f'нет мутаций по фильтру {wanted}')
        return 1

    print('=' * 68)
    print(f'МУТАЦИОННАЯ ПРОВЕРКА ГЕЙТОВ — {len(picked)} мутаций')
    print('=' * 68)

    # Базовая линия: на неизменённом дереве прогон обязан быть зелёным.
    # Без неё красный гейт под мутацией ничего не значит — он мог быть
    # красным и до неё.
    base_verdict, base_failed, base_out = run_regress(ROOT)
    if base_verdict == 'crash':
        print('BASELINE CRASH — харнесс не проходит на чистом дереве')
        print(base_out[-2000:])
        return 1
    if base_failed:
        print(f'BASELINE НЕ ЗЕЛЁНАЯ: {sorted(base_failed)}')
        return 1
    print('базовая линия чистая: 0 FAIL\n')

    good, blind, setup, crash = [], [], [], []
    for gate, rel, anchor, repl, note in picked:
        src = ROOT / rel
        if not src.exists():
            setup.append((gate, f'файла нет: {rel}'))
            print(f'  [SETUP-FAIL] {gate}: файла нет: {rel}')
            continue
        text = src.read_text()
        n = text.count(anchor)
        if n != 1:
            setup.append((gate, f'анкер встречается {n} раз в {rel}'))
            print(f'  [SETUP-FAIL] {gate}: анкер встречается {n} раз '
                  f'в {rel} (нужно ровно 1)')
            continue
        with tempfile.TemporaryDirectory(prefix='mut_') as tmp:
            work = pathlib.Path(tmp) / 'tree'
            shutil.copytree(ROOT, work,
                            ignore=shutil.ignore_patterns(
                                '.git', '__pycache__', 'build', '.dart_tool'))
            tgt = work / rel
            tgt.write_text(text.replace(anchor, repl, 1))
            verdict, failed, out = run_regress(work)
        if verdict == 'crash':
            crash.append((gate, note))
            print(f'  [CRASH] {gate}: мутация РОНЯЕТ прогон — '
                  f'гейт бросает исключение вместо FAIL')
            print('          ' + out.strip().split('\n')[-1][:120])
            continue
        if gate in failed:
            extra = sorted(failed - {gate})
            tail = f' (попутно: {", ".join(extra)})' if extra else ''
            good.append(gate)
            print(f'  [OK] {gate} упал от «{note}»{tail}')
        else:
            blind.append((gate, note))
            print(f'  [BLIND] {gate} НЕ упал от «{note}» — '
                  f'гейт не держит свой предмет')
            if failed:
                print(f'          вместо него упали: {sorted(failed)}')

    print('=' * 68)
    print(f'OK {len(good)} · BLIND {len(blind)} · '
          f'SETUP-FAIL {len(setup)} · CRASH {len(crash)}')
    for g, n in blind:
        print(f'  BLIND      {g} — {n}')
    for g, n in setup:
        print(f'  SETUP-FAIL {g} — {n}')
    for g, n in crash:
        print(f'  CRASH      {g} — {n}')
    print('=' * 68)
    return 1 if (blind or setup or crash) else 0


if __name__ == '__main__':
    sys.exit(main())
