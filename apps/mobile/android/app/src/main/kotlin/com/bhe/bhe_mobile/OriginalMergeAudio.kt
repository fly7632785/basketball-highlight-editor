package com.bhe.bhe_mobile

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import com.bhe.bhe_mobile.diagnostics.AppDiagnostics
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/** Preserve the source's additional audio tracks on the same timeline as the rendered cut. */
internal object OriginalMergeAudio {
    fun append(
        source: MediaExtractor, rendered: File, target: File, cuts: List<OriginalMergeCut>,
        audio: List<ExportSourceTrack>, cancelled: AtomicBoolean,
    ): List<ExportSourceTrack> {
        val encoded = MediaExtractor()
        try {
            encoded.setDataSource(rendered.absolutePath)
            val muxer = MediaMuxer(target.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            var failure: Throwable? = null
            try {
                val encodedTracks = (0 until encoded.trackCount).associateWith { index ->
                    val format = encoded.getTrackFormat(index)
                    if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                        muxer.setOrientationHint(ExportTrackPolicy.orientation(format.getInteger(MediaFormat.KEY_ROTATION, 0)))
                    }
                    encoded.selectTrack(index)
                    muxer.addTrack(format)
                }
                val skipped = mutableListOf<ExportSourceTrack>()
                val sourceTracks = buildMap {
                    for (track in audio) {
                        try {
                            put(track.index, muxer.addTrack(source.getTrackFormat(track.index)))
                        } catch (error: IllegalArgumentException) {
                            skipped.add(track)
                            AppDiagnostics.event("export.audio.skipped", mapOf("track" to track.index, "mime" to track.mime), error)
                        }
                    }
                }
                muxer.start()
                var buffer = ByteBuffer.allocate(1024 * 1024)
                val info = MediaCodec.BufferInfo()
                fun write(reader: MediaExtractor, track: Int, pts: Long) {
                    if (cancelled.get()) throw InterruptedException("导出已取消")
                    val size = reader.sampleSize
                    check(size in 1..Int.MAX_VALUE.toLong()) { "合并结果视频样本无效" }
                    if (size > buffer.capacity()) buffer = ByteBuffer.allocate(size.toInt())
                    buffer.clear()
                    check(reader.readSampleData(buffer, 0) == size.toInt()) { "合并结果视频样本损坏" }
                    info.set(0, size.toInt(), pts, reader.sampleFlags)
                    muxer.writeSampleData(track, buffer, info)
                    reader.advance()
                }
                fun writeEncodedBefore(pts: Long) {
                    while (encoded.sampleTrackIndex >= 0 && encoded.sampleTime < pts) {
                        write(encoded, encodedTracks.getValue(encoded.sampleTrackIndex), encoded.sampleTime)
                    }
                }
                if (sourceTracks.isNotEmpty()) {
                    sourceTracks.keys.forEach(source::selectTrack)
                    var offset = 0L
                    for (cut in cuts) {
                        source.seekTo(cut.startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                        while (source.sampleTrackIndex >= 0 && source.sampleTime < cut.endUs) {
                            if (cancelled.get()) throw InterruptedException("导出已取消")
                            if (source.sampleTime < cut.startUs) {
                                source.advance()
                                continue
                            }
                            val pts = source.sampleTime - cut.startUs + offset
                            writeEncodedBefore(pts)
                            write(source, sourceTracks.getValue(source.sampleTrackIndex), pts)
                        }
                        offset += cut.durationUs
                    }
                }
                writeEncodedBefore(Long.MAX_VALUE)
                muxer.stop()
                return skipped
            } catch (error: Throwable) {
                failure = error
                throw error
            } finally {
                try {
                    muxer.release()
                } catch (cleanupError: Exception) {
                    if (failure == null) throw cleanupError
                    failure.addSuppressed(cleanupError)
                }
            }
        } finally {
            encoded.release()
        }
    }
}
