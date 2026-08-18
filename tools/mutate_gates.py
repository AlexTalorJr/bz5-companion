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
CW = 'lib/screens/wide/charging_view_wide.dart'
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
CS = 'lib/services/cloud_sync_service.dart'
BNP = ('android/app/src/main/kotlin/com/bz5companion/bz5_companion/'
       'BydNativePlugin.kt')
CP = 'lib/services/cell_pair.dart'
PH = 'lib/services/power_history_service.dart'
DVT = 'lib/screens/driver_view_tall.dart'
DVW = 'lib/screens/wide/driver_view_wide.dart'
BC = 'lib/widgets/band_card.dart'
SPS = 'lib/services/speed_profile_service.dart'
SPU = 'lib/screens/speed_profile.dart'
TST = 'test/speed_profile_engine_test.dart'
EXP = 'lib/widgets/atlas_export.dart'
ATW = 'lib/screens/wide/atlas_wide.dart'
DW = 'lib/screens/wide/dashboard_wide.dart'
TAB = ('android/app/src/main/kotlin/com/bz5companion/bz5_companion'
       '/hal/TelemetryDecoderTable.kt')
DSH = 'lib/screens/dashboard.dart'
HM = 'lib/screens/home.dart'
HUS = 'lib/screens/wide/head_unit_scaffold.dart'
CDO = ('android/app/src/main/kotlin/com/bz5companion/'
       'bz5_companion/hal/CompanionDecoderOverrides.kt')
