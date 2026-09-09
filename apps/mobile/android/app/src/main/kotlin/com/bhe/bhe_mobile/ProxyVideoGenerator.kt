package com.bhe.bhe_mobile

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaMetadataRetriever
import android.opengl.EGL14
import android.opengl.EGLExt
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.io.File
import java.security.MessageDigest
import kotlin.math.max
import kotlin.math.roundToInt

object ProxyVideoGenerator {
    data class Result(
        val file: File,
        val width: Int,
        val height: Int,
        val durationMs: Long,
        val rotationDegrees: Int,
        val cached: Boolean,
    )

    private const val CACHE_DIR = "analysis/proxies"
    private const val CACHE_VERSION = 3
    private const val MAX_WIDTH = 960
    private const val MAX_HEIGHT = 720
    // Keep the proxy cadence identical to the desktop standard pipeline.
    // The coarse scan requests one inference frame per proxy frame.
    private const val FPS = 5
    private const val BITRATE = 2_000_000

    fun createOrGet(
        context: Context,
        sourcePath: String,
        startMs: Long,
        endMs: Long,
        shouldCancel: () -> Boolean,
        onProgress: (Double) -> Unit,
    ): Result {
        val source = File(sourcePath)
        require(source.isFile) { "视频文件不存在" }
        val probe = probe(sourcePath)
        val outputSize = fitSize(probe.width, probe.height, MAX_WIDTH, MAX_HEIGHT)
        val cacheKey = sha256(
            listOf(
                source.absolutePath,
                source.length(),
                source.lastModified(),
                startMs,
                endMs,
                outputSize.first,
                outputSize.second,
                FPS,
                probe.rotation,
                CACHE_VERSION,
            ).joinToString("|")
        )
        val directory = File(context.filesDir, CACHE_DIR).also { it.mkdirs() }
        val output = File(directory, "$cacheKey.mp4")
        val metadata = File(directory, "$cacheKey.json")
        if (output.isFile && output.length() > 0L && metadata.isFile) {
            val actualDurationMs = duration(output)
            if (actualDurationMs > 0L) {
                return Result(output, outputSize.first, outputSize.second, actualDurationMs, probe.rotation, true)
            }
            output.delete()
            metadata.delete()
        }
        val temporary = File(directory, ".$cacheKey.part.mp4")
        temporary.delete()
        try {
            encode(
                sourcePath,
                temporary,
                startMs * 1000L,
                endMs * 1000L,
                outputSize.first,
                outputSize.second,
                probe.rotation,
                shouldCancel,
                onProgress,
            )
            if (shouldCancel()) throw InterruptedException("分析已取消")
            require(temporary.isFile && temporary.length() > 0L) { "代理视频生成失败" }
            temporary.renameTo(output)
            val actualDurationMs = duration(output)
            require(actualDurationMs >= (endMs - startMs - 1_000L).coerceAtLeast(1L)) {
                "代理视频时长不完整：${actualDurationMs}ms/${endMs - startMs}ms"
            }
            metadata.writeText(
                "{\"version\":$CACHE_VERSION,\"width\":${outputSize.first},\"height\":${outputSize.second},\"fps\":$FPS,\"start_ms\":$startMs,\"end_ms\":$endMs,\"rotation\":${probe.rotation}}",
            )
            return Result(output, outputSize.first, outputSize.second, actualDurationMs, probe.rotation, false)
        } finally {
            temporary.delete()
        }
    }

    private data class Probe(val width: Int, val height: Int, val rotation: Int)

