package com.bhe.bhe_mobile

import org.json.JSONArray
import org.json.JSONObject

/** The runtime returns boxes in the orientation and size of the frame it saw. */
internal class RimCheckFrameCoordinates(
    frameWidth: Int,
    frameHeight: Int,
    rotationDegrees: Int,
    displayWidth: Double,
    displayHeight: Double,
) {
    // For direct YUV the runtime applies rotation before reporting boxes.
    // Bitmaps arrive display-oriented, so callers pass zero rotation for them.
    private val swapsAxes = rotationDegrees % 180 != 0
    private val scaleX = displayWidth / if (swapsAxes) frameHeight else frameWidth
    private val scaleY = displayHeight / if (swapsAxes) frameWidth else frameHeight

    fun toDisplay(detection: JSONObject): JSONArray = JSONArray()
        .put(detection.getDouble("x1") * scaleX)
        .put(detection.getDouble("y1") * scaleY)
        .put(detection.getDouble("x2") * scaleX)
        .put(detection.getDouble("y2") * scaleY)
}
