package com.bhe.bhe_mobile

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.Image
import android.graphics.Bitmap
import android.graphics.ImageFormat
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
class FramePipeline(
    private val videoPath: String,
    private val fallbackMaxDimension: Int? = null,
) {
    private val tag = "BHE-FramePipeline"
    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var trackIndex = -1
    private var videoWidth = 0
    private var videoHeight = 0
    private var rotationDegrees = 0
    val rotationDegreesValue: Int
        get() = rotationDegrees
    private var fallbackRetriever: MediaMetadataRetriever? = null
    private var outputImageUnavailableLogged = false
    private var fallbackCount = 0

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
        onFrame: (Bitmap, Long, Long) -> Unit,
    ): Int {
        val ext = extractor ?: error("call prepare() first")
        val decoder = codec ?: error("call prepare() first")
        val info = MediaCodec.BufferInfo()
        var delivered = 0
        var targetIdx = 0
        var inputDone = false
        var outputDone = false
        val matchToleranceUs = 0L
        while (!outputDone && targetIdx < timestampsUs.size) {
            if (shouldCancel()) throw InterruptedException("分析已取消")
            // Fill all currently available codec input slots before draining
            // output. Feeding only one sample per loop leaves MediaCodec
            // starved while JNI/ONNX is processing a selected frame.
            while (!inputDone) {
                val inIdx = decoder.dequeueInputBuffer(0)
                if (inIdx < 0) break
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

            // Drain output
            val outIdx = decoder.dequeueOutputBuffer(info, 10_000)
            when {
                outIdx >= 0 -> {
                    try {
                        val pts = info.presentationTimeUs
                        if (targetIdx < timestampsUs.size) {
                            val target = timestampsUs[targetIdx]
                            // Do not convert skipped decoder output frames. At
                            // 10fps sampling this keeps the expensive YUV→ARGB
                            // conversion and JNI/ONNX call close to the requested
                            // rate instead of paying it for every source frame.
                            if (pts + matchToleranceUs >= target) {
                                val bitmap = renderToBitmap(decoder, outIdx) ?: fallbackFrameAt(target, pts)
                                if (bitmap != null) {
                                    // Runtime timestamps are the canonical target
                                    // timestamps. Decoder PTS is diagnostic only.
                                    onFrame(bitmap, pts, target)
                                    delivered++
                                    targetIdx++
                                }
                            }
                        }
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            while (targetIdx < timestampsUs.size) {
                                val target = timestampsUs[targetIdx]
                                val bitmap = fallbackFrameAt(target, pts) ?: break
                                onFrame(bitmap, pts, target)
                                delivered++
                                targetIdx++
                                Log.w(tag, "recovered target at EOS targetUs=$target decoderPtsUs=$pts")
                            }
                            outputDone = true
                        }
                    } finally {
                        // A callback may throw or cancel. The output buffer must
                        // still be released, but only after the callback has
                        // closed any borrowed Image.
                        decoder.releaseOutputBuffer(outIdx, false)
                    }
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

    /**
     * Decodes target frames and exposes MediaCodec's YUV planes directly.
     * Bitmap conversion remains the fallback for devices that do not expose
     * Image output from this decoder.
     */
    fun decodeFramesYuv(
        timestampsUs: List<Long>,
        shouldCancel: () -> Boolean,
        onFrame: (Image?, Bitmap?, Long, Long) -> Unit,
    ): Int {
        val ext = extractor ?: error("call prepare() first")
        val decoder = codec ?: error("call prepare() first")
        val info = MediaCodec.BufferInfo()
        var delivered = 0
        var targetIdx = 0
        var inputDone = false
        var outputDone = false
        val matchToleranceUs = 0L
        var lastOutputPtsUs = Long.MIN_VALUE
        while (!outputDone && targetIdx < timestampsUs.size) {
            if (shouldCancel()) {
                decoder.flush()
                throw InterruptedException("分析已取消")
            }
            while (!inputDone) {
                val inIdx = decoder.dequeueInputBuffer(0)
                if (inIdx < 0) break
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
            val outIdx = decoder.dequeueOutputBuffer(info, 10_000)
            when {
                outIdx >= 0 -> {
                    try {
                        val pts = info.presentationTimeUs
                        lastOutputPtsUs = pts
                        if (targetIdx < timestampsUs.size) {
                            val target = timestampsUs[targetIdx]
                            if (pts + matchToleranceUs >= target) {
                                var image: Image? = null
                                try {
                                    image = try {
                                        decoder.getOutputImage(outIdx)?.takeIf { it.format == ImageFormat.YUV_420_888 }
                                    } catch (_: IllegalStateException) { null }
                                    if (image != null && image.planes.all { it.buffer.isDirect }) {
                                        // The JNI path borrows these direct plane buffers only
                                        // during the callback. The caller owns and closes Image.
                                        val borrowedImage = image
                                        image = null
                                        onFrame(borrowedImage, null, pts, target)
                                    } else {
                                        image?.close()
                                        image = null
                                        val bitmap = renderToBitmap(decoder, outIdx) ?: fallbackFrameAt(target, pts)
                                        if (bitmap != null) {
                                            onFrame(null, bitmap, pts, target)
                                        } else {
                                            targetIdx++
                                            continue
                                        }
                                    }
                                    delivered++
                                    targetIdx++
                                } finally {
                                    image?.close()
                                }
                            }
                        }
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            while (targetIdx < timestampsUs.size) {
                                val target = timestampsUs[targetIdx]
                                val bitmap = fallbackFrameAt(target, pts) ?: break
                                onFrame(null, bitmap, pts, target)
                                delivered++
                                targetIdx++
                                Log.w(tag, "recovered target at EOS targetUs=$target decoderPtsUs=$pts")
                            }
                            outputDone = true
                        }
                    } finally {
                        // releaseOutputBuffer is deliberately after the callback:
                        // Image plane memory is borrowed until the callback closes it.
                        decoder.releaseOutputBuffer(outIdx, false)
                    }
                }
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val fmt = decoder.outputFormat
                    videoWidth = fmt.getInteger(MediaFormat.KEY_WIDTH)
                    videoHeight = fmt.getInteger(MediaFormat.KEY_HEIGHT)
                }
            }
        }
        Log.i(tag, "decoded YUV $delivered/${timestampsUs.size} frames lastPtsUs=$lastOutputPtsUs")
        return delivered
    }

    /** Renders the decoder's current output buffer to an ARGB Bitmap. */
    private fun renderToBitmap(decoder: MediaCodec, bufferIndex: Int): Bitmap? {
        // Method 1: Use Image API (API 21+)
        val image = try {
            decoder.getOutputImage(bufferIndex)
        } catch (error: IllegalStateException) {
            if (!outputImageUnavailableLogged) {
                Log.w(tag, "decoder output image unavailable; using fallback decoder", error)
                outputImageUnavailableLogged = true
            }
            null
        } ?: return null
        val sourceWidth = image.width
        val sourceHeight = image.height
        val limit = fallbackMaxDimension?.takeIf { it > 0 }
        val scale = limit?.let {
            minOf(1.0, it.toDouble() / sourceWidth, it.toDouble() / sourceHeight)
        } ?: 1.0
        val width = (sourceWidth * scale).toInt().coerceAtLeast(2)
        val height = (sourceHeight * scale).toInt().coerceAtLeast(2)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)

        // YUV_420_888 → scaled ARGB conversion. The fallback must not first
        // materialize a full-resolution Bitmap for a coarse frame.
        try {
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
                val sourceRow = (row * sourceHeight / height).coerceAtMost(sourceHeight - 1)
                for (col in 0 until width) {
                    val sourceCol = (col * sourceWidth / width).coerceAtMost(sourceWidth - 1)
                    val yIndex = sourceRow * yStride + sourceCol * yPixStride
                    val y = (yBuffer.get(yIndex).toInt() and 0xFF) - 16
                    val uIndex = (sourceRow / 2) * uStride + (sourceCol / 2) * uPixStride
                    val u = (uBuffer.get(uIndex).toInt() and 0xFF) - 128
                    val vIndex = (sourceRow / 2) * vStride + (sourceCol / 2) * vPixStride
                    val v = (vBuffer.get(vIndex).toInt() and 0xFF) - 128

                    var r = (1.164 * y + 1.596 * v).toInt()
                    var g = (1.164 * y - 0.391 * u - 0.813 * v).toInt()
                    var b = (1.164 * y + 2.018 * u).toInt()
                    r = r.coerceIn(0, 255); g = g.coerceIn(0, 255); b = b.coerceIn(0, 255)
                    pixels[row * width + col] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
                }
            }
            bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
            return normalizeBitmap(bitmap)
        } finally {
            image.close()
        }
    }

    private fun fallbackFrameAt(timestampUs: Long, decodedPtsUs: Long): Bitmap? = try {
        val retriever = fallbackRetriever ?: MediaMetadataRetriever().also {
            it.setDataSource(videoPath)
            fallbackRetriever = it
        }
        val (width, height) = fallbackOutputSize()
        fallbackCount++
        Log.w(tag, "using retriever fallback #$fallbackCount at targetUs=$timestampUs decoderPtsUs=$decodedPtsUs output=${width}x$height")
        retriever.getScaledFrameAtTime(
            timestampUs,
            MediaMetadataRetriever.OPTION_CLOSEST,
            width,
            height,
        )?.let(::normalizeBitmap)
    } catch (error: RuntimeException) {
        Log.e(tag, "fallback frame decode failed at $timestampUs", error)
        null
    }

    private fun fallbackOutputSize(): Pair<Int, Int> {
        val limit = fallbackMaxDimension?.takeIf { it > 0 } ?: return videoWidth to videoHeight
        val scale = minOf(1.0, limit.toDouble() / videoWidth, limit.toDouble() / videoHeight)
        return (videoWidth * scale).toInt().coerceAtLeast(2) to
            (videoHeight * scale).toInt().coerceAtLeast(2)
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
        // AndroidBitmap_lockPixels requires a software bitmap with writable
        // pixels. Rotation and retriever fallbacks may return immutable or
        // hardware-backed bitmaps, so normalize those before the JNI call.
        if (rotated.isMutable && rotated.config != Bitmap.Config.HARDWARE) {
            return rotated
        }
        return rotated.copy(Bitmap.Config.ARGB_8888, true)?.also {
            rotated.recycle()
        } ?: throw IllegalStateException("无法创建可读写的视频帧")
    }

    fun release() {
        try {
            codec?.stop()
        } catch (_: IllegalStateException) {
        } finally {
            codec?.release()
            codec = null
            extractor?.release()
            extractor = null
            fallbackRetriever?.release()
            fallbackRetriever = null
        }
    }
}
