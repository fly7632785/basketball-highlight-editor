package com.bhe.bhe_mobile

internal data class ExportSourceTrack(val index: Int, val mime: String, val dolbyProfile: Int? = null, val hasSamples: Boolean = true)
internal data class ExportTrackSelection(
    val trackMap: Map<Int, Int>,
    val skippedAudio: List<ExportSourceTrack>,
    val skippedVideo: List<ExportSourceTrack> = emptyList(),
)

/** Container policy is independent of Android codecs so error paths are unit-testable. */
internal object ExportTrackPolicy {
    private const val DOLBY_VISION = DolbyVisionPolicy.MIME

    // Export a single video track. Prefer the readable profile 8 track, whose
    // samples are remuxed as HEVC, over extractor-provided duplicate tracks.
    private fun chosenVideoIndex(tracks: List<ExportSourceTrack>): Int? {
        val videos = tracks.filter { it.mime.startsWith("video/") && it.hasSamples }
        if (videos.isEmpty()) return null
        return (videos.firstOrNull { DolbyVisionPolicy.hasHevcBase(it.mime, it.dolbyProfile) }
            ?: videos.firstOrNull { it.mime == "video/hevc" }
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
        check(chosenVideo != null) { "视频没有可读取的视频轨道" }
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
                if (isVideo) DolbyVisionPolicy.exportMime(track.mime, track.dolbyProfile)
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
