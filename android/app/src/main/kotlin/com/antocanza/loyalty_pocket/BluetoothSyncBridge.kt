package com.antocanza.loyalty_pocket

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

internal class BluetoothSyncBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : ServiceConnection {
    private val channel = MethodChannel(messenger, "loyalty_pocket/bluetooth_sync")
    private val main = Handler(Looper.getMainLooper())
    private val keys = BluetoothSyncKeys(activity.applicationContext)
    private val keyWorker = Executors.newSingleThreadExecutor()
    private val serviceIntent = Intent(activity, BluetoothSyncService::class.java)
    private val startResults = mutableListOf<MethodChannel.Result>()
    private val startTimeout = Runnable { finishStart("unavailable") }
    private var requestingPermissions = false
    private var bound = false
    private var service: BluetoothSyncService? = null

    init {
        channel.setMethodCallHandler(::onCall)
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call.argument<Boolean>("prompt") == true, result)
            "stop" -> {
                stop()
                result.success(null)
            }
            "send" -> {
                val id = call.argument<String>("id")
                val bytes = call.argument<ByteArray>("bytes")
                val connectedService = service
                if (id == null || bytes == null) {
                    result.error("invalid_argument", "Expected a peer and a packet.", null)
                } else if (connectedService == null) {
                    result.error("bluetooth_send", "Bluetooth sync is inactive.", null)
                } else {
                    connectedService.send(id, bytes) { error ->
                        if (error == null) result.success(null)
                        else result.error("bluetooth_send", error, null)
                    }
                }
            }
            "disconnect" -> {
                call.argument<String>("id")?.let { service?.disconnect(it) }
                result.success(null)
            }
            "readGroupKey" -> withKeys(result) { keys.read() }
            "writeGroupKey" -> {
                val value = call.arguments
                if (value == null || value is ByteArray && value.size == BluetoothSyncKeys.KEY_SIZE) {
                    withKeys(result) {
                        keys.write(value)
                        null
                    }
                } else {
                    result.error("invalid_argument", "Expected a 32-byte group key.", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun withKeys(result: MethodChannel.Result, operation: () -> Any?) {
        keyWorker.execute {
            try {
                val value = operation()
                main.post { result.success(value) }
            } catch (_: Exception) {
                main.post { result.error("group_key", "Could not access the secure group key.", null) }
            }
        }
    }

    private fun start(prompt: Boolean, result: MethodChannel.Result) {
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            result.success("unavailable")
            return
        }
        val missing = requiredPermissions.filterNot { hasPermission(activity, it) }
        if (missing.isNotEmpty() && !prompt && !requestingPermissions) {
            result.success("permissionDenied")
            return
        }
        startResults.add(result)
        if (requestingPermissions) return
        val requested = missing.toMutableList()
        if (prompt && Build.VERSION.SDK_INT >= 33 && !hasPermission(activity, Manifest.permission.POST_NOTIFICATIONS)) {
            requested.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (requested.isEmpty()) {
            launchService()
        } else {
            requestingPermissions = true
            try {
                activity.requestPermissions(requested.toTypedArray(), PERMISSION_REQUEST)
            } catch (_: RuntimeException) {
                requestingPermissions = false
                finishStart("unavailable")
            }
        }
    }

    fun onRequestPermissionsResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST) return
        requestingPermissions = false
        if (startResults.isEmpty()) return
        if (hasBluetoothPermissions(activity)) launchService()
        else finishStart("permissionDenied")
    }

    private fun launchService() {
        service?.let {
            it.refresh()
            it.status?.let(::finishStart)
            if (it.status == null) armStartTimeout()
            return
        }
        if (bound) return
        try {
            if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(serviceIntent)
            else activity.startService(serviceIntent)
            bound = activity.bindService(serviceIntent, this, Context.BIND_AUTO_CREATE)
        } catch (_: RuntimeException) {
            bound = false
        }
        if (bound) armStartTimeout()
        else {
            activity.stopService(serviceIntent)
            finishStart("unavailable")
        }
    }

    private fun armStartTimeout() {
        main.removeCallbacks(startTimeout)
        main.postDelayed(startTimeout, 12_000L)
    }

    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
        if (!bound) return
        val connectedService = (binder as BluetoothSyncService.LocalBinder).service
        service = connectedService
        connectedService.attach { method, arguments ->
            if (method == "status") finishStart(arguments as String)
            channel.invokeMethod(method, arguments)
        }
        connectedService.status?.let(::finishStart)
    }

    override fun onServiceDisconnected(name: ComponentName) = lostService()

    override fun onBindingDied(name: ComponentName) = lostService()

    override fun onNullBinding(name: ComponentName) = lostService()

    private fun lostService() {
        stop()
        channel.invokeMethod("status", "unavailable")
    }

    private fun finishStart(status: String) {
        main.removeCallbacks(startTimeout)
        val requests = startResults.toList()
        startResults.clear()
        requests.forEach { it.success(status) }
    }

    private fun stop() {
        finishStart("unavailable")
        service?.stopSync()
        service = null
        if (bound) {
            bound = false
            activity.unbindService(this)
        }
        activity.stopService(serviceIntent)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        stop()
        keyWorker.shutdown()
    }

    companion object {
        private const val PERMISSION_REQUEST = 18392

        private val requiredPermissions: List<String>
            get() = if (Build.VERSION.SDK_INT >= 31) {
                listOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_ADVERTISE)
            } else {
                listOf(Manifest.permission.ACCESS_FINE_LOCATION)
            }

        private fun hasPermission(context: Context, permission: String): Boolean =
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

        fun hasBluetoothPermissions(context: Context): Boolean =
            requiredPermissions.all { hasPermission(context, it) }
    }
}
