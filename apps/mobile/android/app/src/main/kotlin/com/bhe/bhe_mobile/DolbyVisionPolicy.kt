package com.bhe.bhe_mobile

/** ISO dvcC profile is a number; Android profile is a bit flag (profile 8 = 256). */
internal object DolbyVisionPolicy {
    const val MIME = "video/dolby-vision"
    const val HEVC = "video/hevc"
    fun profile(androidProfile: Int?, config: ByteArray?): Int? =
        if (config != null && config.size >= 4) (config[2].toInt() and 0xff) shr 1
        else androidProfile?.takeIf { it > 0 && it and (it - 1) == 0 }?.let { Integer.numberOfTrailingZeros(it) }

    fun hasHevcBase(mime: String, profile: Int?, config: ByteArray? = null): Boolean {
        if (mime != MIME || profile != 8) return false
        if (config == null) return true
        if (config.size < 5) return false
        val baseLayerPresent = config[3].toInt() and 1 != 0
        val compatibilityId = (config[4].toInt() and 0xff) shr 4
        return baseLayerPresent && compatibilityId in setOf(1, 2, 4)
    }
    fun exportMime(mime: String, profile: Int?): String {
        if (mime != MIME) return mime
        check(hasHevcBase(mime, profile)) { "杜比视频格式不兼容，需要先转码为 HEVC/H.264 后导出（profile=${profile ?: "unknown"}）" }
        return HEVC
    }
}
