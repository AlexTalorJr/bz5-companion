package com.bz5companion.bz5_companion

import android.app.Activity
import android.content.Intent
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity for BZ5 Companion.
 *
 * v0.1.27: registers BydNativePlugin so the head-unit native API is
 * reachable via MethodChannel("bz5_companion/native_car"). The plugin
 * is a no-op on phones (BYDAutoBodyworkDevice reflection returns
 * ClassNotFoundException, NativeDetector reports isOnHeadUnit=false),
 * so registering it unconditionally is safe.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        /** v0.1.93+192: свой код запроса, чтобы не пересечься с
         *  BYDAUTO-разрешениями и с выбором файла. */
        const val REQ_STORAGE_PERM = 0x5A11
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(BydNativePlugin())
        // v0.1.56+155: autostart net arm/disarm. Dart calls "arm" once
        // per launch on the head unit (canUseHal gate) — the initial
        // manual wind-up that the START_STICKY contract requires.
        //
        // v0.1.72+171: тот же вызов теперь ещё и ЗАПОМИНАЕТ взвод.
        // BootReceiver просыпается в процессе, где нет ни Flutter-
        // движка, ни сервиса, и спросить «нужен ли автозапуск» ему
        // больше не у кого. Флаг ставится здесь, а не в сервисе,
        // потому что здесь он ставится ровно тогда, когда владелец
        // открыл приложение на ГУ, — и только на ГУ: Dart-сторона за
        // гейтом canUseHal.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "bz5/autostart",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "arm" -> {
                    try {
                        AutostartPrefs.setArmed(this, true)
                        val i = Intent(this, AutostartService::class.java)
                            .setAction(AutostartService.ACTION_ARM)
                        if (android.os.Build.VERSION.SDK_INT >= 26) {
                            startForegroundService(i)
                        } else {
                            startService(i)
                        }
                        result.success(true)
                    } catch (t: Throwable) {
                        result.success(false)
                    }
                }
                "disarm" -> {
                    try {
                        AutostartPrefs.setArmed(this, false)
                        val i = Intent(this, AutostartService::class.java)
                            .setAction(AutostartService.ACTION_STOP)
                        startService(i)
                        result.success(true)
                    } catch (t: Throwable) {
                        result.success(false)
                    }
                }
                // v0.1.74+173: состояние для переключателя. До этого
                // патча спросить у нативной стороны «взведено ли»
                // было нечем, и UI пришлось бы держать вторую копию
                // правды на стороне Dart.
                // v0.1.75+174: отдать журнал наружу, чтобы он уехал
                // диаг-дампом. Экспортный ZIP 29.07 дважды приехал
                // обрезанным, диаг-дамп — целым оба раза.
                "marker" -> result.success(AutostartMarker.read(this))
                "isArmed" -> result.success(AutostartPrefs.isArmed(this))
                "optedOut" -> result.success(AutostartPrefs.optedOut(this))
                else -> result.notImplemented()
            }
        }
        // v0.1.73+172: путь установки. Проба только читает; pick /
        // stage / launch — попытка поставить APK поверх, без которой
        // каждый патч продолжит стоить полного стирания данных.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ApkInstall.CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "probe" -> result.success(ApkInstall.probe(this))
                "pick" -> {
                    // Ответ придёт из onActivityResult: SAF — это
                    // отдельная активити, и вернуться раньше нечем.
                    if (claimPending(result, ApkInstall.REQ_PICK)) {
                        try {
                            ApkInstall.pick(this)
                        } catch (t: Throwable) {
                            releasePending()
                            result.success(mapOf<String, Any?>(
                                "ok" to false,
                                "error" to
                                    "${t.javaClass.simpleName}: ${t.message}",
                            ))
                        }
                    }
                }
                "pickContent" -> {
                    if (claimPending(result, ApkInstall.REQ_PICK)) {
                        try {
                            ApkInstall.pickContent(this)
                        } catch (t: Throwable) {
                            releasePending()
                            result.success(mapOf<String, Any?>(
                                "ok" to false,
                                "error" to
                                    "${t.javaClass.simpleName}: ${t.message}",
                            ))
                        }
                    }
                }
                "stage" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) {
                        result.success(mapOf<String, Any?>(
                            "ok" to false, "error" to "no uri"
                        ))
                    } else {
                        offMain(result) { ApkInstall.stage(this, uri) }
                    }
                }
                // v0.1.88+187: тот же выбранный файл, но в слот архива.
                // Копирование в рабочем потоке — архив это десятки
                // мегабайт, и главный поток на них держать нельзя.
                "stageArchive" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) {
                        result.success(mapOf<String, Any?>(
                            "ok" to false, "error" to "no uri"
                        ))
                    } else {
                        offMain(result) { ApkInstall.stageArchive(this, uri) }
                    }
                }
                // v0.1.88+187: только чтение, ничего не запускает.
                "storageProbe" ->
                    offMain(result) { ApkInstall.storageProbe(this) }
                // v0.1.93+192 — ЗАПРОС РАЗРЕШЕНИЯ НА ХРАНИЛИЩЕ.
                //
                // Обещан был ещё в +187 и не сделан: тогда появился только
                // ПОКАЗ состояния, а замер требует ещё и запроса. Поле
                // 03.08 отдало `read_perm=false`, и это оставило версию
                // владельца («дело в правах») строго непроверенной.
                //
                // Отдельно от `requestRuntimePermissions`, потому что тот
                // просит только разрешения BYDAUTO: `BydPermissions.
                // DANGEROUS` собирается из карты BYDAUTO-прав, и
                // `READ_EXTERNAL_STORAGE` в неё не входит.
                //
                // Ответ придёт в системный колбэк, не сюда, поэтому здесь
                // возвращается только «спросили или уже было». Настоящее
                // состояние покажет проба следующим нажатием — так честнее,
                // чем обещать результат, которого мы ещё не знаем.
                "requestStoragePermission" -> {
                    val perm = android.Manifest.permission.READ_EXTERNAL_STORAGE
                    // Проверка вынесена в `ApkInstall`: там получатель —
                    // параметр `Context`, и сверка базовой линии остаётся
                    // без новых имён. `ActivityCompat.requestPermissions`
                    // уже стоит в `BydNativePlugin` и собран на CI.
                    val had = ApkInstall.hasReadStoragePermission(this)
                    if (!had) {
                        try {
                            // ActivityCompat, а не голый Activity: так уже
                            // делает BydNativePlugin, и на минимальном API
                            // это единственный корректный путь.
                            ActivityCompat.requestPermissions(
                                this, arrayOf(perm), REQ_STORAGE_PERM
                            )
                        } catch (t: Throwable) {
                            AutostartMarker.write(
                                this,
                                "storage-perm: request failed — " +
                                    "${t.javaClass.simpleName}"
                            )
                        }
                    }
                    result.success(mapOf<String, Any?>(
                        "ok" to true,
                        "granted_before" to had,
                        "requested" to !had,
                    ))
                }
                "launch" -> {
                    // v0.1.77+176: попытка идёт через
                    // startActivityForResult, и resultCode придёт в
                    // onActivityResult. Сам вызов отвечает сразу — он
                    // сообщает, ЧТО запустилось; ответ установщика
                    // приезжает второй строкой в журнал попытки.
                    result.success(ApkInstall.launch(this))
                }
                "unknownSources" ->
                    result.success(ApkInstall.openUnknownSources(this))
                // ── +176 §A1: обозреватель ────────────────────────
                "openTree" -> {
                    if (claimPending(result, ApkInstall.REQ_TREE)) {
                        val r = ApkInstall.openTree(this)
                        if (r["ok"] != true) {
                            // Ни один из двух интентов дерева не пошёл —
                            // ответа из onActivityResult не будет, и
                            // держать Result значит подвесить экран.
                            releasePending()
                            result.success(r)
                        }
                    }
                }
                "rememberTree" -> {
                    val uri = call.argument<String>("uri")
                    result.success(
                        if (uri == null) {
                            mapOf<String, Any?>(
                                "ok" to false, "error" to "no uri"
                            )
                        } else {
                            ApkInstall.rememberTree(this, uri)
                        }
                    )
                }
                "listApks" -> offMain(result) { ApkInstall.listApks(this) }
                "openDoor" -> {
                    val name = call.argument<String>("door")
                    result.success(
                        if (name == null) {
                            mapOf<String, Any?>(
                                "ok" to false, "error" to "no door"
                            )
                        } else {
                            ApkInstall.openDoor(this, name)
                        }
                    )
                }
                // Путь к подготовленному файлу отдаётся наружу, чтобы
                // §B скачивал ровно туда, откуда читает провайдер, а не
                // в место, которое Dart считает тем же самым.
                "stagedPath" -> result.success(mapOf<String, Any?>(
                    "ok" to true,
                    "path" to
                        java.io.File(cacheDir, ApkFileProvider.STAGED).path
                ))
                else -> result.notImplemented()
            }
        }
    }

    /** Ответ SAF-выбора. Держится ровно один запрос за раз. */
    private var pendingPick: MethodChannel.Result? = null

    /** Какой именно ответ мы ждём. v0.1.77+176: запросов стало три
     *  (файл, дерево, установка), и без кода они неразличимы — а
     *  ответить надо по существу каждого. */
    private var pendingCode: Int = 0

    /**
     * Занять единственный слот ожидания.
     *
     * ОДНА КОПИЯ НА ДВА ВЫЗОВА, и это не косметика. В первой редакции
     * +176 охрана слота стояла отдельно в `pick` и в `openTree`, и
     * мутационный харнесс отказался работать: анкер гейта BI8 перестал
     * быть уникальным. Предохранитель «анкер ровно один раз» поймал не
     * свою ошибку, а мою — две копии условия, которые разошлись бы при
     * первой правке одной из них. Слот один, значит и охрана одна.
     *
     * Возвращает true, если слот занят нами и вызывающему можно
     * запускать активити; false — если ответ уже отправлен отказом.
     */
    private fun claimPending(
        result: MethodChannel.Result, code: Int
    ): Boolean {
        if (pendingPick != null) {
            result.success(mapOf<String, Any?>(
                "ok" to false, "error" to "pick already in flight"
            ))
            return false
        }
        pendingPick = result
        pendingCode = code
        return true
    }

    /** Освободить слот, не отвечая: ответ отправляет вызывающий. */
    private fun releasePending() {
        pendingPick = null
        pendingCode = 0
    }

    /**
     * v0.1.77+176 — ТЯЖЁЛУЮ РАБОТУ С ФАЙЛАМИ УБРАТЬ С ГЛАВНОГО ПОТОКА.
     *
     * Обработчики MethodChannel вызываются на платформенном потоке, то
     * есть на главном. Через них теперь проходят две операции, которые
     * там стоять не могут:
     *
     *   • `stage` копирует APK целиком — десятки мегабайт, и читает их
     *     с USB-флешки, у которой скорость чтения непредсказуема;
     *   • `listApks` делает до 64 запросов к DocumentsProvider флешки,
     *     каждый из которых уходит в чужой процесс.
     *
     * Это ровно тот класс отказа, за который проект уже платил дважды:
     * обречённое обращение к мёртвым Downloads на каждую строку маркера
     * (+173) и `readText()` многомегабайтного журнала (+174). Оба раза
     * ANR был маловероятен и оба раза его убирали — потому что
     * срабатывает он раз в сотню случаев и не воспроизводится.
     *
     * Ответ ОБЯЗАН уйти на главном потоке: `MethodChannel.Result` не
     * потокобезопасен, и вызов `success` из рабочего потока — это
     * плавающий отказ канала. Поэтому работа в потоке, ответ через
     * Handler главного лупера.
     */
    private fun offMain(
        result: MethodChannel.Result,
        work: () -> Map<String, Any?>
    ) {
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        Thread {
            val out = try {
                work()
            } catch (t: Throwable) {
                mapOf<String, Any?>(
                    "ok" to false,
                    "error" to "${t.javaClass.simpleName}: ${t.message}"
                )
            }
            main.post { result.success(out) }
        }.start()
    }

    /**
     * Страховка от повисшего Future.
     *
     * onActivityResult вызывается ПЕРЕД onResume — это порядок,
     * гарантированный документацией. Значит если мы вернулись на
     * передний план, а запрос всё ещё висит, то результата не будет
     * никогда: активити выбора не поднялась или умерла молча. Без
     * этого ответа Dart-сторона ждала бы вечно, `finally` не
     * выполнился бы, и кнопка осталась бы заблокированной до
     * перезахода на экран — на экране, которым пользуются один раз и
     * в неудачный момент.
     */
    override fun onResume() {
        super.onResume()
        val pending = pendingPick ?: return
        pendingPick = null
        pendingCode = 0
        pending.success(
            mapOf<String, Any?>("ok" to false, "error" to "no-result")
        )
    }

    override fun onActivityResult(
        requestCode: Int, resultCode: Int, data: Intent?
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        // v0.1.77+176: REQ_INSTALL отвечает НЕ в pendingPick. Ответ
        // установщика — главный неизвестный факт этой темы (пять
        // прогонов 29.07 дали staged_bytes: 0, то есть он не
        // спрашивался ни разу), и потерять его из-за того, что
        // Dart-сторона уже получила ответ на «что запустилось», нельзя.
        // Поэтому resultCode уезжает в журнал автозапуска — канал,
        // который доехал целым оба раза, когда ZIP приезжал обрезанным.
        if (requestCode == ApkInstall.REQ_INSTALL) {
            AutostartMarker.write(
                this,
                "install-result: resultCode=$resultCode" +
                    " data=${data?.dataString ?: "-"}"
            )
            return
        }
        if (requestCode != ApkInstall.REQ_PICK &&
            requestCode != ApkInstall.REQ_TREE
        ) {
            return
        }
        val pending = pendingPick ?: return
        pendingPick = null
        pendingCode = 0
        val uri = data?.data
        pending.success(
            if (resultCode == Activity.RESULT_OK && uri != null) {
                mapOf<String, Any?>(
                    "ok" to true,
                    "uri" to uri.toString(),
                    "tree" to (requestCode == ApkInstall.REQ_TREE)
                )
            } else {
                mapOf<String, Any?>("ok" to false, "error" to "cancelled")
            }
        )
    }
}
