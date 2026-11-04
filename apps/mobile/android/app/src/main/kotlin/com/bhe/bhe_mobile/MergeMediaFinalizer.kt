package com.bhe.bhe_mobile

import com.bhe.bhe_mobile.diagnostics.AppDiagnostics
import java.io.File

internal data class MergeMediaFacts(
    val videoTracks: Int,
    val durationMs: Long,
    val readableVideoSamples: Long,
    val tracks: List<MergeTrackFacts> = emptyList(),
)

internal class MergeRangeUnavailable(message: String) : IllegalStateException(message)

/** MediaExtractor 在没有（或读不到）样本时给出的时间戳；负的 PTS 不是这个值。 */
internal const val NO_SAMPLE_TIME = -1L

/** Injectable media boundary: the caller owns resource cleanup if a step fails. */
internal object MergeMediaFinalizer {
    /** -1（SAMPLE_TIME_NONE）且没有可读样本才算定位失败；负的起始 PTS 是合法时间戳（手机录制常见）。 */
    fun requireLocation(sampleTimeUs: Long, sampleTrackIndex: Int = 0) {
        if (sampleTimeUs == NO_SAMPLE_TIME && sampleTrackIndex < 0) {
            throw MergeRangeUnavailable("无法定位合并片段")
        }
    }

    /** 成品只能有 1 条视频轨：多轨时写入/回读的样本口径对不上，播放器也只会认其中一条。 */
    fun requireSingleVideoTrack(videoTracks: Int) {
        check(videoTracks <= 1) { "合并结果出现多条视频轨（$videoTracks）" }
    }

    fun requireVideoSamples(count: Long) {
        if (count <= 0) throw MergeRangeUnavailable("合并片段没有可读取的视频样本")
    }

    fun finish(
        transaction: MergeOutputTransaction,
        writtenVideoSamples: Long,
        stop: () -> Unit,
        release: () -> Unit,
        inspect: (File) -> MergeMediaFacts,
        stats: MergeVideoStats = MergeVideoStats().apply { this.writtenVideoSamples = writtenVideoSamples },
    ) {
        try {
            stop()
        } catch (error: Exception) {
            try {
                release()
            } catch (releaseError: Exception) {
                error.addSuppressed(releaseError)
            }
            throw error
        }
        release()
        check(writtenVideoSamples > 0) { "合并结果没有视频样本" }
        transaction.publish { file ->
            val facts = inspect(file)
            check(facts.videoTracks > 0 && facts.durationMs > 0) { "合并结果没有有效视频轨或时长" }
            if (facts.readableVideoSamples != writtenVideoSamples) {
                // 先把两边的数记进诊断，再照旧失败：这是区分「误报」和「真丢帧」的唯一证据。
                MergeMismatchReport.events(stats, facts).forEach { (event, fields) ->
                    AppDiagnostics.event(event, fields)
                }
                check(false) { "合并结果视频样本不完整" }
            }
        }
    }
}

internal object MergeOutputFiles {
    fun create(destination: File, createTemporary: (File) -> File = {
        File.createTempFile(".bhe-merge-", ".mp4", it)
    }): File {
        val parent = destination.absoluteFile.parentFile ?: throw IllegalArgumentException("无效的输出目录")
        if (!parent.exists() && !parent.mkdirs() && !parent.isDirectory) {
            throw IllegalStateException("无法创建输出目录")
        }
        return createTemporary(parent)
    }
}
