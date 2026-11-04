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

/** Injectable media boundary: the caller owns resource cleanup if a step fails. */
internal object MergeMediaFinalizer {
    fun requireLocation(sampleTimeUs: Long) {
        if (sampleTimeUs < 0) throw MergeRangeUnavailable("无法定位合并片段")
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
