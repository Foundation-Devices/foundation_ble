package xyz.foundation.ble.foundation_ble.connection.gatt

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import java.util.UUID
import xyz.foundation.ble.foundation_ble.channel.chunked
import xyz.foundation.ble.foundation_ble.connection.BleConnection
import xyz.foundation.ble.foundation_ble.connection.BleConnectionCallback
import xyz.foundation.ble.foundation_ble.model.BluetoothConnectionEventType
import xyz.foundation.ble.foundation_ble.transport.SessionChannelNames

class GattBleConnection(
    deviceId: String,
    private val context: Context,
    bluetoothManager: BluetoothManager,
    binaryMessenger: io.flutter.plugin.common.BinaryMessenger,
    callback: BleConnectionCallback,
    channelNames: SessionChannelNames,
    scope: CoroutineScope = CoroutineScope(Dispatchers.Main)
) : BleConnection(
    deviceId = deviceId,
    bluetoothManager = bluetoothManager,
    binaryMessenger = binaryMessenger,
    callback = callback,
    channelNames = channelNames,
    scope = scope
) {

    companion object {
        private const val TAG = "GattBleConnection"
        private const val BLUETOOTH_DISCOVERY_DELAY_MS = 700L
        private const val BLE_PACKET_SIZE = 244
        private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private var bluetoothGatt: BluetoothGatt? = null
    private var writeCharacteristic: BluetoothGattCharacteristic? = null
    private var readCharacteristic: BluetoothGattCharacteristic? = null
    private var bleWriteQueue: BleWriteQueue? = null
    private var pendingRssiResult: MethodChannel.Result? = null

    override fun isReady(): Boolean {
        return isConnected() && writeCharacteristic != null
    }

    @SuppressLint("MissingPermission")
    override fun isConnected(): Boolean {
        val device = connectedDevice ?: return false

        return if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            bluetoothManager.getConnectionState(device, BluetoothProfile.GATT) ==
                    BluetoothProfile.STATE_CONNECTED
        } else {
            @Suppress("DEPRECATION")
            bluetoothGatt?.getConnectionState(device) == BluetoothProfile.STATE_CONNECTED
        }
    }


    @SuppressLint("MissingPermission")
    override fun connect(device: BluetoothDevice) {
        bluetoothGatt?.let { existingGatt ->
            existingGatt.disconnect()
            existingGatt.close()
        }

        bluetoothGatt = null

        sendConnectionEvent(BluetoothConnectionEventType.CONNECTION_ATTEMPT)

        try {
            bluetoothGatt = device.connectGatt(
                context,
                true,
                gattCallback,
                BluetoothDevice.TRANSPORT_LE
            )

            if (bluetoothGatt == null) {
                onConnectionError("Failed to create GATT connection")
            }
        } catch (error: SecurityException) {
            onConnectionError("Permission denied: ${error.message}")
        } catch (error: Exception) {
            onConnectionError("Connection failed: ${error.message}")
        }
    }

    @SuppressLint("MissingPermission")
    override fun disconnectTransport(result: MethodChannel.Result) {
        try {
            bluetoothGatt?.disconnect()
            result.success(mapOf("disconnecting" to true))
        } catch (error: Exception) {
            result.error("DISCONNECT_ERROR", "Failed to disconnect: ${error.message}", null)
        }
    }

    @SuppressLint("MissingPermission")
    override suspend fun handleBinaryWrite(message: ByteBuffer?): ByteBuffer {
        val failureBuffer = createReplyBuffer(0)

        if (message == null) {
            return failureBuffer
        }

        val data = ByteArray(message.remaining())
        message.get(data)

        if (bluetoothGatt == null || writeCharacteristic == null || bleWriteQueue == null) {
            return failureBuffer
        }

        if (data.size > BLE_PACKET_SIZE) {
            var success = true
            data.chunked(BLE_PACKET_SIZE).forEach { chunk ->
                val result = bleWriteQueue?.enqueue(chunk) ?: false
                if (!result) {
                    success = false
                    return@forEach
                }
            }
            return if (success) createReplyBuffer(1) else failureBuffer
        }

        val success = bleWriteQueue?.enqueue(data) ?: false
        return if (success) createReplyBuffer(1) else failureBuffer
    }

    @SuppressLint("MissingPermission")
    override fun requestPhy2(result: io.flutter.plugin.common.MethodChannel.Result) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            bluetoothGatt?.setPreferredPhy(
                BluetoothDevice.PHY_LE_2M,
                BluetoothDevice.PHY_LE_2M,
                BluetoothDevice.PHY_LE_2M
            )
            result.success(bluetoothGatt != null)
        } else {
            result.success(false)
        }
    }

    @SuppressLint("MissingPermission")
    override fun cleanupTransport() {
        resetConnectionState(closeGatt = true)
    }

    @SuppressLint("MissingPermission")
    override fun readRssi(result: MethodChannel.Result) {
        val gatt = bluetoothGatt
        if (gatt == null || !isConnected()) {
            result.success(null)
            return
        }
        pendingRssiResult = result
        gatt.readRemoteRssi()
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onMtuChanged(gatt: BluetoothGatt?, mtu: Int, status: Int) {
            super.onMtuChanged(gatt, mtu, status)
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt?, rssi: Int, status: Int) {
            val pending = pendingRssiResult
            pendingRssiResult = null
            scope.launch {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    pending?.success(rssi)
                } else {
                    pending?.success(null)
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt?, status: Int, newState: Int) {
            if (isStaleGattCallback(gatt)) {
                return
            }

            if (status != BluetoothGatt.GATT_SUCCESS) {
                failConnection(
                    gatt = gatt,
                    message = "GATT connection failed with status $status"
                )
                return
            }

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    connectedDevice = gatt?.device
                    bleWriteQueue?.restart()

                    bluetoothGatt?.requestMtu(247)
                    val highPriorityRequested = bluetoothGatt?.requestConnectionPriority(
                        BluetoothGatt.CONNECTION_PRIORITY_HIGH
                    ) ?: false
                    Log.d(
                        TAG,
                        "[$deviceId] Requested CONNECTION_PRIORITY_HIGH for GATT: $highPriorityRequested"
                    )

                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                        bluetoothGatt?.setPreferredPhy(
                            BluetoothDevice.PHY_LE_2M,
                            BluetoothDevice.PHY_LE_2M,
                            BluetoothDevice.PHY_LE_2M
                        )
                        Log.d(TAG, "[$deviceId] Requested LE 2M PHY for GATT")
                    }

                    scope.launch {
                        delay(BLUETOOTH_DISCOVERY_DELAY_MS)
                        gatt?.discoverServices()
                    }
                }

                BluetoothProfile.STATE_DISCONNECTED -> {
                    resetConnectionState(gatt = gatt, closeGatt = true)
                    onDeviceDisconnected()
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt?, status: Int) {
            if (isStaleGattCallback(gatt)) {
                return
            }

            if (status != BluetoothGatt.GATT_SUCCESS) {
                failConnection(
                    gatt = gatt,
                    message = "Service discovery failed with status $status"
                )
                return
            }

            val resolvedGatt = gatt ?: return
            Log.i(TAG, "onServicesDiscovered: ${resolvedGatt.services.size}")

            var write: BluetoothGattCharacteristic? = null
            var read: BluetoothGattCharacteristic? = null

            if (resolvedGatt.services.isEmpty()) {
                scope.launch {
                    delay(BLUETOOTH_DISCOVERY_DELAY_MS)
                    gatt.discoverServices()
                }
                return;
            }
            outer@ for (service in resolvedGatt.services) {
                for (char in service.characteristics) {
                    val hasWriteNoResponse =
                        char.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
                    val hasWrite =
                        char.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0

                    if (hasWriteNoResponse || hasWrite) {
                        val readCandidate = service.characteristics.firstOrNull {
                            it !== char &&
                                    it.properties and (
                                    BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                                            BluetoothGattCharacteristic.PROPERTY_INDICATE or
                                            BluetoothGattCharacteristic.PROPERTY_READ
                                    ) != 0
                        }
                        if (hasWriteNoResponse) {
                            write = char
                            read = readCandidate
                            break@outer
                        } else if (write == null) {
                            write = char
                            read = readCandidate
                        }
                    }
                }
            }

            if (write == null) {
                Log.w(TAG, "[$deviceId] No writable characteristic found")
                failConnection(
                    gatt = resolvedGatt,
                    message = "No writable characteristic found"
                )
                return
            }

            bleWriteQueue?.cancel()
            bleWriteQueue = BleWriteQueue(resolvedGatt, write, CoroutineScope(Dispatchers.IO))
            writeCharacteristic = write
            readCharacteristic = read

            Log.d(TAG, "[$deviceId] write=${write.uuid} read=${read?.uuid}")

            read?.let { configureReadCharacteristic(resolvedGatt, it) }
            sendConnectionEvent(BluetoothConnectionEventType.DEVICE_CONNECTED)
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWrite(
            gatt: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?,
            status: Int
        ) {
            if (isStaleGattCallback(gatt)) {
                return
            }

            if (characteristic?.uuid == writeCharacteristic?.uuid) {
                bleWriteQueue?.onCharacteristicWrite(status)
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?,
            status: Int
        ) {
            if (isStaleGattCallback(gatt)) {
                return
            }

            if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU &&
                status == BluetoothGatt.GATT_SUCCESS
            ) {
                @Suppress("DEPRECATION")
                characteristic?.value?.let(::sendBinaryData)
            }
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int
        ) {
            if (isStaleGattCallback(gatt)) {
                return
            }

            super.onCharacteristicRead(gatt, characteristic, value, status)
            if (status == BluetoothGatt.GATT_SUCCESS && value.isNotEmpty()) {
                sendBinaryData(value)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (isStaleGattCallback(gatt)) {
                return
            }

            super.onCharacteristicChanged(gatt, characteristic, value)
            if (value.isNotEmpty()) {
                sendBinaryData(value)
            }
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?
        ) {
            if (isStaleGattCallback(gatt)) {
                return
            }

            if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU) {
                @Suppress("DEPRECATION")
                characteristic?.value?.let(::sendBinaryData)
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun failConnection(gatt: BluetoothGatt?, message: String) {
        Log.w(TAG, "[$deviceId] $message")
        resetConnectionState(gatt = gatt, closeGatt = true)
        onConnectionError(message)
    }

    private fun isStaleGattCallback(gatt: BluetoothGatt?): Boolean {
        val activeGatt = bluetoothGatt
        return gatt != null && activeGatt != null && gatt !== activeGatt
    }

    @SuppressLint("MissingPermission")
    private fun resetConnectionState(
        gatt: BluetoothGatt? = bluetoothGatt,
        closeGatt: Boolean
    ) {
        bleWriteQueue?.cancel()
        bleWriteQueue = null
        writeCharacteristic = null
        readCharacteristic = null
        connectedDevice = null

        if (bluetoothGatt === gatt || gatt == null) {
            bluetoothGatt = null
        }

        if (closeGatt) {
            try {
                gatt?.close()
            } catch (_: Exception) {
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun configureReadCharacteristic(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic
    ) {
        if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY == 0 &&
            characteristic.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE == 0
        ) {
            return
        }

        gatt.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(CCCD_UUID) ?: return
        val enableValue =
            if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) {
                BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            } else {
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            }

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, enableValue)
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = enableValue
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(descriptor)
        }
    }
}
