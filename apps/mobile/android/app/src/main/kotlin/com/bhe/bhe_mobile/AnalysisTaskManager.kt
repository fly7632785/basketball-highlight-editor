package com.bhe.bhe_mobile

import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.PowerManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.round
import java.util.Locale

object AnalysisTaskManager {
    interface Listener {
        fun onProgress(event: Map<String, Any?>)
        fun onComplete(result: Map<String, Any?>)
        fun onError(code: String, message: String)
    }

    private const val TAG = "BHE-AnalysisTask"
    private const val STATE_FILE = "analysis_task.json"
    private const val COARSE_TRIGGER_FPS = 0.5
    // Keep discovery sampling identical to the desktop coarse pass. A lower
    // cadence changes the pair of detections used by the crossing gate and
    // can turn a real crossing into zero coarse candidates.
    private const val COARSE_FPS = 5.0
    private const val COARSE_MODEL_SIZE = 640
    private const val COARSE_MAX_DIMENSION = 960
    private const val COARSE_WINDOW_MS = 4_000L
    private const val FINE_WINDOW_MS = 1_500L
    private const val USE_PROXY_COARSE_SCAN = true

    private var thread: Thread? = null
    private var listener: Listener? = null
    private var context: Context? = null
    private var cancelRequested = AtomicBoolean(false)
    private var state: JSONObject = JSONObject().put("status", "idle")
    private var pendingResult: MethodResult? = null

    interface MethodResult {
        fun success(value: Map<String, Any?>)
        fun error(code: String, message: String)
    }

    @Synchronized
    fun isRunning(): Boolean = thread?.isAlive == true || state.optString("status") == "running"

    @Synchronized
    fun hasWorkerThread(): Boolean = thread?.isAlive == true

    @Synchronized
    fun attach(newListener: Listener, serviceContext: Context? = null): Map<String, Any?> {
        serviceContext?.applicationContext?.let { context = it }
        if (state.optString("status") == "idle") {
            context?.let(::readState)?.let { state = it }
        }
        listener = newListener
        val snapshot = jsonObjectToMap(state)
        when (state.optString("status")) {
            "completed" -> state.optJSONObject("result")?.let { newListener.onComplete(jsonObjectToMap(it)) }
            "failed", "cancelled" -> newListener.onError(
                state.optString("errorCode", "ANALYSIS_FAILED"),
                state.optString("errorMessage", "移动端分析任务失败"),
            )
        }
        return snapshot
    }

    @Synchronized
    fun detach(detached: Listener) {
        if (listener === detached) listener = null
    }

    @Synchronized
    fun prepare(serviceContext: Context, requestJson: String, methodResult: MethodResult? = null) {
        if (isRunning()) return
        context = serviceContext.applicationContext
        pendingResult = methodResult
        cancelRequested = AtomicBoolean(false)
        state = JSONObject()
            .put("status", "running")
            .put("request", requestJson)
            .put("processed", 0)
            .put("total", 0)
        persistState()
    }

    @Synchronized
    fun startPrepared(serviceContext: Context, requestJson: String? = null) {
        if (thread?.isAlive == true) return
        context = serviceContext.applicationContext
        val saved = readState(serviceContext.applicationContext)
        val request = requestJson
            ?: saved?.optString("request")?.takeIf { it.isNotEmpty() }
            ?: return
        if (requestJson == null && saved?.optString("status") != "running") return
        if (state.optString("status") != "running" && saved != null) state = saved
        cancelRequested = AtomicBoolean(false)
        thread = Thread({ run(serviceContext.applicationContext, JSONObject(request)) }, TAG).also { it.start() }
    }

    @Synchronized
    fun start(serviceContext: Context, requestJson: String, methodResult: MethodResult? = null) {
        prepare(serviceContext, requestJson, methodResult)
        startPrepared(serviceContext, requestJson)
    }


    @Synchronized
    fun cancel() {
        cancelRequested.set(true)
        val worker = thread
        worker?.interrupt()
        state.put("status", "cancelled")
            .put("errorCode", "ANALYSIS_CANCELLED")
            .put("errorMessage", "分析已取消")
        persistState()
        if (worker == null || !worker.isAlive) {
            listener?.onError("ANALYSIS_CANCELLED", "分析已取消")
            pendingResult?.error("ANALYSIS_CANCELLED", "分析已取消")
            pendingResult = null
            context?.stopService(Intent(context, AnalysisForegroundService::class.java).apply {
                action = AnalysisForegroundService.ACTION_STOP
            })
        }
    }

