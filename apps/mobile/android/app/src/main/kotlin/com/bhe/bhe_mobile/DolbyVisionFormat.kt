package com.bhe.bhe_mobile

import android.media.MediaCodecInfo
import android.media.MediaFormat
import com.bhe.bhe_mobile.diagnostics.AppDiagnostics

internal object DolbyVisionFormat {
    private fun config(format: MediaFormat): ByteArray? =
        format.getByteBuffer("csd-2")?.duplicate()?.let { buffer ->
            ByteArray(minOf(buffer.remaining(), 5)).also { buffer.get(it) }
        }

    private fun profile(format: MediaFormat, config: ByteArray?): Int? = DolbyVisionPolicy.profile(
        if (format.containsKey(MediaFormat.KEY_PROFILE)) format.getInteger(MediaFormat.KEY_PROFILE) else null,
        config,
    )

    fun profile(format: MediaFormat): Int? =
        if (format.getString(MediaFormat.KEY_MIME) == DolbyVisionPolicy.MIME) profile(format, config(format)) else null

    /** Omit DV-only metadata; preserve base-layer HDR color and codec configuration. */
    fun hevcBase(format: MediaFormat): MediaFormat {
        val output = MediaFormat.createVideoFormat(DolbyVisionPolicy.HEVC,
            format.getInteger(MediaFormat.KEY_WIDTH), format.getInteger(MediaFormat.KEY_HEIGHT))
        for (key in listOf("csd-0", "csd-1")) {
            format.getByteBuffer(key)?.let { output.setByteBuffer(key, it.duplicate()) }
        }
        for (key in listOf(MediaFormat.KEY_ROTATION, MediaFormat.KEY_MAX_INPUT_SIZE,
            MediaFormat.KEY_COLOR_STANDARD, MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.KEY_COLOR_RANGE)) {
            if (format.containsKey(key)) output.setInteger(key, format.getInteger(key))
        }
        if (format.containsKey(MediaFormat.KEY_DURATION)) output.setLong(MediaFormat.KEY_DURATION, format.getLong(MediaFormat.KEY_DURATION))
        format.getByteBuffer("hdr-static-info")?.let { output.setByteBuffer("hdr-static-info", it.duplicate()) }
        output.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10)
        return output
    }

    fun canUseHevcBase(format: MediaFormat): Boolean {
        if (format.getString(MediaFormat.KEY_MIME) != DolbyVisionPolicy.MIME) return false
        val config = config(format)
        return DolbyVisionPolicy.hasHevcBase(DolbyVisionPolicy.MIME, profile(format, config), config) &&
            (format.getByteBuffer("csd-0")?.remaining() ?: 0) > 0
    }

    fun forDecode(format: MediaFormat): MediaFormat {
        if (format.getString(MediaFormat.KEY_MIME) != DolbyVisionPolicy.MIME) return format
        return if (canUseHevcBase(format)) {
            AppDiagnostics.event("decode.dolby.hevc_base", mapOf("profile" to 8))
            hevcBase(format)
        } else format
    }

    fun forExport(format: MediaFormat): MediaFormat {
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return format
        val target = DolbyVisionPolicy.exportMime(mime, profile(format))
        if (target != mime) check(canUseHevcBase(format)) { "HEVC codec configuration is missing" }
        return if (target != mime) {
            AppDiagnostics.event("export.dolby.hevc_base", mapOf("profile" to 8))
            hevcBase(format)
        } else format
    }
}
