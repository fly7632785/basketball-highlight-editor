package com.bhe.bhe_mobile.diagnostics

/** No arbitrary exception message, paths or request JSON may cross this API. */
object NativeDiagnosticEvent {
    private val token = Regex("[a-zA-Z0-9_.:-]{1,120}")
    private val keys = setOf(
        "stage", "progress", "processed", "total", "status", "code", "mime", "track",
        "provider", "count", "duration_ms", "available", "cancelled", "threads", "operation",
        // 合并导出的样本数对照（D-L058m）：只有数字和 mime
        "written", "readable", "clips", "tracks", "interval", "samples", "clamped",
        "nonmono", "sync", "pts_first", "pts_last", "clip_start_us", "width", "height",
        "fps", "track_duration_ms",
    )
    private val mime = Regex("(?:audio|video)/[a-zA-Z0-9._+-]{1,100}")
    fun format(event: String, fields: Map<String, Any?> = emptyMap(), error: Throwable? = null): String {
        val name = event.takeIf { token.matches(it) } ?: "native.event"
        val body = StringBuilder(name)
        for ((key, value) in fields) {
            if (key !in keys) continue
            val safe = when (value) {
                is Number, is Boolean -> value.toString()
                is String -> value.takeIf { token.matches(it) || mime.matches(it) }
                else -> null
            }
            if (safe != null) body.append(" $key=$safe")
        }
        if (error != null) {
            val seen = mutableSetOf<Throwable>()
            var cause: Throwable? = error
            var count = 0
            while (cause != null && seen.add(cause) && count++ < 8) {
                body.append(" exception=${cause.javaClass.name}")
                cause = cause.cause
            }
            error.stackTrace.take(30).forEach { frame ->
                // Source basenames are code metadata, never the exception's file argument.
                val source = frame.fileName?.substringAfterLast('/')?.substringAfterLast('\\')?.filter { !it.isISOControl() }?.take(120) ?: "unknown"
                val type = frame.className.takeIf { it.matches(Regex("[a-zA-Z0-9_.$<>-]+")) } ?: "frame"
                val method = frame.methodName.takeIf { it.matches(Regex("[a-zA-Z0-9_.$<>-]+")) } ?: "method"
                body.append("\n  at $type.$method($source:${frame.lineNumber})")
            }
        }
        return body.toString()
    }
}

class LoggingUncaughtHandler(
    private val record: (Throwable) -> Unit,
    private val original: Thread.UncaughtExceptionHandler,
) : Thread.UncaughtExceptionHandler {
    override fun uncaughtException(thread: Thread, error: Throwable) {
        try { record(error) } catch (_: Throwable) { }
        finally { original.uncaughtException(thread, error) }
    }
}