    private fun run(appContext: Context, request: JSONObject) {
        var coarsePipeline: FramePipeline? = null
        val wakeLock = (appContext.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "BHE::Analysis")
            .apply { setReferenceCounted(false); acquire() }
        try {
            val videoPath = request.getString("videoPath")
            val modelPath = request.getString("modelPath")
            val startMs = request.getLong("startMs")
            val endMs = request.getLong("endMs")
            val fps = request.getDouble("fps").coerceIn(1.0, 10.0)
            val duration = MediaDuration.read(videoPath, endMs)
            if (duration <= 0L || startMs < 0L || startMs >= duration || endMs <= startMs) {
                throw IllegalArgumentException("分析范围超出视频时长")
            }
            val actualEndMs = endMs.coerceIn(startMs + 1L, duration)
            val modelSize = request.getInt("modelSize").also {
                require(it >= 320 && it % 32 == 0) {
                    "模型输入尺寸无效：$it，必须是 32 的倍数且不小于 320"
                }
            }
            val confidence = request.getDouble("confidenceThreshold")
            val hoopRoi = request.getJSONObject("hoopRoi")
            val netRoi = request.getJSONObject("netRoi")
            val rimRoi = request.optJSONObject("rimRoi")
            val totalFull = sampleTimes(startMs, actualEndMs, fps).size
            updateProgress("validateInput", 0.03, 0, totalFull, "正在读取视频信息")
            updateProgress("prepareProxy", 0.05, 0, totalFull, "正在加载本地模型")
            val onnxPath = File(appContext.applicationInfo.nativeLibraryDir, "libonnxruntime.so").absolutePath
            if (!NativeRuntime.ensureOnnxLoaded(onnxPath) || !NativeRuntime.initializeOnnx(onnxPath)) {
                throw IllegalStateException("ONNX Runtime 初始化失败：${NativeRuntime.loadError ?: "Android 原生推理库无法加载"}")
            }
            updateProgress("prepareProxy", 0.06, 0, totalFull, "正在检测推理加速")
            // Rust selects the native provider from this value. Keep one
            // provider choice for coarse and fine passes so their results and
            // performance are comparable.
            val requestedEp = request.optString("executionProvider", "auto")
            val requestedBatchSize = request.optInt("inferenceBatchSize", 4).coerceIn(1, 8)
            val tuned = if (requestedEp == "auto") {
                updateProgress("prepareProxy", 0.07, 0, totalFull, "正在选择最快的本地推理方式")
                InferenceTuner.select(appContext, videoPath, modelPath, startMs, request)
            } else {
                InferenceTuner.Selection(requestedEp, requestedBatchSize, 0.0, true)
            }
            val resolvedEp = tuned.provider
            val inferenceBatchSize = tuned.batchSize
            synchronized(this) {
                state.put("executionProvider", resolvedEp)
                    .put("inferenceBatchSize", inferenceBatchSize)
                    .put("benchmarkFps", tuned.measuredFps)
                persistState()
            }
            Log.i(
                TAG,
                "analysis runtime requested=$requestedEp/$requestedBatchSize provider=$resolvedEp batch=$inferenceBatchSize " +
                    "benchmarkFps=${String.format(Locale.US, "%.2f", tuned.measuredFps)} cached=${tuned.cached} " +
                    "coarseFps=$COARSE_FPS fineFps=$fps",
            )

            var coarseRimRoi: JSONObject? = null
            var coarseResult: CoarseResult? = null
            val fineTimes = if (fps > COARSE_TRIGGER_FPS) {
                val coarseTotal = sampleTimes(startMs, actualEndMs, COARSE_FPS).size
                val proxy = if (USE_PROXY_COARSE_SCAN) {
                    updateProgress("prepareProxy", 0.06, 0, totalFull, "正在生成低分辨率代理视频")
                    try {
                        ProxyVideoGenerator.createOrGet(
                            appContext,
                            videoPath,
                            startMs,
                            actualEndMs,
                            { cancelRequested.get() },
                        ) { proxyProgress ->
                            updateProgress("prepareProxy", 0.06 + proxyProgress * 0.08, 0, totalFull, "正在生成低分辨率代理视频")
                        }
                    } catch (cancelled: InterruptedException) {
                        throw cancelled
                    } catch (error: Exception) {
                        Log.w(TAG, "代理视频生成失败，回退原视频粗扫", error)
                        null
                    }
                } else {
                    null
                }
                var coarse = if (proxy != null) {
                    updateProgress("coarseScan", 0.18, 0, coarseTotal, "正在快速扫描视频")
                    runCoarseScan(
                        proxy.file.path,
                        modelPath,
                        0L,
                        proxy.durationMs,
                        confidence,
                        hoopRoi,
                        null,
                        startMs,
                        COARSE_FPS,
                        resolvedEp,
                        inferenceBatchSize,
                    ) { pipeline -> coarsePipeline = pipeline }
                } else {
                    updateProgress("coarseScan", 0.18, 0, coarseTotal, "正在快速扫描视频")
                    runCoarseScan(
                        videoPath,
                        modelPath,
                        startMs,
                        actualEndMs,
                        confidence,
                        hoopRoi,
                        null,
                        0L,
                        COARSE_FPS,
                        resolvedEp,
                        inferenceBatchSize,
                    ) { pipeline -> coarsePipeline = pipeline }
                }
                coarseRimRoi = coarse.bestRimRoi
                coarseResult = coarse
                Log.i(
                    TAG,
                    "coarse summary: sampled=${coarse.sampledFrames} detections=${coarse.detectionCount} " +
                        "balls=${coarse.ballDetectionCount} rims=${coarse.rimDetectionCount} " +
                    "selectedRim=${coarseRimRoi} ep=$resolvedEp",
                )
                if (coarse.times.isEmpty()) {
                    updateProgress("coarseScan", 0.48, coarse.sampledFrames, coarse.sampledFrames, "快速扫描完成，未发现候选")
                    emptyList()
                } else {
                    // The desktop refiner runs one independent native-frame
                    // scan per coarse crossing. Do not merge neighbouring
                    // crossings into one session: merging changes tracking,
                    // net history and local rim calibration.
                    coarseCandidateTimes(coarse)
                }
            } else {
                sampleTimes(startMs, actualEndMs, fps)
            }
            // The PC refiner always receives a compact physical rim. Reuse
            // the project calibration first; if this older project lacks it,
            // promote the stable coarse calibration instead of starting each
            // fine window from an uncalibrated full-frame box.
            val effectiveRimRoi = coarseRimRoi ?: rimRoi
            coarsePipeline?.release()
            coarsePipeline = null
            if (cancelRequested.get()) throw InterruptedException("分析已取消")
            if (fineTimes.isEmpty()) {
                Log.i(
                    TAG,
                    "analysis summary: no coarse candidates; sampled=${coarseResult?.sampledFrames ?: 0} " +
                        "detections=${coarseResult?.detectionCount ?: 0} " +
                        "balls=${coarseResult?.ballDetectionCount ?: 0} " +
                        "rims=${coarseResult?.rimDetectionCount ?: 0}",
                )
                complete(
                    mapOf(
                        "candidates" to emptyList<Map<String, Any?>>(),
                        "processed_frames" to 0,
                        "total_frames" to 0,
                        "coarse_sampled_frames" to (coarseResult?.sampledFrames ?: 0),
                        "coarse_detection_count" to (coarseResult?.detectionCount ?: 0),
                        "coarse_ball_detection_count" to (coarseResult?.ballDetectionCount ?: 0),
                        "coarse_rim_detection_count" to (coarseResult?.rimDetectionCount ?: 0),
                    ),
                )
                return
            }

            val candidateEvents = fineTimes
            val fineTotal = candidateEvents.sumOf { eventMs ->
                sampleTimes(max(startMs, eventMs - FINE_WINDOW_MS), min(actualEndMs, eventMs + FINE_WINDOW_MS), fps).size
            }.coerceAtLeast(1)
            val aggregateCandidates = JSONArray()
            var completedFrames = 0
            var fineDetectionCount = 0
            var fineBallDetectionCount = 0
            var fineRimDetectionCount = 0
            var fineCandidatePeak = 0
            var inferenceNanos = 0L
            val startedAt = System.nanoTime()
            updateProgress("refineCandidates", 0.52, 0, fineTotal, "正在精筛候选片段")
            for (eventMs in candidateEvents) {
                if (cancelRequested.get()) throw InterruptedException("分析已取消")
                val window = runFineWindow(
                    videoPath, modelPath, eventMs, startMs, actualEndMs, fps,
                    confidence, hoopRoi, netRoi, effectiveRimRoi, duration, request,
                    modelSize, resolvedEp, fineTotal, completedFrames,
                ) { processed, total ->
                    updateProgress(
                        "refineCandidates",
                        0.52 + (completedFrames + processed).toDouble() / fineTotal * 0.44,
                        completedFrames + processed,
                        fineTotal,
                        "正在分析候选 ${candidateEvents.indexOf(eventMs) + 1}/${candidateEvents.size}",
                    )
                }
                completedFrames += window.processed
                fineDetectionCount += window.detectionCount
                fineBallDetectionCount += window.ballDetectionCount
                fineRimDetectionCount += window.rimDetectionCount
                fineCandidatePeak = max(fineCandidatePeak, window.candidatePeak)
                inferenceNanos += window.inferenceNanos
                val candidates = window.response.optJSONArray("candidates")
                for (index in 0 until (candidates?.length() ?: 0)) {
                    candidates?.optJSONObject(index)?.let { aggregateCandidates.put(it) }
                }
            }
            val finalResponse = JSONObject().put("candidates", dedupeJsonCandidates(aggregateCandidates, request.getLong("dedupeMs")))
            if (finalResponse.optJSONArray("candidates")?.length() == 0) {
                val coarseCandidates = coarseResult?.candidateTimes.orEmpty().distinct().sorted()
                if (coarseCandidates.isNotEmpty()) {
                    val fallback = JSONArray()
                    coarseCandidates.forEach { fallback.put(reviewFallbackCandidate(it, startMs, actualEndMs, request)) }
                    finalResponse.put("candidates", fallback)
                    Log.i(TAG, "fine empty; retained ${coarseCandidates.size} coarse crossings for review")
                }
            }
            val result = jsonObjectToMap(finalResponse).toMutableMap()
            result["processed_frames"] = completedFrames
            result["total_frames"] = fineTotal
            val processingMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)
            val inferenceMs = TimeUnit.NANOSECONDS.toMillis(inferenceNanos)
            val finalCandidateCount = finalResponse.optJSONArray("candidates")?.length() ?: 0
            Log.i(
                TAG,
                "fine summary: frames=$completedFrames/$fineTotal detections=$fineDetectionCount balls=$fineBallDetectionCount " +
                    "rims=$fineRimDetectionCount candidatePeak=$fineCandidatePeak finalCandidates=" +
                    "$finalCandidateCount coarseCandidates=${candidateEvents.size} " +
                    "totalMs=$processingMs inferenceMs=$inferenceMs ep=$resolvedEp",
            )
            updateProgress("persistCandidates", 0.98, completedFrames, fineTotal, "正在写入分析结果")
            complete(result)
        } catch (_: InterruptedException) {
            fail("ANALYSIS_CANCELLED", "分析已取消", cancelled = true)
        } catch (error: Exception) {
            Log.e(TAG, "analysis failed", error)
            fail("ANALYSIS_FAILED", error.message ?: "移动端分析失败", cancelled = false)
        } finally {
            coarsePipeline?.release()
            wakeLock.release()
            synchronized(this) { thread = null }
            appContext.stopService(Intent(appContext, AnalysisForegroundService::class.java).apply {
                action = AnalysisForegroundService.ACTION_STOP
            })
        }
    }

    private data class CoarseResult(
        val candidateTimes: List<Long> = emptyList(),
        val pipeline: FramePipeline?,
        val calibratedRimRoi: JSONObject? = null,
        val sampledFrames: Int = 0,
        val detectionCount: Int = 0,
        val ballDetectionCount: Int = 0,
        val rimDetectionCount: Int = 0,
    ) {
        val times: List<Long> get() = candidateTimes.distinct().sorted()
        val bestRimRoi: JSONObject? get() = calibratedRimRoi
    }

    private data class FineWindowResult(
        val response: JSONObject,
        val processed: Int,
        val detectionCount: Int,
        val ballDetectionCount: Int,
        val rimDetectionCount: Int,
        val candidatePeak: Int,
        val inferenceNanos: Long,
    )

    private fun coarseCandidateTimes(coarse: CoarseResult): List<Long> =
        coarse.candidateTimes.distinct()
            .sorted()

    private fun runFineWindow(
        videoPath: String,
        modelPath: String,
        eventMs: Long,
        startMs: Long,
        endMs: Long,
        fps: Double,
        confidence: Double,
        analysisRoi: JSONObject,
        netRoi: JSONObject,
        rimRoi: JSONObject?,
        duration: Long,
        request: JSONObject,
        modelSize: Int,
        executionProvider: String,
        totalProgressFrames: Int,
        completedProgressFrames: Int,
        onProgress: (processed: Int, total: Int) -> Unit,
    ): FineWindowResult {
        val timestampsUs = sampleTimes(
            max(startMs, eventMs - FINE_WINDOW_MS),
            min(endMs, eventMs + FINE_WINDOW_MS),
            fps,
        ).map { it * 1000L }
        val total = timestampsUs.size.coerceAtLeast(1)
        val config = JSONObject()
            .put("model_path", modelPath)
            .put("hoop_roi", rimRoi ?: fullRoi())
            .put("analysis_roi", analysisRoi)
            .put("net_roi", netRoi)
            .put("duration_ms", duration)
            .put("confidence_threshold", confidence)
            .put("clip_before_ms", request.getLong("beforeMs"))
            .put("clip_after_ms", request.getLong("afterMs"))
            .put("model_size", modelSize)
            .put("crop_scale", request.getDouble("cropScale"))
            .put("max_cross_gap_ms", request.getLong("maxCrossGapMs"))
            .put("dedupe_ms", request.getLong("dedupeMs"))
            .put("intra_threads", 2)
            .put("execution_provider", executionProvider)
            .put("inference_batch_size", request.optInt("inferenceBatchSize", 4).coerceIn(1, 8))
        request.optString("optimizedModelPath").takeIf { it.isNotEmpty() }?.let {
            config.put("optimized_model_path", it)
        }
        rimRoi?.let { config.put("rim", it) }
        val sessionCreateStarted = System.nanoTime()
        val session = NativeRuntime.createSession(config.toString())
        if (session == 0L) throw IllegalStateException("Rust Runtime 无法加载模型或 ONNX Runtime")
        Log.i(
            TAG,
            "fine runtime=${NativeRuntime.sessionInfo(session)} createMs=${nanosToMs(System.nanoTime() - sessionCreateStarted)} eventMs=$eventMs",
        )
        val pipeline = FramePipeline(videoPath, 960).also { it.prepare(timestampsUs.first()) }
        var processed = 0
        var detectionCount = 0
        var ballDetectionCount = 0
        var rimDetectionCount = 0
        var candidatePeak = 0
        var inferenceNanos = 0L
        try {
            val delivered = pipeline.decodeFramesYuv(timestampsUs, { cancelRequested.get() }) { image, bitmap, _, targetTimestampUs ->
                if (cancelRequested.get()) throw InterruptedException("分析已取消")
                try {
                    val inferenceStarted = System.nanoTime()
                    val response = if (image != null) {
                        val planes = image.planes
                        NativeRuntime.pushFrameYuv(
                            session, targetTimestampUs / 1000L, image.width, image.height,
                            planes[0].buffer, planes[0].buffer.position(), planes[0].buffer.remaining(), planes[0].rowStride, planes[0].pixelStride,
                            planes[1].buffer, planes[1].buffer.position(), planes[1].buffer.remaining(), planes[1].rowStride, planes[1].pixelStride,
                            planes[2].buffer, planes[2].buffer.position(), planes[2].buffer.remaining(), planes[2].rowStride, planes[2].pixelStride,
                            pipeline.rotationDegreesValue,
                        )
                    } else {
                        try {
                            NativeRuntime.pushFrameBitmap(session, targetTimestampUs / 1000L, requireNotNull(bitmap))
                        } finally {
                            if (bitmap != null && !bitmap.isRecycled) bitmap.recycle()
                        }
                    }
                    inferenceNanos += System.nanoTime() - inferenceStarted
                    val parsed = JSONObject(response)
                    parsed.optString("error").takeIf { it.isNotEmpty() }?.let { throw IllegalStateException(it) }
                    val detections = parsed.optJSONArray("detections")
                    detectionCount += detections?.length() ?: 0
                    for (index in 0 until (detections?.length() ?: 0)) {
                        when (detections?.optJSONObject(index)?.optInt("class_id", -1)) {
                            0 -> ballDetectionCount++
                            1 -> rimDetectionCount++
                        }
                    }
                    candidatePeak = max(candidatePeak, parsed.optJSONArray("candidates")?.length() ?: 0)
                } finally {
                    image?.close()
                    if (bitmap != null && !bitmap.isRecycled) bitmap.recycle()
                }
                processed++
                if (processed == 1 || processed % 3 == 0 || processed == total) {
                    onProgress(processed, total)
                }
            }
            if (delivered != total || processed != total) throw IllegalStateException("视频解码不完整：$processed/$total 帧")
            val response = JSONObject(NativeRuntime.finishSession(session))
            response.optString("error").takeIf { it.isNotEmpty() }?.let { throw IllegalStateException(it) }
            Log.i(
                TAG,
                "fine performance eventMs=$eventMs frames=$processed nativeMs=${nanosToMs(inferenceNanos)} " +
                    "nativeFps=${formatFps(processed, inferenceNanos)} runtime=${NativeRuntime.sessionInfo(session)}",
            )
            return FineWindowResult(response, processed, detectionCount, ballDetectionCount, rimDetectionCount, candidatePeak, inferenceNanos)
        } finally {
            NativeRuntime.freeSession(session)
            pipeline.release()
        }
    }

    private fun dedupeJsonCandidates(candidates: JSONArray, dedupeMs: Long): JSONArray {
        val sorted = (0 until candidates.length())
            .mapNotNull { candidates.optJSONObject(it) }
            .sortedBy { it.optLong("event_ms", Long.MIN_VALUE) }
        val result = JSONArray()
        var clusterStart = Long.MIN_VALUE
        var winner: JSONObject? = null
        fun priority(candidate: JSONObject): Double =
            candidate.optDouble("composite_score", candidate.optDouble("confidence", 0.0))
        fun flush() { winner?.let(result::put) }
        for (candidate in sorted) {
            val eventMs = candidate.optLong("event_ms", Long.MIN_VALUE)
            if (eventMs == Long.MIN_VALUE) continue
            if (winner == null || eventMs - clusterStart <= dedupeMs) {
                if (winner == null) clusterStart = eventMs
                if (winner == null || priority(candidate) > priority(winner!!)) winner = candidate
            } else {
                flush()
                clusterStart = eventMs
                winner = candidate
            }
        }
        flush()
        return result
    }

    private fun runCoarseScan(
        videoPath: String,
        modelPath: String,
        startMs: Long,
        endMs: Long,
        confidence: Double,
        scanRoi: JSONObject,
        rimRoi: JSONObject?,
        sourceOffsetMs: Long,
        sampleFps: Double,
        executionProvider: String,
        inferenceBatchSize: Int,
        onPipeline: (FramePipeline) -> Unit,
    ): CoarseResult {
        val times = sampleTimes(startMs, endMs, sampleFps)
        if (times.isEmpty()) return CoarseResult(pipeline = null)
        val config = JSONObject()
            .put("model_path", modelPath)
            .put("hoop_roi", rimRoi ?: fullRoi())
            // The desktop coarse scan feeds the configured analysis ROI as-is.
            // Expanding it here changes the model's effective pixel scale and
            // is enough to lose the small ball on the same video.
            .put("analysis_roi", scanRoi)
            .put("net_roi", fullRoi())
            .put("duration_ms", endMs)
            .put("confidence_threshold", confidence)
            .put("model_size", COARSE_MODEL_SIZE)
            .put("crop_scale", 4.0)
            .put("input_max_dimension", COARSE_MAX_DIMENSION)
            // Use the same tracking/crossing decision layer as the desktop
            // Coarse candidates are emitted only by the Rust crossing pass.
            .put("detection_only", false)
            .put("coarse_mode", true)
            .put("intra_threads", 2)
            .put("execution_provider", executionProvider)
            .put("inference_batch_size", inferenceBatchSize)
        val sessionCreateStarted = System.nanoTime()
        val session = NativeRuntime.createSession(config.toString())
        if (session == 0L) return CoarseResult(pipeline = null)
        Log.i(
            TAG,
            "coarse runtime=${NativeRuntime.sessionInfo(session)} createMs=${nanosToMs(System.nanoTime() - sessionCreateStarted)} sampleFps=$sampleFps",
        )
        val pipeline = FramePipeline(videoPath, COARSE_MAX_DIMENSION).also {
            it.prepare(times.first() * 1000L)
            onPipeline(it)
        }
        var detectionCount = 0
        var ballDetectionCount = 0
        var rimDetectionCount = 0
        val candidateTimes = mutableListOf<Long>()
        val rimObservations = mutableListOf<JSONObject>()
        var nativeNanos = 0L
        val passStarted = System.nanoTime()
        try {
            var processed = 0
            val delivered = pipeline.decodeFramesYuv(times.map { it * 1000L }, { cancelRequested.get() }) { image, bitmap, _, targetUs ->
                if (cancelRequested.get()) throw InterruptedException("分析已取消")
                try {
                    val nativeStarted = System.nanoTime()
                    val response = if (image != null) {
                        val planes = image.planes
                        NativeRuntime.pushFrameYuv(
                            session, targetUs / 1000L, image.width, image.height,
                            planes[0].buffer, planes[0].buffer.position(), planes[0].buffer.remaining(), planes[0].rowStride, planes[0].pixelStride,
                            planes[1].buffer, planes[1].buffer.position(), planes[1].buffer.remaining(), planes[1].rowStride, planes[1].pixelStride,
                            planes[2].buffer, planes[2].buffer.position(), planes[2].buffer.remaining(), planes[2].rowStride, planes[2].pixelStride,
                            pipeline.rotationDegreesValue,
                        )
                    } else {
                        try {
                            NativeRuntime.pushFrameBitmap(session, targetUs / 1000L, requireNotNull(bitmap))
                        } finally {
                            if (bitmap != null && !bitmap.isRecycled) bitmap.recycle()
                        }
                    }
                    nativeNanos += System.nanoTime() - nativeStarted
                    if (cancelRequested.get()) throw InterruptedException("分析已取消")
                    val frameWidth = if (image != null && pipeline.rotationDegreesValue % 180 != 0) image.height else image?.width ?: bitmap?.width ?: 1
                    val frameHeight = if (image != null && pipeline.rotationDegreesValue % 180 != 0) image.width else image?.height ?: bitmap?.height ?: 1
                    val parsedResponse = JSONObject(response)
                    parsedResponse.optJSONArray("candidates")?.let { candidates ->
                        for (candidateIndex in 0 until candidates.length()) {
                            val candidate = candidates.optJSONObject(candidateIndex) ?: continue
                            val eventMs = candidate.optLong("event_ms", Long.MIN_VALUE)
                            if (eventMs != Long.MIN_VALUE) {
                                candidateTimes += eventMs + sourceOffsetMs
                            }
                        }
                    }
                    val detections = parsedResponse.optJSONArray("detections")
                    detectionCount += detections?.length() ?: 0
                    for (index in 0 until (detections?.length() ?: 0)) {
                        when (detections?.optJSONObject(index)?.optInt("class_id", -1)) {
                            0 -> ballDetectionCount++
                            1 -> rimDetectionCount++
                        }
                    }
                    collectHoopObservations(parsedResponse, rimObservations, frameWidth, frameHeight)
                    processed++
                    if (processed % 60 == 0) {
                        val elapsed = System.nanoTime() - passStarted
                        Log.i(
                            TAG,
                            "coarse performance frames=$processed elapsedMs=${nanosToMs(elapsed)} nativeMs=${nanosToMs(nativeNanos)} " +
                                "wallFps=${formatFps(processed, elapsed)} nativeFps=${formatFps(processed, nativeNanos)}",
                        )
                    }
                    if (processed == 1 || processed % 3 == 0) {
                        val stage = "coarseScan"
                        val base = 0.18
                        val span = 0.30
                        val coarseProgress = base + processed.toDouble() / times.size.coerceAtLeast(1) * span
                        updateProgress(stage, coarseProgress, processed, times.size, "正在快速扫描视频")
                    }
                } finally {
                    image?.close()
                    if (bitmap != null && !bitmap.isRecycled) bitmap.recycle()
                }
            }
            if (delivered != times.size) {
                throw IllegalStateException("粗扫视频解码不完整：$delivered/${times.size} 帧")
            }
            val finalResponse = JSONObject(NativeRuntime.finishSession(session))
            val passElapsed = System.nanoTime() - passStarted
            Log.i(
                TAG,
                "coarse performance final frames=$processed elapsedMs=${nanosToMs(passElapsed)} nativeMs=${nanosToMs(nativeNanos)} " +
                    "wallFps=${formatFps(processed, passElapsed)} nativeFps=${formatFps(processed, nativeNanos)} " +
                    "runtime=${NativeRuntime.sessionInfo(session)}",
            )
            Log.i(
                TAG,
                "coarse result crossings=${finalResponse.optJSONArray("candidates")?.length() ?: 0} " +
                    "hoopObservations=${rimObservations.size} ballDetections=$ballDetectionCount rimDetections=$rimDetectionCount",
            )
            finalResponse.optJSONArray("candidates")?.let { candidates ->
                for (candidateIndex in 0 until candidates.length()) {
                    val candidate = candidates.optJSONObject(candidateIndex) ?: continue
                    val eventMs = candidate.optLong("event_ms", Long.MIN_VALUE)
                    if (eventMs != Long.MIN_VALUE) {
                        candidateTimes += eventMs + sourceOffsetMs
                    }
                }
            }
            return CoarseResult(
                candidateTimes = candidateTimes.distinct().sorted(),
                pipeline = pipeline,
                calibratedRimRoi = medianCoarseRim(rimObservations),
                sampledFrames = processed,
                detectionCount = detectionCount,
                ballDetectionCount = ballDetectionCount,
                rimDetectionCount = rimDetectionCount,
            )
        } finally {
            NativeRuntime.freeSession(session)
        }
    }

    private fun reviewFallbackCandidate(
        eventMs: Long,
        startMs: Long,
        endMs: Long,
        request: JSONObject,
    ): JSONObject {
        val beforeMs = request.optLong("beforeMs", 6_000L)
        val afterMs = request.optLong("afterMs", 3_000L)
        val clipStart = max(startMs, eventMs - beforeMs)
        val clipEnd = min(endMs, eventMs + afterMs)
        return JSONObject()
            .put("id", "coarse_review_$eventMs")
            .put("track_id", -1)
            .put("start_ms", clipStart)
            .put("end_ms", clipEnd)
            .put("default_start_ms", clipStart)
            .put("default_end_ms", clipEnd)
            .put("event_ms", eventMs)
            .put("confidence", 0.0)
            .put("confidence_label", "review")
            .put("verdict", "ambiguous")
            .put("reason", "coarse_crossing_fine_review")
            .put("selection", "included")
            .put("trajectory", JSONArray())
            .put("algorithm_version", "analysis-contract-v1")
            .put("evidence_source", "android_coarse_crossing")
    }

    private fun coarseRoi(hoop: JSONObject): JSONObject {
        val left = (hoop.optDouble("left", 0.0) - 0.20).coerceIn(0.0, 1.0)
        val top = (hoop.optDouble("top", 0.0) - 0.30).coerceIn(0.0, 1.0)
        val right = (hoop.optDouble("right", 1.0) + 0.20).coerceIn(0.0, 1.0)
        val bottom = (hoop.optDouble("bottom", 1.0) + 0.30).coerceIn(0.0, 1.0)
        return JSONObject().put("left", left).put("top", top).put("right", right).put("bottom", bottom)
    }

    private fun hasBallNearHoop(response: JSONObject, width: Int, height: Int, hoop: JSONObject): Boolean {
        val detections = response.optJSONArray("detections") ?: return false
        val left = hoop.optDouble("left", 0.0) - 0.16
        val top = hoop.optDouble("top", 0.0) - 0.22
        val right = hoop.optDouble("right", 1.0) + 0.16
        val bottom = hoop.optDouble("bottom", 1.0) + 0.22
        for (index in 0 until detections.length()) {
            val detection = detections.optJSONObject(index) ?: continue
            if (detection.optInt("class_id", -1) != 0) continue
            val centerX = (detection.optDouble("x1") + detection.optDouble("x2")) / 2.0 / width
            val centerY = (detection.optDouble("y1") + detection.optDouble("y2")) / 2.0 / height
            if (centerX in left..right && centerY in top..bottom) return true
        }
        return false
    }

    private fun collectHoopObservations(
        response: JSONObject,
        output: MutableList<JSONObject>,
        width: Int,
        height: Int,
    ) {
        val detections = response.optJSONArray("detections") ?: return
        for (index in 0 until detections.length()) {
            val detection = detections.optJSONObject(index) ?: continue
            if (detection.optInt("class_id", -1) != 1) continue
            output += JSONObject()
                .put("x1", detection.optDouble("x1") / width.coerceAtLeast(1))
                .put("y1", detection.optDouble("y1") / height.coerceAtLeast(1))
                .put("x2", detection.optDouble("x2") / width.coerceAtLeast(1))
                .put("y2", detection.optDouble("y2") / height.coerceAtLeast(1))
        }
    }

    private fun medianCoarseRim(observations: List<JSONObject>): JSONObject? {
        if (observations.isEmpty()) return null
        fun median(values: List<Double>): Double = values.sorted().let {
            if (it.size % 2 == 1) it[it.size / 2]
            else (it[it.size / 2 - 1] + it[it.size / 2]) / 2.0
        }
        val left = observations.map { it.optDouble("x1") }
        val top = observations.map { it.optDouble("y1") }
        val right = observations.map { it.optDouble("x2") }
        val bottom = observations.map { it.optDouble("y2") }
        val x1 = median(left)
        val y1 = median(top)
        val x2 = median(right)
        val y2 = median(bottom)
        return JSONObject()
            .put("left", x1.coerceIn(0.0, 1.0))
            .put("top", y1.coerceIn(0.0, 1.0))
            .put("right", x2.coerceIn(0.0, 1.0))
            .put("bottom", y2.coerceIn(0.0, 1.0))
    }

    /** Converts the detector's hoop box into the compact physical-rim ROI used by PC geometry. */
    private fun detectedRimRoi(response: JSONObject, width: Int, height: Int): Pair<JSONObject, Double>? {
        val detections = response.optJSONArray("detections") ?: return null
        var best: JSONObject? = null
        var confidence = 0.0
        for (index in 0 until detections.length()) {
            val detection = detections.optJSONObject(index) ?: continue
            if (detection.optInt("class_id", -1) != 1) continue
            val candidateConfidence = detection.optDouble("confidence", 0.0)
            if (candidateConfidence > confidence) {
                best = detection
                confidence = candidateConfidence
            }
        }
        val hoop = best ?: return null
        val left = hoop.optDouble("x1") / width
        val top = hoop.optDouble("y1") / height
        val right = hoop.optDouble("x2") / width
        val bottom = hoop.optDouble("y2") / height
        val boxWidth = (right - left).coerceAtLeast(0.002)
        val boxHeight = (bottom - top).coerceAtLeast(0.002)
        val centerX = (left + right) / 2.0
        // Keep the same detector-box -> rim-plane conversion as the desktop
        // `hoop_bbox_to_rim_roi` implementation.
        val rimY = top + boxHeight * 0.50 - boxHeight * 0.28
        val rimWidth = boxWidth
        val rimHeight = boxHeight * 0.45
        return JSONObject()
            .put("left", (centerX - rimWidth / 2).coerceIn(0.0, 1.0))
            .put("top", (rimY - rimHeight / 2).coerceIn(0.0, 1.0))
            .put("right", (centerX + rimWidth / 2).coerceIn(0.0, 1.0))
            .put("bottom", (rimY + rimHeight / 2).coerceIn(0.0, 1.0))
            .let { it to confidence }
    }

    private fun fineTimesAround(seeds: List<Long>, startMs: Long, endMs: Long, fps: Double): List<Long> {
        val ranges = seeds.map { max(startMs, it - COARSE_WINDOW_MS) to min(endMs, it + COARSE_WINDOW_MS) }
            .sortedBy { it.first }
        val merged = mutableListOf<Pair<Long, Long>>()
        for (range in ranges) {
            val previous = merged.lastOrNull()
            if (previous != null && range.first <= previous.second) {
                merged[merged.lastIndex] = previous.first to max(previous.second, range.second)
            } else {
                merged += range
            }
        }
        return merged.flatMap { sampleTimes(it.first, it.second, fps) }.distinct().sorted()
    }

    private fun sampleTimes(startMs: Long, endMs: Long, fps: Double): List<Long> {
        val count = max(1, kotlin.math.ceil((endMs - startMs) * fps / 1000.0 - 1e-9).toInt())
        return (0 until count)
            .map { startMs + round(it * 1000.0 / fps).toLong() }
            .filter { it < endMs }
            .distinct()
    }

    private fun fullRoi() = JSONObject()
        .put("left", 0.0).put("top", 0.0).put("right", 1.0).put("bottom", 1.0)

    private fun nanosToMs(value: Long): Long = TimeUnit.NANOSECONDS.toMillis(value)

    private fun formatFps(frames: Int, nanos: Long): String {
        if (frames <= 0 || nanos <= 0L) return "0.00"
        return String.format(Locale.US, "%.2f", frames * 1_000_000_000.0 / nanos)
    }

    private fun updateProgress(stage: String, progress: Double, processed: Int, total: Int, message: String) {
        val event = mapOf<String, Any?>(
            "stage" to stage,
            "progress" to progress.coerceIn(0.0, 1.0),
            "processedFrames" to processed,
            "totalFrames" to total,
            "message" to message,
        )
        synchronized(this) {
            state.put("stage", stage).put("progress", progress).put("processed", processed).put("total", total)
            state.put("message", message)
            persistState()
            listener?.onProgress(event)
        }
    }

    private fun complete(result: Map<String, Any?>) {
        synchronized(this) {
            state.put("status", "completed").put("result", JSONObject(result))
            persistState()
            listener?.onComplete(result)
            pendingResult?.success(result)
            pendingResult = null
        }
    }

    private fun fail(code: String, message: String, cancelled: Boolean) {
        synchronized(this) {
            state.put("status", if (cancelled) "cancelled" else "failed")
                .put("errorCode", code)
                .put("errorMessage", message)
            persistState()
            listener?.onError(code, message)
            pendingResult?.error(code, message)
            pendingResult = null
        }
    }

    private fun persistState() {
        val appContext = context ?: return
        runCatching { File(appContext.filesDir, STATE_FILE).writeText(state.toString()) }
    }

    private fun readState(appContext: Context): JSONObject? = runCatching {
        JSONObject(File(appContext.filesDir, STATE_FILE).takeIf { it.isFile }?.readText() ?: return null)
    }.getOrNull()

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

    private object MediaDuration {
        fun read(path: String, fallback: Long): Long {
            val retriever = android.media.MediaMetadataRetriever()
            return try {
                retriever.setDataSource(path)
                retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: fallback
            } finally {
                retriever.release()
            }
        }
    }
}
