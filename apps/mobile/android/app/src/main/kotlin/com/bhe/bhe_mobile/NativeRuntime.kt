package com.bhe.bhe_mobile

object NativeRuntime {
    val available: Boolean

    init {
        available = try {
            System.loadLibrary("bhe_runtime_jni")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    @JvmStatic
    external fun createSession(config: String): Long

    @JvmStatic
    external fun pushFrame(session: Long, frame: String): String

    @JvmStatic
    external fun freeSession(session: Long)
}
