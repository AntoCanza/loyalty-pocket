package com.antocanza.loyalty_pocket

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var brightnessChannel: MethodChannel? = null
    private var bluetoothSyncBridge: BluetoothSyncBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bluetoothSyncBridge = BluetoothSyncBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        brightnessChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "loyalty_pocket/screen_brightness"
        ).apply {
            setMethodCallHandler { call, result ->
                if (call.method != "setBarcodeVisible") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val visible = call.arguments as? Boolean
                if (visible == null) {
                    result.error("invalid_argument", "Expected a boolean.", null)
                    return@setMethodCallHandler
                }
                setBarcodeVisible(visible)
                result.success(null)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bluetoothSyncBridge?.dispose()
        bluetoothSyncBridge = null
        brightnessChannel?.setMethodCallHandler(null)
        brightnessChannel = null
        setBarcodeVisible(false)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        bluetoothSyncBridge?.onRequestPermissionsResult(requestCode)
    }

    private fun setBarcodeVisible(visible: Boolean) {
        window.attributes = window.attributes.apply {
            screenBrightness = if (visible) {
                WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_FULL
            } else {
                WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            }
        }
    }
}
