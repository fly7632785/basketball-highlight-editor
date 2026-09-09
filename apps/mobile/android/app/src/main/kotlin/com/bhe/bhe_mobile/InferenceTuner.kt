package com.bhe.bhe_mobile

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.Locale

object InferenceTuner {
    private const val TAG = "BHE-InferenceTuner"
    private const val PREFS = "bhe_inference_tuner"

    data class Selection(
        val provider: String,
        val batchSize: Int,
        val measuredFps: Double,
        val cached: Boolean,
    )

    private data class Profile(val provider: String, val batchSize: Int)
    private data class DetectionSignature(val countPerFrame: Int, val peakConfidence: Double)
    private data class Benchmark(val selection: Selection, val signature: DetectionSignature)

    fun select(
        context: Context,
        videoPath: String,
        modelPath: String,
        startMs: Long,
        request: JSONObject,
    ): Selection {
        val key = cacheKey(modelPath, request.optInt("modelSize", 640))
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val cachedProvider = prefs.getString("${key}_provider", null)
        val cachedBatch = prefs.getInt("${key}_batch", 0)
        val cachedFps = prefs.getFloat("${key}_fps", 0f).toDouble()
        if (cachedProvider != null && cachedBatch in 1..8) {
            return Selection(cachedProvider, cachedBatch, cachedFps, true)
        }

        val bitmap = sampleBitmap(videoPath, startMs) ?: return Selection("auto", 1, 0.0, false)
        val profiles = listOf(
            Profile("xnnpack", 1),
            Profile("xnnpack", 4),
            Profile("nnapi_fp32_no_cpu", 1),
            Profile("nnapi_fp32_no_cpu", 4),
            Profile("nnapi_fp16_no_cpu", 1),
        )
        try {
            val benchmarks = profiles.mapNotNull { profile ->
                benchmarkProfile(profile, bitmap, modelPath, request)
            }
            val baseline = benchmarks.firstOrNull { it.selection.provider == "xnnpack" && it.selection.batchSize == 1 }
            val results = benchmarks.filter { benchmark ->
                baseline == null || signaturesMatch(baseline.signature, benchmark.signature)
            }.map { it.selection }
            val best = results.maxByOrNull { it.measuredFps }
                ?: return Selection("auto", 1, 0.0, false)
            prefs.edit()
                .putString("${key}_provider", best.provider)
                .putInt("${key}_batch", best.batchSize)
                .putFloat("${key}_fps", best.measuredFps.toFloat())
                .apply()
            Log.i(
                TAG,
                "selected provider=${best.provider} batch=${best.batchSize} fps=${format(best.measuredFps)} " +
                    "profiles=${results.joinToString { "${it.provider}/b${it.batchSize}=${format(it.measuredFps)}" }}",
            )
            return best
        } finally {
            bitmap.recycle()
        }
    }

    private fun benchmarkProfile(
        profile: Profile,
        bitmap: Bitmap,
        modelPath: String,
        request: JSONObject,
    ): Benchmark? {
        val config = JSONObject()
            .put("model_path", modelPath)
            .put("hoop_roi", fullRoi())
            .put("analysis_roi", request.getJSONObject("hoopRoi"))
            .put("net_roi", fullRoi())
            .put("confidence_threshold", request.optDouble("confidenceThreshold", 0.1))
            .put("model_size", request.optInt("modelSize", 640))
            .put("crop_scale", request.optDouble("cropScale", 2.0))
            .put("input_max_dimension", 960)
            .put("detection_only", true)
            .put("intra_threads", 2)
            .put("execution_provider", profile.provider)
            .put("inference_batch_size", profile.batchSize)
        val session = NativeRuntime.createSession(config.toString())
        if (session == 0L) {
            Log.w(TAG, "profile unavailable provider=${profile.provider} batch=${profile.batchSize}")
            return null
        }
        return try {
            repeat(profile.batchSize) { index ->
                checkedPush(session, bitmap, index.toLong())
            }
            val started = System.nanoTime()
            var measuredResponse = JSONObject()
            repeat(profile.batchSize) { index ->
                measuredResponse = checkedPush(session, bitmap, (profile.batchSize + index).toLong())
            }
            val elapsed = System.nanoTime() - started
            val fps = profile.batchSize * 1_000_000_000.0 / elapsed.coerceAtLeast(1L)
            val info = NativeRuntime.sessionInfo(session)
            Log.i(
                TAG,
                "profile provider=${profile.provider} batch=${profile.batchSize} fps=${format(fps)} runtime=$info",
            )
            Benchmark(
                Selection(profile.provider, profile.batchSize, fps, false),
                detectionSignature(measuredResponse, profile.batchSize),
            )
        } catch (error: Exception) {
            Log.w(TAG, "profile failed provider=${profile.provider} batch=${profile.batchSize}", error)
            null
        } finally {
            NativeRuntime.freeSession(session)
        }
    }

    private fun checkedPush(session: Long, bitmap: Bitmap, timestamp: Long): JSONObject {
        val response = JSONObject(NativeRuntime.pushFrameBitmap(session, timestamp, bitmap))
        response.optString("error").takeIf { it.isNotEmpty() }?.let(::IllegalStateException)?.let { throw it }
        return response
    }

    private fun detectionSignature(response: JSONObject, batchSize: Int): DetectionSignature {
        val detections = response.optJSONArray("detections")
        var peak = 0.0
        for (index in 0 until (detections?.length() ?: 0)) {
            peak = maxOf(peak, detections?.optJSONObject(index)?.optDouble("confidence", 0.0) ?: 0.0)
        }
        return DetectionSignature((detections?.length() ?: 0) / batchSize.coerceAtLeast(1), peak)
    }

    private fun signaturesMatch(baseline: DetectionSignature, candidate: DetectionSignature): Boolean {
        val matches = baseline.countPerFrame == candidate.countPerFrame &&
            kotlin.math.abs(baseline.peakConfidence - candidate.peakConfidence) <= 0.03
        if (!matches) {
            Log.w(TAG, "profile rejected by detection parity baseline=$baseline candidate=$candidate")
        }
        return matches
    }

    private fun sampleBitmap(videoPath: String, startMs: Long): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(videoPath)
            val source = retriever.getFrameAtTime((startMs + 2_000L) * 1_000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return null
            val scale = minOf(1.0, 960.0 / source.width, 960.0 / source.height)
            val width = (source.width * scale).toInt().coerceAtLeast(2)
            val height = (source.height * scale).toInt().coerceAtLeast(2)
            val scaled = if (width == source.width && height == source.height) source
            else Bitmap.createScaledBitmap(source, width, height, true).also { source.recycle() }
            if (scaled.config == Bitmap.Config.ARGB_8888) scaled
            else scaled.copy(Bitmap.Config.ARGB_8888, false).also { scaled.recycle() }
        } finally {
            retriever.release()
        }
    }

    private fun cacheKey(modelPath: String, modelSize: Int): String {
        val file = File(modelPath)
        val raw = "${Build.MANUFACTURER}|${Build.MODEL}|${Build.SOC_MODEL}|$modelSize|${file.length()}|${file.lastModified()}"
        return MessageDigest.getInstance("SHA-256")
            .digest(raw.toByteArray())
            .take(12)
            .joinToString("") { "%02x".format(it) }
    }

    private fun fullRoi() = JSONObject()
        .put("left", 0.0).put("top", 0.0).put("right", 1.0).put("bottom", 1.0)

    private fun format(value: Double): String = String.format(Locale.US, "%.2f", value)
}
