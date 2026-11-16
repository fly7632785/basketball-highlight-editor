package com.bhe.bhe_mobile

import org.json.JSONObject

/** Retry only the rim check, using a portable model and no provider-specific cache. */
internal object RimCheckSession {
    fun create(
        config: JSONObject,
        sourceModelPath: String,
        createSession: (String) -> Long,
        creationError: () -> String,
        log: (String) -> Unit,
    ): Long {
        val session = createSession(config.toString())
        if (session != 0L) return session
        val provider = config.optString("execution_provider", "cpu")
        val firstError = creationError().ifBlank { "native session creation returned 0" }
        log("rim check session failed provider=$provider model_size=${config.optInt("model_size")}: $firstError; retrying CPU")
        // QNN's precompiled context contains accelerator-only operators. CPU
        // must load the original ONNX graph and must not reuse its optimized cache.
        val cpuConfig = JSONObject(config.toString())
            .put("model_path", sourceModelPath)
            .put("execution_provider", "cpu")
            .put("intra_threads", InferenceTuner.CPU_THREADS)
        cpuConfig.remove("optimized_model_path")
        cpuConfig.remove("execution_provider_backend")
        val cpuSession = createSession(cpuConfig.toString())
        if (cpuSession != 0L) {
            log("rim check CPU fallback succeeded; initial provider=$provider cause=$firstError")
            return cpuSession
        }
        val cpuError = creationError().ifBlank { "native session creation returned 0" }
        val message = "Rust Runtime 无法加载篮筐复核模型：$provider: $firstError; CPU: $cpuError"
        log(message)
        throw IllegalStateException(message)
    }
}
