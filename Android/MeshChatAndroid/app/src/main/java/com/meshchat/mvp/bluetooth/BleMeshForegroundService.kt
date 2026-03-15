package com.meshchat.mvp.bluetooth

import android.app.*
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.meshchat.mvp.MainActivity

/**
 * Optional foreground service to keep BLE scanning/advertising alive when the
 * app is backgrounded. The main BluetoothMeshService is instantiated in the
 * ViewModel; this service keeps the process alive on Android's task killer.
 */
class BleMeshForegroundService : Service() {

    override fun onCreate() {
        super.onCreate()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        val channel = "mesh_fg_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(channel) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(channel, "Mesh BLE", NotificationManager.IMPORTANCE_LOW)
                        .apply { description = "Keeps BLE mesh running in background" }
                )
            }
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, channel)
            .setContentTitle("MeshChat active")
            .setContentText("BLE mesh is running")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val NOTIFICATION_ID = 1001
    }
}
