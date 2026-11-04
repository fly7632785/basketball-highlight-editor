package com.bhe.bhe_mobile

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/** Validates the finalized MP4 container and every encoded video sample. */
internal data class MergeTrackFacts(
    val mime: String,
    val width: Int,
    val height: Int,
    val frameRate: Float,
    val durationUs: Long,
    val samples: Long,
    val syncSamples: Long,
    val firstPtsUs: Long,
    val lastPtsUs: Long,
)

internal object AndroidMergeMediaInspector {
    fun inspect(file: File, cancelled: AtomicBoolean): MergeMediaFacts {
        fun checkCancelled() {
            if (cancelled.get()) throw InterruptedException("合并导出已取消")
        }
        checkCancelled()
        val retriever = MediaMetadataRetriever()
        val durationMs = try {
            retriever.setDataSource(file.absolutePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        } finally {
            retriever.release()
        }
        check(durationMs > 0) { "合并结果时长无效" }
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            var tracks = 0
            var samples = 0L
            val trackFacts = mutableListOf<MergeTrackFacts>()
            for (index in 0 until extractor.trackCount) {
                checkCancelled()
                val format = extractor.getTrackFormat(index)
                if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") != true) continue
                check(format.containsKey(MediaFormat.KEY_WIDTH) && format.getInteger(MediaFormat.KEY_WIDTH) > 0 &&
                    format.containsKey(MediaFormat.KEY_HEIGHT) && format.getInteger(MediaFormat.KEY_HEIGHT) > 0) {
                    "合并结果视频轨无效"
                }
                tracks++
                // 只写入 1 条视频轨，成品就不该出现第 2 条；多出来就明说，不去猜哪条该算。
                MergeMediaFinalizer.requireSingleVideoTrack(tracks)
                extractor.selectTrack(index)
                try {
                    extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                    var count = 0L
                    var syncSamples = 0L
                    var firstPtsUs = -1L
                    var lastPtsUs = -1L
                    var buffer = ByteBuffer.allocate(1024 * 1024)
                    while (extractor.sampleTrackIndex >= 0) {
                        checkCancelled()
                        val size = extractor.sampleSize
                        check(size > 0 && size <= Int.MAX_VALUE) { "合并结果视频样本无效" }
                        if (size > buffer.capacity()) buffer = ByteBuffer.allocate(size.toInt())
                        buffer.clear()
                        check(extractor.readSampleData(buffer, 0) == size.toInt()) { "合并结果视频样本损坏" }
                        if (firstPtsUs < 0L) firstPtsUs = extractor.sampleTime
                        lastPtsUs = extractor.sampleTime
                        if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) syncSamples++
                        count++
                        extractor.advance()
                    }
                    check(count > 0) { "合并结果视频轨没有样本" }
                    samples += count
                    trackFacts.add(
                        MergeTrackFacts(
                            mime = format.getString(MediaFormat.KEY_MIME) ?: "unknown",
                            width = format.getInteger(MediaFormat.KEY_WIDTH),
                            height = format.getInteger(MediaFormat.KEY_HEIGHT),
                            frameRate = if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                                format.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat()
                            } else {
                                0f
                            },
                            durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                                format.getLong(MediaFormat.KEY_DURATION)
                            } else {
                                0L
                            },
                            samples = count,
                            syncSamples = syncSamples,
                            firstPtsUs = firstPtsUs,
                            lastPtsUs = lastPtsUs,
                        ),
                    )
                } finally {
                    extractor.unselectTrack(index)
                }
            }
            return MergeMediaFacts(tracks, durationMs, samples, trackFacts)
        } finally {
            extractor.release()
        }
    }
}
