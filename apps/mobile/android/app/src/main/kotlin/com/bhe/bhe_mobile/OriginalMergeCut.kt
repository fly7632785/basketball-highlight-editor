package com.bhe.bhe_mobile

import android.media.MediaExtractor
import android.media.MediaFormat
import java.util.concurrent.atomic.AtomicBoolean

internal data class OriginalMergeCut(
    val startUs: Long,
    val endUs: Long,
    val decodeEndUs: Long?,
    val canCopy: Boolean,
    val videoSamples: Long,
) {
    val durationUs: Long get() = endUs - startUs

    companion object {
        fun read(
            extractor: MediaExtractor, track: Int, interval: ExportInterval, cancelled: AtomicBoolean,
        ): OriginalMergeCut {
            val format = extractor.getTrackFormat(track)
            val sourceEndUs = format.getLong(MediaFormat.KEY_DURATION)
            val requestedStartUs = interval.startMs * 1000L
            val requestedEndUs = interval.endMs * 1000L
            extractor.selectTrack(track)
            try {
                extractor.seekTo(requestedStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                var startUs = Long.MAX_VALUE
                var endUs = sourceEndUs
                var highestDecodedPts = Long.MIN_VALUE
                var requiredReferencePts = Long.MIN_VALUE
                var startSync = false
                var endSync = false
                var syncSamplesPastCut = 0
                var videoSamples = 0L
                while (extractor.sampleTrackIndex == track) {
                    if (cancelled.get()) throw InterruptedException("导出已取消")
                    val pts = extractor.sampleTime
                    val sync = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                    highestDecodedPts = maxOf(highestDecodedPts, pts)
                    if (pts in requestedStartUs until requestedEndUs) {
                        videoSamples++
                        requiredReferencePts = highestDecodedPts
                        if (pts < startUs) {
                            startUs = pts
                            startSync = sync
                        }
                    } else if (pts >= requestedEndUs) {
                        if (pts < endUs) {
                            endUs = pts
                            endSync = sync
                        }
                        // Read past the next sync sample as well: an open GOP
                        // can have leading pictures after it in decode order.
                        if (sync && ++syncSamplesPastCut == 2) break
                    }
                    if (!extractor.advance()) break
                }
                if (startUs >= endUs) throw MergeRangeUnavailable("合并片段没有可读取的视频样本")
                val decodeEnd = maxOf(endUs, requiredReferencePts + 1)
                val copy = startSync && startUs == requestedStartUs &&
                    endSync && endUs == requestedEndUs && requiredReferencePts < endUs
                return OriginalMergeCut(startUs, endUs, decodeEnd.takeIf { it < sourceEndUs }, copy, videoSamples)
            } finally {
                extractor.unselectTrack(track)
            }
        }
    }
}
