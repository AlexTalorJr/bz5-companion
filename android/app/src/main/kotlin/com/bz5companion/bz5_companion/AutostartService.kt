package com.bz5companion.bz5_companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * v0.1.56+155 — autostart net (вариант D, spec Друга 3 20.07).
 *
 * The head unit (DiLink 5.0, Android 12, restricted standby bucket)
 * blocks FGS launches from boot receivers, but a START_STICKY service
 * is resurrected by ActivityManager itself — recon's LiveMonitorService
 * proved it in the field (self-revived after a night's sleep, 27 min
 * of recording, autostart-receiver log empty). Companion had NO Android
 * service at all, so there was nothing to resurrect; this is that
 * service. Its ONE job on resurrection: bring MainActivity (and with it
 * the whole ordinary Dart pipeline) back up. No data path of its own —
 * no chunks, no second engine, nothing to merge later.
 *
 * Known open question (marker log answers it from the field): Android
 * 12 Background-Activity-Launch policy may silently block startActivity
 * from a background service on stock builds; HU launchers are often
 * laxer. Every attempt is appended to the marker file in Downloads —
 * the recon p112/p113 diagnostic pattern.
 *
 * Lifecycle: Dart arms the net via MethodChannel("bz5/autostart") once
 * per app launch on the head unit (canUseHal gate). Explicit STOP
 * action returns START_NOT_STICKY; the null-intent resurrection path
 * NEVER hits the stop branch (the trap Друг 3 warned about).
 */
class AutostartService : Service() {

    companion object {
        private const val TAG = "Bz5Autostart"
        const val ACTION_ARM = "com.bz5companion.ARM"
        const val ACTION_STOP = "com.bz5companion.STOP"
        private const val CHANNEL_ID = "bz5_autostart"
        private const val NOTIF_ID = 4151
        private const val MARKER = "bz5_companion_autostart_log.txt"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Explicit stop only — a null intent is a STICKY resurrection
        // and must fall through to the relaunch path below.
        if (intent?.action == ACTION_STOP) {
            marker("stop: explicit ACTION_STOP")
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(NOTIF_ID, buildNotification())

        if (intent == null) {
            // Resurrected by the system after a kill/sleep — the whole
            // point of the net. Bring the app up.
            val ok = tryLaunchActivity()
            marker("resurrected: launch=${if (ok) "attempted-no-throw" else "threw"}")
        } else {
            marker("armed: ${intent.action ?: "no-action"}")
        }
        return START_STICKY
    }

    private fun tryLaunchActivity(): Boolean {
        return try {
            val li = Intent(this, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                )
            }
            startActivity(li)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "activity launch failed", t)
            marker("launch exception: ${t.javaClass.simpleName}: ${t.message}")
            false
        }
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "BZ5 Companion autostart",
                        NotificationManager.IMPORTANCE_MIN,
                    ).apply { setShowBadge(false) }
                )
            }
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("BZ5 Companion")
            .setContentText("автостарт взведён")
            .setOngoing(true)
            .build()
    }

    /** Append-only field marker — the recon p112/p113 diagnostic pattern. */
    private fun marker(line: String) {
        try {
            val ts = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
            val f = File("/sdcard/Download/$MARKER")
            f.appendText("$ts  $line\n")
        } catch (t: Throwable) {
            Log.w(TAG, "marker write failed: ${t.message}")
        }
    }
}
