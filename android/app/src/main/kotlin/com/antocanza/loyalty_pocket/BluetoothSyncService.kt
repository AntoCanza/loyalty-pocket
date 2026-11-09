package com.antocanza.loyalty_pocket

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.location.LocationManager
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.provider.Settings

internal class BluetoothSyncService : Service() {
    internal class LocalBinder(val service: BluetoothSyncService) : Binder()

    var status: String? = null
        private set

    private val binder = LocalBinder(this)
    private var listener: ((String, Any) -> Unit)? = null
    private var transport: BluetoothSyncTransport? = null
    private var foreground = false

    private val radioState = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                BluetoothAdapter.ACTION_STATE_CHANGED -> when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                    BluetoothAdapter.STATE_ON -> refresh()
                    BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                        closeTransport()
                        updateStatus("bluetoothOff")
                    }
                }
                LocationManager.MODE_CHANGED_ACTION -> refresh()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED).apply {
            if (Build.VERSION.SDK_INT < 31) addAction(LocationManager.MODE_CHANGED_ACTION)
        }
        // The protected radio broadcast comes from the Bluetooth system process.
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(radioState, filter, Context.RECEIVER_EXPORTED)
        else registerReceiver(radioState, filter)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            if (!foreground) {
                val notification = notification()
                if (Build.VERSION.SDK_INT >= 29) {
                    var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                    if (Build.VERSION.SDK_INT < 31) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                    startForeground(NOTIFICATION_ID, notification, type)
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                foreground = true
            }
            refresh()
        } catch (_: RuntimeException) {
            closeTransport()
            updateStatus("unavailable")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent): IBinder = binder

    fun attach(listener: (String, Any) -> Unit) {
        this.listener = listener
        transport?.replayPeers()
    }

    @SuppressLint("MissingPermission")
    fun refresh() {
        if (!foreground) return
        val manager = getSystemService(BluetoothManager::class.java)
        val adapter = manager?.adapter
        val blocked = when {
            !BluetoothSyncBridge.hasBluetoothPermissions(this) -> "permissionDenied"
            adapter == null -> "unavailable"
            !adapter.isEnabled -> "bluetoothOff"
            Build.VERSION.SDK_INT < 31 && !locationEnabled() -> "unavailable"
            else -> null
        }
        if (blocked != null || manager == null || adapter == null) {
            closeTransport()
            updateStatus(blocked ?: "unavailable")
            return
        }
        if (transport?.active == true) return
        status = null
        val next = BluetoothSyncTransport(this, manager, adapter, ::updateStatus) { method, arguments ->
            listener?.invoke(method, arguments)
        }
        transport = next
        next.start()
    }

    fun send(id: String, bytes: ByteArray, complete: (String?) -> Unit) {
        val current = transport
        if (current == null) complete("Bluetooth sync is inactive.")
        else current.send(id, bytes, complete)
    }

    fun disconnect(id: String) {
        transport?.disconnect(id)
    }

    fun stopSync() {
        closeTransport()
        listener = null
    }

    override fun onDestroy() {
        unregisterReceiver(radioState)
        closeTransport()
        updateStatus("unavailable")
        listener = null
        super.onDestroy()
    }

    private fun closeTransport() {
        transport?.close()
        transport = null
    }

    private fun updateStatus(next: String) {
        if (status == next) return
        status = next
        listener?.invoke("status", next)
    }

    @Suppress("DEPRECATION")
    private fun locationEnabled(): Boolean = if (Build.VERSION.SDK_INT >= 28) {
        getSystemService(LocationManager::class.java)?.isLocationEnabled == true
    } else {
        Settings.Secure.getInt(contentResolver, Settings.Secure.LOCATION_MODE, Settings.Secure.LOCATION_MODE_OFF) !=
            Settings.Secure.LOCATION_MODE_OFF
    }

    @Suppress("DEPRECATION")
    private fun notification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            val notifications = getSystemService(NotificationManager::class.java)
            notifications?.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, getString(R.string.bluetooth_sync_channel), NotificationManager.IMPORTANCE_LOW,
            ))
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        val openApp = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return builder.setSmallIcon(R.drawable.ic_bluetooth_sync)
            .setContentTitle(applicationInfo.loadLabel(packageManager))
            .setContentText(getString(R.string.bluetooth_sync_notification))
            .setContentIntent(PendingIntent.getActivity(this, 0, openApp, PendingIntent.FLAG_IMMUTABLE))
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "nearby_card_sync"
        private const val NOTIFICATION_ID = 3982
    }
}
