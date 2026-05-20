package com.bz5companion.bz5_companion

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Existing MainActivity wired to register BydNativePlugin.
 *
 * The plugin needs to be registered against the FlutterEngine before
 * any Dart code touches `bz5_companion/native_car`. Doing it here
 * (configureFlutterEngine) ensures it's ready on cold start.
 *
 * If your project uses a different MainActivity (Kotlin or Java),
 * apply the same `flutterEngine.plugins.add(BydNativePlugin())` call.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(BydNativePlugin())
    }
}
