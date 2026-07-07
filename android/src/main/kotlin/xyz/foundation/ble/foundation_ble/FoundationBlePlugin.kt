package xyz.foundation.ble.foundation_ble

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import xyz.foundation.ble.foundation_ble.channel.BluetoothChannel

class FoundationBlePlugin : FlutterPlugin, ActivityAware {
    private var bluetoothChannel: BluetoothChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Register channels without waiting for an activity so headless
        // engines (e.g. the BLE foreground service) can use the plugin.
        bluetoothChannel = BluetoothChannel(
            context = binding.applicationContext,
            binaryMessenger = binding.binaryMessenger
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        bluetoothChannel?.cleanup()
        bluetoothChannel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        bluetoothChannel?.attachToActivity(binding.activity, binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        bluetoothChannel?.detachFromActivityForConfigChanges()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        bluetoothChannel?.attachToActivity(binding.activity, binding)
    }

    override fun onDetachedFromActivity() {
        bluetoothChannel?.detachFromActivity()
    }
}
