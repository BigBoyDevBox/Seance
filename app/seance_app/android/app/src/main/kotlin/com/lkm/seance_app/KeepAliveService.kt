package com.lkm.seance_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Foreground service anchoring Séance's process while SSH sessions are live.
 *
 * Android freezes (and later kills) cached processes once they leave the
 * screen; a frozen process cannot service dartssh2's keepalives, so every
 * open connection drops moments after the app is backgrounded — taking the
 * remote shells with it. Running as a dataSync foreground service keeps the
 * process unfrozen and its sockets alive, at the cost of an ongoing
 * notification the user can see (and switch off in Settings).
 *
 * All control flows through the companion's [start]/[update]/[stop], called
 * from the `seance/keepalive` method channel; this class itself only renders
 * the notification and stops when told.
 */
class KeepAliveService : Service() {

    companion object {
        const val EXTRA_SESSION_COUNT = "sessionCount"
        private const val CHANNEL_ID = "seance.keepalive"
        private const val NOTIFICATION_ID = 1

        /** Whether the service is running; mutated only by its lifecycle. */
        @Volatile
        var isActive = false
            private set

        fun start(context: Context, sessionCount: Int) {
            if (isActive) {
                update(context, sessionCount)
                return
            }
            val intent = Intent(context, KeepAliveService::class.java)
                .putExtra(EXTRA_SESSION_COUNT, sessionCount)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                @Suppress("DEPRECATION")
                context.startService(intent)
            }
        }

        /** Refresh the session count on the running service's notification. */
        fun update(context: Context, sessionCount: Int) {
            if (!isActive) return
            context.getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, notification(context, sessionCount))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }

        private fun notification(context: Context, sessionCount: Int): Notification {
            val sessions = if (sessionCount == 1) "session" else "sessions"
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            return builder
                .setContentTitle("Séance")
                .setContentText(
                    "Keeping $sessionCount $sessions alive in the background."
                )
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isActive = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Session keep-alive",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        description =
                            "Shown while connections are kept alive in the background."
                    }
                )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val count = intent?.getIntExtra(EXTRA_SESSION_COUNT, 1) ?: 1
        startForeground(NOTIFICATION_ID, notification(this, count))
        // Not sticky: only the Dart side knows whether sessions are still
        // live; a service restarted without it would be a zombie anchor.
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int) {
        // Android 15 caps dataSync foreground services (~6 h). Stop cleanly:
        // the app becomes freezable again and sessions drop exactly as they
        // would without the anchor — the reconnect flow already covers that.
        stopSelf()
    }

    override fun onDestroy() {
        isActive = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
