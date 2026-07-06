package xyz.foundation.ble.foundation_ble.transport

data class SessionChannelNames(
    val methodChannelName: String,
    val scanStreamName: String,
    val logStreamName: String,
    val connectionMethodRoot: String,
    val readChannelRoot: String,
    val writeChannelRoot: String,
    val connectionStreamRoot: String
) {
    companion object {
        fun defaultNames(): SessionChannelNames {
            return SessionChannelNames(
                methodChannelName = "foundation_ble/bluetooth",
                scanStreamName = "foundation_ble/bluetooth/scan/stream",
                logStreamName = "foundation_ble/bluetooth/log/stream",
                connectionMethodRoot = "foundation_ble/bluetooth",
                readChannelRoot = "foundation_ble/ble/read",
                writeChannelRoot = "foundation_ble/ble/write",
                connectionStreamRoot = "foundation_ble/bluetooth/connection/stream"
            )
        }
    }
}
