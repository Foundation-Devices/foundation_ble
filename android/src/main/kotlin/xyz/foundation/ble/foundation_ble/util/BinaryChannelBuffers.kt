package xyz.foundation.ble.foundation_ble.util

import java.nio.ByteBuffer

internal object BinaryChannelBuffers {
    fun payload(data: ByteArray): ByteBuffer {
        val buffer = ByteBuffer.allocateDirect(data.size)
        buffer.put(data)
        return buffer
    }

    fun reply(value: Byte): ByteBuffer = payload(byteArrayOf(value))
}
