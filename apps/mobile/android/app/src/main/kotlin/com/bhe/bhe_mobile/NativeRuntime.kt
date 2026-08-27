package com.bhe.bhe_mobile

object NativeRuntime {
    private val loadResult: Pair<Boolean, String?> = try {
            System.loadLibrary("bhe_runtime_jni")
            true to null
        } catch (error: UnsatisfiedLinkError) {
            false to (error.message ?: error.toString())
        }

    val available: Boolean = loadResult.first
    val loadError: String? = loadResult.second

    @JvmStatic
    external fun initializeOnnx(libraryPath: String?): Boolean

    @JvmStatic
    external fun createSession(config: String): Long

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

    @JvmStatic
    external fun freeSession(session: Long)
}
