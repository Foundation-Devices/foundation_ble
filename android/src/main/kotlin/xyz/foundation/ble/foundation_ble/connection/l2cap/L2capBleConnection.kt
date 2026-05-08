package xyz.foundation.ble.foundation_ble.connection.l2cap

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import xyz.foundation.ble.foundation_ble.connection.BleConnection
import xyz.foundation.ble.foundation_ble.connection.BleConnectionCallback
import xyz.foundation.ble.foundation_ble.model.BluetoothConnectionEventType
import xyz.foundation.ble.foundation_ble.transport.SessionChannelNames

class L2capBleConnection(
    deviceId: String,
    context: Context,
    bluetoothManager: BluetoothManager,
    binaryMessenger: BinaryMessenger,
    callback: BleConnectionCallback,
    channelNames: SessionChannelNames,
    private val psm: Int,
    scope: CoroutineScope = CoroutineScope(Dispatchers.Main)
) : BleConnection(
    deviceId = deviceId,
    bluetoothManager = bluetoothManager,
    binaryMessenger = binaryMessenger,
    callback = callback,
    channelNames = channelNames,
    scope = scope
) {
    private val socketLock = Any()
    private val gattSidecar = L2capGattSidecar(deviceId = deviceId, context = context)

    private var bluetoothSocket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null
    private var readJob: Job? = null

    override fun isReady(): Boolean {
        synchronized(socketLock) {
            return bluetoothSocket?.isConnected == true &&
                    inputStream != null &&
                    outputStream != null
        }
    }

    override fun isConnected(): Boolean {
        synchronized(socketLock) {
            return bluetoothSocket?.isConnected == true
        }
    }

    @SuppressLint("MissingPermission")
    override fun connect(device: BluetoothDevice) {
        Log.d(
            logTag,
            "[$deviceId] Starting L2CAP connect to ${device.address} on PSM 0x${psm.toString(16)}"
        )
        closeSocket(notifyDisconnect = false)
        connectedDevice = device
        sendConnectionEvent(BluetoothConnectionEventType.CONNECTION_ATTEMPT)

        scope.launch(Dispatchers.IO) {
            try {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    Log.e(
                        logTag,
                        "[$deviceId] L2CAP connect blocked: API ${Build.VERSION.SDK_INT} < 29"
                    )
                    onConnectionError("Android L2CAP requires API 29 or newer")
                    return@launch
                }

                gattSidecar.connectAndWarmUp(device)

                val socket = device.createInsecureL2capChannel(psm)
                synchronized(socketLock) {
                    bluetoothSocket = socket
                }

                socket.connect()

                synchronized(socketLock) {
                    inputStream = socket.inputStream
                    outputStream = socket.outputStream
                }
                connectedDevice = device

                Log.d(
                    logTag,
                    "[$deviceId] L2CAP connected maxTxPacketSize=${socket.maxTransmitPacketSize}"
                )
                sendConnectionEvent(BluetoothConnectionEventType.DEVICE_CONNECTED)
                startReadLoop(socket)
            } catch (error: SecurityException) {
                Log.e(
                    logTag,
                    "[$deviceId] L2CAP connect permission failure: ${error.message}",
                    error
                )
                closeSocket(notifyDisconnect = false)
                onConnectionError("Permission denied: ${error.message}")
            } catch (error: Exception) {
                Log.e(logTag, "[$deviceId] L2CAP connect failure: ${error.message}", error)
                closeSocket(notifyDisconnect = false)
                onConnectionError("L2CAP connection failed: ${error.message}")
            }
        }
    }

    override fun disconnectTransport(result: MethodChannel.Result) {
        val wasConnected = connectedDevice != null || isConnected()
        Log.d(logTag, "[$deviceId] Disconnect requested. wasConnected=$wasConnected")
        closeSocket(notifyDisconnect = wasConnected)
        result.success(mapOf("disconnecting" to wasConnected))
    }

    override suspend fun handleBinaryWrite(message: ByteBuffer?): ByteBuffer {
        val failureBuffer = createReplyBuffer(0)
        if (message == null) {
            return failureBuffer
        }

        val data = ByteArray(message.remaining())
        message.get(data)

        val stream = synchronized(socketLock) {
            if (!isReady()) {
                null
            } else {
                outputStream
            }
        } ?: return failureBuffer
        val packetSize = currentMaxTransmitPacketSize()

        return try {
            withContext(Dispatchers.IO) {
                var offset = 0
                while (offset < data.size) {
                    val size = minOf(packetSize, data.size - offset)
                    stream.write(data, offset, size)
                    offset += size
                }
                stream.flush()
            }
            createReplyBuffer(1)
        } catch (error: Exception) {
            Log.e(logTag, "[$deviceId] L2CAP write failed: ${error.message}", error)
            closeSocket(notifyDisconnect = true, error = "L2CAP write failed")
            failureBuffer
        }
    }

    override fun requestPhy2(result: MethodChannel.Result) {
        result.success(gattSidecar.requestPhy2())
    }

    override fun cleanupTransport() {
        closeSocket(notifyDisconnect = false)
    }

    private fun startReadLoop(socket: BluetoothSocket) {
        readJob?.cancel()
        readJob = scope.launch(Dispatchers.IO) {
            val buffer = ByteArray(4096)
            try {
                while (true) {
                    val read = socket.inputStream.read(buffer)
                    if (read < 0) {
                        break
                    }
                    if (read > 0) {
                        sendBinaryData(buffer.copyOf(read))
                    }
                }

                if (isCurrentSocket(socket)) {
                    closeSocket(notifyDisconnect = true)
                }
            } catch (_: CancellationException) {
            } catch (error: Exception) {
                Log.e(logTag, "[$deviceId] L2CAP read loop failed: ${error.message}", error)
                if (isCurrentSocket(socket)) {
                    closeSocket(
                        notifyDisconnect = true,
                        error = error.message ?: "L2CAP read failed"
                    )
                }
            }
        }
    }

    private fun isCurrentSocket(socket: BluetoothSocket): Boolean {
        synchronized(socketLock) {
            return bluetoothSocket === socket
        }
    }

    private fun currentMaxTransmitPacketSize(): Int {
        val socket = synchronized(socketLock) {
            bluetoothSocket
        }
        return resolveMaxTransmitPacketSize(socket)
    }

    private fun resolveMaxTransmitPacketSize(socket: BluetoothSocket?): Int {
        if (socket == null) {
            return 1
        }

        val packetSize = socket.maxTransmitPacketSize
        return if (packetSize > 0) packetSize else 1
    }

    private fun closeSocket(
        notifyDisconnect: Boolean,
        error: String? = null
    ) {
        val socket: BluetoothSocket?
        val input: InputStream?
        val output: OutputStream?
        val job: Job?

        synchronized(socketLock) {
            socket = bluetoothSocket
            input = inputStream
            output = outputStream
            job = readJob

            bluetoothSocket = null
            inputStream = null
            outputStream = null
            readJob = null
            connectedDevice = null
        }

        gattSidecar.disconnect()

        try {
            job?.cancel()
        } catch (_: Exception) {
        }

        try {
            input?.close()
        } catch (_: Exception) {
        }

        try {
            output?.close()
        } catch (_: Exception) {
        }

        try {
            socket?.close()
        } catch (_: Exception) {
        }

        if (notifyDisconnect) {
            onDeviceDisconnected(error)
        }
    }
}
