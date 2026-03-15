package com.meshchat.mvp

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.lifecycle.ViewModelProvider

class MainActivity : ComponentActivity() {

    // Held as a property so onResume can call onPermissionsGranted()
    private lateinit var vm: MeshViewModel

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        val allGranted = results.values.all { it }
        if (allGranted) {
            // All permissions granted — (re)start BLE roles that may have no-oped at startup
            vm.mesh.onPermissionsGranted()
        } else {
            // Some denied — log which ones; BLE will stay silent until granted
            val denied = results.filterValues { !it }.keys
            Log.w("MeshPermissions", "Denied: $denied")
            Toast.makeText(this,
                "BLE permissions needed for mesh networking. Please grant in Settings.",
                Toast.LENGTH_LONG).show()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            Log.e("MeshCrash", "Uncaught on ${thread.name}", throwable)
        }

        createNotificationChannel()

        // Create ViewModel early so permissionLauncher callback can reference it
        vm = ViewModelProvider(this)[MeshViewModel::class.java]

        requestRequiredPermissions()

        try {
            setContent {
                com.meshchat.mvp.ui.theme.MeshChatTheme {
                    Surface(
                        modifier = Modifier.fillMaxSize(),
                        color = MaterialTheme.colorScheme.background
                    ) {
                        com.meshchat.mvp.ui.MeshApp(mesh = vm.mesh)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("MeshCrash", "setContent crashed", e)
            Toast.makeText(this, "Startup error: ${e.message}", Toast.LENGTH_LONG).show()
        }
    }

    override fun onResume() {
        super.onResume()
        // If user came back from enabling Bluetooth/location in Settings, retry BLE setup
        if (::vm.isInitialized) {
            vm.mesh.onPermissionsGranted()
        }
    }

    private fun requestRequiredPermissions() {
        val perms = mutableListOf(
            android.Manifest.permission.ACCESS_FINE_LOCATION,
            android.Manifest.permission.ACCESS_COARSE_LOCATION,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            perms += listOf(
                android.Manifest.permission.BLUETOOTH_SCAN,
                android.Manifest.permission.BLUETOOTH_ADVERTISE,
                android.Manifest.permission.BLUETOOTH_CONNECT,
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms += android.Manifest.permission.POST_NOTIFICATIONS
            perms += android.Manifest.permission.READ_MEDIA_IMAGES
        } else {
            perms += android.Manifest.permission.READ_EXTERNAL_STORAGE
        }
        permissionLauncher.launch(perms.toTypedArray())
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)

            // Chat/photo/label messages — default importance, suppressed in foreground
            nm.createNotificationChannel(NotificationChannel(
                "mesh_channel", "Mesh Messages", NotificationManager.IMPORTANCE_DEFAULT
            ).apply { description = "Incoming mesh chat messages and map labels" })

            // Safety alerts — high importance, fires even in foreground
            nm.createNotificationChannel(NotificationChannel(
                "mesh_alert_channel", "Mesh Alerts", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Safety alerts from the mesh — always shown"
                enableVibration(true)
                enableLights(true)
            })

            // Foreground service channel — silent
            nm.createNotificationChannel(NotificationChannel(
                "mesh_fg_channel", "Mesh BLE", NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Keeps BLE mesh running in background" })
        }
    }
}
