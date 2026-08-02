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
DD = 'lib/services/diag_dump_file.dart'
CH = 'lib/services/apk_install_channel.dart'
IS_ = 'lib/services/import_service.dart'
MN = 'lib/main.dart'
DM = 'lib/screens/data_management.dart'
HO = KT + 'hal/HalOut.kt'
HW = KT + 'hal/HalStreamOwner.kt'
DS = KT + 'hal/DecodedStreamSink.kt'
NP = KT + 'BydNativePlugin.kt'
DB = 'lib/data/database.dart'
HT = 'lib/services/hal_telemetry_service.dart'
BJ = 'lib/services/hal_bg_journal.dart'
TAG = 'lib/services/trip_aggregates.dart'
BTB = 'lib/services/bg_trip_builder.dart'
CONN = 'lib/services/connection.dart'
FHO = ('android/app/src/main/kotlin/com/bz5companion/bz5_companion/'
       'FlutterHalOut.kt')
UU = 'lib/data/uuid_v7.dart'
DBL = 'tools/dart_balance.py'

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
    # v0.1.83+182: дизъюнкция путей наверх переехала в поле lastHeadless
    # (надпись обновляется позже, чем startForeground), поэтому анкер
    # мутации переехал за ней. Предмет тот же — мост не должен потерять
    # различитель «поднялся сам».
    ('BF3', AS_,
     'lastHeadless = resurrected || bridged',
     'lastHeadless = resurrected',
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
    # v0.1.83+182: сбор за тумблером появился, и прежняя надпись «сбор
    # начнётся при открытии» стала отрицанием работы, которая идёт.
    # Предмет гейта тот же — надпись обязана описывать измеренное
    # состояние; мутация возвращает ей обещание вместо измерения.
    ('BJ3', AS_,
     '    private fun collectingText(): String {',
     '    private fun collectingTextUnused(): String {',
     'убрать измерение состояния сбора — надписи снова нечем быть '
     'честной'),
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
     'available >= installed && installed > 0 && available > 0',
     'available > installed && installed > 0 && available > 0',
     'снова закрыть равную версию — единственный путь к файлу'),

    # ─── эра BM (+178) «Что сказало поле 30.07» ─────────────────────
    ('BM1', DD,
     'final fresh = await _fallbackFilename(dir);',
     'final fresh = _filename;',
     'лишить дамп свежего имени — один файл и один шанс'),

    # ─── эра BN (+179) «Журнал — приватный файл» ────────────────────
    ('BN1', MK,
     '        var privOk = false',
     '        if (!pubDead) {\n'
     '            try {\n'
     '                File("$PUB_DIR/x.txt").appendText(text)\n'
     '                return\n'
     '            } catch (t: Throwable) {\n'
     '                pubDead = true\n'
     '            }\n'
     '        }\n'
     '        var privOk = false',
     'вернуть публичную запись ПЕРЕД приватной с ранним выходом'),
    ('BN2', MK,
     'FILE_NAME.removeSuffix(".txt") + "_$code.txt"',
     'FILE_NAME.removeSuffix(".txt") + "_" + SimpleDateFormat('
     '"yyyyMMdd-HHmmss", Locale.US).format(Date()) + ".txt"',
     'вернуть ключ по времени — файл на каждый процесс'),
    ('BN3', DD,
     '    if (memo != null) return memo;',
     '',
     'снять память запасного имени — новый файл на каждый вызов'),
    ('BM2', DD,
     "reasons.add('${candidate.path}: ${e.runtimeType}: $e');",
     "reasons.add('write failed');",
     'снять причину отказа — остаётся голый вердикт'),
    ('BM3', MK,
     ' * ── ПОПРАВКА v0.1.79+178',
     ' * Публичные Downloads unwritable (fails=1) — мертвы. ──',
     'вернуть опровергнутое «публичные Downloads мертвы»'),
    ('BM4', ST,
     "S.of('settings.adv.dump_empty')",
     "S.of('settings.adv.dump_fail')",
     'снова назвать отсутствие данных отказом хранилища'),
    ('BM5', AI,
     '        if (out["error"] == null) out["error"] = '
     '"no tree intent to try"',
     '',
     'вернуть журналу подстановку «cancelled» вместо причины'),
    ('BM6', AI,
     '    fun pickContent(activity: Activity) {',
     '    fun pickContentUnused(activity: Activity) {',
     'убрать GET_CONTENT как путь к файлу'),
    ('BM7', SC,
     "S.of('install.raw.title')",
     "S.of('install.log.title')",
     'убрать пробу с экрана — читать её станет нечем'),
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

    # ─── эра BO (+180) «Импорт из архива» ───────────────────────────
    ('BO1', MN,
     '  final importApplied = await ImportService.applyPending();',
     '  final importApplied = null;',
     'убрать обмен файла до открытия базы — импорт станет немым'),
    ('BO2', IS_,
     "    'cloud_sync_cursor_canmonitor': 'can_monitor_sessions',",
     "    'cloud_sync_cursor_canmon': 'can_monitor_sessions',",
     'разойтись с сервисом в имени курсора — лавина 04.07 вернётся'),
    ('BO3', IS_,
     '      if (!allowed.contains(k)) continue;',
     '      if (false) continue;',
     'снять проверку белого списка на входе — чужой архив подменит '
     'привязку устройства'),
    ('BO4', IS_,
     '      await staged.rename(livePath);',
     '      final live = File(livePath);\n'
     '      if (await live.exists()) await live.delete();\n'
     '      await staged.rename(livePath);',
     'удалить базу до переименования — открыть окно без базы вовсе'),
    ('BO5', IS_,
     '    if (schemaVersion > appSchemaVersion) {',
     '    if (false) {',
     'принять архив со схемой новее нашей, которую Drift не опустит'),
    ('BO6', ES,
     '        ImportService.kPrefsEntry,',
     "        'prefs_unused.json',",
     'перестать писать настройки под именем, которое читает импорт'),
    ('BO7', MK,
     '        if (fallbackNoted || pubFails == 0) return',
     '        if (fallbackNoted || where == "pub") return',
     'вернуть охрану на `where` — маркер снова соврёт про отказ'),
    ('BO8', DM,
     '    exit(0);',
     '    Navigator.of(context).pop();',
     'убрать снятие процесса — отложенный импорт не применится никогда'),

    # ─── эра BP (+181) «Сбор в автостарте» ──────────────────────────
    ('BP1', DS,
     '    private var sink: HalOut? = out',
     '    private var sink: io.flutter.plugin.common.EventChannel.EventSink? '
     '= null',
     'вернуть сник к EventChannel — второй адресат потребовал бы второй '
     'копии извлечений из BigData'),
    # v0.1.86+185: анкер переписан под новую подпись `attachFlutter` —
    # плагин передаёт готовый `FlutterHalOut`, а не голый EventSink.
    # Предмет мутации прежний: плагин не смеет строить движок сам.
    ('BP2', NP,
     '                val status = HalStreamOwner.attachFlutter(\n'
     '                    ctx, FlutterHalOut(sink), platformOverrideId)',
     '                val streamSink = DecodedStreamSink(sink)\n'
     '                val halEngine = 1\n'
     '                val status = HalStreamOwner.attachFlutter(\n'
     '                    ctx, FlutterHalOut(sink), platformOverrideId)',
     'дать плагину строить свой движок — двойная подписка, которую патч '
     'и снимает'),
    ('BP3', HW,
     '        if (engine != null) {\n'
     '            streamSink?.setOut(out)\n'
     '            return\n'
     '        }',
     '        if (engine != null) {\n'
     '            stopAll()\n'
     '        }',
     'пересоздавать живой движок при передаче потока — дыра в данных и '
     'два прокси разом'),
    ('BP4', HW,
     '                "BYDAutoPowerDevice_canDataCollect",',
     '                "BYDAutoPowerDevice_disabled",',
     'сломать пару Power+BigData в единственном месте сборки целей — '
     'soc_precise, SOH и температура исчезнут молча'),
    ('BP5', HO,
     '        for (e in batch) {\n'
     '            seen.incrementAndGet()',
     '        if (full) {\n'
     '            dropped.addAndGet(batch.size.toLong())\n'
     '            return\n'
     '        }\n'
     '        for (e in batch) {\n'
     '            seen.incrementAndGet()',
     'поставить счётчики за потолок — работающий HAL прочитался бы как '
     'молчащий'),
    ('BP6', HO,
     '        if (bytes + size > CAP_BYTES) {',
     '        if (false) {',
     'снять потолок журнала — файл растёт без объявленной границы'),
    ('BP7', HT,
     '      final ing = await HalBgJournal.ingest(bgDb);',
     '      final ing = const HalBgIngestResult(present: false);',
     'убрать втягивание журнала из init() до перенаправления потока'),
    ('BP8', DB,
     '              timestamp: Value(r.at),',
     '              timestamp: Value(DateTime.now()),',
     'ставить фоновым строкам время вставки — вся поездка в одно '
     'мгновение'),
    ('BP10', HW,
     '        if (engine != null && outTag == OUT_FLUTTER) return lastStatus',
     '        if (false) return lastStatus',
     'снять охрану владельца потока — будильник моста при открытом '
     'приложении заморозит приборы'),
    ('BP9', DM,
     "      'hal_samples': await db.countAllHalSamples(),",
     '',
     'убрать главное число импорта с экрана — сверять его снова станет '
     'нечем'),

    # ─── эра BQ (+182) «Журнал: владение, идемпотентность, границы» ──
    ('BQ1', BJ,
     '      final raw = await taken.readAsString();',
     '      final raw = await live.readAsString();',
     'читать живой путь вместо забранного — строки между чтением и '
     'удалением исчезнут'),
    ('BQ2', BJ,
     '      await db.transaction(() async {',
     '      await Future<void>(() async {',
     'вернуть вставку без общей транзакции — отказ на середине '
     'гарантирует дубли'),
    ('BQ3', BJ,
     '      if (await taken.exists()) {',
     '      if (false) {',
     'втягивать остаток упавшего захода второй раз — удвоение без '
     'всякой сверки'),
    ('BQ4', BJ,
     '      if (hdr != fmt) {',
     '      if (false) {',
     'принять журнал чужого формата — мусор уедет в hal_samples молча'),
    ('BQ5', HO,
     '        ArrayBlockingQueue(QUEUE_CAPACITY),',
     '        java.util.concurrent.LinkedBlockingQueue(),',
     'снять границу очереди записи — рост памяти в foreground-сервисе'),
    ('BQ6', HO,
     '        var bytes = if (existed) f.length() else 0L',
     '        var bytes = 0L',
     'перестать спрашивать длину у файловой системы — потолок разойдётся '
     'с действительностью'),
    ('BQ7', AS_,
     '        if (HalStreamOwner.activeOut() != HalStreamOwner.OUT_FLUTTER) {',
     '        if (false) {',
     'оставить подписку без владельца при смерти сервиса'),

    # ─── эра BR (+183) «Строка журнала разбирается, и это видно» ─────
    #
    # Эра называется BR, и переменная BR выше — это BootReceiver.kt.
    # Совпадение только в буквах: первое поле кортежа — идентификатор
    # гейта, строка, и с алиасами файлов не пересекается.
    ('BR1', BJ,
     '  static BgHalRow? _parse(String line) {',
     '  static BgHalRow? _parseUnused(String line) {',
     'вернуть +182 дословно: вызов есть, объявления нет — падение '
     'kernel_snapshot'),
    ('BR2', BJ,
     "      final subtype = i < 0 ? '' : key.substring(i + 3);",
     '      final subtype = i < 0 ? null : key.substring(i + 3);',
     'отдать null вместо пустого подтипа — одна цель расщепится на две '
     'молча'),
    ('BR3', BJ,
     '        at: DateTime.fromMillisecondsSinceEpoch(ms),',
     '        at: DateTime.now(),',
     'ставить время втягивания вместо времени события — вся поездка в '
     'одно мгновение'),
    ('BR4', BJ,
     '          if (line.startsWith(\'{"_":\')) continue;',
     '          if (seenLines == 0 && line.contains(\'"_":"hdr"\')) continue;',
     'вернуть частный случай только для первой строки — строка потолка '
     'уедет в malformed'),
    ('BR5', DBL,
     "            fails.append(f'{f.name}:{name}')",
     '            pass',
     'печатать нерезолвящийся приватный вызов, но не краснеть от него'),

    # ─── эра BS (+185) «Поездка из фоновых строк» ────────────────────
    ('BS1', TAG,
     'TripDerived computeTripDerived({',
     "import '../data/database.dart';\n\nTripDerived computeTripDerived({",
     'втащить базу в чистый расчёт — зеркалом его больше не проверить'),
    ('BS2', CONN,
     '      final avgConsumption = derived.avgConsumptionKwh100km;',
     '      final avgConsumption = (energyUsedKwh != null && '
     'distanceKm != null)\n          ? (energyUsedKwh / distanceKm) * 100.0'
     '\n          : null;',
     'вернуть вторую копию формулы расхода в живой путь'),
    ('BS3', BTB,
     '    final derived = computeTripDerived(',
     '    final derived = _ownMaths(',
     'дать фоновому пути считать поездку по-своему'),
    ('BS4', BTB,
     "import '../data/database.dart';",
     "import '../data/database.dart';\nimport 'hal_telemetry_service.dart';",
     'дать строителю увидеть HAL-сервис — граница AA2 пробита'),
    ('BS5', BTB,
     '    await db.insertTripWithStampedSamples(',
     '    await db.insertCompletedTrip(',
     'не штамповать строки — поездки пересобираются при каждом открытии'),
    ('BS6', DB,
     '            await _addColumnIfAbsent(m, trips, trips.source);',
     '            await m.deleteTable(\'trips\');',
     'переписать таблицу поездок вместо аддитивной колонки'),
    ('BS7', FHO,
     'class FlutterHalOut(private val sink: EventChannel.EventSink) : HalOut {',
     'class FlutterHalOutMoved(private val sink: EventChannel.EventSink) : '
     'HalOut {',
     'убрать адаптер из корневого пакета — граница пакета снова не мерится'),
    ('BS8', HW,
     '    fun detachFlutter(keepCollecting: Boolean, ctx: Context) {',
     '    fun detachFlutter(keepCollecting: Boolean, ctx: Context) {\n'
     '        val keep = AutostartPrefs.isArmed(ctx) && '
     '!AutostartPrefs.optedOut(ctx)',
     'вернуть чтение настроек внутрь механизма'),
    ('BS9', HO,
     '            if (prev != null && ts - prev < throttleFor(name)) {',
     '            if (prev != null && ts - prev < THROTTLE_MS) {',
     'вернуть общий порог — таблица есть, но её никто не спрашивает'),
    ('BS10', BTB,
     '      source: kSourceHalBg,',
     '      source: null,',
     'выпустить фоновую поездку без подписи — она сойдёт за донгловую'),
    ('BS12', DB,
     '    return transaction(() async {',
     '    return Future.sync(() async {',
     'снять транзакцию со вставки и штампа — дубль поездки в облаке'),
    ('BS13', BTB,
     '            truncated && i == clusters.length - 1 && i > 0;',
     '            truncated && i == clusters.length - 1;',
     'откладывать и единственный обрезанный кластер — знак не сдвинется '
     'никогда'),
    ('BS14', BTB,
     '        rows.removeWhere((r) => r.timestamp.isAfter(at));',
     '        return const BgTripBuildResult('
     'scanned: 0, built: 0, discarded: 0);',
     'выходить из сборки от одной строки впереди часов — навсегда'),
    # ─── эра BT (+186) «Фоновая поездка узнаётся в облаке» ───────────
    ('BT1', BTB,
     '      extraJson: \'{"v":1,"source":"$kSourceHalBg"}\',',
     '      extraJson: null,',
     'отправить фоновую поездку без происхождения — ночной алерт на '
     'каждую'),
    ('BT2', DB,
     '        await mergeTripExtra(id, extra);',
     '        // extra пишется выше',
     'вернуть перезапись блоба целиком — чужие ключи пропадут молча'),
    ('BT3', DB,
     '      clientUuid: Value(uuidV7Deterministic(',
     '      clientUuid: Value(uuidV7(),',
     'вернуть случайный uuid — пересборка даст дубль в облаке'),
    ('BT4', UU,
     '  b[6] = 0x70 | (b[6] & 0x0F); // версия 7\n  b[8] = 0x80 | '
     '(b[8] & 0x3F); // вариант 10xx\n\n  final hex = StringBuffer();\n'
     '  for (var i = 0; i < 16; i++) {\n    if (i == 4 || i == 6 || '
     'i == 8 || i == 10) hex.write(\'-\');\n    hex.write(b[i].'
     'toRadixString(16).padLeft(2, \'0\'));\n  }\n  return hex.toString();\n}\n',
     '  b[8] = 0x80 | (b[8] & 0x3F);\n\n  final hex = StringBuffer();\n'
     '  for (var i = 0; i < 16; i++) {\n    if (i == 4 || i == 6 || '
     'i == 8 || i == 10) hex.write(\'-\');\n    hex.write(b[i].'
     'toRadixString(16).padLeft(2, \'0\'));\n  }\n  return hex.toString();\n}\n',
     'потерять версию 7 в детерминированном uuid — сервер сортирует по '
     'нему'),

    ('BT5', DBL,
     "            fails.append(f'{f.name}:await:{ln}')",
     '            pass',
     'печатать await не в том теле, но не краснеть от него'),

    ('BS11', BTB,
     '    const maxGapSec = 15;',
     '    const unusedGapSec = 15;\n    final movingShortcut = '
     'speedSamples * 3;',
     'вернуть умножение на шаг прореживания — §2 сделает время в движении '
     'втрое больше'),

    # ── эра BU (+187): архив читается, а не только находится ──
    ('BU1', IS_,
     '      if (c.readable) {\n        chosen = c;\n        break;\n      }',
     '      if (c.path.isNotEmpty) {\n        chosen = c;\n        break;'
     '\n      }',
     'вернуть выбор по наличию — чужой нечитаемый файл снова заслонит '
     'свежий'),
    ('BU2', AI,
     '    const val ARCHIVE = "imported_archive.zip"',
     '    const val ARCHIVE = "staged_archive.zip"',
     'развести имя слота между Dart и Kotlin — принятый архив ляжет мимо '
     'импорта'),
    ('BU3', IS_,
     '      out.add(await getApplicationSupportDirectory());',
     '      // свой каталог больше не кандидат',
     'убрать свой каталог из кандидатов — приём по гранту ведёт в никуда'),
    ('BU4', DM,
     '      final staged = await ApkInstallChannel.stageArchive(uri);',
     '      final staged = <String, dynamic>{};',
     'читать выбранный uri после того, как грант мог погаснуть'),
    ('BU5', MF,
     '                <data android:mimeType="application/zip" />',
     '                <data android:mimeType="application/pdf" />',
     'снять заявку на приём zip — единственный путь мимо uid закрывается'),
    ('BU6', AI,
     '            val dir = File("/storage/emulated/0/Download")',
     '            startActivity(Intent())\n'
     '            val dir = File("/storage/emulated/0/Download")',
     'дать пробе побочное действие — звать её при каждом отказе станет '
     'нельзя'),
    ('BU7', ES,
     "      debugPrint('Export: fixed-name copy FAILED — $e. '",
     "      debugPrint('Отказ безобиден — $e. '",
     'вернуть ложное обещание про безобидный отказ'),
    ('BU8', DM,
     "      tail = S.of('dataimp.cand_denied');",
     "      tail = S.of('dataimp.cand_' + 'denied');",
     'снова собирать ключ локали выражением — харнесс его не увидит'),
    ('BU9', DM,
     '      final found = await ImportService.searchArchive();',
     '      final found = await ImportService.findArchiveCandidates();',
     'вернуть выбор в экран — гейт BU1 снова станет вакуумным'),
    ('BU10', DM,
     '        picked = await _pickWithTimeout(ApkInstallChannel.pick);',
     '        picked = <String, dynamic>{};',
     'снять вторую ступень выбора файла — восстановление станет менее '
     'живучим, чем установка'),
    ('BU11', AI,
     '                "stage-archive: ok=${out["ok"]} bytes='
     '${out["bytes"] ?: 0}" +',
     '                "" +',
     'лишить приём архива долговечного следа — визит ничего не расскажет'),
    ('BU12', IS_,
     '      final staged = File(p.join(support.path, kStagedName));',
     '      final staged = File(p.join(support.path, _pendingDbName));',
     'перестать убирать принятую копию — она вечно будет первой в списке'),
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
