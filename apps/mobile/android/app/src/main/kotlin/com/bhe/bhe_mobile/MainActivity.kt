package com.bhe.bhe_mobile

import com.bhe.bhe_mobile.diagnostics.AppDiagnostics
import com.bhe.bhe_mobile.diagnostics.NativeFailureDetails
import android.content.ContentValues
import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import android.provider.MediaStore
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private data class HoopObservation(
        val bbox: FloatArray,
        val confidence: Float,
        val timeMs: Long,
    )

    // Zoomed check of each hoop cluster, the same as desktop
    // detect_auto_roi.py: a square of this many box sizes around the cluster
    // at native resolution, re-detected at the model input size.
    private val verifyCropBoxSizes = 5f
    private val verifyMinCropPx = 96f
    private val verifyFrames = 2

    private data class StableHoop(
        val bbox: FloatArray,
        val confidence: Float,
        val previewTimeMs: Long,
        val samples: Int,
        val stability: Double,
    )

    private val videoImportPicker by lazy { VideoImportPicker(this) }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!videoImportPicker.onResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    private val tag = "BHE-Analysis"
    private val mediaChannelName = "com.bhe.bhe/mobile_media"
    private val analysisChannelName = "com.bhe.bhe/mobile_analysis"
    private val progressChannelName = "com.bhe.bhe/mobile_analysis_progress"
    private val updateChannelName = "com.bhe.bhe/mobile_update"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val exportCancelled = ConcurrentHashMap<String, AtomicBoolean>()
    private val mergeTransactions = ConcurrentHashMap<String, MergeOutputTransaction>()
    private var progressSink: EventChannel.EventSink? = null
    private var analysisTaskListener: AnalysisTaskManager.Listener? = null

    override fun onDestroy() {
        setAnalysisScreenOn(false)
        analysisTaskListener?.let(AnalysisTaskManager::detach)
        analysisTaskListener = null
        exportCancelled.forEach { (id, flag) -> flag.set(true); ExportPathRegistry.releaseIdle(id) }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        com.bhe.bhe_mobile.diagnostics.DiagnosticsChannel.register(flutterEngine, applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(true)
                    "pickVideo" -> videoImportPicker.pick(result)
                    "pickProject" -> videoImportPicker.pick(result, project = true)
                    "pruneVideoGrants" -> {
                        val referenced = call.argument<List<String>>("referenced").orEmpty().toSet()
                        videoImportPicker.pruneGrants(referenced)
                        result.success(null)
                    }
                    "videoMetadata" -> videoMetadata(call, result)
                    "exportClip" -> exportClip(call, result)
                    "mergeClips" -> mergeClips(call, result)
                    "registerMergeExport" -> registerMergeExport(call, result)
                    "releaseMergeExport" -> releaseMergeExport(call, result)
                    "cancelExport" -> cancelExport(call, result)
                    "isExportActive" -> result.success(call.argument<String>("exportId")?.let(ExportPathRegistry::contains))
                    "saveToLibrary" -> saveToLibrary(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, analysisChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "analyzeVideo" -> analyzeVideo(call, result)
                    "suggestRoi" -> suggestRoi(call, result)
                    "extractCover" -> extractCover(call, result)
                    "getAnalysisState" -> getAnalysisState(result)
                    "isAnalysisActive" -> result.success(AnalysisTaskManager.isRunning())
                    "cancelAnalysis" -> {
                        AnalysisTaskManager.cancel()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> installApk(call, result)
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, progressChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    progressSink = events
                }

                override fun onCancel(arguments: Any?) {
                    progressSink = null
                }
        })
    }

    /// 交给系统安装器；没有「安装未知应用」权限时先打开设置页让用户允许。
    private fun installApk(call: MethodCall, result: MethodChannel.Result) {
        try {
            AppDiagnostics.event("update.install")
            val path = call.argument<String>("path")
            if (path.isNullOrEmpty() || !File(path).isFile) {
                result.error("UPDATE_FILE_MISSING", "安装包不存在", null)
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                )
                result.success("permission_required")
                return
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.update_provider", File(path))
            startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, "application/vnd.android.package-archive")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            result.success("started")
        } catch (error: Exception) {
            AppDiagnostics.event("update.install.failed", error = error)
            result.error("UPDATE_INSTALL_FAILED", error.message, NativeFailureDetails.from(error))
        }
    }

    private fun getAnalysisState(result: MethodChannel.Result) {
        val listener = object : AnalysisTaskManager.Listener {
            override fun onProgress(event: Map<String, Any?>) = emitProgress(event)

            override fun onComplete(result: Map<String, Any?>) {
                emitAnalysisCompletion(result)
                setAnalysisScreenOn(false)
                analysisTaskListener = null
            }

            override fun onError(code: String, message: String) {
                emitAnalysisError(code, message)
                setAnalysisScreenOn(false)
                analysisTaskListener = null
            }
        }
        analysisTaskListener?.let(AnalysisTaskManager::detach)
        analysisTaskListener = listener
        val snapshot = AnalysisTaskManager.attach(listener, applicationContext)
        if (snapshot["status"] == "running" && !AnalysisTaskManager.hasWorkerThread()) {
            val intent = Intent(applicationContext, AnalysisForegroundService::class.java).apply {
                action = AnalysisForegroundService.ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        }
        setAnalysisScreenOn(snapshot["status"] == "running")
        result.success(snapshot)
    }

    private fun setAnalysisScreenOn(enabled: Boolean) {
        runOnUiThread {
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    private fun suggestRoi(call: MethodCall, result: MethodChannel.Result) {
        if (!NativeRuntime.ensureLoaded(applicationInfo.nativeLibraryDir)) {
            result.error("NATIVE_RUNTIME_UNAVAILABLE", NativeRuntime.loadError, null)
            return
        }
        val videoPath = call.argument<String>("videoPath")
        val modelPath = call.argument<String>("modelPath")
        val modelSize = ((call.argument<Int>("modelSize") ?: 640) / 32 * 32).coerceAtLeast(320)
        val startMs = call.argument<Int>("startMs") ?: 0
        val durationMs = call.argument<Int>("durationMs") ?: 0
        val sampleFps = (call.argument<Double>("sampleFps") ?: 1.0).coerceIn(0.5, 2.0)
        val maxSamples = (call.argument<Int>("maxSamples") ?: 12).coerceIn(2, 12)
        if (videoPath == null || modelPath == null) {
            result.error("INVALID_ARGUMENT", "自动识别参数无效", null)
            return
        }
        Thread {
            var session = 0L
            var pipeline: FramePipeline? = null
            val retriever = MediaMetadataRetriever()
            try {
                VideoInput.open(retriever, videoPath)
                val duration = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: durationMs.toLong()
                val safeStartMs = startMs.toLong().coerceIn(0L, duration)
                val scanDurationMs = if (durationMs > 0) {
                    durationMs.toLong().coerceAtMost(20_000L)
                } else {
                    20_000L.coerceAtMost((duration - safeStartMs).coerceAtLeast(0L))
                }
                val requestedEndMs = (safeStartMs + scanDurationMs).coerceAtMost(duration)
                val timestamps = generateSequence(0) { it + 1 }
                    .map { index ->
                        safeStartMs + kotlin.math.floor(index * 1000.0 / sampleFps + 0.5).toLong()
                    }
                    .take(maxSamples)
                    .takeWhile { it < requestedEndMs }
                    .toList()
                if (timestamps.isEmpty()) throw IllegalStateException("视频没有可采样帧")
                val config = JSONObject()
                    .put("model_path", modelPath)
                    .put("hoop_roi", fullRoi())
                    .put("analysis_roi", fullRoi())
                    .put("net_roi", fullRoi())
                    .put("duration_ms", duration)
                    .put("confidence_threshold", 0.05)
                    .put("model_size", modelSize - modelSize % 32)
                    // Auto ROI scans the full frame, matching Python
                    // detect_auto_roi.py. The 4x crop scale belongs only to
                    // the later ball-analysis path.
                    .put("crop_scale", 1.0)
                val onnxPath = File(applicationInfo.nativeLibraryDir, "libonnxruntime.so").absolutePath
                if (!NativeRuntime.ensureOnnxLoaded(onnxPath) || !NativeRuntime.initializeOnnx(onnxPath)) {
                    throw IllegalStateException("ONNX Runtime 初始化失败：${NativeRuntime.loadError ?: "Android 原生推理库无法加载"}")
                }
                session = NativeRuntime.createSession(config.toString())
                if (session == 0L) throw IllegalStateException("无法创建自动识别会话")
                val observations = mutableListOf<HoopObservation>()
                val verifyBitmaps = mutableListOf<Bitmap>()
                var decodedWidth = 0f
                var decodedHeight = 0f
                val decoderPipeline = FramePipeline(videoPath).also {
                    it.prepare(timestamps.first() * 1000L)
                }
                pipeline = decoderPipeline
                decoderPipeline.decodeFrames(timestamps.map { it * 1000L }, { false }) { bitmap, _, targetTimestampUs ->
                    try {
                        // Detection coordinates are expressed in the decoded
                        // (rotation-normalized, max-960) bitmap coordinate
                        // space. Do not normalize them with the source
                        // metadata dimensions, or the returned ROI is scaled
                        // incorrectly on high-resolution videos.
                        decodedWidth = bitmap.width.toFloat()
                        decodedHeight = bitmap.height.toFloat()
                        val response = JSONObject(
                            NativeRuntime.pushFrameBitmap(
                                session,
                                targetTimestampUs / 1000L,
                                bitmap,
                            ),
                        )
                        val detections = response.optJSONArray("detections") ?: return@decodeFrames
                        for (index in 0 until detections.length()) {
                            val detection = detections.optJSONObject(index) ?: continue
                            if (detection.optInt("class_id", -1) != 1) continue
                            observations += HoopObservation(
                                bbox = floatArrayOf(
                                    detection.optDouble("x1").toFloat(),
                                    detection.optDouble("y1").toFloat(),
                                    detection.optDouble("x2").toFloat(),
                                    detection.optDouble("y2").toFloat(),
                                ),
                                confidence = detection.optDouble("confidence").toFloat(),
                                timeMs = targetTimestampUs / 1000L,
                            )
                        }
                    } finally {
                        if (verifyBitmaps.size < verifyFrames) verifyBitmaps += bitmap else bitmap.recycle()
                    }
                }
                val stable = try {
                    selectStableHoop(observations, decodedWidth, decodedHeight) { bbox ->
                        zoomVerify(session, verifyBitmaps, bbox, timestamps.last())
                    }
                } finally {
                    verifyBitmaps.forEach(Bitmap::recycle)
                } ?: throw IllegalStateException("未识别到稳定的篮筐")
                val bbox = stable.bbox
                val width = decodedWidth.coerceAtLeast(1f)
                val height = decodedHeight.coerceAtLeast(1f)
                val roi = expandedRoi(bbox, width, height)
                val rimRoi = physicalRimRoi(bbox, width, height)
                mainHandler.post {
                    result.success(
                        mapOf(
                            "success" to true,
                            "roi" to roi,
                            "rim_roi" to rimRoi,
                            "hoop_bbox" to bbox.toList(),
                            "samples" to stable.samples,
                            "stability" to stable.stability,
                            "preview_time_ms" to stable.previewTimeMs,
                            "model_input_size" to modelSize,
                            "source" to "android_onnx_hoop_model",
                        ),
                    )
                }
            } catch (error: Exception) {
                AppDiagnostics.event("roi.failed", error = error)
                Log.w(tag, "automatic ROI suggestion failed", error)
                mainHandler.post { result.error("AUTO_ROI_FAILED", error.message ?: "自动识别篮筐失败", null) }
            } finally {
                if (session != 0L) NativeRuntime.freeSession(session)
                pipeline?.release()
                retriever.release()
            }
        }.start()
    }

    private fun fullRoi() = JSONObject()
        .put("left", 0.0)
        .put("top", 0.0)
        .put("right", 1.0)
        .put("bottom", 1.0)

    private fun median(values: List<Float>): Float {
        val sorted = values.sorted()
        return if (sorted.size % 2 == 0) {
            (sorted[sorted.size / 2 - 1] + sorted[sorted.size / 2]) / 2f
        } else sorted[sorted.size / 2]
    }

    private fun selectStableHoop(
        observations: List<HoopObservation>,
        frameWidth: Float,
        frameHeight: Float,
        verify: (FloatArray) -> Float,
    ): StableHoop? {
        if (observations.size < 2 || frameWidth <= 0f || frameHeight <= 0f) return null
        val clusters = mutableListOf<MutableList<HoopObservation>>()
        for (observation in observations) {
            // A far hoop is only a few pixels wide; a fixed share of the
            // frame merges it with nearby lookalikes such as windows.
            val radius = max(16f, 2f * max(observation.bbox[2] - observation.bbox[0], observation.bbox[3] - observation.bbox[1]))
            val centerX = (observation.bbox[0] + observation.bbox[2]) / 2f
            val centerY = (observation.bbox[1] + observation.bbox[3]) / 2f
            var best: MutableList<HoopObservation>? = null
            var bestDistance = Float.MAX_VALUE
            for (cluster in clusters) {
                val clusterX = median(cluster.map { (it.bbox[0] + it.bbox[2]) / 2f })
                val clusterY = median(cluster.map { (it.bbox[1] + it.bbox[3]) / 2f })
                val distance = kotlin.math.hypot(centerX - clusterX, centerY - clusterY)
                if (distance <= radius && distance < bestDistance) {
                    best = cluster
                    bestDistance = distance
                }
            }
            (best ?: mutableListOf<HoopObservation>().also(clusters::add)).add(observation)
        }
        val stableClusters = clusters.filter { it.size >= 2 }
        if (stableClusters.isEmpty()) return null
        fun clusterBox(cluster: List<HoopObservation>) =
            FloatArray(4) { index -> median(cluster.map { it.bbox[index] }) }
        val selected = stableClusters.map { it to verify(clusterBox(it)) }.maxWithOrNull(
            compareBy<Pair<MutableList<HoopObservation>, Float>> { it.second }
                .thenBy { it.first.size }
                .thenBy { median(it.first.map(HoopObservation::confidence)) }
                .thenBy { median(it.first.map { item -> (item.bbox[2] - item.bbox[0]) * (item.bbox[3] - item.bbox[1]) }) },
        )?.first ?: return null
        val bbox = clusterBox(selected)
        val bestConfidence = selected.maxBy { it.confidence }
        return StableHoop(
            bbox = bbox,
            confidence = median(selected.map(HoopObservation::confidence)),
            previewTimeMs = bestConfidence.timeMs,
            samples = selected.size,
            stability = min(1.0, selected.size.toDouble() / observations.size.toDouble()),
        )
    }

    /** Best hoop confidence centred inside [bbox] on a zoomed crop. */
    private fun zoomVerify(session: Long, frames: List<Bitmap>, bbox: FloatArray, lastTimeMs: Long): Float {
        val centerX = (bbox[0] + bbox[2]) / 2f
        val centerY = (bbox[1] + bbox[3]) / 2f
        var best = 0f
        frames.forEachIndexed { index, frame ->
            val side = min(
                max(verifyMinCropPx, verifyCropBoxSizes * max(bbox[2] - bbox[0], bbox[3] - bbox[1])),
                min(frame.width, frame.height).toFloat(),
            ).toInt()
            val left = (centerX - side / 2f).coerceIn(0f, (frame.width - side).toFloat()).toInt()
            val top = (centerY - side / 2f).coerceIn(0f, (frame.height - side).toFloat()).toInt()
            val crop = Bitmap.createBitmap(frame, left, top, side, side)
            val response = try {
                JSONObject(NativeRuntime.pushFrameBitmap(session, lastTimeMs + 1_000L * (index + 1), crop))
            } finally {
                if (crop !== frame) crop.recycle()
            }
            val detections = response.optJSONArray("detections") ?: return@forEachIndexed
            for (item in 0 until detections.length()) {
                val detection = detections.optJSONObject(item) ?: continue
                if (detection.optInt("class_id", -1) != 1) continue
                val x = (detection.optDouble("x1") + detection.optDouble("x2")).toFloat() / 2f
                val y = (detection.optDouble("y1") + detection.optDouble("y2")).toFloat() / 2f
                // A neighbouring hoop inside the crop must not confirm this cluster.
                if (x in (bbox[0] - left)..(bbox[2] - left) && y in (bbox[1] - top)..(bbox[3] - top)) {
                    best = max(best, detection.optDouble("confidence").toFloat())
                }
            }
        }
        return best
    }

    private fun expandedRoi(bbox: FloatArray, frameWidth: Float, frameHeight: Float): Map<String, Double> {
        val boxWidth = max(4f, bbox[2] - bbox[0])
        val boxHeight = max(4f, bbox[3] - bbox[1])
        val centerX = (bbox[0] + bbox[2]) / 2f
        val centerY = (bbox[1] + bbox[3]) / 2f
        val roiWidth = min(max(boxWidth * 15f, frameWidth * .18f), frameWidth * .65f)
        val roiHeight = min(max(boxHeight * 20f, frameHeight * .28f), frameHeight * .75f)
        var topExtent = max(boxHeight * 8f, roiHeight * .44f)
        var bottomExtent = max(boxHeight * 12f, roiHeight * .56f)
        val totalHeight = topExtent + bottomExtent
        if (totalHeight > frameHeight * .75f) {
            val scale = frameHeight * .75f / totalHeight
            topExtent *= scale
            bottomExtent *= scale
        }
        return mapOf(
            "left" to ((centerX - roiWidth / 2f) / frameWidth).coerceIn(0f, 1f).toDouble(),
            "top" to ((centerY - topExtent) / frameHeight).coerceIn(0f, 1f).toDouble(),
            "right" to ((centerX + roiWidth / 2f) / frameWidth).coerceIn(0f, 1f).toDouble(),
            "bottom" to ((centerY + bottomExtent) / frameHeight).coerceIn(0f, 1f).toDouble(),
        )
    }

    private fun physicalRimRoi(bbox: FloatArray, frameWidth: Float, frameHeight: Float): Map<String, Double> {
        val boxWidth = max(1f, bbox[2] - bbox[0])
        val boxHeight = max(1f, bbox[3] - bbox[1])
        val centerX = (bbox[0] + bbox[2]) / 2f
        val centerY = (bbox[1] + bbox[3]) / 2f
        val rimY = centerY - boxHeight * .28f
        // Match Python refine's `scale_rim`: the plane is shifted by 28% and
        // the corrected rim ROI keeps 45% of the detector-box height.
        val rimHeight = boxHeight * .45f
        return mapOf(
            "left" to ((centerX - boxWidth / 2f) / frameWidth).coerceIn(0f, 1f).toDouble(),
            "top" to ((rimY - rimHeight / 2f) / frameHeight).coerceIn(0f, 1f).toDouble(),
            "right" to ((centerX + boxWidth / 2f) / frameWidth).coerceIn(0f, 1f).toDouble(),
            "bottom" to ((rimY + rimHeight / 2f) / frameHeight).coerceIn(0f, 1f).toDouble(),
        )
    }

    private fun extractCover(call: MethodCall, result: MethodChannel.Result) {
        val videoPath = call.argument<String>("videoPath")
        val timeMs = call.argument<Number>("timeMs")?.toLong()
        val outputPath = call.argument<String>("outputPath")
        if (videoPath == null || timeMs == null || outputPath == null) {
            result.error("INVALID_ARGUMENT", "封面参数无效", null)
            return
        }
        Thread {
            val retriever = MediaMetadataRetriever()
            val saved = try {
                VideoInput.open(retriever, videoPath)
                val source = retriever.getFrameAtTime(timeMs * 1000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                if (source == null) {
                    false
                } else {
                    val scale = min(1f, 480f / max(source.width, source.height))
                    val frame = Bitmap.createScaledBitmap(
                        source,
                        max(1, (source.width * scale).toInt()),
                        max(1, (source.height * scale).toInt()),
                        true,
                    )
                    val partial = File("$outputPath.partial")
                    partial.outputStream().use { frame.compress(Bitmap.CompressFormat.JPEG, 82, it) }
                    if (frame !== source) frame.recycle()
                    source.recycle()
                    partial.renameTo(File(outputPath))
                }
            } catch (error: Exception) {
                AppDiagnostics.event("cover.failed", error = error)
                Log.w("BHE-Cover", "cover extraction failed", error)
                false
            } finally {
                retriever.release()
            }
            mainHandler.post { result.success(saved) }
        }.start()
    }

    private fun analyzeVideo(call: MethodCall, result: MethodChannel.Result) {
        if (AnalysisTaskManager.isRunning()) {
            result.error("ANALYSIS_BUSY", "已有分析任务正在运行", null)
            return
        }
        val videoPath = call.argument<String>("videoPath")
        val modelPath = call.argument<String>("modelPath")
        val hoopRoi = call.argument<Map<String, Any>>("hoopRoi")
        val rimRoi = call.argument<Map<String, Any>>("rimRoi")
        val netRoi = call.argument<Map<String, Any>>("netRoi")
        val startMs = call.argument<Int>("startMs") ?: 0
        val endMs = call.argument<Int>("endMs") ?: 0
        if (videoPath == null || modelPath == null || hoopRoi == null || netRoi == null || endMs <= startMs) {
            result.error("INVALID_ARGUMENT", "分析参数无效", null)
            return
        }
        val request = JSONObject()
            .put("videoPath", videoPath)
            .put("modelPath", modelPath)
            .put("hoopRoi", JSONObject(hoopRoi))
            .put("netRoi", JSONObject(netRoi))
            .put("startMs", startMs)
            .put("endMs", endMs)
            .put("beforeMs", call.argument<Int>("beforeMs") ?: 6000)
            .put("afterMs", call.argument<Int>("afterMs") ?: 3000)
            .put("fps", (call.argument<Double>("fps") ?: 3.0).coerceIn(1.0, 10.0))
            .put("confidenceThreshold", (call.argument<Double>("confidenceThreshold") ?: 0.10).coerceIn(0.0, 1.0))
            .put("modelSize", ((call.argument<Int>("modelSize") ?: 640) / 32 * 32).coerceAtLeast(320))
            .put("cropScale", (call.argument<Double>("cropScale") ?: 2.0).coerceIn(1.0, 8.0))
            .put("maxCrossGapMs", (call.argument<Int>("maxCrossGapMs") ?: 1800).coerceAtLeast(1))
            .put("dedupeMs", (call.argument<Int>("dedupeMs") ?: 2000).coerceAtLeast(0))
            .put("executionProvider", call.argument<String>("executionProvider") ?: "auto")
            .put("inferenceBatchSize", (call.argument<Int>("inferenceBatchSize") ?: 4).coerceIn(1, 8))
            .put("optimizedModelPath", call.argument<String>("optimizedModelPath") ?: "")
        if (rimRoi != null) request.put("rimRoi", JSONObject(rimRoi))
        val listener = object : AnalysisTaskManager.Listener {
            override fun onProgress(event: Map<String, Any?>) = emitProgress(
                event["stage"] as? String ?: "refineCandidates",
                (event["progress"] as? Number)?.toDouble() ?: 0.0,
                (event["processedFrames"] as? Number)?.toInt() ?: 0,
                (event["totalFrames"] as? Number)?.toInt() ?: 0,
                event["message"] as? String ?: "正在分析视频",
            )

            override fun onComplete(result: Map<String, Any?>) {
                setAnalysisScreenOn(false)
                analysisTaskListener = null
            }

            override fun onError(code: String, message: String) {
                setAnalysisScreenOn(false)
                analysisTaskListener = null
            }
        }
        analysisTaskListener = listener
        setAnalysisScreenOn(true)
        AnalysisTaskManager.attach(listener, applicationContext)
        AnalysisTaskManager.prepare(applicationContext, request.toString(), object : AnalysisTaskManager.MethodResult {
            override fun success(value: Map<String, Any?>) {
                mainHandler.post { result.success(value) }
            }
            override fun error(code: String, message: String) {
                mainHandler.post { result.error(code, message, null) }
            }
        })
        startAnalysisForegroundService()
    }

    private fun startAnalysisForegroundService() {
        val intent = Intent(this, AnalysisForegroundService::class.java).apply {
            action = AnalysisForegroundService.ACTION_START
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        Log.i(tag, "analysis foreground service started")
    }

    private fun emitProgress(stage: String, progress: Double, processed: Int, total: Int, message: String) {
        mainHandler.post {
            progressSink?.success(mapOf(
                "stage" to stage,
                "progress" to progress.coerceIn(0.0, 1.0),
                "processedFrames" to processed,
                "totalFrames" to total,
                "message" to message,
            ))
        }
    }

    private fun emitProgress(event: Map<String, Any?>) {
        emitProgress(
            event["stage"] as? String ?: "refineCandidates",
            (event["progress"] as? Number)?.toDouble() ?: 0.0,
            (event["processedFrames"] as? Number)?.toInt() ?: 0,
            (event["totalFrames"] as? Number)?.toInt() ?: 0,
            event["message"] as? String ?: "正在分析视频",
        )
    }

    private fun emitAnalysisCompletion(result: Map<String, Any?>) {
        mainHandler.post {
            progressSink?.success(mapOf(
                "status" to "completed",
                "stage" to "completed",
                "progress" to 1.0,
                "message" to "分析完成",
                "processedFrames" to result["processed_frames"],
                "totalFrames" to result["total_frames"],
                "candidates" to result["candidates"],
            ))
        }
    }

    private fun emitAnalysisError(code: String, message: String) {
        mainHandler.post {
            progressSink?.success(mapOf(
                "status" to if (code == "ANALYSIS_CANCELLED") "cancelled" else "failed",
                "stage" to if (code == "ANALYSIS_CANCELLED") "cancelled" else "failed",
                "progress" to 0.0,
                "message" to message,
            ))
        }
    }

    private fun videoMetadata(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: run { result.success(null); return }
        Thread {
            val extractor = MediaExtractor()
            val retriever = MediaMetadataRetriever()
            val metadata = mutableMapOf<String, Any?>()
            try {
                if (VideoInput.isDocument(path)) {
                    check(contentResolver.persistedUriPermissions.any {
                        it.uri.toString() == path && it.isReadPermission
                    }) { "Video document permission unavailable" }
                }
                VideoInput.open(retriever, path)
                metadata["creationTime"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE)
                if (VideoInput.isDocument(path)) {
                    metadata["modifiedMs"] = VideoInput.modified(path).takeIf { it > 0 }
                    metadata["sizeBytes"] = VideoInput.seekableSize(path)
                    metadata["fingerprint"] = VideoInput.fingerprint(path)
                }
                VideoInput.open(extractor, path)
                val formats = (0 until extractor.trackCount).map(extractor::getTrackFormat)
                val format = formats.firstOrNull { it.getString(MediaFormat.KEY_MIME) == DolbyVisionPolicy.MIME }
                    ?: formats.firstOrNull { it.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
                if (format != null) {
                    metadata["codec"] = format.getString(MediaFormat.KEY_MIME)
                    metadata["frameRate"] = runCatching { format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble() }
                        .recoverCatching { format.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() }.getOrNull()
                }
            } catch (_: Exception) {
                // Optional metadata must not stop import of an otherwise playable file.
            } finally {
                runCatching { retriever.release() }
                extractor.release()
                mainHandler.post { result.success(metadata) }
            }
        }.start()
    }

    private fun addExportableTracks(extractor: MediaExtractor, muxer: MediaMuxer): ExportTrackSelection =
        ExportTrackPolicy.select(
            (0 until extractor.trackCount).mapNotNull { index ->
                val format = extractor.getTrackFormat(index)
                format.getString(MediaFormat.KEY_MIME)?.let { mime ->
                    val hasSamples = if (mime.startsWith("video/")) {
                        extractor.selectTrack(index)
                        try {
                            extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                            extractor.sampleTrackIndex == index && extractor.sampleSize > 0
                        } finally { extractor.unselectTrack(index) }
                    } else true
                    ExportSourceTrack(index, mime, DolbyVisionFormat.profile(format), hasSamples)
                }
            },
            addTrack = { index -> muxer.addTrack(DolbyVisionFormat.forExport(extractor.getTrackFormat(index))) },
            onSkipped = { track, error ->
                Log.w("BHE-Export", "skipping audio track ${track.index}: ${track.mime}", error)
                AppDiagnostics.event("export.audio.skipped", mapOf("track" to track.index, "mime" to track.mime), error)
            },
            onSkippedVideo = { track, mime ->
                Log.w("BHE-Export", "skipping extra video track ${track.index}: $mime")
                AppDiagnostics.event("export.video.skipped", mapOf("track" to track.index, "mime" to mime))
            },
        )

    private fun applySourceOrientation(extractor: MediaExtractor, muxer: MediaMuxer) {
        for (index in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(index)
            if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") != true) continue
            val rotation = if (format.containsKey(MediaFormat.KEY_ROTATION)) format.getInteger(MediaFormat.KEY_ROTATION) else 0
            muxer.setOrientationHint(ExportTrackPolicy.orientation(rotation))
            return
        }
    }

    private fun exportResult(path: String, selection: ExportTrackSelection): Map<String, Any> = mapOf(
        "outputPath" to path,
        "skippedAudioTracks" to selection.skippedAudio.map { mapOf("index" to it.index, "mime" to it.mime) },
    )

    private fun exportClip(call: MethodCall, result: MethodChannel.Result) {
        AppDiagnostics.event("export.start", mapOf("operation" to "exportClip"))
        val exportId = call.argument<String>("exportId") ?: outputPathId(call)
        val inputPath = call.argument<String>("inputPath")
        val outputPath = call.argument<String>("outputPath")
        val startMs = call.argument<Int>("startMs")
        val endMs = call.argument<Int>("endMs")
        if (inputPath == null || outputPath == null || startMs == null || endMs == null || endMs <= startMs) {
            result.error("INVALID_ARGUMENT", "视频片段参数无效", null)
            return
        }
        val reserved = try {
            ExportStart.acquire(
                { ExportPathRegistry.reserve(exportId, outputPath) },
                { ExportPathRegistry.start(exportId, outputPath) },
                { ExportPathRegistry.releaseIdle(exportId) },
            )
        } catch (error: Exception) { false }
        if (!reserved) {
            result.error("EXPORT_BUSY", "这个输出文件正在导出，请稍后重试。", null)
            return
        }
        val cancelled = ExportStart.claimFlag(exportCancelled, exportId)
        if (cancelled == null) {
            ExportPathRegistry.finish(exportId)
            result.error("EXPORT_BUSY", "这个输出文件正在导出，请稍后重试。", null)
            return
        }
        val worker = Thread {
            var completion: (() -> Unit)? = null
            var extractor: MediaExtractor? = null
            var muxer: MediaMuxer? = null
            var muxerStarted = false
            var transcoded: File? = null
            try {
                File(outputPath).parentFile?.mkdirs()
                File(outputPath).delete()
                transcoded = DolbyExportSource.transcodeIfNeeded(applicationContext, inputPath, cancelled)
                val currentExtractor = MediaExtractor()
                extractor = currentExtractor
                VideoInput.open(currentExtractor, transcoded?.absolutePath ?: inputPath)
                val currentMuxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                muxer = currentMuxer
                val selection = addExportableTracks(currentExtractor, currentMuxer)
                val trackMap = selection.trackMap
                applySourceOrientation(currentExtractor, currentMuxer)
                trackMap.keys.forEach(currentExtractor::selectTrack)
                if (trackMap.isEmpty()) throw IllegalStateException("视频没有可导出的音视频轨道")
                currentMuxer.start()
                muxerStarted = true
                val endUs = endMs.toLong() * 1000L
                currentExtractor.seekTo(startMs.toLong() * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                val clipStartUs = currentExtractor.sampleTime
                // -1 且没有样本才是「定位不到」；负的起始 PTS（手机录制常见）是合法时间戳。
                MergeMediaFinalizer.requireLocation(clipStartUs, currentExtractor.sampleTrackIndex)
                var buffer = ByteBuffer.allocate(16 * 1024 * 1024)
                val info = android.media.MediaCodec.BufferInfo()
                var writtenVideoSamples = 0L
                val videoTracks = trackMap.keys.filter { currentExtractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }.toSet()
                while (true) {
                    if (cancelled.get()) throw InterruptedException("导出已取消")
                    val sourceTrack = currentExtractor.sampleTrackIndex
                    if (sourceTrack < 0 || currentExtractor.sampleTime >= endUs) break
                    val muxTrack = trackMap[sourceTrack]
                    if (muxTrack != null) {
                        val sampleSize = currentExtractor.sampleSize
                        if (sampleSize > Int.MAX_VALUE) throw IllegalStateException("视频样本过大，无法导出")
                        if (sampleSize > buffer.capacity()) buffer = ByteBuffer.allocate(sampleSize.toInt())
                        buffer.clear()
                        val size = currentExtractor.readSampleData(buffer, 0)
                        if (size <= 0) break
                        info.offset = 0
                        info.size = size
                        info.presentationTimeUs = (currentExtractor.sampleTime - clipStartUs).coerceAtLeast(0L)
                        info.flags = currentExtractor.sampleFlags
                        currentMuxer.writeSampleData(muxTrack, buffer, info)
                        if (sourceTrack in videoTracks) writtenVideoSamples++
                    }
                    currentExtractor.advance()
                }
                MergeMediaFinalizer.requireVideoSamples(writtenVideoSamples)
                if (muxerStarted) {
                    currentMuxer.stop()
                    muxerStarted = false
                }
                AppDiagnostics.event("export.completed")
                completion = { result.success(exportResult(outputPath, selection)) }
            } catch (_: InterruptedException) {
                File(outputPath).delete()
                AppDiagnostics.event("export.cancelled")
                completion = { result.error("EXPORT_CANCELLED", "导出已取消", null) }
            } catch (error: Exception) {
                File(outputPath).delete()
                AppDiagnostics.event("export.failed", error = error)
                completion = { result.error("EXPORT_FAILED", error.message, NativeFailureDetails.from(error)) }
            } finally {
                if (muxerStarted) {
                    try {
                        muxer?.stop()
                    } catch (_: Exception) {
                    }
                }
                try { muxer?.release() } catch (error: Exception) { AppDiagnostics.event("export.cleanup.failed", error = error) }
                try { extractor?.release() } catch (error: Exception) { AppDiagnostics.event("export.cleanup.failed", error = error) }
                transcoded?.delete()
                exportCancelled.remove(exportId, cancelled)
                ExportPathRegistry.finish(exportId)
                mainHandler.post { completion?.invoke() }
            }
        }
        try {
            ExportStart.launch({ worker.start() }, {
                exportCancelled.remove(exportId, cancelled)
                ExportPathRegistry.finish(exportId)
            })
        } catch (error: Throwable) {
            AppDiagnostics.event("export.failed", error = error)
            result.error("EXPORT_FAILED", error.message, NativeFailureDetails.from(error))
        }
    }

    private fun registerMergeExport(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("exportId")
        val outputPath = call.argument<String>("outputPath")
        if (id.isNullOrBlank() || outputPath.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "合并导出任务无效", null)
            return
        }
        val reserved = try { ExportPathRegistry.reserve(id, outputPath) } catch (error: Exception) { false }
        if (!reserved) {
            result.error("EXPORT_BUSY", "这个输出文件正在导出，请稍后重试。", null)
            return
        }
        if (exportCancelled.putIfAbsent(id, AtomicBoolean(false)) != null) {
            ExportPathRegistry.releaseIdle(id)
            result.error("INVALID_ARGUMENT", "合并导出任务无效", null)
            return
        }
        result.success(true)
    }

    private fun releaseMergeExport(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("exportId")
        if (id != null) {
            if (ExportPathRegistry.releaseIdle(id)) exportCancelled.remove(id)
        }
        result.success(null)
    }

    private fun mergeClips(call: MethodCall, result: MethodChannel.Result) {
        AppDiagnostics.event("export.start", mapOf("operation" to "mergeClips"))
        val batchGroup = call.argument<Int>("batchGroup")
        val exportId = call.argument<String>("exportId") ?: "merge-${System.nanoTime()}"
        val inputPath = call.argument<String>("inputPath")
        val outputPath = call.argument<String>("outputPath")
        val rawClips = call.argument<List<*>>("clips")
        val plan = try {
            require(inputPath != null && outputPath != null && rawClips != null)
            val intervals = rawClips.map { item ->
                val values = item as? Map<*, *> ?: throw IllegalArgumentException("Invalid interval")
                val start = (values["startMs"] as? Number)?.toLong() ?: throw IllegalArgumentException("Invalid start")
                val end = (values["endMs"] as? Number)?.toLong() ?: throw IllegalArgumentException("Invalid end")
                ExportInterval(start, end)
            }
            ExportOverlapPlanner.plan(intervals)
        } catch (error: IllegalArgumentException) {
            result.error("INVALID_ARGUMENT", "合并导出参数无效", null)
            return
        }
        val clips = plan.intervals
        val reserved = call.argument<Boolean>("reservationRequired") == true
        val cancelled = if (reserved) {
            exportCancelled[exportId] ?: run {
                result.error("EXPORT_CANCELLED", "合并导出已取消", null)
                return
            }
        } else {
            ExportStart.claimFlag(exportCancelled, exportId) ?: run {
                result.error("EXPORT_BUSY", "这个输出文件正在导出，请稍后重试。", null)
                return
            }
        }
        val started = try {
            ExportStart.acquire(
                { reserved || ExportPathRegistry.reserve(exportId, outputPath) },
                { ExportPathRegistry.start(exportId, outputPath) },
                { if (ExportPathRegistry.releaseIdle(exportId)) exportCancelled.remove(exportId, cancelled) },
            )
        } catch (error: Exception) { false }
        if (!started) {
            if (!reserved) exportCancelled.remove(exportId, cancelled)
            result.error("EXPORT_BUSY", "这个输出文件正在导出，请稍后重试。", null)
            return
        }
        val worker = Thread {
            var completion: (() -> Unit)? = null
            var muxer: MediaMuxer? = null
            var muxerStarted = false
            var transcoded: File? = null
            var transaction: MergeOutputTransaction? = null
            try {
                val destination = File(outputPath).absoluteFile
                val temporary = MergeOutputFiles.create(destination)
                val currentTransaction = MergeOutputTransaction(temporary, destination, cancelled) { from, to ->
                    android.system.Os.rename(from.absolutePath, to.absolutePath)
                }
                transaction = currentTransaction
                mergeTransactions[exportId] = currentTransaction
                if (cancelled.get()) throw InterruptedException("合并导出已取消")
                transcoded = DolbyExportSource.transcodeIfNeeded(applicationContext, inputPath, cancelled)
                val sourcePath = transcoded?.absolutePath ?: inputPath
                val firstExtractor = MediaExtractor()
                val currentMuxer = try {
                    VideoInput.open(firstExtractor, sourcePath)
                    MediaMuxer(temporary.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                } catch (error: Exception) {
                    firstExtractor.release()
                    throw error
                }
                muxer = currentMuxer
                val selection: ExportTrackSelection
                val videoTrack: Int
                try {
                    selection = addExportableTracks(firstExtractor, currentMuxer)
                    videoTrack = selection.trackMap.keys.single { index ->
                        firstExtractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
                    }
                    applySourceOrientation(firstExtractor, currentMuxer)
                } finally {
                    firstExtractor.release()
                }
                val trackMap = selection.trackMap
                val audioTracks = trackMap.keys - videoTrack
                currentMuxer.start()
                muxerStarted = true
                var buffer = ByteBuffer.allocate(16 * 1024 * 1024)
                val info = android.media.MediaCodec.BufferInfo()
                var outputBaseUs = 0L
                val videoStats = MergeVideoStats()
                val lastWrittenPtsByTrack = mutableMapOf<Int, Long>()
                for ((index, clip) in clips.withIndex()) {
                    val (startMs, endMs) = clip
                    if (cancelled.get()) throw InterruptedException("合并导出已取消")
                    val extractor = MediaExtractor()
                    try {
                        VideoInput.open(extractor, sourcePath)
                        val endUs = endMs * 1000L
                        extractor.selectTrack(videoTrack)
                        extractor.seekTo(startMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                        val clipStartUs = extractor.sampleTime
                        MergeMediaFinalizer.requireLocation(clipStartUs, extractor.sampleTrackIndex)
                        if (audioTracks.isNotEmpty()) {
                            audioTracks.forEach(extractor::selectTrack)
                            // 各轨各自定位同步样本。用实际视频关键帧为共同定位点。
                            extractor.seekTo(clipStartUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                        }
                        val window = MergeClipWindow(clipStartUs, endUs, outputBaseUs)
                        val intervalStats = videoStats.startInterval(clipStartUs)
                        var nextVideoPtsUs: Long? = null
                        while (true) {
                            if (cancelled.get()) throw InterruptedException("合并导出已取消")
                            val sourceTrack = extractor.sampleTrackIndex
                            val sampleTime = extractor.sampleTime
                            if (sourceTrack < 0 || sampleTime == NO_SAMPLE_TIME) break
                            val isVideo = sourceTrack == videoTrack
                            if (isVideo && sampleTime >= endUs) {
                                // 用首个不写入的视频样本时刻，保留上一帧的时长。
                                nextVideoPtsUs = sampleTime
                                break
                            }
                            val muxTrack = trackMap[sourceTrack]
                            if (muxTrack != null && window.includes(sampleTime, isVideo)) {
                                if (isVideo && intervalStats.samples == 0L && sampleTime != clipStartUs) {
                                    throw MergeRangeUnavailable("无法从合并片段的视频起点读取")
                                }
                                val sampleSizeBytes = extractor.sampleSize
                                if (sampleSizeBytes > Int.MAX_VALUE) throw IllegalStateException("视频样本过大，无法合并导出")
                                if (sampleSizeBytes > buffer.capacity()) buffer = ByteBuffer.allocate(sampleSizeBytes.toInt())
                                buffer.clear()
                                val size = extractor.readSampleData(buffer, 0)
                                if (size <= 0) break
                                info.offset = 0
                                info.size = size
                                info.presentationTimeUs = mergeSamplePtsUs(sampleTime, clipStartUs, outputBaseUs)
                                info.flags = extractor.sampleFlags
                                try {
                                    currentMuxer.writeSampleData(muxTrack, buffer, info)
                                } catch (error: Exception) {
                                    AppDiagnostics.event("export.merge.write_failed", linkedMapOf(
                                        "batch_group" to batchGroup,
                                        "interval" to index + 1,
                                        "clip_requested_start_us" to startMs * 1000L,
                                        "clip_start_us" to clipStartUs,
                                        "clip_end_us" to endUs,
                                        "output_base_us" to outputBaseUs,
                                        "source_track" to sourceTrack,
                                        "mux_track" to muxTrack,
                                        "is_video" to isVideo,
                                        "sample_pts_us" to sampleTime,
                                        "output_pts_us" to info.presentationTimeUs,
                                        "prev_output_pts_us" to lastWrittenPtsByTrack[muxTrack],
                                        "flags" to info.flags,
                                        "sample_bytes" to size,
                                        "wrote_samples" to lastWrittenPtsByTrack.isNotEmpty(),
                                        "video_samples" to intervalStats.samples,
                                        "was_transcoded" to (transcoded != null),
                                    ))
                                    throw error
                                }
                                lastWrittenPtsByTrack[muxTrack] = info.presentationTimeUs
                                if (isVideo) {
                                    intervalStats.record(
                                        sourcePtsUs = sampleTime,
                                        outputPtsUs = info.presentationTimeUs,
                                        isSync = info.flags and MediaExtractor.SAMPLE_FLAG_SYNC != 0,
                                    )
                                }
                            }
                            extractor.advance()
                        }
                        videoStats.finishInterval(intervalStats)
                        MergeMediaFinalizer.requireVideoSamples(intervalStats.samples)
                        if (index < clips.lastIndex) outputBaseUs = window.nextOutputBaseUs(nextVideoPtsUs)
                    } finally {
                        extractor.release()
                    }
                }
                MergeMediaFinalizer.finish(
                    transaction = currentTransaction,
                    writtenVideoSamples = videoStats.writtenVideoSamples,
                    stop = { currentMuxer.stop(); muxerStarted = false },
                    release = { currentMuxer.release(); muxer = null },
                    inspect = { file -> AndroidMergeMediaInspector.inspect(file, cancelled) },
                    stats = videoStats,
                )
                AppDiagnostics.event("export.completed")
                completion = { result.success(exportResult(outputPath, selection) + mapOf("mergedOverlapCount" to plan.mergedOverlapCount, "committed" to true)) }
            } catch (_: InterruptedException) {
                AppDiagnostics.event("export.cancelled")
                completion = { result.error("EXPORT_CANCELLED", "合并导出已取消", null) }
            } catch (error: MergeRangeUnavailable) {
                AppDiagnostics.event("export.failed", error = error)
                completion = { result.error("EXPORT_RANGE_UNREADABLE", error.message, NativeFailureDetails.from(error)) }
            } catch (error: Exception) {
                AppDiagnostics.event("export.failed", error = error)
                completion = { result.error("EXPORT_FAILED", error.message, NativeFailureDetails.from(error)) }
            } finally {
                if (muxerStarted) {
                    try {
                        muxer?.stop()
                    } catch (_: Exception) {
                    }
                }
                try {
                    muxer?.release()
                } catch (error: Exception) {
                    AppDiagnostics.event("export.cleanup.failed", error = error)
                }
                try {
                    transaction?.cleanup()
                } catch (error: Exception) {
                    AppDiagnostics.event("export.cleanup.failed", error = error)
                }
                transaction?.let { mergeTransactions.remove(exportId, it) }
                transcoded?.delete()
                exportCancelled.remove(exportId, cancelled)
                ExportPathRegistry.finish(exportId)
                mainHandler.post { completion?.invoke() }
            }
        }
        try {
            ExportStart.launch({ worker.start() }, {
                exportCancelled.remove(exportId, cancelled)
                ExportPathRegistry.finish(exportId)
            })
        } catch (error: Throwable) {
            AppDiagnostics.event("export.failed", error = error)
            result.error("EXPORT_FAILED", error.message, NativeFailureDetails.from(error))
        }
    }

    private fun outputPathId(call: MethodCall): String =
        call.argument<String>("outputPath") ?: "export-${System.nanoTime()}"

    private fun cancelExport(call: MethodCall, result: MethodChannel.Result) {
        val exportId = call.argument<String>("exportId")
        fun cancelOne(id: String, flag: AtomicBoolean) {
            val transaction = mergeTransactions[id]
            if (transaction != null) transaction.cancel() else flag.set(true)
        }
        if (exportId != null) {
            exportCancelled[exportId]?.let { cancelOne(exportId, it) }
        } else {
            exportCancelled.forEach { (id, flag) -> cancelOne(id, flag) }
        }
        result.success(null)
    }

    private fun saveToLibrary(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("INVALID_ARGUMENT", "媒体路径无效", null)
            return
        }
        Thread {
            try {
                val source = File(path)
                val values = ContentValues().apply {
                    put(MediaStore.Video.Media.DISPLAY_NAME, source.name)
                    put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/BHE")
                        put(MediaStore.Video.Media.IS_PENDING, 1)
                    }
                }
                val resolver = contentResolver
                val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("无法创建相册文件")
                try {
                    resolver.openOutputStream(uri).use { output ->
                        requireNotNull(output)
                        FileInputStream(source).use { input -> input.copyTo(output) }
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        resolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
                    }
                } catch (error: Exception) {
                    resolver.delete(uri, null, null)
                    throw error
                }
                mainHandler.post { result.success(null) }
            } catch (error: Exception) {
                AppDiagnostics.event("export.save.failed", error = error)
                mainHandler.post { result.error("PHOTO_SAVE_FAILED", error.message, NativeFailureDetails.from(error)) }
            }
        }.start()
    }

    private fun jsonObjectToMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith { key ->
        when (val item = value.get(key)) {
            is JSONObject -> jsonObjectToMap(item)
            is JSONArray -> jsonArrayToList(item)
            JSONObject.NULL -> null
            else -> item
        }
    }

    private fun jsonArrayToList(value: JSONArray): List<Any?> = (0 until value.length()).map { index ->
        when (val item = value.get(index)) {
            is JSONObject -> jsonObjectToMap(item)
            is JSONArray -> jsonArrayToList(item)
            JSONObject.NULL -> null
            else -> item
        }
    }
}
