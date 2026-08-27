package com.bhe.bhe_mobile

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.graphics.Bitmap
import android.graphics.Matrix
import android.util.Log

/**
 * Sequential MediaCodec frame decoder — replaces per-frame
 * MediaMetadataRetriever.getScaledFrameAtTime calls.
 *
 * The old approach: for each target timestamp, seek to nearest I-frame
 * then decode forward = O(keyframe_interval) per frame. For a 10-minute
 * video at 3fps sampling (1800 frames), this is extremely slow.
 *
 * This pipeline: set up MediaCodec once, feed ALL video samples
 * sequentially, only render Bitmaps at target timestamps.
 * Total decode = one pass through the video = O(duration).
 *
 * Expected speedup: 10-50x for typical videos with 1-2s keyframe intervals.
 */
class FramePipeline(private val videoPath: String) {
    private val tag = "BHE-FramePipeline"
    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var trackIndex = -1
    private var videoWidth = 0
    private var videoHeight = 0
    private var rotationDegrees = 0
    private var fallbackRetriever: MediaMetadataRetriever? = null

    /** Opens the video and prepares the decoder near [startUs]. */
    fun prepare(startUs: Long = 0L) {
        val ext = MediaExtractor()
        ext.setDataSource(videoPath)
        for (i in 0 until ext.trackCount) {
            val format = ext.getTrackFormat(i)
            if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                trackIndex = i
                videoWidth = format.getInteger(MediaFormat.KEY_WIDTH)
                videoHeight = format.getInteger(MediaFormat.KEY_HEIGHT)
                ext.selectTrack(i)
                break
            }
        }
        check(trackIndex >= 0) { "No video track found" }
        if (startUs > 0L) {
            // Decode from the nearest preceding key frame, not from the
            // beginning of a potentially long source video.
            ext.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        }
        val format = ext.getTrackFormat(trackIndex)
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        if (format.containsKey(MediaFormat.KEY_ROTATION)) {
            rotationDegrees = format.getInteger(MediaFormat.KEY_ROTATION)
        }
        codec = MediaCodec.createDecoderByType(mime).also { it.configure(format, null, null, 0); it.start() }
        extractor = ext
        Log.i(tag, "prepared ${videoWidth}x${videoHeight} mime=$mime startUs=$startUs")
    }

    /**
     * Sequentially decodes the video, invoking [onFrame] for each frame whose
     * presentation time is within tolerance of any target timestamp.
     *
     * @param timestampsUs target timestamps in microseconds, must be sorted ascending
     * @param onFrame callback (bitmap, timestampUs) for each matched frame
     * @return number of frames that were successfully delivered
     */
    fun decodeFrames(
        timestampsUs: List<Long>,
        shouldCancel: () -> Boolean,
        onFrame: (Bitmap, Long) -> Unit,
    ): Int {
        val ext = extractor ?: error("call prepare() first")
        val decoder = codec ?: error("call prepare() first")
        val info = MediaCodec.BufferInfo()
        var delivered = 0
        var targetIdx = 0
        var inputDone = false
        var outputDone = false
        val toleranceUs = 50_000L // 50ms tolerance for matching target timestamps

        while (!outputDone && targetIdx < timestampsUs.size) {
            if (shouldCancel()) throw InterruptedException("分析已取消")
            // Feed input
            if (!inputDone) {
                val inIdx = decoder.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val buf = decoder.getInputBuffer(inIdx)!!
                    val size = ext.readSampleData(buf, 0)
                    if (size < 0) {
                        decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        val pts = ext.sampleTime
                        decoder.queueInputBuffer(inIdx, 0, size, pts, 0)
                        ext.advance()
                    }
                }
            }

            // Drain output
            val outIdx = decoder.dequeueOutputBuffer(info, 10_000)
            when {
                outIdx >= 0 -> {
                    val pts = info.presentationTimeUs
                    // Check if this frame matches any pending target
                    while (targetIdx < timestampsUs.size && timestampsUs[targetIdx] <= pts + toleranceUs) {
                        val target = timestampsUs[targetIdx]
                        if (pts >= target - toleranceUs) {
                            // Render this frame to a Bitmap
                            val bitmap = renderToBitmap(decoder, outIdx) ?: fallbackFrameAt(target)
                            if (bitmap != null) {
                                onFrame(bitmap, target)
                                delivered++
                            }
                        }
                        targetIdx++
                    }
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        outputDone = true
                    }
                    decoder.releaseOutputBuffer(outIdx, false)
                }
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> { /* keep going */ }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val fmt = decoder.outputFormat
                    videoWidth = fmt.getInteger(MediaFormat.KEY_WIDTH)
                    videoHeight = fmt.getInteger(MediaFormat.KEY_HEIGHT)
                }
            }
        }
        Log.i(tag, "decoded $delivered/${timestampsUs.size} frames")
        return delivered
    }

    /** Renders the decoder's current output buffer to an ARGB Bitmap. */
    private fun renderToBitmap(decoder: MediaCodec, bufferIndex: Int): Bitmap? {
        // Method 1: Use Image API (API 21+)
        val image = try {
            decoder.getOutputImage(bufferIndex)
        } catch (error: IllegalStateException) {
            Log.w(tag, "decoder output image unavailable", error)
            null
        } ?: return null
        val width = image.width
        val height = image.height
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)

        // YUV_420_888 → ARGB conversion
        val yBuffer = image.planes[0].buffer
        val uBuffer = image.planes[1].buffer
        val vBuffer = image.planes[2].buffer
        val yStride = image.planes[0].rowStride
        val yPixStride = image.planes[0].pixelStride
        val uStride = image.planes[1].rowStride
        val vStride = image.planes[2].rowStride
        val uPixStride = image.planes[1].pixelStride
        val vPixStride = image.planes[2].pixelStride

        val pixels = IntArray(width * height)
        for (row in 0 until height) {
            for (col in 0 until width) {
                val yIndex = row * yStride + col * yPixStride
                val y = (yBuffer.get(yIndex).toInt() and 0xFF) - 16
                val uIndex = (row / 2) * uStride + (col / 2) * uPixStride
                val u = (uBuffer.get(uIndex).toInt() and 0xFF) - 128
                val vIndex = (row / 2) * vStride + (col / 2) * vPixStride
                val v = (vBuffer.get(vIndex).toInt() and 0xFF) - 128

                var r = (1.164 * y + 1.596 * v).toInt()
                var g = (1.164 * y - 0.391 * u - 0.813 * v).toInt()
                var b = (1.164 * y + 2.018 * u).toInt()
                r = r.coerceIn(0, 255); g = g.coerceIn(0, 255); b = b.coerceIn(0, 255)
                pixels[row * width + col] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
        image.close()
        return normalizeBitmap(bitmap)
    }

    private fun fallbackFrameAt(timestampUs: Long): Bitmap? = try {
        val retriever = fallbackRetriever ?: MediaMetadataRetriever().also {
            it.setDataSource(videoPath)
            fallbackRetriever = it
        }
        retriever.getScaledFrameAtTime(
            timestampUs,
            MediaMetadataRetriever.OPTION_CLOSEST,
            960,
            960,
        )?.let(::normalizeBitmap)
    } catch (error: RuntimeException) {
        Log.e(tag, "fallback frame decode failed at $timestampUs", error)
        null
    }

    private fun normalizeBitmap(bitmap: Bitmap): Bitmap {
        val rotated = if (rotationDegrees == 0) {
            bitmap
        } else {
            Bitmap.createBitmap(
                bitmap,
                0,
                0,
                bitmap.width,
                bitmap.height,
                Matrix().apply { postRotate(rotationDegrees.toFloat()) },
                true,
            ).also { bitmap.recycle() }
        }
        val longest = maxOf(rotated.width, rotated.height)
        if (longest <= 960) return rotated
        val scale = 960.0 / longest
        return Bitmap.createScaledBitmap(
            rotated,
            (rotated.width * scale).toInt().coerceAtLeast(1),
            (rotated.height * scale).toInt().coerceAtLeast(1),
            true,
        ).also { rotated.recycle() }
    }

    fun release() {
        codec?.stop()
        codec?.release()
        codec = null
        extractor?.release()
        extractor = null
        fallbackRetriever?.release()
        fallbackRetriever = null
    }
}
