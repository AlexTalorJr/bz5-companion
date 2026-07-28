package com.bz5companion.bz5_companion

import android.app.Activity
import android.content.Intent
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
                    if (pendingPick != null) {
                        result.success(mapOf<String, Any?>(
                            "ok" to false, "error" to "pick already in flight"
                        ))
                    } else {
                        pendingPick = result
                        try {
                            ApkInstall.pick(this)
                        } catch (t: Throwable) {
                            pendingPick = null
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
                        result.success(ApkInstall.stage(this, uri))
                    }
                }
                "launch" -> result.success(ApkInstall.launch(this))
                "unknownSources" ->
                    result.success(ApkInstall.openUnknownSources(this))
                else -> result.notImplemented()
            }
        }
    }

    /** Ответ SAF-выбора. Держится ровно один запрос за раз. */
    private var pendingPick: MethodChannel.Result? = null

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
        pending.success(
            mapOf<String, Any?>("ok" to false, "error" to "no-result")
        )
    }

    override fun onActivityResult(
        requestCode: Int, resultCode: Int, data: Intent?
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != ApkInstall.REQ_PICK) return
        val pending = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        pending.success(
            if (resultCode == Activity.RESULT_OK && uri != null) {
                mapOf<String, Any?>("ok" to true, "uri" to uri.toString())
            } else {
                mapOf<String, Any?>("ok" to false, "error" to "cancelled")
            }
        )
    }
}
