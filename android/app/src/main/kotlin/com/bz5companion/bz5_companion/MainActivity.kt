package com.bz5companion.bz5_companion

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
                else -> result.notImplemented()
            }
        }
    }
}
