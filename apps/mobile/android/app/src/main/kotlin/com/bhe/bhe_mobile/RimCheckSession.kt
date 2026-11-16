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
        val modelPaths = listOf(
            sourceModelPath, config.optString("model_path"),
            config.optString("optimized_model_path"), config.optString("execution_provider_backend"),
        )
        val firstError = safeFailure(creationError(), modelPaths)
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
        val cpuError = safeFailure(creationError(), modelPaths)
        val message = "Rust Runtime 无法加载篮筐复核模型：$provider: $firstError; CPU: $cpuError"
        log(message)
        throw IllegalStateException(message)
    }

    private val filePath = Regex("""(["'])([^"'\r\n]*[/\\][^"'\r\n]*)\1|(?:[A-Za-z]:)?[^\s"'<>:;,()\[\]{}]*[/\\][^\s"'<>:;,()\[\]{}]+""")

    private fun safeFailure(value: String, modelPaths: List<String>): String {
        fun basename(path: String) = path.trimEnd('/', '\\').substringAfterLast('/').substringAfterLast('\\')
        var safe = value
        // Known model/cache paths may contain spaces without quotes in ORT errors.
        modelPaths.filter { '/' in it || '\\' in it }.sortedByDescending { it.length }.forEach {
            safe = safe.replace(it, basename(it))
        }
        return filePath.replace(safe) { match ->
            val quote = match.groups[1]?.value.orEmpty()
            quote + basename(match.groups[2]?.value ?: match.value) + quote
        }.replace(Regex("[\r\n\t]+"), " ").ifBlank { "native session creation returned 0" }
    }
}
