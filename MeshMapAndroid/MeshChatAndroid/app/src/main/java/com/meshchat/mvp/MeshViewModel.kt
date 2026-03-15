package com.meshchat.mvp

import android.app.Application
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import com.meshchat.mvp.bluetooth.BluetoothMeshService

class MeshViewModel(app: Application) : AndroidViewModel(app) {

    val mesh: BluetoothMeshService = try {
        BluetoothMeshService(app.applicationContext)
    } catch (e: Exception) {
        Log.e("MeshViewModel", "Failed to create BluetoothMeshService", e)
        throw e
    }

    init {
        // start() is lightweight — DB init and BLE setup are dispatched internally.
        // Must be called on main thread because BLE APIs need a Looper.
        mesh.start()
    }

    override fun onCleared() {
        super.onCleared()
        try { mesh.stop() } catch (_: Exception) {}
    }
}
