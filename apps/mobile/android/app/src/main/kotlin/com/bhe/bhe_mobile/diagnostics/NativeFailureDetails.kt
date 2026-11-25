package com.bhe.bhe_mobile.diagnostics

import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.ExportException

/** Interpret known causes; arbitrary exception text never becomes a UI message. */
object NativeFailureDetails {
    // App-owned and Media3 fixed messages only. Vendor exceptions can contain
    // file paths, project titles, or media URLs.
    private val clipMessages = setOf(
        "Asset loader error",
        "Video frame processing error",
        "Muxer error",
        "Unexpected runtime error",
        "Unexpected error",
        "Failed to instantiate extractor.",
        "Failed to stop the muxer",
        "Failed to write sample",
        "无法定位合并片段",
        "合并片段没有可读取的视频样本",
        "杜比视界视频转码失败，无法导出画面。",
        "The source is already portrait. Follow-ball cropping is unnecessary.",
        "The video reader could not decode the portrait samples.",
        "Portrait export did not produce a readable SDR video",
        "Portrait export did not preserve its audio track",
        "Android clip export failed",
    )

    internal fun safeClipMessage(message: String?): String? = message?.takeIf { it in clipMessages }

    @UnstableApi
    internal fun clip(error: Throwable, code: String): Map<String, Any?> {
        val causes = generateSequence(error) { it.cause }.take(8).toList()
        val media3 = causes.filterIsInstance<ExportException>().firstOrNull()
        val message = causes.firstNotNullOfOrNull { safeClipMessage(it.message) } ?: "Android clip export failed"
        return from(error) + mapOf(
            "code" to code,
            "native_error" to if (error is ExportException) {
                "androidx.media3.transformer.ExportException"
            } else error.javaClass.name,
            "error_message" to message,
            "media3_error_code" to media3?.errorCode,
            "media3_error_name" to media3?.getErrorCodeName(),
            "media3_message" to safeClipMessage(media3?.message),
        )
    }

    fun from(error: Throwable): Map<String, Any> {
        val text = (error.message ?: "").lowercase()
        val result = linkedMapOf<String, Any>()
        when {
            "enospc" in text || "no space left" in text -> { result["kind"] = "storage"; result["errno"] = 28 }
            error is SecurityException || "permission denied" in text || "eacces" in text -> { result["kind"] = "permission"; result["errno"] = 13 }
            "muxer" in text || "codec" in text || "decoder" in text || "unsupported" in text -> result["kind"] = "unsupported"
            else -> result["kind"] = "unknown"
        }
        Regex("(?:audio|video)/[a-z0-9._+-]+").find(text)?.value?.let { result["mime"] = it }
        return result
    }
}