CB = 'lib/widgets/charging_banner.dart'
ST_ = 'lib/screens/status.dart'
DVT = 'lib/screens/driver_view_tall.dart'
OVR = ('android/app/src/main/kotlin/com/bz5companion/bz5_companion'
       '/hal/CompanionDecoderOverrides.kt')

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
     '    final st = await AutostartArm.state();',
     '    // иначе он покажет состояние, которого нет.\n'
     '    final st = v ? AutostartState.on : AutostartState.offByOwner;',
     'заставить переключатель верить своему намерению'),

    # ─── эра BK (+174) «Четыре долга по полю 29.07» ─────────────────
    ('BK1', MK,
     'File("$PUB_DIR/${pubFileName(context)}").appendText(text)',
     'File("/dev/null").appendText(text)',
     'увести публичное зеркало журнала в никуда — остаётся только '
     'хрупкий экспортный ZIP, который дважды приезжал обрезанным'),
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
     '    final tripId = await db.insertTripWithStampedSamples(',
     '    final tripId = await db.insertCompletedTrip(',
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
    # ОБНОВЛЕНО (+193): прежний анкер стоял на строке отказа копии под
    # постоянным именем, а копии больше нет — мутация осела бы на пустоте и
    # честно дала SETUP-FAIL. Предмет BU7 перенесён вместе с гейтом: ложное
    # обещание не смеет вернуться в файл экспорта.
    ('BU7', ES,
     '    // ── КОПИЮ ПОД ПОСТОЯННЫМ ИМЕНЕМ БОЛЬШЕ НЕ ПИШЕМ ──',
     '    // Отказ безобиден: импорт найдёт архив перечислением.',
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
     '                "stage-archive: ok=${out["ok"]}" +',
     '                "" +',
     'лишить приём архива долговечного следа — визит ничего не расскажет'),
    ('BU12', IS_,
     '      final staged = File(p.join(support.path, kStagedName));',
     '      final staged = File(p.join(support.path, _pendingDbName));',
     'перестать убирать принятую копию — она вечно будет первой в списке'),

    # ── эра BV (+188): живой старт подхватывает фон ──
    ('BV1', HT,
     '      final join = await _findJoinableTail(db);',
     '      final _HalJoinTail? join = null;',
     'снять подхват с живого пути — один заезд снова станет двумя '
     'поездками'),
    ('BV2', DB,
     '      startedAt: Value(startedAt ?? DateTime.now()),',
     '      startedAt: Value(DateTime.now()),',
     'рождать подхваченную поездку временем открытия приложения'),
    ('BV3', HT,
     '    if (j.distanceKm > 0) _halTripDistAccumKm += j.distanceKm;',
     '    final joinedKm = j.distanceKm;',
     'увести подхваченные километры мимо аккумулятора — экран и история '
     'разойдутся'),
    ('BV4', DB,
     '              s.tripId.isNull() &\n              s.source.equals(\'hal\') &',
     '              s.source.equals(\'hal\') &',
     'штамповать без проверки на свободную строку — можно увести чужие'),
    ('BV5', HT,
     '        await db.mergeTripExtra(id, \'{"v":1,"joinedInProgress":true}\');',
     '        // происхождение не пишем',
     'отправить подхваченную поездку без происхождения — ночной алерт'),
    ('BX2', DBL,
     "            fails.append(f'{f.name}:rec:{ln}')",
     '            pass',
     'печатать расхождение арности записи, но не краснеть от него'),
    ('BX3', DBL,
     "            fails.append(f'{f.name}:nullkey:{ln}')",
     '            pass',
     'печатать nullable-ключ карты, но не краснеть от него'),
    # ── эра BY (+192): обрыв виден там, где случился ──
    ('BY1', AI,
     '            if (srcBytes > 0 && written != srcBytes) {',
     '            if (false) {',
     'перестать сверять байты с источником — обрыв снова станет успехом'),
    ('BY2', ES,
     '      if (len != expectLen) {',
     '      if (false) {',
     'не сверять длину записанного файла с ожидаемой'),
    ('BY3', DM,
     "                '${S.of('dataexp.write_warn_fmt').replaceFirst('{detail}', warn)}';",
     "                '';",
     'проверять запись, но не показывать жалобу владельцу'),
    ('BY4', IS_,
     "      if (!hasZipTail(tail)) return 'truncated';",
     '      // хвост не проверяем',
     'снова считать открываемость пригодностью'),
    ('BY5', HT,
     '    _halTripStartOdo = j.startOdo ?? _halTripStartOdo;',
     '    _halTripStartOdo ??= j.startOdo;',
     'вернуть якорь живого старта подхваченной поездке'),
    ('BY6', MA,
     '                "requestStoragePermission" -> {',
     '                "neverAskedForStorage" -> {',
     'снять запрос разрешения — read_perm=false останется без объяснения'),
    ('BY7', BNP,
     '                "detach-flutter: keepCollecting=$keepCollecting"',
     '                ""',
     'лишить отсоединение следа — подтверждать придётся заходом к машине'),

    ('BX1', DBL,
     "            fails.append(f'{f.name}:arg:{ln}')",
     '            pass',
     'печатать несовпадение типа литерала, но не краснеть от него'),
    ('BV6', HT,
     '    if (now.difference(end) >= BgTripBuilder.kMotionGap) return null;',
     '    if (now.difference(end) >= const Duration(minutes: 5)) return null;',
     'завести второе определение разрыва движения'),
    ('BV8', HT,
     '      if (!_halTripActive) return;\n      if (join != null) '
     '_adoptJoinedTail(join);',
     '      if (join != null) _adoptJoinedTail(join);',
     'вставлять строку, не проверив, жива ли ещё поездка после чтения '
     'хвоста'),
    # ── эра BW (+189): фон виден Трендам, карта сущностей целая ──
    ('BW1', BTB,
     '    await _writeSnapshots(db, window, tripId);',
     '    // снапшоты не пишем',
     'вернуть фоновые поездки без снапшотов — Тренды снова слепнут'),
    # ОБНОВЛЕНО (+193): перевод вольтов в милливольты переехал в общий
    # помощник, поэтому и мутировать надо ЕГО — там единственное место, где
    # единицы ещё можно развести с живым писателем.
    ('BW2', CP,
     '    minMv: loVolts * 1000.0,',
     '    minMv: loVolts,',
     'развести единицы с живым писателем — история читалась бы в тысячу '
     'раз мимо'),
    ('BW4', IS_,
     "    'canmonitor',\n  ];",
     '  ];',
     'снова обслуживать пять сущностей списком из четырёх'),
    ('BW5', IS_,
     '    for (final t in uuidMapTables.values) {',
     '    for (final t in uuidMapEntities) {',
     'подставлять имя сущности вместо имени таблицы — сканер соврёт '
     '«пропусков нет»'),
    ('BW6', CS,
     "                'started_at': at.toUtc().toIso8601String(),",
     '                //',
     'снять время строки с отображения — тихая привязка к чужой строке'),
    ('BW7', IS_,
     "    'bg_trip_watermark_ms',\n  ];",
     '  ];',
     'оставить знак строителя дома — импорт заставит перечитать все '
     'стоянки'),

    ('BV7', HT,
     '      if ((sp != null && sp > _halMovingKmh) || odoGrew) {',
     '      if (gear == null) {\n      if (sp != null && sp > _halMovingKmh) {',
     'вернуть глушение запасного пути кадром передачи'),

    # ─── эра BZ (+193) ──────────────────────────────────────────────
    ('BZ1', ST,
     "      if (context.watch<HalTelemetryService>().canUseHal)\n"
     "        SwitchListTile(\n"
     "          secondary: const Icon(Icons.play_circle_outline,\n"
     "              color: Colors.lightBlueAccent),\n"
     "          title: Text(S.of('settings.autostart.title')),",
     "      if (false)\n"
     "        SwitchListTile(\n"
     "          secondary: const Icon(Icons.play_circle_outline,\n"
     "              color: Colors.lightBlueAccent),\n"
     "          title: Text('settings.autostart.title'),",
     'убрать тумблер из основного списка — он снова достижим только '
     'через 15 тапов'),

    ('BZ2', ARM,
     'enum AutostartState { undecided, on, offByOwner }',
     '// enum снят',
     'снять тройное состояние — «не решали» опять неотличимо от '
     '«выключено»'),

    ('BZ3', ARM,
     "      await _ch\n          .invokeMethod<bool>('armSkipped')\n"
     "          .catchError((_) => false);\n      return;",
     '      return;',
     'вернуть молчаливый пропуск — отказ владельца снова читается как '
     'поломка'),

    ('BZ4', HT,
     '          cellSpread: Value(triple?.spreadMv),',
     '          cellSpread: Value(halCellSpreadMv),',
     'вернуть живому писателю показное значение — презентационный ноль '
     'уедет в базу'),

    # Второй анкер того же гейта: BZ4 обязан держать ОБА писателя, а не
    # один. Первая редакция мутации была подписана «BZ4b» — имени, которого
    # среди гейтов нет, и харнесс честно назвал это слепотой.
    ('BZ4', BTB,
     "      final triple = cellTriple(\n"
     "        loVolts: latest['cell_v_lowest'],",
     "      final triple = _noRule(\n"
     "        loVolts: latest['cell_v_lowest'],",
     'обойти общее правило в синтезе снапшотов'),

    ('BZ5', CP,
     'const int kCellPairWindowJournalMs = 1000;',
     'const int kCellPairWindowJournalMs = 3000;',
     'взять для журнала живое окно — три секунды дрейфа снова станут '
     '«парой»'),

    ('BZ6', HO,
     '                    lastPerName[partner] = ts - throttleFor(partner)',
     '                    // встречная запись снята',
     'снять встречную запись пары — источник опять отдаёт противофазу'),

    ('BZ7', DB,
     "              'UPDATE snapshots SET cell_spread = NULL, '",
     "              'UPDATE snapshots SET cell_spread = 0, '",
     'заменить чистку тройки обнулением разброса — выдуманные границы '
     'останутся в базе'),

    # Второй анкер BZ7: чистка снапшотов без чистки агрегата оставляла бы
    # 190 мВ ровно там, где владелец их и видит.
    ('BZ7', DB,
     "              'UPDATE trips SET max_cell_spread_mv = NULL '",
     "              'SELECT 1 -- '",
     'снять чистку агрегата — выдуманные 190 мВ останутся в Трендах'),

    ('BZ8', DVT,
     '                    samples: hist.tail(slots),',
     '                    samples: const <double?>[],',
     'отвязать экран от сервиса — гейт обязан заметить мёртвый путь '
     '(урок BU1)'),

    ('BZ9', PH,
     '    _timer = Timer.periodic(tick, (_) => _sample());',
     '    // таймер не заводим',
     'остановить такт сервиса — история снова живёт только пока смотрят'),

    ('BZ9', PH,
     '    final look = _windowHint < _filled ? _windowHint : _filled;',
     '    final look = _filled;',
     'считать масштаб по всему кольцу — один разгон прижмёт шкалу на '
     'четверть часа'),

    ('BZ10', DVW,
     '      final leftPx = (i * pitchPx).roundToDouble();',
     '      final leftPx = i * pitchPx;',
     'снять округление до пикселя — однопиксельные столбики размажутся '
     'сглаживанием'),

    ('BZ11', BC,
     '      maxLines: 1,\n      overflow: TextOverflow.ellipsis,',
     '      maxLines: 1,',
     'вернуть молчаливый обрез «около N км» — число врало в десять раз'),

    # Второй анкер BZ11: постоянное имя не должно вернуться и в сверку.
    ('BZ11', ES,
     '    final writeWarning = await _verifyWritten(zipBytes.length, [\n'
     '      File(zipPath),\n    ]);',
     '    final writeWarning = await _verifyWritten(zipBytes.length, [\n'
     '      File(zipPath),\n'
     '      File(p.join(destDir.path, ImportService.kFixedName)),\n    ]);',
     'вернуть в сверку файл, записать который мы не смогли'),

    # ── ЭРА CA (+196) ──
    #
    # Восемь гейтов, десять мутаций: у CA1 и CA4 предмет составной, и
    # снимать надо каждую половину отдельно — иначе гейт мог бы держаться
    # за одну и молча отпустить вторую.

    ('CA1', AI,
     '        AutostartMarker.write(\n'
     '            this,\n'
     '            "stage-open: action=${intent?.action ?: "-"}" +\n'
     '                " type=${intent?.type ?: "-"}"\n'
     '        )\n',
     '',
     'убрать след запуска окна приёма — отсутствие строки снова означало '
     'бы сразу «нас не звали» и «позвали и убили»'),

    ('CA1', MF,
     '            android:theme="@android:style/Theme.Translucent.NoTitleBar">',
     '            android:theme="@android:style/Theme.NoDisplay">',
     'вернуть тему, требующую закрыться до конца onResume, — окно снимут '
     'посреди копирования'),

    ('CA2', MA,
     '                "markerWrite" -> {',
     '                "markerWriteDisabled" -> {',
     'отобрать у Dart дверь в файл-журнал — путь восстановления снова '
     'рассказывал бы о себе только в память'),

    ('CA3', IS_,
     "      await AutostartArm.write('import-apply: ok=false "
     "err=staged-missing');\n",
     '',
     'отнять строку у одного из отказов применения — молчал бы ровно тот '
     'выход, ради которого журнал и заводили'),

    ('CA4', AI,
     '        val isArchive = if (byName) true else looksLikeArchive(uri)',
     '        val isArchive = byName',
     'вернуть решение по одному имени файла — при молчащем провайдере '
     'архив снова уходит в ветку APK'),

    ('CA4', AI,
     '} else if (n in ourNames) {\n                            verdict = true',
     '} else if (n in ourNames) {\n                            verdict = false',
     'заглянуть внутрь и не узнать своё — ступень есть, толку нет'),

    ('CA5', BC,
     '                Expanded(flex: 3, child: _leftBlock()),',
     '                SizedBox(width: 200, child: _leftBlock()),',
     'вернуть жёсткий слот в 200 dp — подпись стадии обрежется на любом '
     'экране'),

    ('CA6', ES,
     "        'screen': ScreenGeometry.snapshot(),\n",
     '',
     'убрать размер экрана из экспорта — число снова застрянет в журнале, '
     'который никто не выгружает'),

    ('CA7', PH,
     "  if (slots > PowerHistoryService.ringLength) {\n    debugPrint(",
     "  if (slots > PowerHistoryService.ringLength) {\n    if (false) "
     "debugPrint(",
     'отодвинуть запись от условия обёрткой — гейт обязан требовать её '
     'ПЕРВЫМ действием, иначе заглушить её можно не тронув ни буквы'),

    ('CA8', DM,
     "      'stage-peek:',\n",
     '',
     'выкинуть метку из показа — писатель остался, экран о нём молчит'),

    ('CA9', DM,
     '    _refreshStaged();\n',
     '',
     'перестать спрашивать про принятую копию при открытии — полоса '
     'появится только после ручного поиска, то есть с опозданием'),

    ('CA9', IS_,
     '  static Future<ArchiveCandidate?> stagedCopy() async {',
     '  static Future<ArchiveCandidate?> stagedCopyUnused() async {',
     'убрать дешёвую проверку — экрану снова придётся звать тяжёлый поиск'),

    # ── ЭРА CB (+197) ──

    ('CB1', SPS,
     'const double kBandMinSeconds = 180.0;',
     'const double kBandMinSeconds = 120.0;',
     'вернуть двухминутный замер — один спуск снова занимает треть'),

    ('CB2', SPS,
     '    final win = _ledger?.activeWindow;',
     '    final win = _displayWindow;',
     'взять окно набора карточек вместо того, в которое идёт запись — '
     'полоска снова замрёт при расхождении окон'),

    ('CB2', SPS,
     '  int? get atlasActiveWindow => _ledger?.activeWindow;',
     '  int? get atlasActiveWindowUnused => _ledger?.activeWindow;',
     'убрать доступ к активному окну — экрану нечем будет подписать откат'),

    ('CB3', SPU,
     '          tempWindow: svc.atlasActiveWindow,',
     '          tempWindow: null,',
     'перестать отдавать окно карточке — откат снова без объяснения'),

    ('CB3', BC,
     "                .of('measure.temp_window')",
     "                .of('measure.stage_maturing')",
     'подписать откат не тем словом — градусов на экране не будет'),

    ('CB4', ST,
     '          value: _autostartWillRise,',
     '          value: false,',
     'оторвать тумблер от состояния — он перестанет отвечать на свой '
     'же вопрос'),

    ('CB4', ST,
     '      _autostartState != AutostartState.offByOwner;',
     '      _autostartState == AutostartState.on;',
     'приравнять «не решали» к «выключено» — тумблер покажет выключено '
     'и через минуту перекинется сам'),

    ('CB5', CS,
     "            errCode == 'account_suspended' ||\n"
     "            errCode == 'account_deletion_pending') {\n"
     "          throw _AccountGateException(errCode!);\n"
     "        }\n"
     "      }\n"
     "      // 400 / 403 / 404 / 409 / other 4xx",
     "            errCode == 'account_deletion_pending') {\n"
     "          throw _AccountGateException(errCode!);\n"
     "        }\n"
     "      }\n"
     "      // 400 / 403 / 404 / 409 / other 4xx",
     'снять приостановку с ОДНОГО из двух путей запроса — пути разойдутся '
     'молча'),

    # v0.2.2+201: якорь переехал вместе с состоянием аккаунта в своё
    # поле. Предмет мутации прежний — обратимая приостановка не должна
    # становиться неотличимой от запрета навсегда.
    # Якорь берётся вместе с условием: одна и та же запись состояния
    # встречается и в разборе кода отказа, и в восстановлении полосы
    # при старте, и короткий образец совпал бы с обеими.
    ('CB5', CS,
     "    } else if (gate == 'account_suspended') {\n"
     '      _accountGate = CloudSyncStatus.accountSuspended;',
     "    } else if (gate == 'account_suspended') {\n"
     '      _accountGate = CloudSyncStatus.accessDenied;',
     'сделать обратимую приостановку неотличимой от запрета навсегда'),

    # v0.2.2+201: ритм опроса стал переменным, якорь переехал в
    # _armDeviceMeTimer. Предмет расширен: мало того что опрос обязан
    # быть, он обязан учащаться при отказе — это единственный канал, по
    # которому приложение узнаёт о снятии отказа.
    ('CB6', CS,
     '        : const Duration(minutes: 1);',
     '        : const Duration(minutes: 10);',
     'перестать учащать опрос при отказе — о снятии узнаем через десять '
     'минут вместо одной'),

    # v0.2.2+201: прежняя мутация целилась в сердцебиение и ловилась
    # равенством счётчиков гашения. Равенство снято намеренно — оно
    # требовало, чтобы опрос гас везде, где гаснут те два, то есть
    # запрещало саму починку. Целимся прямо в предмет: опрос обязан
    # гаснуть, когда владелец выключил обмен.
    ('CB6', CS,
     '    _deviceMeTimer?.cancel();\n    if (!_enabled || !isRegistered) return;',
     '    if (!_enabled || !isRegistered) return;',
     'перестать гасить опрос при отключении — он переживёт выключение и '
     'будет стучаться мёртвым токеном'),

    ('CB7', HM,
     '    if (w <= 0 || h <= 0) return;',
     '',
     'снять стража нулевого размера — в экспорт снова уедут нули'),

    ('CB8', HT,
     "      await AutostartArm.write('soh-load: fail · $e');",
     '',
     'вернуть немой отказ чтения оценки — три недели вслепую повторятся'),
    # +202: последний исход по порядку в теле метода. Старая редакция
    # CB8 брала окно в 2600 знаков и до него не доставала — гейт зеленел,
    # не увидев предмета. Мутация сторожит именно то, что окно теперь
    # кончается на конце метода, а не на длине.
    ('CB8', HT,
     "        await AutostartArm.write('soh-load: none · записи нет, '\n"
     "            'показываем число машины');",
     '',
     'убрать самый дальний исход чтения оценки — поймает только окно, '
     'дотянутое до конца метода'),

    ('CB8', HT,
     '    await loadHalSohEstimate();\n'
     '    // v0.2.0+199: норма изоляции.',
     '    // v0.2.0+199: норма изоляции.',
     'убрать чтение из начала запуска — оно снова окажется за тяжёлой '
     'работой или пропадёт вовсе'),

    ('CB9', TST,
     'final int _pastThreshold = kBandMinSeconds.toInt() + 10;',
     'final int _pastThreshold = 130;',
     'вернуть жёсткое число в тест — следующая смена порога снова уронит '
     'CI после зелёной церемонии'),

    # ── ЭРА CC (+199) ──

    ('CC1', EXP,
     '                      mean: _meanOf(b, w),',
     '                      mean: null,',
     'вернуть пустые клетки в картинку — переслать её снова будет незачем'),

    ('CC1', EXP,
     '      final image = await obj.toImage(pixelRatio: 2.0);',
     '      final image = await obj.toImage(pixelRatio: 1.0);',
     'вернуть прежнюю плотность — цифра в клетке расплывётся в сжатом PNG'),

    ('CC2', ATW,
     '                                textScaler: const TextScaler.linear(1.7),',
     '                                textScaler: const TextScaler.linear(1.0),',
     'открыть подробности телефонным шрифтом — нажатие ведёт на '
     'нечитаемый экран, а это хуже отсутствия нажатия'),

    ('CC2', ATW,
     "                      Text(S.of('atlas.tap_for_detail'),",
     "                      Text(S.of('atlas.view_only'),",
     'оставить подпись «подробности на телефоне» при живых клетках — '
     'экран будет врать про себя'),

    ('CC3', DW,
     "                        label: S.of('dash.insulation'),",
     "                        label: S.of('dash.total_energy'),",
     'вернуть накопительный итог вместо показателя безопасности'),

    ('CC3', HT,
     '  static const int _kInsulBaselineMin = 20;',
     '  static const int _kInsulBaselineMin = 1;',
     'объявить нормой один замер — оценка станет совпадением, а не нормой'),

    ('CC3', DW,
     '  if (mOhm < base * 0.5) return _Insul.watch;',
     '  if (mOhm < base * 0.6) return _Insul.watch;\n'
     '  if (mOhm < base * 0.5) return _Insul.watch;',
     'развести пороги по двум местам — цвет и подпись однажды разойдутся, '
     'как уже разошлись в первой редакции'),

    ('CC4', HT,
     "    if (e.name == 'insulation_resistance') {\n"
     "      unawaited(refreshInsulationBaseline());\n"
     "    }",
     '',
     'отрезать пересчёт нормы от прихода замера — норма замрёт на той, '
     'что успела набраться при запуске'),

    ('CC5', TAB,
     '            Decoder("pack_voltage_fine", "V", ValueSource.DOUBLE,',
     '            Decoder("pack_voltage_fine", "V", ValueSource.INT,',
     'читать дробное напряжение как целое — придёт ноль, и весь смысл '
     'канала пропадёт молча'),

    # ── ЭРА CD (+200) ──

    # v0.2.2+201: у вызова появилось ожидание, якорь обновлён.
    ('CD1', CS,
     '      await _applyAccountGate(e);\n'
     '    } catch (e) {\n'
     '      // Heartbeat failure is non-fatal',
     '    } catch (e) {\n'
     '      // Heartbeat failure is non-fatal',
     'вернуть сердцебиению общий перехват — самый частый запрос снова '
     'проглотит отказ ворот, как это и нашёл Друг 2'),

    ('CD2', CS,
     "    if (gate == 'account_pending') {",
     "    if (gate == 'account_pending_x') {",
     'сломать единственную раскладку кодов — ожидание одобрения станет '
     'запретом навсегда'),

    # v0.2.2+201: отдельный перечень отказных состояний удалён,
    # сердцебиение спрашивает у состояния аккаунта. Предмет прежний —
    # в отказе оно обязано затихать.
    # Якорь с последующей строкой: такое же условие стоит и в единой
    # точке записи состояния, короткий образец совпал бы с обоими.
    ('CD3', CS,
     '    if (_accountGate != null) {\n'
     '      // v0.2.2+201. Здесь стояло обоснование',
     '    if (false) {\n'
     '      // v0.2.2+201. Здесь стояло обоснование',
     'вернуть сердцебиению стук раз в минуту там, где сервер отказывает'),

    ('CD4', DSH,
     '        const _AccountBanner(),',
     '',
     'снять полосу с главного экрана — состояние опять спрячется в '
     'настройках, куда владелец не заходит'),

    # v0.2.2+201: тело признака приведено к той же раскладке, которой
    # экран берёт текст. Предмет мутации прежний.
    ('CD4', CS,
     '  bool get accountNeedsAttention => accountGateStringKey(_status) != null;',
     '  bool get accountNeedsAttention => false;',
     'заставить признак всегда молчать — полоса есть, а показать ей нечего'),

    ('CD5', CS,
     'String? accountGateStringKey(CloudSyncStatus s) {',
     'String? accountGateStringKeyUnused(CloudSyncStatus s) {',
     'убрать общую раскладку слов — экраны заведут свои копии и разойдутся'),

    ('CD6', DSH,
     '      ScaffoldMessenger.of(context).showSnackBar(',
     '      debugPrint(',
     'вернуть свайпу молчание про аккаунт — тишина снова прочитается как '
     '«всё в порядке»'),

    # ─── эра CE (+201) «Состояние аккаунта — от сервера» ────────────
    # Якорь взят дословно из файла: между «on _AccountGateException» и
    # «rethrow» лежит длинное примечание, и склейка их в одну строку
    # (как было в первой редакции) в файле не встречается.
    ('CE1', CS,
     '      rethrow;\n    } catch (e) {\n      _lastPullError = e.toString();',
     '      _lastPullError = 0;\n    } catch (e) {\n      _lastPullError = e.toString();',
     'вернуть скачиванию проглатывание отказа — свайп снова погасит полосу'),

    ('CE2', CS,
     '      await _applyAccountGate(e);\n    } catch (e) {',
     '      _applyAccountGate(e);\n    } catch (e) {',
     'убрать ожидание у разбора отказа — порядок двух записей снова станет '
     'случайным'),

    ('CE3', CS,
     '      _status = _accountGate!;\n    } else if (_lastError != null',
     '      _status = CloudSyncStatus.idle;\n    } else if (_lastError != null',
     'вернуть пересчёту право затирать состояние аккаунта'),

    ('CE4', CS,
     '    _accountGate = next;',
     '    _accountGate = next;\n    if (_syncInProgress) _accountGate = null;',
     'дать постороннему условию снимать полосу без доказательства'),

    ('CE5', CS,
     '    unawaited(fetchDeviceMe());\n    notifyListeners();',
     '    notifyListeners();',
     'убрать немедленный вопрос серверу при отказе — владелец снова ждёт '
     'до десяти минут'),

    ('CE6', CS,
     '    _lastPullAt = null;\n    _armDeviceMeTimer();',
     '    _armDeviceMeTimer();',
     'не сбрасывать отсчёт скачивания при снятии отказа — короткая '
     'приостановка снова оставит обмен молчать'),

    ('CE7', CS,
     '      // v0.2.2+201. Здесь стояло обоснование',
     "      // gated — syncOnce's probe is enough traffic.\n"
     '      // v0.2.2+201. Здесь стояло обоснование',
     'вернуть ложное обоснование молчания сердцебиения'),

    ('CE8', CS,
     '    _setStatus(CloudSyncStatus.syncing);',
     '    _status = CloudSyncStatus.syncing;',
     'вернуть прямую запись на входе цикла — полоса снова гаснет в момент '
     'начала обмена'),

    ('CE9', CS,
     "      case 'deletion_pending':\n        return CloudSyncStatus.accountDeletionPending;",
     "      case 'deletion_pending_unused':\n        return CloudSyncStatus.accountDeletionPending;",
     'выбить одно из шести значений словаря состояний'),

    # Вторая мутация того же гейта: часовой на незнакомом значении. Без
    # него седьмое значение или опечатка сервера СНИМУТ полосу — это
    # опаснее, чем лишняя полоса.
    ('CE9', CS,
     "    if (next == null && raw != 'approved') {",
     '    if (false) {',
     'убрать часового на незнакомом состоянии — непонятое слово снимет '
     'полосу и возобновит обмен в стену'),

    ('CE10', CS,
     '  bool get accountNeedsAttention => accountGateStringKey(_status) != null;',
     '  bool get accountNeedsAttention => _gatedStates.contains(_status);',
     'развести признак полосы и её текст по разным спискам — экран снова '
     'сможет упасть на восклицательном знаке'),

    # ─── эра CF (+202) «Порог охвата, изоляция, немые отбраковки» ────
    ('CF1', CONN,
     '  static const double _kSohMinDeltaSocPct = 40.0;',
     '  static const double _kSohMinDeltaSocPct = 20.0;',
     'развести два порога охвата — одна таблица получит две несравнимые '
     'оценки'),
    ('CF2', HT,
     '      if (row != null && row.deltaSocCovered < _kHalSohMinDeltaSocPct) {',
     '      if (false) {',
     'снять отбор при чтении в пути HAL — узкая старая запись снова '
     'доедет до экрана'),
    ('CF3', CONN,
     '        if (row.deltaSocCovered < _kSohMinDeltaSocPct) {',
     '        if (false) {',
     'снять отбор при чтении в пути адаптера — узкая запись id=1 встанет '
     'на место отвергнутой id=2'),
    ('CF4', DSH,
     "    final sohBms = svc.readNumeric('790', '0029');",
     "    final double? sohBms = null;",
     'убрать источник нижней ступени лестницы — на месте отвергнутой '
     'оценки окажется прочерк вместо числа машины'),
    ('CF5', DW,
     '            minDeltaSocPct: hal.halSohMinDeltaSocPct,',
     '            minDeltaSocPct: 40.0,',
     'вписать порог в объяснение числом — объяснение разойдётся с '
     'проверкой при следующей смене порога'),
    ('CF6', HT,
     "    // _continuousWindow (30 с) убрана — она противоречила этой.\n"
     "    'insulation_resistance',",
     "    // _continuousWindow (30 с) убрана — она противоречила этой.",
     'убрать изоляцию из событийных — срок годности снова погасит '
     'разрешение показывать'),
    ('CF6', HT,
     "    // одной строки здесь.\n    'insulation_resistance',",
     '    // одной строки здесь.',
     'убрать изоляцию из удерживаемых — значение перестанет доходить до '
     '_lastGood, и ячейка снова станет пустой навсегда'),
    ('CF6', HT,
     '    if (_eventDriven.contains(name)) return s.value;',
     '',
     'вернуть срок годности событийному значению — разрешение показывать '
     'переживёт само значение, и ячейка станет пустой при живом '
     'разрешении'),
    ('CF7', HT,
     "      unawaited(AutostartArm.write(\n"
     "          'soh-drop: нет заряда на начало сессии, считать не из чего'));\n"
     "      return;",
     '      return;',
     'вернуть молчание первому раннему выходу — сессия снова исчезнет '
     'без следа'),
    ('CF8', DVW,
     '                          maxLines: 1,\n'
     '                          overflow: TextOverflow.ellipsis,\n',
     '',
     'снять ограничение длины с подписи на драйверском экране — длинный '
     'текст снова переполнит строку в Row'),
    ('CF7', HT,
     "      unawaited(AutostartArm.write('soh-drop: '\n"
     "          'расчёт ${sohPct.toStringAsFixed(1)}% вне коридора 50…110% · '\n"
     "          'охват ${deltaSocPct.toStringAsFixed(1)}% · '\n"
     "          'набрано ${chargeAh.toStringAsFixed(1)} А·ч'));",
     "      unawaited(AutostartArm.write('soh-drop: '\n"
     "          'расчёт вне коридора 50…110%'));",
     'оставить запись, но снять из неё все числа — журнал перестанет '
     'объяснять, насколько результат вышел за коридор'),

    # ── ЭРА CG (+203) ──
    #
    # Эра закрывает дефект, который церемония пропускала восемь версий:
    # страж, отбраковывающий 100 % данных, оставался зелёным, потому что
    # ни один прибор не смотрел на числа из машины. Мутации ниже бьют по
    # каждому гейту эры с обеих сторон.

    ('CG1', HT,
     "    'insulation_resistance': (0.01, 100),",
     "    'insulation_resistance': (1000, 100000),",
     'вернуть стража изоляции в килоомы — ровно тот дефект, что жил с '
     '+84 и отбраковывал все замеры до единого'),
    ('CG1', HT,
     "    'insulation_resistance': (0.01, 100),",
     "    'insulation_resistance': (1.0, 100),",
     'поднять низ стража до единицы — настоящее падение изоляции будет '
     'выброшено вместе с мусором, то есть ячейка промолчит именно тогда, '
     'когда обязана заговорить'),

    ('CG2', HT,
     "    return _heldValue('insulation_resistance', _coreHold);",
     "    final raw = _heldValue('insulation_resistance', _coreHold);\n"
     "    return raw == null ? null : raw * 0.001;",
     'вернуть второе умножение в геттер — на экране будет 0,0147 вместо '
     '14,7'),
    ('CG2', HT,
     '      _insulBaselineMOhm = med;',
     '      _insulBaselineMOhm = med * 0.001;',
     'вернуть умножение в расчёт нормы — приговор станет сравнивать '
     'настоящее число с нормой в тысячу раз меньшей'),
    ('CG2', OVR,
     '            scale = 0.001,',
     '            scale = 1.0,',
     'снять масштаб со стороны Kotlin — придут килоомы, и на экране '
     'окажется четырёхзначное число мегаом'),

    ('CG3', HT,
     "    'speed': (0, 220),",
     "    'speed': (0, 100),",
     'сузить стража скорости ниже наблюдённого максимума 121 — на трассе '
     'скорость будет молча пропадать'),
    ('CG3', HT,
     "    'pack_current': (-600, 600),",
     "    'pack_current': (-100, 600),",
     'сузить стража тока заряда ниже наблюдённых −193 А — быстрая зарядка '
     'станет невидимой'),

    ('CG4', HT,
     "    'motor_rpm': (-25000, 25000),",
     "    'motor_rpm': (0, 25000),",
     'вернуть стража оборотов к нулю — задний ход снова выбросит 2 % '
     'замеров, и на панели обороты в нём погаснут'),

    ('CG5', TAB,
     '            Decoder("speed", "km/h", ValueSource.INT,',
     '            Decoder("odometer", "km/h", ValueSource.INT,',
     'подписать фид чужим утверждённым именем — пара с каталогом '
     'разойдётся'),
    ('CG5', TAB,
     '        put("BYDAutoStatisticDevice|0x47300018",',
     '        put("BYDAutoStatisticDevice|0x47300019",',
     'завести фид, которого в каталоге нет вовсе — так и появляются '
     'выдуманные адреса'),

    ('CG6', TAB,
     '            Decoder("cell_idx_lowest", "", ValueSource.INT,',
     '            Decoder("cell_idx_highest", "", ValueSource.INT,',
     'вернуть перекрещенную подпись младшему номеру ячейки'),
    ('CG6', TAB,
     '            Decoder("cell_idx_highest",  "", ValueSource.INT,',
     '            Decoder("cell_idx_lowest",  "", ValueSource.INT,',
     'вернуть перекрещенную подпись старшему номеру ячейки'),

    ('CG7', IS_,
     '    final names = <String>[kStagedName, kFixedName];',
     '    final names = <String>[];',
     'опустошить список известных имён — единственная работающая на '
     'машине ступень поиска перестанет искать'),
    ('CG7', IS_,
     "        await consider(f, n == kStagedName ? 'staged' : 'fixed');",
     '        continue;',
     'выпотрошить первую ступень, оставив её литерал на месте — найденный '
     'файл не дойдёт до отбора'),

    ('CG8', DM,
     '    final bool isPhone = hal.platformProbed && !hal.canUseHal;',
     '    final bool isPhone = !hal.canUseHal;',
     'спросить признак до окончания опроса платформы — на холодном старте '
     'кнопки подменятся под пальцем'),
    ('CG8', DM,
     '            if (isPhone)\n'
     '            Padding(\n'
     '              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),\n'
     '              child: OutlinedButton.icon(\n'
     '                icon: const Icon(Icons.attach_file),',
     '            if (!hal.canUseHal)\n'
     '            Padding(\n'
     '              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),\n'
     '              child: OutlinedButton.icon(\n'
     '                icon: const Icon(Icons.attach_file),',
     'завести кнопке собственную проверку устройства — два признака '
     'разойдутся молча'),

    ('CG9', L10,
     "    'dataimp.help_title': 'Не получилось?',",
     '',
     'снять новый ключ из русского набора — на русском экране появится '
     'английская строка'),
    ('CG9', L10,
     "    'dataimp.step1': '1. In the car file manager pick the archive, press '",
     "    'dataimp.intro': 'Reads an export archive back.',\n"
     "    'dataimp.step1': '1. In the car file manager pick the archive, press '",
     'вернуть снятый ключ в один из языков — мёртвые ключи так и '
     'накапливаются'),

    # CC4 держал только вторую половину своего условия: мутация на
    # побочное действие В ГЕТТЕРЕ появилась только сейчас, вместе с
    # починкой окна гейта. +203.
    ('CC4', HT,
     "    return _heldValue('insulation_resistance', _coreHold);",
     '    unawaited(refreshInsulationBaseline());\n'
     "    return _heldValue('insulation_resistance', _coreHold);",
     'вернуть побочное действие в геттер, читаемый на каждой перерисовке'),

    # CH1 — полный паритет наборов, +204. Обе стороны: ключ, потерявший
    # русскую половину, и ключ, потерявший английскую.
    ('CH1', L10,
     "    'settings.dtc.title': 'Диагностика (DTC)',",
     '',
     'снять русский перевод — ключ снова живёт только в английском '
     'наборе'),
    ('CH1', L10,
     "    'settings.dtc.title': 'Diagnostics (DTC)',",
     '',
     'снять английскую половину — русский ключ остаётся без пары'),

    # CH2 — удалённые ключи, +204. Обе карты: возврат в английскую и
    # возврат в русскую.
    ('CH2', L10,
     "    'settings.adapter.not_connected': 'Not connected',",
     "    'settings.adapter.title': 'ELM327 BLE adapter',\n"
     "    'settings.adapter.not_connected': 'Not connected',",
     'вернуть мёртвый ключ в английскую карту'),
    ('CH2', L10,
     "    'trip.charging_power': 'Мощность зарядки',",
     "    'trip.charging_power': 'Мощность зарядки',\n"
     "    'trip.hv_bus_v': 'Напряжение шины HV',",
     'вернуть мёртвый ключ в русскую карту'),

    # CH3 — подсказки экрана зарядки, +204. Обе иголки по очереди.
    ('CH3', CW,
     "          label: S.of('chg.counter_hdr'),\n"
     "          value: counterRaw != null ? '$counterRaw' : '—',\n"
     "          hint: '',",
     "          label: S.of('chg.counter_hdr'),\n"
     "          value: counterRaw != null ? '$counterRaw' : '—',\n"
     "          hint: S.of('chg.counter_raw'),",
     'вернуть подсказку сырого счётчика на экран зарядки '
     '(якорь перепришпилен в +205: подпись стала ключом)'),
    ('CH3', CW,
     "            : '—',\n"
     "        hint: '',\n"
     "      ),\n"
     "      _Metric(\n"
     "        label: S.of('chg.soc_gain'),",
     "            : '—',\n"
     "        hint: 'ΔSOC × pack kWh',\n"
     "      ),\n"
     "      _Metric(\n"
     "        label: S.of('chg.soc_gain'),",
     'вернуть формулу прироста заряда на видимую плитку'),

    # CI1 — цепь ротации, +205. По мутации на каждое звено.
    ('CI1', CONN,
     "      unawaited(_rotateHalRetention());",
     "",
     'выбить крюк ротации из финализатора поездки'),
    ('CI1', CONN,
     "      final n = await db.rotateHalSamples(\n"
     "          DateTime.now().subtract(Duration(days: days)));",
     "      final n = 0;",
     'выбить вызов базы из метода ротации'),
    ('CI1', DB,
     "            ..limit(1, offset: batch - 1))",
     "            )",
     'сломать граничную порционность — удаление одним запросом'),
    ('CI1', IS_,
     "    'hal_retention_days',",
     "",
     'выбить ключ настройки из списка переезжающих prefs'),

    # CI2 — расшифровка источника, +205.
    ('CI2', DW,
     "                              color: Colors.white54)),\n"
     "                    ],\n"
     "                  ],\n"
     "                ),\n"
     "              ],\n"
     "            ),\n"
     "          ],\n"
     "        ),\n"
     "      ),\n"
     "    );\n"
     "  }\n"
     "}",
     "                              color: Colors.white54)),\n"
     "                    ],\n"
     "                  ],\n"
     "                ),\n"
     "              ],\n"
     "            ),\n"
     "            const Text(\n"
     "                'live · avg cell × series count  ·  hv bus · "
     "790/0x0015 (post-contactor)',\n"
     "                style: TextStyle(fontSize: 11, color: Colors.grey)),\n"
     "          ],\n"
     "        ),\n"
     "      ),\n"
     "    );\n"
     "  }\n"
     "}",
     'вернуть расшифровку источника под напряжение пака'),

    # CI3 — нарисованность ключей, +205.
    ('CI3', CW,
     "        label: S.of('chg.imax_hdr'),",
     "        label: 'I-MAX SET',",
     'снять отрисовку ключа — ключ есть в картах, но не рисуется'),

    # CJ1 — автопоказ зарядки, +206. Обе половины проводки.
    ('CJ1', HUS,
     "                autoPushWhenVisible: true,",
     "                autoPushWhenVisible: _index == 0,",
     'вернуть ГУ старое условие — автопоказ снова только с «Вождения»'),
    ('CJ1', HM,
     "        // Auto-push only when the user is on Dashboard (index 0).\n"
     "        autoPushWhenVisible: _index == 0,",
     "        // Auto-push only when the user is on Dashboard (index 0).\n"
     "        autoPushWhenVisible: true,",
     'выровнять телефон под ГУ — автопоказ с любой вкладки телефона'),
    ('CJ1', HM,
     "        autoPushWhenVisible: true,\n"
     "        // v0.1.62+161 (§6.11): sticky plate on every tab but «Замеры».\n"
     "        showAtlasPlate: _index != 2,",
     "        autoPushWhenVisible: _index == 0,\n"
     "        // v0.1.62+161 (§6.11): sticky plate on every tab but «Замеры».\n"
     "        showAtlasPlate: _index != 2,",
     'вернуть BZ3 старое условие — высокий каркас снова ждёт «Вождение»'),

    # CK1 — цепь флага кабеля, +207. По мутации на звено.
    ('CK1', CDO,
     '        "BYDAutoChargingDevice|0x0A50000D" to Decoder(\n'
     '            "charger_connect_state", "", ValueSource.INT,\n'
     '            notes = "CHARGING_CHARGER_CONNECT_STATE; 1=plugged 0=unplugged; recon 20260814_165329"),\n',
     '',
     'выбить запись декодера — события снова режутся в drop'),
    ('CK1', HT,
     "    'charger_connect_state',",
     '',
     'выбить имя из липких — флаг умирает на первом удержании'),
    ('CK1', CB,
     'bool _chargingSessionNow(ConnectionService svc, HalTelemetryService hal) =>\n'
     '    svc.isCharging ||\n'
     '    (hal.halChargerConnected ?? false) ||\n'
     '    hal.halChargingActive;',
     'bool _chargingSessionNow(ConnectionService svc, HalTelemetryService hal) =>\n'
     '    svc.isCharging;',
     'ослепить помощник до одного OBD-источника'),
    ('CK1', CB,
     '        if (mounted &&\n'
     '            _chargingSessionNow(context.read<ConnectionService>(),\n'
     '                context.read<HalTelemetryService>())) {\n'
     '          _openChargingScreen(context);\n'
     '        }',
     '        if (mounted && svc.isCharging) _openChargingScreen(context);',
     'вернуть перепроверке показа голый OBD-предикат'),
    ('CK1', CB,
     '      body: _chargingSessionNow(svc, hal)\n'
     '          ? const ChargingViewWide()',
     '      body: svc.isCharging\n'
     '          ? const ChargingViewWide()',
     'вернуть развилке маршрута голый OBD-предикат'),
    ('CK1', DVT,
     '    final isCharging = svc.isCharging || hal.halChargingActive;',
     '    final isCharging = svc.isCharging;',
     'ослепить значок ⚡ на BZ3'),

    # CI1 (+208) — второй финализатор. Обе стороны нового звена.
    ('CI1', HT,
     "    unawaited(_rotateHalRetention());",
     "",
     'выбить крюк ротации из финализатора машины HAL'),
    ('CI1', HT,
     "      final n = await db.rotateHalSamples(\n"
     "          DateTime.now().subtract(Duration(days: days)));",
     "      final n = 0;",
     'выбить вызов базы из метода ротации машины HAL'),

    # CL1 — стражи +208. Снятие и порча смысловой границы.
    ('CL1', HT,
     "    'cell_temp_lowest': (-40, 150),",
     "",
     'снять страж cell_temp_lowest — мусор 1e9 снова проходит'),
    ('CL1', HT,
     "    'cell_temp_lowest': (-40, 150),",
     "    'cell_temp_lowest': (-40, 2000000000),",
     'растянуть температурную полосу до мусора'),

    # CL2 — цепь пистолета. Kotlin-имя, липкость, заголовок.
    ('CL2', CDO,
     '            "charging_gun_state", "", ValueSource.INT,',
     '            "charging_gun_connect_candidate", "", ValueSource.INT,',
     'вернуть кандидатское имя — переименование наполовину'),
    ('CL2', HT,
     "    'charging_gun_state',",
     "",
     'выбить тип пистолета из липких'),
    ('CL2', CB,
     "    final gunType = hal.halChargerTypeLabel;",
     "    final String? gunType = null;",
     'отвязать заголовок от типа пистолета'),

    # CM1 — экран зарядки на HAL, +210.
    ('CM1', CW,
     '    if (!svc.isBleConnected) return const SizedBox.shrink();',
     '',
     'вернуть карточку UDS-лога на ГУ без донгла'),
    ('CM1', CW,
     '    final kw = kwObd > 0 ? kwObd : (kwHal ?? kwSlope ?? 0);',
     '    final kw = kwObd;',
     'отрезать HAL-цепочку мощности — экран снова показывает тире'),
    ('CM1', CW,
     '      final hh = hal.halChargingHistory;',
     '      final hh = <HalChargePoint>[];',
     'отрезать HAL-историю — графики снова пустые'),
    ('CM1', CW,
     '      if (svc.isBleConnected) ...[',
     '      ...[',
     'вернуть донгловые плитки на ГУ'),

    # CM2 — неисправности, +210.
    ('CM2', ST_,
     '                    ..._issueLines(status.issueRaw!, fg),',
     "                    Text(status.issueRaw!,\n"
     "                        style: TextStyle(\n"
     "                            fontSize: 12,\n"
     "                            color: fg,\n"
     "                            fontFamily: 'monospace')),",
     'вернуть сырой JSON на экран'),

    # CM3 — пистолет первичен, +210.
    ('CM3', HT,
     "    final gun = halValue('charging_gun_state');\n"
     "    if (gun != null) return gun >= 1.5;\n"
     "    final v = halValue('charger_connect_state');",
     "    final v = halValue('charger_connect_state');",
     'вернуть флаг-первичность — AC-сессии снова без кабельного сигнала'),
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
