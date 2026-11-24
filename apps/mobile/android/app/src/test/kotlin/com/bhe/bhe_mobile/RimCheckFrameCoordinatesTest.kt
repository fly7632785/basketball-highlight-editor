package com.bhe.bhe_mobile

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class RimCheckFrameCoordinatesTest {
    @Test
    fun rotated4kYuvAndDownscaledPortraitBitmapUseTheSameRimCoordinates() {
        val yuv = RimCheckFrameCoordinates(3840, 2160, 90, 2160.0, 3840.0)
        val bitmap = RimCheckFrameCoordinates(540, 960, 0, 2160.0, 3840.0)

        val yuvBox = yuv.toDisplay(box(1680.0, 1416.0, 1700.0, 1440.0))
        val bitmapBox = bitmap.toDisplay(box(420.0, 354.0, 425.0, 360.0))

        assertBox(yuvBox, 1680.0, 1416.0, 1700.0, 1440.0)
        assertBox(bitmapBox, 1680.0, 1416.0, 1700.0, 1440.0)
    }

    @Test
    fun usesActualFrameDimensionsForEachAxis() {
        val bitmap = RimCheckFrameCoordinates(539, 960, 0, 2160.0, 3840.0)

        assertBox(bitmap.toDisplay(box(0.0, 240.0, 539.0, 960.0)), 0.0, 960.0, 2160.0, 3840.0)
    }

    private fun box(x1: Double, y1: Double, x2: Double, y2: Double): JSONObject =
        JSONObject().put("x1", x1).put("y1", y1).put("x2", x2).put("y2", y2)

    private fun assertBox(actual: JSONArray, vararg expected: Double) {
        assertEquals(expected.size, actual.length())
        expected.forEachIndexed { index, coordinate ->
            assertEquals(coordinate, actual.getDouble(index), 0.000001)
        }
    }
}
