package xyz.foundation.ble.foundation_ble.connection.gatt

import android.annotation.SuppressLint
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothStatusCodes
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

private const val TAG = "BleWriteQueue"

@OptIn(ExperimentalCoroutinesApi::class)
class BleWriteQueue(
    private val gatt: BluetoothGatt,
    private val characteristic: BluetoothGattCharacteristic,
    externalScope: CoroutineScope
) {
    private val queue = Channel<WriteRequest>(Channel.UNLIMITED)
    private var continuation: CompletableDeferred<Boolean>? = null
    private var isActive = true

    init {
        externalScope.launch {
            for (request in queue) {
                if (!isActive) {
                    request.result.complete(false)
                    continue
                }

                val success = performWrite(request.data)
                if (!success) {
                    isActive = false
                    request.result.complete(false)
                    clearQueue()
                    break
                }

                request.result.complete(true)
            }
        }
    }

    fun restart() {
        if (!isActive) {
            isActive = true
            continuation = null
            clearQueue()
        }
    }

    suspend fun enqueue(data: ByteArray): Boolean {
        if (!isActive) {
            return false
        }

        val result = CompletableDeferred<Boolean>()
        queue.send(WriteRequest(data = data, result = result))
        return result.await()
    }

    fun onCharacteristicWrite(status: Int) {
        val currentContinuation = continuation
        continuation = null
        currentContinuation?.complete(status == BluetoothGatt.GATT_SUCCESS)
    }

    fun cancel() {
        continuation?.complete(false)
        continuation = null
        queue.cancel()
        Log.i(TAG, "Write queue cancelled")
    }

    @SuppressLint("MissingPermission")
    private suspend fun performWrite(data: ByteArray): Boolean {
        if (!isActive) {
            return false
        }

        val deferred = CompletableDeferred<Boolean>()
        continuation = deferred

        val writeType =
            if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            } else {
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            }

        val writeSuccess = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(
                characteristic,
                data,
                writeType
            ) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.writeType = writeType
            @Suppress("DEPRECATION")
            characteristic.value = data
            @Suppress("DEPRECATION")
            gatt.writeCharacteristic(characteristic)
        }

        if (!writeSuccess) {
            continuation = null
            isActive = false
            return false
        }
        return deferred.await()
    }

    fun clearQueue() {
        while (!queue.isEmpty) {
            queue.tryReceive().getOrNull()?.result?.complete(false)
        }
    }

    private data class WriteRequest(
        val data: ByteArray,
        val result: CompletableDeferred<Boolean>
    )
}
