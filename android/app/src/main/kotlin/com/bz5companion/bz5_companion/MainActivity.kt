package com.bz5companion.bz5_companion

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

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
    }
}
