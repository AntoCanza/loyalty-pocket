package com.antocanza.loyalty_pocket

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
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
    private val startTimeout = Runnable { finishStart(serviceFailureStatus) }
    private var requestingPermissions = false
    private var requestingRadio = false
    private var explicitSyncRequested = false
    private var keepAliveRequested = false
    private var serviceFailureStatus = "unavailable"
    private var bound = false
    private var service: BluetoothSyncService? = null

    init {
        channel.setMethodCallHandler(::onCall)
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(
                prompt = call.argument<Boolean>("prompt") == true,
                enableRadio = call.argument<Boolean>("enableRadio") == true,
                keepAlive = call.argument<Boolean>("keepAlive") == true,
                result = result,
            )
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

    private fun start(prompt: Boolean, enableRadio: Boolean, keepAlive: Boolean, result: MethodChannel.Result) {
        val hasBluetooth = supportsBluetooth(activity)
        if (!hasBluetooth && !keepAlive) {
            result.success("unavailable")
            return
        }
        val missing = if (hasBluetooth) requiredPermissions.filterNot { hasPermission(activity, it) } else emptyList()
        if (missing.isNotEmpty() && !prompt && !keepAlive && !requestingPermissions) {
            result.success("permissionDenied")
            return
        }
        startResults.add(result)
        explicitSyncRequested = explicitSyncRequested || (prompt && enableRadio)
        keepAliveRequested = keepAliveRequested || keepAlive
        if (requestingPermissions || requestingRadio) return
        val requested = if (prompt) missing.toMutableList() else mutableListOf()
        if (prompt && Build.VERSION.SDK_INT >= 33 && !hasPermission(activity, Manifest.permission.POST_NOTIFICATIONS)) {
            requested.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (requested.isEmpty()) {
            continueStart()
        } else {
            main.removeCallbacks(startTimeout)
            requestingPermissions = true
            try {
                activity.requestPermissions(requested.toTypedArray(), PERMISSION_REQUEST)
            } catch (_: RuntimeException) {
                requestingPermissions = false
                if (keepAliveRequested) continueStart()
                else finishStart("unavailable")
            }
        }
    }

    fun onRequestPermissionsResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST) return
        requestingPermissions = false
        if (startResults.isEmpty()) return
        continueStart()
    }

    @SuppressLint("MissingPermission") // Bluetooth permissions are checked before using the adapter.
    @Suppress("DEPRECATION") // FlutterActivity exposes results via onActivityResult.
    private fun continueStart() {
        if (!supportsBluetooth(activity)) {
            startWithoutBluetooth("unavailable")
            return
        }
        if (!hasBluetoothPermissions(activity)) {
            startWithoutBluetooth("permissionDenied")
            return
        }
        if (!explicitSyncRequested) {
            launchService()
            return
        }
        try {
            val adapter = activity.getSystemService(BluetoothManager::class.java)?.adapter
            when {
                adapter == null -> startWithoutBluetooth("unavailable")
                adapter.isEnabled -> launchService()
                else -> {
                    main.removeCallbacks(startTimeout)
                    requestingRadio = true
                    activity.startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), RADIO_REQUEST)
                }
            }
        } catch (_: SecurityException) {
            requestingRadio = false
            startWithoutBluetooth("permissionDenied")
        } catch (_: RuntimeException) {
            requestingRadio = false
            startWithoutBluetooth("unavailable")
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int) {
        if (requestCode != RADIO_REQUEST || !requestingRadio) return
        requestingRadio = false
        if (startResults.isEmpty()) return
        if (resultCode == Activity.RESULT_OK) launchService()
        else startWithoutBluetooth("bluetoothOff")
    }

    private fun startWithoutBluetooth(status: String) {
        if (keepAliveRequested) launchService(failureStatus = status)
        else finishStart(status)
    }

    private fun launchService(failureStatus: String = "unavailable") {
        serviceFailureStatus = failureStatus
        service?.let {
            it.refresh(expediteDiscovery = explicitSyncRequested)
            it.status?.let(::finishServiceStart)
            if (it.status == null) armStartTimeout()
            return
        }
        if (bound) {
            armStartTimeout()
            return
        }
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
            finishStart(failureStatus)
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
            val value = if (method == "status") finishServiceStart(arguments as String) else arguments
            channel.invokeMethod(method, value)
        }
        connectedService.status?.let(::finishServiceStart)
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
        explicitSyncRequested = false
        keepAliveRequested = false
        serviceFailureStatus = "unavailable"
        val requests = startResults.toList()
        startResults.clear()
        requests.forEach { it.success(status) }
    }

    private fun finishServiceStart(status: String): String {
        val reported = if (status == "unavailable") serviceFailureStatus else status
        if (!requestingPermissions && !requestingRadio) finishStart(reported)
        return reported
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
        private const val RADIO_REQUEST = 18393

        private val requiredPermissions: List<String>
            get() = if (Build.VERSION.SDK_INT >= 31) {
                listOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_ADVERTISE)
            } else {
                listOf(Manifest.permission.ACCESS_FINE_LOCATION)
            }

        private fun hasPermission(context: Context, permission: String): Boolean =
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

        fun supportsBluetooth(context: Context): Boolean =
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

        fun hasBluetoothPermissions(context: Context): Boolean =
            requiredPermissions.all { hasPermission(context, it) }
    }
}
