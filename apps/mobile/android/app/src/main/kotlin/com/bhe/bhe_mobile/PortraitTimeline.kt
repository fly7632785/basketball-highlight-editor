package com.bhe.bhe_mobile

import android.media.MediaFormat
import org.json.JSONObject

internal const val PORTRAIT_SAMPLE_HZ = 10
internal const val PORTRAIT_WIDTH = 1080
internal const val PORTRAIT_HEIGHT = 1920

internal data class PortraitKeyframe(val tMs: Long, val cxNorm: Double)

internal class PortraitTimeline(
    val startMs: Long,
    val endMs: Long,
    private val points: List<PortraitKeyframe>,
) {
    init {
        require(startMs >= 0 && endMs > startMs) { "Invalid portrait clip range" }
        require(points.isNotEmpty() && points.all {
            it.tMs in startMs..endMs && it.cxNorm in 0.0..1.0
        } && points.zipWithNext().all { (a, b) -> a.tMs < b.tMs }) {
            "Invalid portrait keyframes"
        }
    }

    fun centerAt(clipTimeUs: Long): Double {
        val time = startMs + clipTimeUs / 1000.0
        val index = points.binarySearch { it.tMs.toDouble().compareTo(time) }
        if (index >= 0) return points[index].cxNorm
        val right = -index - 1
        if (right == 0) return points.first().cxNorm
        if (right == points.size) return points.last().cxNorm
        val a = points[right - 1]
        val b = points[right]
        val fraction = (time - a.tMs) / (b.tMs - a.tMs)
        return a.cxNorm + fraction * (b.cxNorm - a.cxNorm)
    }
}

internal class PortraitGeometry(private val width: Int, height: Int) {
    private val aspect = PORTRAIT_WIDTH.toDouble() / PORTRAIT_HEIGHT
    private val cropWidth = minOf(width.toDouble(), height * aspect)
    private val cropHeight = minOf(height.toDouble(), width / aspect)
    val scaleX = width / cropWidth
    val scaleY = height / cropHeight

    fun translationX(center: Double): Double {
        val half = cropWidth / 2
        val centerPx = (center * width).coerceIn(half, width - half)
        return (width - 2 * centerPx) / cropWidth
    }
}

internal fun portraitSampleTimes(startMs: Long, endMs: Long): List<Long> =
    (startMs until endMs step (1000L / PORTRAIT_SAMPLE_HZ)).toList()

internal fun isPortraitHdr(mime: String?, transfer: Int): Boolean =
    mime == DolbyVisionPolicy.MIME ||
        transfer == MediaFormat.COLOR_TRANSFER_HLG ||
        transfer == MediaFormat.COLOR_TRANSFER_ST2084

internal fun portraitDetection(
    detection: JSONObject,
    coordinates: RimCheckFrameCoordinates,
): Map<String, Double> {
    val box = coordinates.toDisplay(detection)
    val left = box.getDouble(0)
    val top = box.getDouble(1)
    val right = box.getDouble(2)
    val bottom = box.getDouble(3)
    return mapOf(
        "cx" to (left + right) / 2,
        "cy" to (top + bottom) / 2,
        "w" to right - left,
        "h" to bottom - top,
        "conf" to detection.getDouble("confidence"),
    )
}
