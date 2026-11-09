package com.antocanza.loyalty_pocket

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import java.util.UUID
import kotlin.random.Random

@SuppressLint("MissingPermission") // The foreground service checks grants before starting transport.
@Suppress("DEPRECATION") // GATT writes before Android 13 use the mutable-value APIs.
internal class BluetoothSyncTransport(
    private val context: Context,
    private val manager: BluetoothManager,
    private val adapter: BluetoothAdapter,
    private val updateStatus: (String) -> Unit,
    private val emit: (String, Any) -> Unit,
) {
    private class Link(val key: String, val device: BluetoothDevice, val central: Boolean) {
        val id = UUID.randomUUID().toString()
        var gatt: BluetoothGatt? = null
        var write: BluetoothGattCharacteristic? = null
        var ready = false
        var discovering = false
        var mtu = DEFAULT_MTU
        var setupTimeout: Runnable? = null
        var pending: PendingPacket? = null

        val packetBytes: Int get() = (mtu - 3).coerceIn(DEFAULT_MTU - 3, MAX_ATTRIBUTE_BYTES)
    }

    private class PendingPacket(val timeout: Runnable, val complete: (String?) -> Unit)

    private val main = Handler(Looper.getMainLooper())
    private val links = mutableMapOf<String, Link>()
    private val peripheralMtus = mutableMapOf<String, Int>()
    private val retryAfter = linkedMapOf<String, Long>()
    private val startupTimeout = Runnable { fail() }
    private var scanner: BluetoothLeScanner? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var server: BluetoothGattServer? = null
    private var indication: BluetoothGattCharacteristic? = null
    var active = true
        private set

    private val advertisements = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            main.post {
                if (!active) return@post
                val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()
                val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER).build()
                if (attempt { scanner?.startScan(listOf(filter), settings, scanResults) }) {
                    main.removeCallbacks(startupTimeout)
                    updateStatus("ready")
                } else {
                    fail()
                }
            }
        }

        override fun onStartFailure(errorCode: Int) { main.post { fail() } }
    }

    private val scanResults = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post { if (active) connect(result.device) }
        }

        override fun onScanFailed(errorCode: Int) { main.post { fail() } }
    }

    private val centralCallbacks = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                val link = clientLink(gatt) ?: return@post
                if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                    drop(link)
                } else if (newState == BluetoothProfile.STATE_CONNECTED) {
                    if (!accepted { gatt.requestMtu(REQUESTED_MTU) }) discover(gatt, link)
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            main.post {
                val link = clientLink(gatt) ?: return@post
                if (status == BluetoothGatt.GATT_SUCCESS) link.mtu = mtu
                discover(gatt, link)
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            main.post {
                val link = clientLink(gatt) ?: return@post
                val service = gatt.getService(SERVICE)
                val write = service?.getCharacteristic(WRITE)
                val remoteIndication = service?.getCharacteristic(INDICATE)
                val descriptor = remoteIndication?.getDescriptor(CCCD)
                if (status != BluetoothGatt.GATT_SUCCESS || write == null || remoteIndication == null ||
                    descriptor == null || !subscribe(gatt, remoteIndication, descriptor)) {
                    drop(link)
                    return@post
                }
                link.write = write
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            main.post {
                val link = clientLink(gatt) ?: return@post
                if (descriptor.uuid != CCCD || descriptor.characteristic.uuid != INDICATE) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) linkReady(link)
                else drop(link)
            }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            main.post {
                val link = clientLink(gatt) ?: return@post
                if (characteristic.uuid == WRITE) packetAcknowledged(link, status)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) = receiveIndication(gatt, characteristic, value)

        @Deprecated("Used by Android 12 and earlier")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT < 33) characteristic.value?.let { receiveIndication(gatt, characteristic, it) }
        }
    }

    private val peripheralCallbacks = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            main.post {
                if (!active) return@post
                val settings = AdvertiseSettings.Builder()
                    .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                    .setConnectable(true).build()
                val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).build()
                if (status != BluetoothGatt.GATT_SUCCESS || service.uuid != SERVICE ||
                    !attempt { advertiser?.startAdvertising(settings, data, advertisements) }) fail()
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            main.post {
                if (!active) return@post
                // Android reports the physical link here even when our own GATT
                // client opened it. The peer subscribes before using our server.
                if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                    peripheralMtus.remove(device.address)
                    peripheralLink(device)?.let { drop(it) }
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            main.post {
                if (!active) return@post
                peripheralMtus[device.address] = mtu
                peripheralLink(device)?.mtu = mtu
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            val packet = value.copyOf()
            main.post {
                val enable = packet.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
                val disable = packet.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
                val supported = descriptor.uuid == CCCD && descriptor.characteristic.uuid == INDICATE &&
                    !preparedWrite && responseNeeded && offset == 0
                val link = if (supported && enable) incomingSubscription(device) else peripheralLink(device)
                val valid = link != null && supported && (enable || disable)
                val acknowledged = respondToWrite(device, requestId, responseNeeded, valid)
                if (valid && acknowledged) {
                    if (enable) {
                        links[link.key] = link
                        linkReady(link)
                    } else {
                        drop(link)
                    }
                }
            }
        }

        override fun onDescriptorReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor) {
            main.post {
                val link = peripheralLink(device)
                val enabled = link?.ready == true
                val supported = descriptor.uuid == CCCD && descriptor.characteristic.uuid == INDICATE
                val value = if (enabled) BluetoothGattDescriptor.ENABLE_INDICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                attempt {
                    when {
                        !supported -> server?.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, 0, null)
                        offset !in 0..value.size -> server?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, 0, null)
                        else -> server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value.copyOfRange(offset, value.size))
                    }
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            val packet = value.copyOf()
            main.post {
                val link = peripheralLink(device)
                val valid = link?.ready == true && characteristic.uuid == WRITE && !preparedWrite &&
                    responseNeeded && offset == 0 && packet.size in 1..MAX_ATTRIBUTE_BYTES
                val acknowledged = respondToWrite(device, requestId, responseNeeded, valid)
                if (valid && acknowledged) receive(link, packet)
            }
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            main.post { respondToWrite(device, requestId, responseNeeded = true, valid = false) }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            main.post { peripheralLink(device)?.let { packetAcknowledged(it, status) } }
        }
    }

    fun start() {
        val started = accepted {
            scanner = adapter.bluetoothLeScanner
            advertiser = adapter.bluetoothLeAdvertiser
            if (scanner == null || advertiser == null) return@accepted false
            val write = BluetoothGattCharacteristic(WRITE, BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE)
            val notify = BluetoothGattCharacteristic(INDICATE, BluetoothGattCharacteristic.PROPERTY_INDICATE, 0)
            notify.addDescriptor(BluetoothGattDescriptor(CCCD,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
            indication = notify
            val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            service.addCharacteristic(write)
            service.addCharacteristic(notify)
            server = manager.openGattServer(context, peripheralCallbacks)
            server?.addService(service) == true
        }
        if (started) main.postDelayed(startupTimeout, STARTUP_TIMEOUT)
        else fail()
    }

    fun replayPeers() = links.values.filter { it.ready }.forEach(::emitPeer)

    fun send(id: String, bytes: ByteArray, complete: (String?) -> Unit) {
        val link = links.values.firstOrNull { it.id == id }
        if (link?.ready != true) {
            complete("The Bluetooth peer is disconnected.")
            return
        }
        if (bytes.size !in 1..link.packetBytes || link.pending != null) {
            complete("The packet is too large or another packet is pending.")
            return
        }
        val timeout = Runnable { drop(link, error = "Bluetooth packet acknowledgment timed out.") }
        link.pending = PendingPacket(timeout, complete)
        if (accepted { if (link.central) writePacket(link, bytes) else indicatePacket(link, bytes) }) {
            main.postDelayed(timeout, PACKET_TIMEOUT)
        } else {
            drop(link, error = "The Bluetooth stack rejected the packet.")
        }
    }

    fun disconnect(id: String) { links.values.firstOrNull { it.id == id }?.let { drop(it) } }

    fun close() {
        if (!active) return
        active = false
        main.removeCallbacksAndMessages(null)
        attempt { scanner?.stopScan(scanResults) }
        attempt { advertiser?.stopAdvertising(advertisements) }
        links.values.toList().forEach { drop(it) }
        attempt { server?.close() }
        scanner = null
        advertiser = null
        server = null
        indication = null
        retryAfter.clear()
        peripheralMtus.clear()
    }

    private fun fail() {
        if (!active) return
        close()
        updateStatus("unavailable")
    }

    private fun connect(device: BluetoothDevice) {
        val key = linkKey(device, central = true)
        if (links.values.any { it.central } || isCoolingDown(key)) return
        val link = Link(key, device, central = true)
        registerLink(link)
        if (!accepted {
            link.gatt = device.connectGatt(context, false, centralCallbacks, BluetoothDevice.TRANSPORT_LE)
            link.gatt != null
        }) drop(link)
    }

    private fun registerLink(link: Link) {
        links[link.key] = link
        val timeout = Runnable { drop(link) }
        link.setupTimeout = timeout
        main.postDelayed(timeout, LINK_TIMEOUT)
    }

    private fun clientLink(gatt: BluetoothGatt): Link? =
        links[linkKey(gatt.device, central = true)]?.takeIf { it.gatt === gatt }

    private fun peripheralLink(device: BluetoothDevice): Link? = links[linkKey(device, central = false)]

    private fun incomingSubscription(device: BluetoothDevice): Link? {
        if (!active) return null
        peripheralLink(device)?.let { return it }
        val key = linkKey(device, central = false)
        if (links.values.any { !it.central } || isCoolingDown(key)) return null
        return Link(key, device, central = false).apply {
            mtu = peripheralMtus[device.address] ?: DEFAULT_MTU
        }
    }

    private fun discover(gatt: BluetoothGatt, link: Link) {
        if (link.discovering) return
        link.discovering = true
        if (!accepted { gatt.discoverServices() }) drop(link)
    }

    private fun subscribe(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        descriptor: BluetoothGattDescriptor,
    ): Boolean = accepted {
        if (!gatt.setCharacteristicNotification(characteristic, true)) return@accepted false
        val value = BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        if (Build.VERSION.SDK_INT >= 33) {
            gatt.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
        } else {
            descriptor.value = value
            gatt.writeDescriptor(descriptor)
        }
    }

    private fun writePacket(link: Link, bytes: ByteArray): Boolean {
        val gatt = link.gatt ?: return false
        val characteristic = link.write ?: return false
        val type = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        return if (Build.VERSION.SDK_INT >= 33) {
            gatt.writeCharacteristic(characteristic, bytes, type) == BluetoothStatusCodes.SUCCESS
        } else {
            characteristic.writeType = type
            characteristic.value = bytes
            gatt.writeCharacteristic(characteristic)
        }
    }

    private fun indicatePacket(link: Link, bytes: ByteArray): Boolean {
        val gatt = server ?: return false
        val characteristic = indication ?: return false
        return if (Build.VERSION.SDK_INT >= 33) {
            gatt.notifyCharacteristicChanged(link.device, characteristic, true, bytes) == BluetoothStatusCodes.SUCCESS
        } else {
            characteristic.value = bytes
            gatt.notifyCharacteristicChanged(link.device, characteristic, true)
        }
    }

    private fun respondToWrite(device: BluetoothDevice, requestId: Int, responseNeeded: Boolean, valid: Boolean): Boolean {
        if (!responseNeeded) return false
        val status = if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED
        return accepted { server?.sendResponse(device, requestId, status, 0, null) == true }
    }

    private fun linkReady(link: Link) {
        if (link.ready) return
        link.setupTimeout?.let(main::removeCallbacks)
        link.setupTimeout = null
        link.ready = true
        emitPeer(link)
    }

    private fun emitPeer(link: Link) = emit("peerConnected", mapOf(
        "id" to link.id, "central" to link.central, "maxPacketBytes" to link.packetBytes,
    ))

    private fun receiveIndication(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, bytes: ByteArray) {
        if (characteristic.uuid != INDICATE || bytes.size !in 1..MAX_ATTRIBUTE_BYTES) return
        val packet = bytes.copyOf()
        main.post { clientLink(gatt)?.takeIf { it.ready }?.let { receive(it, packet) } }
    }

    private fun receive(link: Link, bytes: ByteArray) = emit("bytesReceived", mapOf("id" to link.id, "bytes" to bytes))

    private fun packetAcknowledged(link: Link, status: Int) {
        val packet = link.pending ?: return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            drop(link, error = "The Bluetooth peer did not acknowledge the packet.")
            return
        }
        link.pending = null
        main.removeCallbacks(packet.timeout)
        packet.complete(null)
    }

    private fun drop(link: Link, error: String = "The Bluetooth peer disconnected.") {
        if (links[link.key] !== link) return
        links.remove(link.key)
        if (retryAfter.size >= MAX_COOLDOWNS) retryAfter.remove(retryAfter.keys.first())
        val delay = if (link.ready) 25_000L else 8_000L
        retryAfter[link.key] = SystemClock.elapsedRealtime() + delay + Random.nextLong(2_000L)
        link.setupTimeout?.let(main::removeCallbacks)
        link.pending?.let { packet ->
            main.removeCallbacks(packet.timeout)
            packet.complete(error)
        }
        link.pending = null
        val gatt = link.gatt
        if (gatt != null) {
            if (peripheralLink(link.device) == null) attempt { gatt.disconnect() }
            attempt { gatt.close() }
        }
        if (link.ready) emit("peerDisconnected", mapOf("id" to link.id))
    }

    private fun isCoolingDown(key: String): Boolean {
        val next = retryAfter[key] ?: return false
        if (SystemClock.elapsedRealtime() < next) return true
        retryAfter.remove(key)
        return false
    }

    private fun linkKey(device: BluetoothDevice, central: Boolean): String =
        (if (central) "central:" else "peripheral:") + device.address

    private inline fun attempt(operation: () -> Unit): Boolean = accepted {
        operation()
        true
    }

    private inline fun accepted(operation: () -> Boolean): Boolean = try {
        operation()
    } catch (_: RuntimeException) {
        false
    }

    companion object {
        private val SERVICE = UUID.fromString("3bf9aa04-1c0d-43b6-95a0-82efcf4dd9a9")
        private val WRITE = UUID.fromString("3bf9aa04-1c0d-43b6-95a0-82efcf4dd9aa")
        private val INDICATE = UUID.fromString("3bf9aa04-1c0d-43b6-95a0-82efcf4dd9ab")
        private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val DEFAULT_MTU = 23
        private const val REQUESTED_MTU = 247
        private const val MAX_ATTRIBUTE_BYTES = 512
        private const val STARTUP_TIMEOUT = 8_000L
        private const val LINK_TIMEOUT = 15_000L
        private const val PACKET_TIMEOUT = 8_000L
        private const val MAX_COOLDOWNS = 64
    }
}