    private fun probe(path: String): Probe {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                    return Probe(
                        format.getInteger(MediaFormat.KEY_WIDTH),
                        format.getInteger(MediaFormat.KEY_HEIGHT),
                        format.getInteger(MediaFormat.KEY_ROTATION, 0),
                    )
                }
            }
            throw IllegalStateException("未找到视频轨道")
        } finally {
            extractor.release()
        }
    }

    private fun duration(file: File): Long {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        } finally {
            retriever.release()
        }
    }

    private fun fitSize(width: Int, height: Int, maxWidth: Int, maxHeight: Int): Pair<Int, Int> {
        val scale = minOf(1.0, maxWidth.toDouble() / width, maxHeight.toDouble() / height)
        var outputWidth = (width * scale).roundToInt().coerceAtLeast(2)
        var outputHeight = (height * scale).roundToInt().coerceAtLeast(2)
        outputWidth -= outputWidth % 2
        outputHeight -= outputHeight % 2
        return max(2, outputWidth) to max(2, outputHeight)
    }

    private fun encode(
        sourcePath: String,
        outputPath: File,
        startUs: Long,
        endUs: Long,
        width: Int,
        height: Int,
        rotation: Int,
        shouldCancel: () -> Boolean,
        onProgress: (Double) -> Unit,
    ) {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var decoderSurface: Surface? = null
        var encoderInputSurface: Surface? = null
        var muxer: MediaMuxer? = null
        var egl: EglRenderer? = null
        var muxerTrack = -1
        var muxerStarted = false
        try {
            extractor.setDataSource(sourcePath)
            var format: MediaFormat? = null
            for (index in 0 until extractor.trackCount) {
                val candidate = extractor.getTrackFormat(index)
                if (candidate.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                    extractor.selectTrack(index)
                    format = candidate
                    break
                }
            }
            val sourceFormat = format ?: throw IllegalStateException("未找到视频轨道")
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val encoderFormat = MediaFormat.createVideoFormat("video/avc", width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
                setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            }
            encoder = MediaCodec.createEncoderByType("video/avc")
            encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoderInputSurface = encoder.createInputSurface()
            encoder.start()

            egl = EglRenderer(
                encoderInputSurface,
                width,
                height,
                sourceFormat.getInteger(MediaFormat.KEY_WIDTH),
                sourceFormat.getInteger(MediaFormat.KEY_HEIGHT),
            )
            decoderSurface = egl.decoderSurface
            decoder = MediaCodec.createDecoderByType(sourceFormat.getString(MediaFormat.KEY_MIME)!!)
            decoder.configure(sourceFormat, decoderSurface, null, 0)
            decoder.start()

            muxer = MediaMuxer(outputPath.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4).also {
                if (rotation != 0) it.setOrientationHint(rotation)
            }
            val decoderInfo = MediaCodec.BufferInfo()
            val startedAt = System.nanoTime()
            val intervalUs = 1_000_000L / FPS
            var nextTargetUs = startUs
            var inputDone = false
            var outputDone = false
            var lastProgress = -1.0
            while (!outputDone) {
                if (shouldCancel()) throw InterruptedException("分析已取消")
                if (!inputDone) {
                    val inputIndex = decoder.dequeueInputBuffer(10_000)
                    if (inputIndex >= 0) {
                        val inputBuffer = decoder.getInputBuffer(inputIndex)!!
                        val sampleTime = extractor.sampleTime
                        val sampleSize = if (sampleTime >= endUs || sampleTime < 0L) {
                            -1
                        } else {
                            extractor.readSampleData(inputBuffer, 0)
                        }
                        if (sampleSize < 0) {
                            decoder.queueInputBuffer(inputIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(inputIndex, 0, sampleSize, sampleTime, extractor.sampleFlags)
                            extractor.advance()
                        }
                    }
                }
                val outputIndex = decoder.dequeueOutputBuffer(decoderInfo, 10_000)
                when {
                    outputIndex >= 0 -> {
                        val pts = decoderInfo.presentationTimeUs
                        val render = pts >= nextTargetUs && pts < endUs
                        decoder.releaseOutputBuffer(outputIndex, render)
                        if (render) {
                            egl.awaitFrame()
                            val outputPtsUs = nextTargetUs - startUs
                            egl.render(outputPtsUs)
                            nextTargetUs += intervalUs
                            while (nextTargetUs <= pts) nextTargetUs += intervalUs
                            drainEncoder(encoder, muxer, muxerStarted, muxerTrack).also {
                                muxerStarted = it.started
                                muxerTrack = it.track
                            }
                            val progress = ((pts - startUs).toDouble() / (endUs - startUs).coerceAtLeast(1L)).coerceIn(0.0, 1.0)
                            if (progress - lastProgress >= 0.01) {
                                onProgress(progress)
                                lastProgress = progress
                            }
                        } else {
                            drainEncoder(encoder, muxer, muxerStarted, muxerTrack).also {
                                muxerStarted = it.started
                                muxerTrack = it.track
                            }
                        }
                        if ((decoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) outputDone = true
                    }
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                }
            }
            encoder.signalEndOfInputStream()
            var encoderDone = false
            while (!encoderDone) {
                val result = drainEncoder(encoder, muxer, muxerStarted, muxerTrack, true)
                muxerStarted = result.started
                muxerTrack = result.track
                encoderDone = result.endOfStream
                if (!encoderDone && shouldCancel()) throw InterruptedException("分析已取消")
            }
            onProgress(1.0)
            @Suppress("UNUSED_VARIABLE") val elapsedMs = (System.nanoTime() - startedAt) / 1_000_000L
        } finally {
            decoder?.stopSafely()
            decoder?.release()
            egl?.release()
            encoderInputSurface?.release()
            encoder?.stopSafely()
            encoder?.release()
            if (muxerStarted) {
                runCatching { muxer?.stop() }
            }
            muxer?.release()
            extractor.release()
        }
    }

    private data class DrainResult(val started: Boolean, val track: Int, val endOfStream: Boolean = false)

    private fun drainEncoder(
        encoder: MediaCodec?,
        muxer: MediaMuxer?,
        started: Boolean,
        track: Int,
        endOfInput: Boolean = false,
    ): DrainResult {
        if (encoder == null || muxer == null) return DrainResult(started, track)
        var muxerStarted = started
        var muxerTrack = track
        val info = MediaCodec.BufferInfo()
        var endOfStream = false
        while (true) {
            val index = encoder.dequeueOutputBuffer(info, if (endOfInput) 10_000 else 0)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    check(!muxerStarted)
                    muxerTrack = muxer.addTrack(encoder.outputFormat)
                    muxer.start()
                    muxerStarted = true
                }
                index >= 0 -> {
                    val buffer = encoder.getOutputBuffer(index)
                    if (buffer != null && info.size > 0 && muxerStarted && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer.writeSampleData(muxerTrack, buffer, info)
                    }
                    encoder.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        endOfStream = true
                        break
                    }
                }
            }
        }
        return DrainResult(muxerStarted, muxerTrack, endOfStream)
    }

    private fun MediaCodec.stopSafely() {
        try { stop() } catch (_: IllegalStateException) { }
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray())
        .joinToString("") { "%02x".format(it) }

    private class EglRenderer(
        inputSurface: Surface?,
        private val width: Int,
        private val height: Int,
        sourceWidth: Int,
        sourceHeight: Int,
    ) {
        private val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        private val eglSurface: android.opengl.EGLSurface
        private val context: android.opengl.EGLContext
        private val textureId: Int
        private val surfaceTexture: SurfaceTexture
        val decoderSurface: Surface
        private val frameLock = Object()
        private var frameAvailable = false
        private val callbackThread = HandlerThread("BHE-ProxyFrame")
        private val program: Int
        private val positionHandle: Int
        private val texCoordHandle: Int
        private val textureMatrixHandle: Int
        private val vertexBuffer = java.nio.ByteBuffer.allocateDirect(64).order(java.nio.ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(floatArrayOf(-1f, -1f, 0f, 0f, 1f, -1f, 1f, 0f, -1f, 1f, 0f, 1f, 1f, 1f, 1f, 1f))
            position(0)
        }

        init {
            val major = IntArray(1)
            val minor = IntArray(1)
            check(EGL14.eglInitialize(display, major, 0, minor, 0))
            val configAttributes = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                0x3142, 1,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
            val count = IntArray(1)
            check(EGL14.eglChooseConfig(display, configAttributes, 0, configs, 0, 1, count, 0))
            val config = configs[0]!!
            context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
            check(context != EGL14.EGL_NO_CONTEXT)
            eglSurface = EGL14.eglCreateWindowSurface(display, config, inputSurface, intArrayOf(EGL14.EGL_NONE), 0)
            check(eglSurface != EGL14.EGL_NO_SURFACE)
            check(EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context))
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            textureId = textures[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            surfaceTexture = SurfaceTexture(textureId).also {
                it.setDefaultBufferSize(sourceWidth, sourceHeight)
            }
            decoderSurface = Surface(surfaceTexture)
            callbackThread.start()
            surfaceTexture.setOnFrameAvailableListener({
                synchronized(frameLock) {
                    frameAvailable = true
                    frameLock.notifyAll()
                }
            }, Handler(callbackThread.looper))
            program = createProgram(VERTEX_SHADER, FRAGMENT_SHADER)
            positionHandle = GLES20.glGetAttribLocation(program, "aPosition")
            texCoordHandle = GLES20.glGetAttribLocation(program, "aTexCoord")
            textureMatrixHandle = GLES20.glGetUniformLocation(program, "uTextureMatrix")
        }

        fun awaitFrame() {
            synchronized(frameLock) {
                val deadline = System.nanoTime() + 500_000_000L
                while (!frameAvailable && System.nanoTime() < deadline) {
                    frameLock.wait(20L)
                }
                frameAvailable = false
            }
            surfaceTexture.updateTexImage()
        }

        fun render(presentationTimeUs: Long) {
            GLES20.glViewport(0, 0, width, height)
            GLES20.glUseProgram(program)
            vertexBuffer.position(0)
            GLES20.glEnableVertexAttribArray(positionHandle)
            GLES20.glVertexAttribPointer(positionHandle, 2, GLES20.GL_FLOAT, false, 16, vertexBuffer)
            vertexBuffer.position(2)
            GLES20.glEnableVertexAttribArray(texCoordHandle)
            GLES20.glVertexAttribPointer(texCoordHandle, 2, GLES20.GL_FLOAT, false, 16, vertexBuffer)
            val matrix = FloatArray(16)
            surfaceTexture.getTransformMatrix(matrix)
            GLES20.glUniformMatrix4fv(textureMatrixHandle, 1, false, matrix, 0)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glDisableVertexAttribArray(positionHandle)
            GLES20.glDisableVertexAttribArray(texCoordHandle)
            EGLExt.eglPresentationTimeANDROID(display, eglSurface, presentationTimeUs * 1000L)
            check(EGL14.eglSwapBuffers(display, eglSurface))
        }

        fun release() {
            decoderSurface.release()
            surfaceTexture.release()
            GLES20.glDeleteTextures(1, intArrayOf(textureId), 0)
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, eglSurface)
            EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
            callbackThread.quitSafely()
        }

        companion object {
            private const val VERTEX_SHADER = "attribute vec4 aPosition; attribute vec4 aTexCoord; uniform mat4 uTextureMatrix; varying vec2 vTexCoord; void main() { gl_Position = aPosition; vTexCoord = (uTextureMatrix * aTexCoord).xy; }"
            private const val FRAGMENT_SHADER = "#extension GL_OES_EGL_image_external : require\nprecision mediump float; uniform samplerExternalOES sTexture; varying vec2 vTexCoord; void main() { gl_FragColor = texture2D(sTexture, vTexCoord); }"

            private fun createProgram(vertex: String, fragment: String): Int {
                fun compile(type: Int, source: String): Int {
                    val shader = GLES20.glCreateShader(type)
                    GLES20.glShaderSource(shader, source)
                    GLES20.glCompileShader(shader)
                    val status = IntArray(1)
                    GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
                    check(status[0] != 0) { GLES20.glGetShaderInfoLog(shader) }
                    return shader
                }
                val program = GLES20.glCreateProgram()
                GLES20.glAttachShader(program, compile(GLES20.GL_VERTEX_SHADER, vertex))
                GLES20.glAttachShader(program, compile(GLES20.GL_FRAGMENT_SHADER, fragment))
                GLES20.glLinkProgram(program)
                val status = IntArray(1)
                GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
                check(status[0] != 0) { GLES20.glGetProgramInfoLog(program) }
                return program
            }
        }
    }

}
