package com.bhe.bhe_mobile

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

    private data class StableHoop(
        val bbox: FloatArray,
        val confidence: Float,
        val previewTimeMs: Long,
        val samples: Int,
        val stability: Double,
    )

    private val tag = "BHE-Analysis"
    private val mediaChannelName = "com.bhe.bhe/mobile_media"
    private val analysisChannelName = "com.bhe.bhe/mobile_analysis"
    private val progressChannelName = "com.bhe.bhe/mobile_analysis_progress"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val exportCancelled = ConcurrentHashMap<String, AtomicBoolean>()
    private var progressSink: EventChannel.EventSink? = null
    private var analysisTaskListener: AnalysisTaskManager.Listener? = null

    override fun onDestroy() {
        setAnalysisScreenOn(false)
        analysisTaskListener?.let(AnalysisTaskManager::detach)
        analysisTaskListener = null
        exportCancelled.values.forEach { it.set(true) }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(true)
                    "exportClip" -> exportClip(call, result)
                    "mergeClips" -> mergeClips(call, result)
                    "cancelExport" -> cancelExport(call, result)
                    "saveToLibrary" -> saveToLibrary(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, analysisChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "analyzeVideo" -> analyzeVideo(call, result)
                    "suggestRoi" -> suggestRoi(call, result)
                    "getAnalysisState" -> getAnalysisState(result)
                    "cancelAnalysis" -> {
                        AnalysisTaskManager.cancel()
                        result.success(null)
                    }
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
        if (!NativeRuntime.available) {
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
                retriever.setDataSource(videoPath)
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
                        if (observations.size >= 5) return@decodeFrames
                    } finally {
                        bitmap.recycle()
                    }
                }
                val stable = selectStableHoop(observations, decodedWidth, decodedHeight)
                    ?: throw IllegalStateException("未识别到稳定的篮筐")
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
    ): StableHoop? {
        if (observations.size < 2 || frameWidth <= 0f || frameHeight <= 0f) return null
        val radius = max(60f, frameWidth * .10f)
        val clusters = mutableListOf<MutableList<HoopObservation>>()
        for (observation in observations) {
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
        val selected = stableClusters.maxWithOrNull(
            compareBy<MutableList<HoopObservation>> { it.size }
                .thenBy { median(it.map(HoopObservation::confidence)) }
                .thenBy { median(it.map { item -> (item.bbox[2] - item.bbox[0]) * (item.bbox[3] - item.bbox[1]) }) },
        ) ?: return null
        val bbox = FloatArray(4) { index -> median(selected.map { it.bbox[index] }) }
        val bestConfidence = selected.maxBy { it.confidence }
        return StableHoop(
            bbox = bbox,
            confidence = median(selected.map(HoopObservation::confidence)),
            previewTimeMs = bestConfidence.timeMs,
            samples = selected.size,
            stability = min(1.0, selected.size.toDouble() / observations.size.toDouble()),
        )
    }

    private fun expandedRoi(bbox: FloatArray, frameWidth: Float, frameHeight: Float): Map<String, Double> {
        val boxWidth = max(4f, bbox[2] - bbox[0])
        val boxHeight = max(4f, bbox[3] - bbox[1])
        val centerX = (bbox[0] + bbox[2]) / 2f
        val centerY = (bbox[1] + bbox[3]) / 2f
        val roiWidth = min(max(boxWidth * 12f, frameWidth * .14f), frameWidth * .65f)
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

    private fun exportClip(call: MethodCall, result: MethodChannel.Result) {
        val exportId = call.argument<String>("exportId") ?: outputPathId(call)
        val inputPath = call.argument<String>("inputPath")
        val outputPath = call.argument<String>("outputPath")
        val startMs = call.argument<Int>("startMs")
        val endMs = call.argument<Int>("endMs")
        if (inputPath == null || outputPath == null || startMs == null || endMs == null || endMs <= startMs) {
            result.error("INVALID_ARGUMENT", "视频片段参数无效", null)
            return
        }
        val cancelled = AtomicBoolean(false)
        exportCancelled[exportId] = cancelled
        Thread {
            var extractor: MediaExtractor? = null
            var muxer: MediaMuxer? = null
            var muxerStarted = false
            try {
                File(outputPath).parentFile?.mkdirs()
                File(outputPath).delete()
                val currentExtractor = MediaExtractor()
                extractor = currentExtractor
                currentExtractor.setDataSource(inputPath)
                val trackMap = mutableMapOf<Int, Int>()
                val currentMuxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                muxer = currentMuxer
                for (index in 0 until currentExtractor.trackCount) {
                    val format = currentExtractor.getTrackFormat(index)
                    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                        trackMap[index] = currentMuxer.addTrack(format)
                        currentExtractor.selectTrack(index)
                    }
                }
                if (trackMap.isEmpty()) throw IllegalStateException("视频没有可导出的音视频轨道")
                currentMuxer.start()
                muxerStarted = true
                val endUs = endMs.toLong() * 1000L
                currentExtractor.seekTo(startMs.toLong() * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                val clipStartUs = currentExtractor.sampleTime
                if (clipStartUs < 0L) throw IllegalStateException("无法定位视频片段起点")
                var buffer = ByteBuffer.allocate(16 * 1024 * 1024)
                val info = android.media.MediaCodec.BufferInfo()
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
                    }
                    currentExtractor.advance()
                }
                if (muxerStarted) {
                    currentMuxer.stop()
                    muxerStarted = false
                }
                mainHandler.post { result.success(outputPath) }
            } catch (_: InterruptedException) {
                File(outputPath).delete()
                mainHandler.post { result.error("EXPORT_CANCELLED", "导出已取消", null) }
            } catch (error: Exception) {
                File(outputPath).delete()
                mainHandler.post { result.error("EXPORT_FAILED", error.message, null) }
            } finally {
                if (muxerStarted) {
                    try {
                        muxer?.stop()
                    } catch (_: Exception) {
                    }
                }
                muxer?.release()
                extractor?.release()
                exportCancelled.remove(exportId)
            }
        }.start()
    }

    private fun mergeClips(call: MethodCall, result: MethodChannel.Result) {
        val exportId = call.argument<String>("exportId") ?: "merge-${System.nanoTime()}"
        val inputPath = call.argument<String>("inputPath")
        val outputPath = call.argument<String>("outputPath")
        val rawClips = call.argument<List<*>>("clips")
        val sortedClips = rawClips?.mapNotNull { item ->
            val values = item as? Map<*, *> ?: return@mapNotNull null
            val start = (values["startMs"] as? Number)?.toLong()
            val end = (values["endMs"] as? Number)?.toLong()
            if (start == null || end == null || end <= start) null else start to end
        }?.sortedBy { it.first } ?: emptyList()
        val clips = mutableListOf<Pair<Long, Long>>()
        for (clip in sortedClips) {
            val previous = clips.lastOrNull()
            if (previous != null && clip.first <= previous.second) {
                clips[clips.lastIndex] = previous.first to maxOf(previous.second, clip.second)
            } else {
                clips += clip
            }
        }
        if (inputPath == null || outputPath == null || clips.isEmpty()) {
            result.error("INVALID_ARGUMENT", "合并导出参数无效", null)
            return
        }
        val cancelled = AtomicBoolean(false)
        exportCancelled[exportId] = cancelled
        Thread {
            var muxer: MediaMuxer? = null
            var muxerStarted = false
            try {
                File(outputPath).parentFile?.mkdirs()
                File(outputPath).delete()
                val firstExtractor = MediaExtractor()
                firstExtractor.setDataSource(inputPath)
                val trackMap = mutableMapOf<Int, Int>()
                val currentMuxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                muxer = currentMuxer
                for (index in 0 until firstExtractor.trackCount) {
                    val format = firstExtractor.getTrackFormat(index)
                    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                        trackMap[index] = currentMuxer.addTrack(format)
                    }
                }
                firstExtractor.release()
                if (trackMap.isEmpty()) throw IllegalStateException("视频没有可合并的音视频轨道")
                currentMuxer.start()
                muxerStarted = true
                var buffer = ByteBuffer.allocate(16 * 1024 * 1024)
                val info = android.media.MediaCodec.BufferInfo()
                var outputBaseUs = 0L
                for ((startMs, endMs) in clips) {
                    if (cancelled.get()) throw InterruptedException("合并导出已取消")
                    val extractor = MediaExtractor()
                    try {
                        extractor.setDataSource(inputPath)
                        trackMap.keys.forEach(extractor::selectTrack)
                        val endUs = endMs * 1000L
                        extractor.seekTo(startMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                        val clipStartUs = extractor.sampleTime
                        if (clipStartUs < 0L) continue
                        while (true) {
                            if (cancelled.get()) throw InterruptedException("合并导出已取消")
                            val sourceTrack = extractor.sampleTrackIndex
                            val sampleTime = extractor.sampleTime
                            if (sourceTrack < 0 || sampleTime < 0L || sampleTime >= endUs) break
                            val muxTrack = trackMap[sourceTrack]
                            if (muxTrack != null) {
                                val sampleSizeBytes = extractor.sampleSize
                                if (sampleSizeBytes > Int.MAX_VALUE) throw IllegalStateException("视频样本过大，无法合并导出")
                                if (sampleSizeBytes > buffer.capacity()) buffer = ByteBuffer.allocate(sampleSizeBytes.toInt())
                                buffer.clear()
                                val size = extractor.readSampleData(buffer, 0)
                                if (size <= 0) break
                                info.offset = 0
                                info.size = size
                                info.presentationTimeUs = outputBaseUs +
                                    (sampleTime - clipStartUs).coerceAtLeast(0L)
                                info.flags = extractor.sampleFlags
                                currentMuxer.writeSampleData(muxTrack, buffer, info)
                            }
                            extractor.advance()
                        }
                        outputBaseUs += (endUs - clipStartUs).coerceAtLeast(1L)
                    } finally {
                        extractor.release()
                    }
                }
                currentMuxer.stop()
                muxerStarted = false
                mainHandler.post { result.success(outputPath) }
            } catch (_: InterruptedException) {
                File(outputPath).delete()
                mainHandler.post { result.error("EXPORT_CANCELLED", "合并导出已取消", null) }
            } catch (error: Exception) {
                File(outputPath).delete()
                mainHandler.post { result.error("EXPORT_FAILED", error.message, null) }
            } finally {
                if (muxerStarted) {
                    try {
                        muxer?.stop()
                    } catch (_: Exception) {
                    }
                }
                muxer?.release()
                exportCancelled.remove(exportId)
            }
        }.start()
    }

    private fun outputPathId(call: MethodCall): String =
        call.argument<String>("outputPath") ?: "export-${System.nanoTime()}"

    private fun cancelExport(call: MethodCall, result: MethodChannel.Result) {
        val exportId = call.argument<String>("exportId")
        if (exportId != null) {
            exportCancelled[exportId]?.set(true)
        } else {
            exportCancelled.values.forEach { it.set(true) }
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
                mainHandler.post { result.error("PHOTO_SAVE_FAILED", error.message, null) }
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
