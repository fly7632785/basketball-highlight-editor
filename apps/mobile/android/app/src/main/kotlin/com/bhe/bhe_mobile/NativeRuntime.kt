package com.bhe.bhe_mobile

import android.util.Log
import android.os.Build
import java.io.File

object NativeRuntime {
    private const val TAG = "BHE-NativeRuntime"

    @Volatile
    var available: Boolean = false
        private set

    @Volatile
    var loadError: String? = null
        private set

    @Volatile
    private var loadAttempted = false

    /**
     * Load the Rust runtime through absolute paths. Android's linker can fail
     * to resolve a custom JNI library's DT_NEEDED dependency on some devices
     * even when both files are present in the APK. Loading the dependency
     * first makes the order explicit and gives us an actionable error.
     */
    @JvmStatic
    fun ensureLoaded(nativeLibraryDir: String): Boolean {
        if (available) return true
        synchronized(this) {
            if (available) return true
            if (loadAttempted) return false
            loadAttempted = true

            val directory = File(nativeLibraryDir)
            val runtime = File(directory, "libbhe_runtime.so")
            val jni = File(directory, "libbhe_runtime_jni.so")
            val missing = listOf(runtime, jni).filterNot(File::isFile)
            if (missing.isNotEmpty()) {
                loadError = "Android native libraries are missing: ${missing.joinToString { it.name }}; " +
                    "nativeLibraryDir=$nativeLibraryDir; supportedAbis=${Build.SUPPORTED_ABIS.joinToString()}"
                Log.e(TAG, loadError!!)
                return false
            }

            try {
                System.load(runtime.absolutePath)
                System.load(jni.absolutePath)
                available = true
                loadError = null
                Log.i(TAG, "loaded runtime=${runtime.absolutePath} jni=${jni.absolutePath}")
            } catch (error: UnsatisfiedLinkError) {
                loadError = "Android native runtime load failed: ${error.message ?: error}; " +
                    "nativeLibraryDir=$nativeLibraryDir; supportedAbis=${Build.SUPPORTED_ABIS.joinToString()}"
                Log.e(TAG, loadError!!, error)
            }
            return available
        }
    }

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
            val result = if (!ensureLoaded(file.parentFile?.absolutePath ?: "")) {
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
