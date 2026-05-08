package xyz.foundation.ble.foundation_ble.connection.l2cap

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

// Android exposes connection priority, MTU, and PHY tuning through GATT APIs,
// not through the L2CAP socket itself. This sidecar keeps a lightweight GATT
// link around long enough to warm up those link-layer settings while payloads
// still flow over the actual L2CAP transport.
internal class L2capGattSidecar(
    private val deviceId: String,
    context: Context
) {
    companion object {
        private const val TAG = "L2capGattSidecar"
        private const val DESIRED_MTU = 517
    }

    private val appContext = context.applicationContext
    private val gattLock = Any()
    private var bluetoothGatt: BluetoothGatt? = null
    private var pendingConnect: CompletableDeferred<Boolean>? = null

    @SuppressLint("MissingPermission")
    suspend fun connectAndWarmUp(
        device: BluetoothDevice,
        timeoutMs: Long = 1500L
    ): Boolean {
        Log.d(
            TAG,
            "[$deviceId] Sidecar warmup: starting best-effort GATT warmup timeout=${timeoutMs}ms"
        )
        connect(device)

        val pending = synchronized(gattLock) { pendingConnect }
        if (pending == null) {
            Log.d(TAG, "[$deviceId] Sidecar warmup: no active pending connect to await")
            return false
        }

        val connected = withTimeoutOrNull(timeoutMs) {
            pending.await()
        } ?: false

        if (connected) {
            Log.d(TAG, "[$deviceId] Sidecar warmup: GATT connected before L2CAP connect")
        } else {
            Log.d(TAG, "[$deviceId] Sidecar warmup: timed out or failed, continuing anyway")
            finishPendingConnect(false)
        }

        return connected
    }

    @SuppressLint("MissingPermission")
    fun connect(device: BluetoothDevice) {
        Log.d(
            TAG,
            "[$deviceId] Sidecar step 1/4: requesting companion GATT connect to ${device.address}"
        )
        disconnect()

        synchronized(gattLock) {
            pendingConnect = CompletableDeferred()
        }

        try {
            val gatt = device.connectGatt(
                appContext,
                false,
                gattCallback,
                BluetoothDevice.TRANSPORT_LE
            )
            synchronized(gattLock) {
                bluetoothGatt = gatt
            }
            if (gatt == null) {
                Log.w(TAG, "[$deviceId] Failed to create GATT sidecar for L2CAP")
                finishPendingConnect(false)
            } else {
                Log.d(TAG, "[$deviceId] Sidecar step 2/4: connectGatt returned a BluetoothGatt")
            }
        } catch (error: SecurityException) {
            finishPendingConnect(false)
            Log.w(
                TAG,
                "[$deviceId] Unable to start GATT sidecar due to permissions: ${error.message}",
                error
            )
        } catch (error: Exception) {
            finishPendingConnect(false)
            Log.w(TAG, "[$deviceId] Unable to start GATT sidecar: ${error.message}", error)
        }
    }

    @SuppressLint("MissingPermission")
    fun disconnect() {
        val gatt = synchronized(gattLock) {
            val activeGatt = bluetoothGatt
            bluetoothGatt = null
            activeGatt
        }

        if (gatt == null) {
            Log.d(TAG, "[$deviceId] Sidecar disconnect skipped: no active GATT")
            finishPendingConnect(false)
            return
        }

        finishPendingConnect(false)

        try {
            gatt.disconnect()
        } catch (_: Exception) {
        }

        try {
            gatt.close()
        } catch (_: Exception) {
        }

        Log.d(TAG, "[$deviceId] Closed GATT sidecar")
    }

    @SuppressLint("MissingPermission")
    fun requestPhy2(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            Log.d(TAG, "[$deviceId] requestPhy2 skipped: API ${Build.VERSION.SDK_INT} < 26")
            return false
        }

        val gatt = synchronized(gattLock) { bluetoothGatt }
        if (gatt == null) {
            Log.d(TAG, "[$deviceId] requestPhy2 skipped: sidecar is not connected")
            return false
        }
        gatt.setPreferredPhy(
            BluetoothDevice.PHY_LE_2M,
            BluetoothDevice.PHY_LE_2M,
            BluetoothDevice.PHY_LE_2M
        )
        Log.d(TAG, "[$deviceId] Requested LE 2M PHY from sidecar")
        return true
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (isStaleGattCallback(gatt)) {
                Log.d(
                    TAG,
                    "[$deviceId] Ignoring stale sidecar callback status=$status state=${
                        stateName(
                            newState
                        )
                    }"
                )
                return
            }

            Log.d(
                TAG,
                "[$deviceId] Sidecar callback onConnectionStateChange status=$status state=${
                    stateName(
                        newState
                    )
                }"
            )

            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(
                    TAG,
                    "[$deviceId] GATT sidecar failed with status=$status, closing sidecar"
                )
                finishPendingConnect(false)
                clearGatt(gatt = gatt, closeGatt = true)
                return
            }

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.d(TAG, "[$deviceId] Sidecar step 3/4: GATT connected")
                    finishPendingConnect(true)
                    requestPreferredLinkConfig(gatt)
                }

                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.d(TAG, "[$deviceId] GATT sidecar disconnected")
                    finishPendingConnect(false)
                    clearGatt(gatt = gatt, closeGatt = true)
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (isStaleGattCallback(gatt)) {
                return
            }

            Log.d(TAG, "[$deviceId] Sidecar step 4/4: MTU callback mtu=$mtu status=$status")
        }

        override fun onPhyUpdate(
            gatt: BluetoothGatt,
            txPhy: Int,
            rxPhy: Int,
            status: Int
        ) {
            if (isStaleGattCallback(gatt)) {
                return
            }

            Log.d(
                TAG,
                "[$deviceId] Sidecar PHY callback tx=${phyName(txPhy)} rx=${phyName(rxPhy)} status=$status"
            )
        }
    }

    @SuppressLint("MissingPermission")
    private fun requestPreferredLinkConfig(gatt: BluetoothGatt) {
        Log.d(TAG, "[$deviceId] Requesting preferred link config over GATT sidecar")

        val mtuRequested = gatt.requestMtu(DESIRED_MTU)
        Log.d(TAG, "[$deviceId] Requested MTU $DESIRED_MTU from sidecar: $mtuRequested")

        val highPriorityRequested = gatt.requestConnectionPriority(
            BluetoothGatt.CONNECTION_PRIORITY_HIGH
        )
        Log.d(
            TAG,
            "[$deviceId] Requested CONNECTION_PRIORITY_HIGH from sidecar: $highPriorityRequested"
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            gatt.setPreferredPhy(
                BluetoothDevice.PHY_LE_2M,
                BluetoothDevice.PHY_LE_2M,
                BluetoothDevice.PHY_LE_2M
            )
            Log.d(TAG, "[$deviceId] Requested LE 2M PHY from sidecar")
        }
    }

    private fun isStaleGattCallback(gatt: BluetoothGatt?): Boolean {
        val activeGatt = synchronized(gattLock) { bluetoothGatt }
        return gatt != null && (activeGatt == null || gatt !== activeGatt)
    }

    private fun finishPendingConnect(value: Boolean) {
        val pending = synchronized(gattLock) {
            val activePending = pendingConnect
            if (activePending != null && !activePending.isCompleted) {
                pendingConnect = null
                activePending
            } else {
                null
            }
        }
        pending?.complete(value)
    }

    @SuppressLint("MissingPermission")
    private fun clearGatt(gatt: BluetoothGatt?, closeGatt: Boolean) {
        val gattToClose = synchronized(gattLock) {
            val activeGatt = bluetoothGatt
            if (gatt == null || activeGatt === gatt) {
                bluetoothGatt = null
                activeGatt
            } else {
                null
            }
        }

        if (closeGatt) {
            try {
                gattToClose?.close()
            } catch (_: Exception) {
            }
        }

        if (gattToClose != null) {
            Log.d(TAG, "[$deviceId] Cleared GATT sidecar closeGatt=$closeGatt")
        }
    }

    private fun stateName(state: Int): String {
        return when (state) {
            BluetoothProfile.STATE_DISCONNECTED -> "DISCONNECTED"
            BluetoothProfile.STATE_CONNECTING -> "CONNECTING"
            BluetoothProfile.STATE_CONNECTED -> "CONNECTED"
            BluetoothProfile.STATE_DISCONNECTING -> "DISCONNECTING"
            else -> "UNKNOWN($state)"
        }
    }

    private fun phyName(phy: Int): String {
        return when (phy) {
            BluetoothDevice.PHY_LE_1M -> "LE_1M"
            BluetoothDevice.PHY_LE_2M -> "LE_2M"
            BluetoothDevice.PHY_LE_CODED -> "LE_CODED"
            BluetoothDevice.PHY_OPTION_NO_PREFERRED -> "NO_PREFERRED"
            else -> "UNKNOWN($phy)"
        }
    }
}
