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

    @JvmStatic
    external fun freeSession(session: Long)
}
