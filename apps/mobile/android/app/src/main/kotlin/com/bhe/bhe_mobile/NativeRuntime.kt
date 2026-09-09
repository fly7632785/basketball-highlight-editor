package com.bhe.bhe_mobile

import android.util.Log
import java.io.File

object NativeRuntime {
    private const val TAG = "BHE-NativeRuntime"

    private val loadResult: Pair<Boolean, String?> = try {
            System.loadLibrary("bhe_runtime_jni")
            true to null
        } catch (error: UnsatisfiedLinkError) {
            false to (error.message ?: error.toString())
        }

    val available: Boolean = loadResult.first
    val loadError: String? = loadResult.second

    @Volatile
    private var onnxLoadResult: Pair<Boolean, String?>? = null

    /**
     * Android's linker does not reliably make a library loaded by an absolute
     * path discoverable to a second native loader. Load ORT first so ort's
     * dynamic loader can resolve the already-installed library consistently.
     */
    @JvmStatic
    fun ensureOnnxLoaded(path: String): Boolean {
        onnxLoadResult?.let { return it.first }
        synchronized(this) {
            onnxLoadResult?.let { return it.first }
            val file = File(path)
            val result = if (!available) {
                false to (loadError ?: "JNI runtime is unavailable")
            } else if (!file.isFile) {
                false to "ONNX library does not exist: $path"
            } else {
                try {
                    System.load(file.absolutePath)
                    true to null
                } catch (error: UnsatisfiedLinkError) {
                    false to (error.message ?: error.toString())
                }
            }
            onnxLoadResult = result
            Log.i(TAG, "load ONNX path=$path exists=${file.isFile} bytes=${if (file.isFile) file.length() else 0} result=${result.first} error=${result.second ?: "none"}")
            return result.first
        }
    }

    @JvmStatic
    external fun initializeOnnx(libraryPath: String?): Boolean

    @JvmStatic
    external fun createSession(config: String): Long

    @JvmStatic
    external fun sessionInfo(session: Long): String

    @JvmStatic
    external fun pushFrame(session: Long, frame: String): String

    /**
     * Fast path: sends raw RGBA pixels directly to the Rust runtime.
     * Eliminates JPEG compression + base64 encoding (+33% size) + JSON
     * serialization overhead. Expected 3-5x speedup per frame.
     *
     * [rgba] must contain width * height * 4 bytes in row-major order.
     */
    @JvmStatic
    external fun pushFrameRaw(
        session: Long,
        timeMs: Long,
        width: Int,
        height: Int,
        rgba: ByteArray,
    ): String

    /**
     * Fastest Android path: passes an RGBA_8888 Bitmap's locked pixels to JNI.
     * JNI supplies the native row stride to Rust and no Kotlin pixel buffer is allocated.
     */
    @JvmStatic
    external fun pushFrameBitmap(
        session: Long,
        timeMs: Long,
        bitmap: android.graphics.Bitmap,
    ): String

    @JvmStatic
    external fun pushFrameYuv(
        session: Long,
        timeMs: Long,
        width: Int,
        height: Int,
        y: java.nio.ByteBuffer,
        yOffset: Int,
        yLength: Int,
        yRowStride: Int,
        yPixelStride: Int,
        u: java.nio.ByteBuffer,
        uOffset: Int,
        uLength: Int,
        uRowStride: Int,
        uPixelStride: Int,
        v: java.nio.ByteBuffer,
        vOffset: Int,
        vLength: Int,
        vRowStride: Int,
        vPixelStride: Int,
        rotationDegrees: Int,
    ): String

    @JvmStatic
    external fun freeSession(session: Long)

    @JvmStatic
    external fun finishSession(session: Long): String
}
