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
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val tag = "BHE-Analysis"
    private val mediaChannelName = "com.bhe.bhe/mobile_media"
    private val analysisChannelName = "com.bhe.bhe/mobile_analysis"
    private val progressChannelName = "com.bhe.bhe/mobile_analysis_progress"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val analysisCancelled = AtomicBoolean(false)
    private var analysisThread: Thread? = null
    private var progressSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(true)
                    "exportClip" -> exportClip(call, result)
                    "saveToLibrary" -> saveToLibrary(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, analysisChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "analyzeVideo" -> analyzeVideo(call, result)
                    "cancelAnalysis" -> {
                        analysisCancelled.set(true)
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

    private fun analyzeVideo(call: MethodCall, result: MethodChannel.Result) {
        Log.i(tag, "analyzeVideo request received")
        if (analysisThread?.isAlive == true) {
            Log.w(tag, "analysis rejected: another task is still running")
            result.error("ANALYSIS_BUSY", "已有分析任务正在运行", null)
            return
        }
        if (!NativeRuntime.available) {
            Log.e(tag, "native runtime unavailable: ${NativeRuntime.loadError}")
            result.error(
                "NATIVE_RUNTIME_UNAVAILABLE",
                "当前 Android 原生 Runtime 加载失败：${NativeRuntime.loadError ?: "未知错误"}",
                null
            )
            return
        }
        val videoPath = call.argument<String>("videoPath")
        val modelPath = call.argument<String>("modelPath")
        val startMs = call.argument<Int>("startMs") ?: 0
        val endMs = call.argument<Int>("endMs") ?: 0
        val beforeMs = call.argument<Int>("beforeMs") ?: 6000
        val afterMs = call.argument<Int>("afterMs") ?: 3000
        val fps = (call.argument<Double>("fps") ?: 3.0).coerceIn(1.0, 10.0)
        val hoopRoi = call.argument<Map<String, Any>>("hoopRoi")
        val netRoi = call.argument<Map<String, Any>>("netRoi")
        if (videoPath == null || modelPath == null || hoopRoi == null || netRoi == null || endMs <= startMs) {
            Log.e(tag, "invalid arguments: videoPath=$videoPath modelPath=$modelPath startMs=$startMs endMs=$endMs")
            result.error("INVALID_ARGUMENT", "分析参数无效", null)
            return
        }

        analysisCancelled.set(false)
        analysisThread = Thread {
            var session = 0L
            var framePipeline: FramePipeline? = null
            val retriever = MediaMetadataRetriever()
            try {
                Log.i(tag, "analysis thread started video=$videoPath model=$modelPath range=${startMs}..${endMs}ms fps=$fps")
                emitProgress("validateInput", 0.03, 0, 0, "正在读取视频信息")
                Log.i(tag, "setDataSource start")
                retriever.setDataSource(videoPath)
                Log.i(tag, "setDataSource success")
                val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: endMs.toLong()
                val actualEndMs = endMs.toLong().coerceAtMost(duration)
                val intervalMs = (1000.0 / fps).toLong().coerceAtLeast(1L)
                val frameWindowMs = (actualEndMs - startMs).coerceAtLeast(1L)
                val totalFrames = ((frameWindowMs + intervalMs - 1L) / intervalMs).toInt().coerceAtLeast(1)
                Log.i(tag, "video metadata duration=${duration}ms actualEnd=${actualEndMs}ms totalFrames=$totalFrames interval=${intervalMs}ms")
                emitProgress("prepareProxy", 0.05, 0, totalFrames, "正在加载本地模型")
                val config = JSONObject()
                    .put("model_path", modelPath)
                    .put("hoop_roi", JSONObject(hoopRoi))
                    .put("net_roi", JSONObject(netRoi))
                    .put("duration_ms", duration)
                    .put("confidence_threshold", 0.10)
                    .put("clip_before_ms", beforeMs)
                    .put("clip_after_ms", afterMs)
                    .put("model_size", 640) // match ONNX export resolution
                val onnxPath = File(applicationInfo.nativeLibraryDir, "libonnxruntime.so").absolutePath
                Log.i(tag, "initializeOnnx start path=$onnxPath exists=${File(onnxPath).isFile}")
                if (!File(onnxPath).isFile || !NativeRuntime.initializeOnnx(onnxPath)) {
                    throw IllegalStateException("ONNX Runtime 初始化失败：Android 原生推理库未正确安装或无法加载")
                }
                Log.i(tag, "initializeOnnx success")
                Log.i(tag, "createSession start modelExists=${File(modelPath).isFile} modelBytes=${File(modelPath).length()}")
                emitProgress("prepareProxy", 0.06, 0, totalFrames, "正在加载本地模型")
                val runtimeExecutor = Executors.newSingleThreadExecutor()
                val runtimeFuture = runtimeExecutor.submit<Long> {
                    NativeRuntime.createSession(config.toString())
                }
                var waitedSeconds = 0
                try {
                    while (true) {
                        try {
                            session = runtimeFuture.get(1, TimeUnit.SECONDS)
                            break
                        } catch (_: TimeoutException) {
                            waitedSeconds++
                            if (waitedSeconds % 5 == 0) {
                                emitProgress(
                                    "prepareProxy",
                                    0.06,
                                    0,
                                    totalFrames,
                                    if (analysisCancelled.get()) "正在停止模型加载" else "正在加载本地模型（已等待 ${waitedSeconds} 秒）",
                                )
                            }
                        }
                    }
                } finally {
                    runtimeExecutor.shutdown()
                }
                if (analysisCancelled.get()) {
                    if (session != 0L) {
                        NativeRuntime.freeSession(session)
                        session = 0L
                    }
                    throw InterruptedException("分析已取消")
                }
                Log.i(tag, "createSession returned session=$session")
                if (session == 0L) throw IllegalStateException("Rust Runtime 无法加载模型或 ONNX Runtime")
                emitProgress("prepareProxy", 0.05, 0, totalFrames, "正在准备本地分析")

                var lastResponse = JSONObject().put("candidates", JSONArray())
                val timestampsUs = ArrayList<Long>(totalFrames)
                var targetMs = startMs.toLong()
                while (targetMs < actualEndMs) {
                    timestampsUs.add(targetMs * 1000L)
                    targetMs += intervalMs
                }
                var processed = 0
                var inferenceNanos = 0L
                val frameProcessingStartedAt = System.nanoTime()
                val pipeline = FramePipeline(videoPath).also {
                    it.prepare(timestampsUs.first())
                }
                framePipeline = pipeline
                pipeline.decodeFrames(
                    timestampsUs = timestampsUs,
                    shouldCancel = { analysisCancelled.get() },
                ) { bitmap, timestampUs ->
                    val timeMs = timestampUs / 1000L
                    val width = bitmap.width
                    val height = bitmap.height
                    try {
                        val rgba = bitmapToRgba(bitmap)
                        val inferenceStartedAt = System.nanoTime()
                        val responseJson = NativeRuntime.pushFrameRaw(
                            session, timeMs, width, height, rgba
                        )
                        inferenceNanos += System.nanoTime() - inferenceStartedAt
                        lastResponse = JSONObject(responseJson)
                        lastResponse.optString("error").takeIf { it.isNotEmpty() }?.let { throw IllegalStateException(it) }
                    } finally {
                        bitmap.recycle()
                    }
                    processed++
                    if (processed == 1) Log.i(tag, "first frame inference success (raw path ${width}x${height})")
                    if (processed % 30 == 0) Log.i(tag, "frame progress=$processed/$totalFrames timeMs=$timeMs")
                    if (processed == 1 || processed % 3 == 0) {
                        emitProgress("refineCandidates", 0.05 + (processed.toDouble() / totalFrames * 0.90), processed, totalFrames, "正在分析视频帧")
                    }
                }
                if (analysisCancelled.get()) throw InterruptedException("分析已取消")
                if (processed == 0) throw IllegalStateException("无法从视频解码分析帧")
                emitProgress("persistCandidates", 0.98, processed, totalFrames, "正在写入分析结果")
                val response = jsonObjectToMap(lastResponse)
                val processingNanos = System.nanoTime() - frameProcessingStartedAt
                val processingMs = TimeUnit.NANOSECONDS.toMillis(processingNanos)
                val inferenceMs = TimeUnit.NANOSECONDS.toMillis(inferenceNanos)
                val decodeMs = (processingMs - inferenceMs).coerceAtLeast(0)
                val effectiveFps = processed * 1_000.0 / processingMs.coerceAtLeast(1)
                Log.i(
                    tag,
                    "analysis metrics: frames=$processed/$totalFrames totalMs=$processingMs " +
                        "decodeMs=$decodeMs inferenceMs=$inferenceMs effectiveFps=${"%.2f".format(java.util.Locale.US, effectiveFps)} " +
                        "candidates=${lastResponse.optJSONArray(\"candidates\")?.length() ?: 0}",
                )
                Log.i(tag, "analysis completed processed=$processed candidates=${lastResponse.optJSONArray("candidates")?.length() ?: 0}")
                mainHandler.post { result.success(response) }
            } catch (_: InterruptedException) {
                Log.i(tag, "analysis cancelled")
                mainHandler.post { result.error("ANALYSIS_CANCELLED", "分析已取消", null) }
            } catch (error: Exception) {
                Log.e(tag, "analysis failed: ${error.stackTraceToString()}")
                mainHandler.post { result.error("ANALYSIS_FAILED", error.message ?: "移动端分析失败", null) }
            } finally {
                if (session != 0L) NativeRuntime.freeSession(session)
                framePipeline?.release()
                retriever.release()
                Log.i(tag, "analysis thread finished")
                analysisThread = null
            }
        }.also { it.start() }
    }

    /**
     * Extracts raw RGBA pixels from a Bitmap as a ByteArray.
     * Each pixel is 4 bytes (R, G, B, A) in row-major order.
     * This avoids the JPEG→base64→JSON→base64→JPEG roundtrip entirely.
     */
    private fun bitmapToRgba(bitmap: Bitmap): ByteArray {
        val width = bitmap.width
        val height = bitmap.height
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        val rgba = ByteArray(width * height * 4)
        var index = 0
        for (pixel in pixels) {
            rgba[index++] = (pixel shr 16 and 0xFF).toByte() // R
            rgba[index++] = (pixel shr 8 and 0xFF).toByte()  // G
            rgba[index++] = (pixel and 0xFF).toByte()         // B
            rgba[index++] = (pixel shr 24 and 0xFF).toByte()  // A
        }
        return rgba
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

    private fun exportClip(call: MethodCall, result: MethodChannel.Result) {
        val inputPath = call.argument<String>("inputPath")
        val outputPath = call.argument<String>("outputPath")
        val startMs = call.argument<Int>("startMs")
        val endMs = call.argument<Int>("endMs")
        if (inputPath == null || outputPath == null || startMs == null || endMs == null || endMs <= startMs) {
            result.error("INVALID_ARGUMENT", "视频片段参数无效", null)
            return
        }
        Thread {
            try {
                File(outputPath).parentFile?.mkdirs()
                File(outputPath).delete()
                val extractor = MediaExtractor()
                extractor.setDataSource(inputPath)
                val trackMap = mutableMapOf<Int, Int>()
                val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                for (index in 0 until extractor.trackCount) {
                    val format = extractor.getTrackFormat(index)
                    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                        trackMap[index] = muxer.addTrack(format)
                        extractor.selectTrack(index)
                    }
                }
                if (trackMap.isEmpty()) throw IllegalStateException("视频没有可导出的音视频轨道")
                muxer.start()
                val endUs = endMs.toLong() * 1000L
                extractor.seekTo(startMs.toLong() * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                val clipStartUs = extractor.sampleTime
                if (clipStartUs < 0L) throw IllegalStateException("无法定位视频片段起点")
                val buffer = ByteBuffer.allocate(16 * 1024 * 1024)
                val info = android.media.MediaCodec.BufferInfo()
                while (true) {
                    val sourceTrack = extractor.sampleTrackIndex
                    if (sourceTrack < 0 || extractor.sampleTime >= endUs) break
                    val muxTrack = trackMap[sourceTrack]
                    if (muxTrack != null) {
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size <= 0) break
                        info.offset = 0
                        info.size = size
                        info.presentationTimeUs = (extractor.sampleTime - clipStartUs).coerceAtLeast(0L)
                        info.flags = extractor.sampleFlags
                        muxer.writeSampleData(muxTrack, buffer, info)
                    }
                    extractor.advance()
                }
                muxer.stop()
                muxer.release()
                extractor.release()
                mainHandler.post { result.success(outputPath) }
            } catch (error: Exception) {
                mainHandler.post { result.error("EXPORT_FAILED", error.message, null) }
            }
        }.start()
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
