package com.bhe.bhe_mobile

internal data class ExportSourceTrack(val index: Int, val mime: String)
internal data class ExportTrackSelection(
    val trackMap: Map<Int, Int>,
    val skippedAudio: List<ExportSourceTrack>,
    val skippedVideo: List<ExportSourceTrack> = emptyList(),
)

/** Container policy is independent of Android codecs so error paths are unit-testable. */
internal object ExportTrackPolicy {
    private const val DOLBY_VISION = "video/dolby-vision"

    /**
     * 成品只能有 1 条视频轨：杜比视界的手机视频会被 Android 报成
     * `video/dolby-vision` + `video/hevc` 两条视频轨，两条都写会让「写入样本数」
     * 和「成品样本数」永远对不上（成品里 DV 轨还会再拆一条出来）。
     * 优先留 HEVC/AVC 底层轨，DV 轨跳过并记诊断；只有 DV 一条时保持原样写入。
     */
    private fun chosenVideoIndex(tracks: List<ExportSourceTrack>): Int? {
        val videos = tracks.filter { it.mime.startsWith("video/") }
        if (videos.isEmpty()) return null
        return (videos.firstOrNull { it.mime == "video/hevc" }
            ?: videos.firstOrNull { it.mime == "video/avc" }
            ?: videos.firstOrNull { it.mime != DOLBY_VISION }
            ?: videos.first()).index
    }

    fun select(
        tracks: List<ExportSourceTrack>,
        addTrack: (Int) -> Int,
        onSkipped: (ExportSourceTrack, Exception) -> Unit = { _, _ -> },
        onSkippedVideo: (ExportSourceTrack, String) -> Unit = { _, _ -> },
    ): ExportTrackSelection {
        val selected = mutableMapOf<Int, Int>()
        val skipped = mutableListOf<ExportSourceTrack>()
        val skippedVideo = mutableListOf<ExportSourceTrack>()
        val chosenVideo = chosenVideoIndex(tracks)
        var videos = 0
        for (track in tracks) {
            val isVideo = track.mime.startsWith("video/")
            if (!isVideo && !track.mime.startsWith("audio/")) continue
            if (isVideo && track.index != chosenVideo) {
                skippedVideo.add(track)
                onSkippedVideo(track, track.mime)
                continue
            }
            try {
                selected[track.index] = addTrack(track.index)
                if (isVideo) videos++
            } catch (error: Exception) {
                if (isVideo) throw IllegalStateException("视频轨道格式（${track.mime}）无法导出", error)
                skipped.add(track)
                onSkipped(track, error)
            }
        }
        check(videos > 0) { "视频没有可导出的音视频轨道" }
        return ExportTrackSelection(selected, skipped, skippedVideo)
    }

    fun orientation(degrees: Int): Int {
        val normalized = ((degrees % 360) + 360) % 360
        require(normalized in listOf(0, 90, 180, 270)) { "Invalid video orientation" }
        return normalized
    }
}
