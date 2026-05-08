package xyz.foundation.ble.foundation_ble

import xyz.foundation.ble.foundation_ble.util.BinaryChannelBuffers
import kotlin.test.Test
import kotlin.test.assertEquals

class BinaryChannelBuffersTest {

    @Test
    fun `payload buffer keeps byte count in position for Flutter messenger`() {
        val data = byteArrayOf(0x01, 0x02, 0x03)
        val buffer = BinaryChannelBuffers.payload(data)
        assertEquals(data.size, buffer.limit())
    }

    @Test
    fun `reply buffer preserves single success byte`() {
        val buffer = BinaryChannelBuffers.reply(0x01)
        assertEquals(1, buffer.limit())
    }
}
