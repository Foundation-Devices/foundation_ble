package xyz.foundation.ble.foundation_ble.connection

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.util.Log
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import xyz.foundation.ble.foundation_ble.model.BluetoothConnectionEventType
import xyz.foundation.ble.foundation_ble.model.BluetoothConnectionStatus
import xyz.foundation.ble.foundation_ble.transport.SessionChannelNames
import xyz.foundation.ble.foundation_ble.util.BinaryChannelBuffers

interface BleConnectionCallback {
    fun onDeviceDisconnected(device: BleConnection)
}

abstract class BleConnection(
    val deviceId: String,
    protected val bluetoothManager: BluetoothManager,
    private val binaryMessenger: BinaryMessenger,
    protected val callback: BleConnectionCallback,
    protected val channelNames: SessionChannelNames,
    protected val scope: CoroutineScope = CoroutineScope(Dispatchers.Main)
) : MethodChannel.MethodCallHandler {

    protected open val logTag: String
        get() = javaClass.simpleName

    private val methodChannel: MethodChannel = MethodChannel(
        binaryMessenger,
        "${channelNames.connectionMethodRoot}/$deviceId"
    )
    private val bleReadChannel: BasicMessageChannel<ByteBuffer> = BasicMessageChannel(
        binaryMessenger,
        "${channelNames.readChannelRoot}/$deviceId",
        BinaryCodec.INSTANCE
    )
    private val bleWriteChannel: BasicMessageChannel<ByteBuffer> = BasicMessageChannel(
        binaryMessenger,
        "${channelNames.writeChannelRoot}/$deviceId",
        BinaryCodec.INSTANCE
    )
    private val connectionEventChannel: EventChannel = EventChannel(
        binaryMessenger,
        "${channelNames.connectionStreamRoot}/$deviceId"
    )

    protected var connectionEventSink: EventChannel.EventSink? = null
    protected var connectedDevice: BluetoothDevice? = null

    val currentDevice: BluetoothDevice?
        get() = connectedDevice

    val peripheralId: String
        get() = deviceId

    val peripheralName: String?
        @SuppressLint("MissingPermission")
        get() = connectedDevice?.name

    val isBonded: Boolean
        @SuppressLint("MissingPermission")
        get() = connectedDevice?.bondState == BluetoothDevice.BOND_BONDED

    init {
        methodChannel.setMethodCallHandler(this)
        connectionEventChannel.setStreamHandler(ConnectionStreamHandler())

        bleWriteChannel.setMessageHandler { message, reply ->
            scope.launch(Dispatchers.IO) {
                val response = handleBinaryWrite(message)
                withContext(Dispatchers.Main) {
                    reply.reply(response)
                }
            }
        }
    }

    final override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "bond" -> bond(result)
            "readRssi" -> readRssi(result)
            "getCurrentDeviceStatus" -> getCurrentDeviceStatus(result)
            "dispose" -> {
                cleanup(); result.success(null)
            }

            "disconnect" -> disconnect(result)
            "getConnectedPeripheralId" -> result.success(peripheralId)
            "isConnected" -> result.success(isConnected())
            "reconnect" -> reconnect(result)
            "requestPhy2" -> requestPhy2(result)
            else -> result.notImplemented()
        }
    }

    protected abstract fun isReady(): Boolean

    abstract fun isConnected(): Boolean

    abstract fun connect(device: BluetoothDevice)

    protected abstract fun disconnectTransport(result: MethodChannel.Result)

    protected abstract suspend fun handleBinaryWrite(message: ByteBuffer?): ByteBuffer

    protected open fun requestPhy2(result: MethodChannel.Result) {
        result.success(false)
    }

    protected open fun readRssi(result: MethodChannel.Result) {
        result.success(null)
    }

    protected abstract fun cleanupTransport()

    @SuppressLint("MissingPermission")
    private fun bond(result: MethodChannel.Result) {
        val device = connectedDevice
        if (device == null) {
            result.error("NO_DEVICE", "No device connected", null)
            return
        }

        when (device.bondState) {
            BluetoothDevice.BOND_NONE -> result.success(device.createBond())
            BluetoothDevice.BOND_BONDED,
            BluetoothDevice.BOND_BONDING -> result.success(true)

            else -> result.success(false)
        }
    }

    private fun getCurrentDeviceStatus(result: MethodChannel.Result) {
        sendConnectionEvent(
            if (isConnected()) {
                BluetoothConnectionEventType.DEVICE_CONNECTED
            } else {
                BluetoothConnectionEventType.DEVICE_DISCONNECTED
            }
        )
        result.success(currentStatus(type = null, error = null).toMap())
    }

    @SuppressLint("MissingPermission")
    private fun reconnect(result: MethodChannel.Result) {
        try {
            val adapter = bluetoothManager.adapter
            if (adapter == null) {
                result.error("NO_ADAPTER", "Bluetooth adapter not available", null)
                return
            }

            val device = adapter.getRemoteDevice(deviceId)
            connect(device)
            result.success(true)
        } catch (error: Exception) {
            result.error("RECONNECT_ERROR", "Failed to reconnect: ${error.message}", null)
        }
    }

    private fun disconnect(result: MethodChannel.Result) {
        disconnectTransport(result)
    }

    fun onBondingStateChanged(bondState: Int) {
        val eventType = when (bondState) {
            BluetoothDevice.BOND_BONDED -> BluetoothConnectionEventType.BOND_BONDED
            BluetoothDevice.BOND_BONDING -> BluetoothConnectionEventType.BOND_BONDING
            BluetoothDevice.BOND_NONE -> BluetoothConnectionEventType.BOND_REMOVED
            else -> return
        }
        sendConnectionEvent(eventType)
    }

    protected fun sendConnectionEvent(
        type: BluetoothConnectionEventType,
        error: String? = null
    ) {
        scope.launch {
            connectionEventSink?.success(currentStatus(type = type, error = error).toMap())
        }
    }

    protected fun sendBinaryData(data: ByteArray) {
//        Log.d(
//            logTag,
//            "[$deviceId] Forwarding ${data.size} byte(s) to Flutter: ${payloadSummary(data)}"
//        )
        scope.launch {
            bleReadChannel.send(BinaryChannelBuffers.payload(data)) {}
        }
    }

    protected fun createReplyBuffer(value: Byte): ByteBuffer {
        return BinaryChannelBuffers.reply(value)
    }

    protected fun payloadSummary(data: ByteArray, maxBytes: Int = 24): String {
        if (data.isEmpty()) {
            return "<empty>"
        }

        val preview = data.take(maxBytes).joinToString(" ") { byte ->
            "%02X".format(byte.toInt() and 0xFF)
        }
        return if (data.size > maxBytes) "$preview ..." else preview
    }

    protected fun onConnectionError(error: String?) {
        sendConnectionEvent(BluetoothConnectionEventType.CONNECTION_ERROR, error)
    }

    protected fun onDeviceDisconnected(error: String? = null) {
        sendConnectionEvent(BluetoothConnectionEventType.DEVICE_DISCONNECTED, error)
        callback.onDeviceDisconnected(this)
    }

    open fun cleanup() {
        cleanupTransport()
        methodChannel.setMethodCallHandler(null)
        bleWriteChannel.setMessageHandler(null)
        connectionEventSink = null
        connectedDevice = null
    }

    private fun currentStatus(
        type: BluetoothConnectionEventType?,
        error: String?
    ): BluetoothConnectionStatus {
        return BluetoothConnectionStatus(
            type = type,
            connected = isConnected(),
            ready = isReady(),
            bonded = isBonded,
            peripheralId = deviceId,
            peripheralName = peripheralName ?: "Unknown Device",
            rssi = null,
            error = error
        )
    }

    private inner class ConnectionStreamHandler : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
            connectionEventSink = sink
            if (connectedDevice != null || isConnected()) {
                sendConnectionEvent(
                    if (isConnected()) {
                        BluetoothConnectionEventType.DEVICE_CONNECTED
                    } else {
                        BluetoothConnectionEventType.DEVICE_DISCONNECTED
                    }
                )
            }
        }

        override fun onCancel(arguments: Any?) {
            connectionEventSink = null
        }
    }
}
