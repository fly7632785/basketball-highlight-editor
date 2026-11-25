package com.bhe.bhe_mobile

import android.content.Context
import androidx.media3.common.util.UnstableApi
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

@UnstableApi
internal class PortraitBallSampler(private val context: Context) {
    fun sample(
        range: PortraitMediaRange,
        cancelled: AtomicBoolean,
        onProgress: (Int, Int) -> Unit,
    ): Map<String, Any> {
        val source = PortraitSource.read(range.path)
        requirePortraitSourceAspect(source.width, source.height)
        val timestamps = portraitSampleTimes(range.startMs, range.endMs)
        val onnxPath = File(context.applicationInfo.nativeLibraryDir, "libonnxruntime.so").absolutePath
        check(NativeRuntime.ensureOnnxLoaded(onnxPath) && NativeRuntime.initializeOnnx(onnxPath)) {
            "ONNX Runtime initialization failed: ${NativeRuntime.loadError.orEmpty()}"
        }
        val roi = JSONObject().put("left", 0.0).put("top", 0.0).put("right", 1.0).put("bottom", 1.0)
        val config = JSONObject()
            .put("model_path", modelPath(cancelled))
            .put("hoop_roi", roi).put("analysis_roi", roi).put("net_roi", roi)
            .put("duration_ms", source.durationMs)
            .put("confidence_threshold", .15)
            .put("model_size", 640)
            .put("crop_scale", 1.0)
            .put("intra_threads", 2)
            .put("inference_batch_size", 1)
            .put("detection_only", true)
        val session = NativeRuntime.createSession(config.toString())
        check(session != 0L) { NativeRuntime.sessionCreateError() }
        var sdr: File? = null
        try {
            // The runtime expects SDR pixels. Only the requested HDR clip is
            // converted, at detector size, with no audio.
            val decodeRange = if (source.isHdr) {
                sdr = File.createTempFile("bhe-portrait-sdr-", ".mp4", context.cacheDir)
                PortraitMedia(context).prepareSdrSample(range, source, sdr, cancelled) {
                    onProgress(it, 200)
                }
                PortraitMediaRange(sdr.absolutePath, 0, range.endMs - range.startMs)
            } else range
            val offsetMs = range.startMs - decodeRange.startMs
            val pipeline = FramePipeline(decodeRange.path, strictFrames = true)
            val samples = ArrayList<Map<String, Any>>(timestamps.size)
            var progressBucket = -1
            val decodeTimes = timestamps.map { (it - offsetMs) * 1000 }
            try {
                requirePortraitActive(cancelled)
                pipeline.prepare(decodeTimes.first())
                val result = pipeline.decodeFramesYuv(
                    decodeTimes, cancelled::get, useActualFrameBuckets = true,
                ) { image, bitmap, ptsUs, targetUs ->
                    try {
                        requirePortraitActive(cancelled)
                        val timeMs = (ptsUs + 500) / 1000 + offsetMs
                        if (timeMs !in range.startMs until range.endMs) return@decodeFramesYuv
                        val frameWidth = image?.width ?: requireNotNull(bitmap).width
                        val frameHeight = image?.height ?: requireNotNull(bitmap).height
                        val rotation = if (image != null) pipeline.rotationDegreesValue else 0
                        val coords = RimCheckFrameCoordinates(
                            frameWidth, frameHeight, rotation, source.width.toDouble(), source.height.toDouble(),
                        )
                        val response = if (image != null) {
                            val (y, u, v) = image.planes
                            NativeRuntime.pushFrameYuv(
                                session, timeMs, frameWidth, frameHeight,
                                y.buffer, y.buffer.position(), y.buffer.remaining(), y.rowStride, y.pixelStride,
                                u.buffer, u.buffer.position(), u.buffer.remaining(), u.rowStride, u.pixelStride,
                                v.buffer, v.buffer.position(), v.buffer.remaining(), v.rowStride, v.pixelStride,
                                rotation,
                            )
                        } else NativeRuntime.pushFrameBitmap(session, timeMs, requireNotNull(bitmap))
                        val parsed = JSONObject(response)
                        parsed.optString("error").takeIf { it.isNotEmpty() }?.let { error(it) }
                        val found = parsed.getJSONArray("detections")
                        val balls = mutableListOf<Map<String, Double>>()
                        val rims = mutableListOf<Map<String, Double>>()
                        for (index in 0 until found.length()) {
                            val box = found.getJSONObject(index)
                            when (box.getInt("class_id")) {
                                0 -> balls.add(portraitDetection(box, coords))
                                1 -> rims.add(portraitDetection(box, coords))
                            }
                        }
                        samples.add(mapOf("tMs" to timeMs, "balls" to balls, "rims" to rims))
                        val percentage = ((targetUs - decodeTimes.first()) / (1_000_000 / PORTRAIT_SAMPLE_HZ) + 1)
                            .toInt() * 100 / timestamps.size
                        if (percentage / 10 > progressBucket) {
                            progressBucket = percentage / 10
                            val processed = if (source.isHdr) 100 + percentage else percentage
                            onProgress(processed, if (source.isHdr) 200 else 100)
                        }
                    } finally {
                        image?.close()
                        bitmap?.recycle()
                    }
                }
                requirePortraitActive(cancelled)
                if (samples.isEmpty() || result.missingBeforeEos) {
                    throw VideoDecodeException("The video reader could not decode the portrait samples.")
                }
                return mapOf("frameWidth" to source.width, "frameHeight" to source.height, "samples" to samples)
            } finally {
                pipeline.release()
            }
        } finally {
            NativeRuntime.freeSession(session)
            sdr?.delete()
        }
    }

    private fun modelPath(cancelled: AtomicBoolean): String {
        // Same asset and application support path as Dart analysis.
        val model = File(context.filesDir, "models/bball_model.onnx")
        context.assets.openFd("flutter_assets/assets/models/bball_model.onnx").use { asset ->
            if (model.isFile && model.length() == asset.length) return model.absolutePath
            val parent = checkNotNull(model.parentFile)
            check(parent.isDirectory || parent.mkdirs()) { "Cannot create model directory" }
            val temporary = File.createTempFile(".portrait-model-", ".onnx", parent)
            try {
                asset.createInputStream().use { input ->
                    temporary.outputStream().use { output ->
                        val buffer = ByteArray(1024 * 1024)
                        while (true) {
                            requirePortraitActive(cancelled)
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                        }
                    }
                }
                check(temporary.length() == asset.length) { "Incomplete detector model asset" }
                android.system.Os.rename(temporary.absolutePath, model.absolutePath)
            } finally {
                if (temporary.exists()) temporary.delete()
            }
        }
        return model.absolutePath
    }
}
