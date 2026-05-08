package xyz.foundation.ble.foundation_ble

import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import xyz.foundation.ble.foundation_ble.channel.BluetoothChannel

class FoundationBlePlugin : FlutterPlugin, ActivityAware {
    private var applicationContext: Context? = null
    private var binaryMessenger: BinaryMessenger? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var bluetoothChannel: BluetoothChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        binaryMessenger = binding.binaryMessenger
        maybeAttachBluetoothChannel()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachBluetoothChannel()
        binaryMessenger = null
        applicationContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        maybeAttachBluetoothChannel()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        bluetoothChannel?.detachFromActivityForConfigChanges()
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        maybeAttachBluetoothChannel()
    }

    override fun onDetachedFromActivity() {
        detachBluetoothChannel()
        activityBinding = null
        activity = null
    }

    private fun maybeAttachBluetoothChannel() {
        val context = applicationContext ?: return
        val messenger = binaryMessenger ?: return
        val hostActivity = activity ?: return
        val binding = activityBinding ?: return

        val existingBluetoothChannel = bluetoothChannel
        if (existingBluetoothChannel != null) {
            existingBluetoothChannel.attachToActivity(hostActivity, binding)
            return
        }

        bluetoothChannel = BluetoothChannel(
            context = context,
            activity = hostActivity,
            activityBinding = binding,
            binaryMessenger = messenger
        )
    }

    private fun detachBluetoothChannel() {
        bluetoothChannel?.cleanup()
        bluetoothChannel = null
    }
}
