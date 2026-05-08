package xyz.foundation.ble.foundation_ble.model

enum class BluetoothConnectionEventType {
    DEVICE_CONNECTED,
    DEVICE_DISCONNECTED,
    DEVICE_FOUND,
    SCAN_STARTED,
    SCAN_STOPPED,
    SCAN_ERROR,
    CONNECTION_ATTEMPT,
    CONNECTION_ERROR,
    BOND_BONDING,
    BOND_BONDED,
    BOND_REMOVED;

    fun toStringValue(): String {
        return when (this) {
            DEVICE_CONNECTED -> "device_connected"
            DEVICE_DISCONNECTED -> "device_disconnected"
            DEVICE_FOUND -> "device_found"
            SCAN_STARTED -> "scan_started"
            SCAN_STOPPED -> "scan_stopped"
            SCAN_ERROR -> "scan_error"
            CONNECTION_ATTEMPT -> "connection_attempt"
            CONNECTION_ERROR -> "connection_error"
            BOND_BONDING -> "bond_bonding"
            BOND_BONDED -> "bond_bonded"
            BOND_REMOVED -> "bond_removed"
        }
    }
}

data class BluetoothConnectionStatus(
    val type: BluetoothConnectionEventType? = null,
    val connected: Boolean,
    val ready: Boolean,
    val bonded: Boolean,
    val peripheralId: String? = null,
    val peripheralName: String? = null,
    val error: String? = null,
    val rssi: Int? = null
) {
    fun toMap(): Map<String, Any?> {
        return mapOf(
            "type" to type?.toStringValue(),
            "connected" to connected,
            "ready" to ready,
            "peripheralId" to peripheralId,
            "peripheralName" to peripheralName,
            "error" to error,
            "bonded" to bonded,
            "rssi" to rssi
        )
    }
}
