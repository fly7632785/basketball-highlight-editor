package com.bhe.bhe_mobile

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.system.Os
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.Locale

object InferenceTuner {
    private const val TAG = "BHE-InferenceTuner"
    private const val PREFS = "bhe_inference_tuner"
    const val CPU_THREADS = 6
    // Precompiled for the Snapdragon 8 Elite Gen 5 NPU (HTP v81) with the
    // bundled QNN 2.42 libraries. Other chips fail to load it and use the CPU.
    private const val QNN_CONTEXT_ASSET = "models/bball_model_qnn_v81.onnx"
    private const val SIGNATURE_MIN_CONFIDENCE = 0.25

    data class Selection(
        val provider: String,
        val batchSize: Int,
        val measuredFps: Double,
        val cached: Boolean,
        val modelPath: String? = null,
        val threads: Int = CPU_THREADS,
    )

    private data class Profile(val provider: String, val batchSize: Int, val threads: Int, val modelPath: String)
    private data class DetectionSignature(val countPerFrame: Int, val peakConfidence: Double)
    private data class Benchmark(val selection: Selection, val signature: DetectionSignature)

    fun select(
        context: Context,
        videoPath: String,
        modelPath: String,
        startMs: Long,
        request: JSONObject,
    ): Selection {
        val modelSize = request.optInt("modelSize", 640)
        val key = cacheKey(modelPath, modelSize)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val cachedProvider = prefs.getString("${key}_provider", null)
        val cachedBatch = prefs.getInt("${key}_batch", 0)
        val cachedFps = prefs.getFloat("${key}_fps", 0f).toDouble()
        val qnnModel = if (modelSize == 640) qnnContextModel(context) else null
        if (cachedProvider == "cpu" && cachedBatch in 1..8) {
            return Selection(cachedProvider, cachedBatch, cachedFps, true)
        }
        if (cachedProvider == "qnn" && qnnModel != null) {
            return Selection(cachedProvider, 1, cachedFps, true, qnnModel, 1)
        }

        val bitmap = sampleBitmap(videoPath, startMs) ?: return Selection("cpu", 1, 0.0, false)
        val profiles = listOfNotNull(
            Profile("cpu", 1, CPU_THREADS, modelPath),
            qnnModel?.let { Profile("qnn", 1, 1, it) },
        )
        try {
            val benchmarks = profiles.mapNotNull { profile ->
                benchmarkProfile(profile, bitmap, request)
            }
            val baseline = benchmarks.firstOrNull { it.selection.provider == "cpu" }
            val results = benchmarks.filter { benchmark ->
                baseline == null || signaturesMatch(baseline.signature, benchmark.signature)
            }.map { it.selection }
            val best = results.maxByOrNull { it.measuredFps }
                ?: return Selection("cpu", 1, 0.0, false)
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

    fun forget(context: Context, modelPath: String, modelSize: Int) {
        val key = cacheKey(modelPath, modelSize)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove("${key}_provider")
            .remove("${key}_batch")
            .remove("${key}_fps")
            .apply()
    }

    private fun benchmarkProfile(
        profile: Profile,
        bitmap: Bitmap,
        request: JSONObject,
    ): Benchmark? {
        val config = JSONObject()
            .put("model_path", profile.modelPath)
            .put("hoop_roi", fullRoi())
            .put("analysis_roi", request.getJSONObject("hoopRoi"))
            .put("net_roi", fullRoi())
            .put("confidence_threshold", request.optDouble("confidenceThreshold", 0.1))
            .put("model_size", request.optInt("modelSize", 640))
            .put("crop_scale", request.optDouble("cropScale", 2.0))
            .put("input_max_dimension", 960)
            .put("detection_only", true)
            .put("intra_threads", profile.threads)
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
                Selection(
                    profile.provider,
                    profile.batchSize,
                    fps,
                    false,
                    profile.modelPath.takeIf { profile.provider == "qnn" },
                    profile.threads,
                ),
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
        var count = 0
        for (index in 0 until (detections?.length() ?: 0)) {
            val confidence = detections?.optJSONObject(index)?.optDouble("confidence", 0.0) ?: 0.0
            peak = maxOf(peak, confidence)
            // FP16 accelerators shift scores slightly, so boxes right at the
            // detection threshold may appear on one provider only.
            if (confidence >= SIGNATURE_MIN_CONFIDENCE) count++
        }
        return DetectionSignature(count / batchSize.coerceAtLeast(1), peak)
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
            VideoInput.open(retriever, videoPath)
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

    private fun qnnContextModel(context: Context): String? {
        val target = File(context.filesDir, QNN_CONTEXT_ASSET)
        return try {
            val size = context.assets.openFd(QNN_CONTEXT_ASSET).use { it.length }
            if (!target.isFile || target.length() != size) {
                target.parentFile?.mkdirs()
                val partial = File(target.path + ".partial")
                context.assets.open(QNN_CONTEXT_ASSET).use { input ->
                    partial.outputStream().use { input.copyTo(it) }
                }
                if (!partial.renameTo(target)) throw IllegalStateException("cannot store ${target.path}")
            }
            // FastRPC loads the NPU skeleton library from this search path.
            Os.setenv("ADSP_LIBRARY_PATH", context.applicationInfo.nativeLibraryDir, true)
            target.path
        } catch (error: Exception) {
            Log.i(TAG, "QNN context unavailable: ${error.message}")
            null
        }
    }

    private fun cacheKey(modelPath: String, modelSize: Int): String {
        val file = File(modelPath)
        val raw = "cpu-qnn-v2|${Build.MANUFACTURER}|${Build.MODEL}|${Build.SOC_MODEL}|$modelSize|${file.length()}|${file.lastModified()}"
        return MessageDigest.getInstance("SHA-256")
            .digest(raw.toByteArray())
            .take(12)
            .joinToString("") { "%02x".format(it) }
    }

    private fun fullRoi() = JSONObject()
        .put("left", 0.0).put("top", 0.0).put("right", 1.0).put("bottom", 1.0)

    private fun format(value: Double): String = String.format(Locale.US, "%.2f", value)
}
