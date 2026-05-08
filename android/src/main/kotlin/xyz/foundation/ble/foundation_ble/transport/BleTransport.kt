package xyz.foundation.ble.foundation_ble.transport

enum class BleTransportMode {
    GATT,
    L2CAP;

    companion object {
        fun fromRawValue(value: String?): BleTransportMode {
            return when (value?.lowercase()) {
                "gatt" -> GATT
                "l2cap" -> L2CAP
                else -> throw IllegalArgumentException("Unsupported BLE transport mode: $value")
            }
        }
    }
}

data class BleTransportConfig(
    val mode: BleTransportMode,
    val psm: Int? = null
) {
    fun validate() {
        if (mode != BleTransportMode.L2CAP) {
            return
        }

        val resolvedPsm = psm
            ?: throw IllegalArgumentException("L2CAP transport requires a PSM")
        require(resolvedPsm in 1..0xFFFF) {
            "L2CAP PSM must be between 1 and 65535"
        }
    }

    companion object {
        fun gatt(): BleTransportConfig = BleTransportConfig(mode = BleTransportMode.GATT)

        fun fromArguments(
            arguments: Map<*, *>?,
            defaultConfig: BleTransportConfig? = null
        ): BleTransportConfig {
            val rawTransport = arguments?.get("transport") as? Map<*, *>
                ?: return defaultConfig
                    ?: throw IllegalArgumentException("Missing BLE transport configuration")
            val config = BleTransportConfig(
                mode = BleTransportMode.fromRawValue(rawTransport["mode"] as? String),
                psm = (rawTransport["psm"] as? Number)?.toInt()
            )
            config.validate()
            return config
        }
    }
}

data class SessionChannelNames(
    val methodChannelName: String,
    val scanStreamName: String,
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
                connectionMethodRoot = "foundation_ble/bluetooth",
                readChannelRoot = "foundation_ble/ble/read",
                writeChannelRoot = "foundation_ble/ble/write",
                connectionStreamRoot = "foundation_ble/bluetooth/connection/stream"
            )
        }
    }
}
