package com.bhe.bhe_mobile

internal class VideoDecodeException(message: String, cause: Throwable? = null) :
    IllegalStateException(message, cause)

data class FrameDecodeResult(
    val delivered: Int,
    val reachedEos: Boolean,
    val lastFramePtsUs: Long?,
    val missingBeforeEos: Boolean,
)

internal object DecodeWindowPolicy {
    fun isFrameOutput(endOfStream: Boolean, codecConfig: Boolean, size: Int): Boolean =
        !codecConfig && (!endOfStream || size > 0)

    fun requireUsable(
        result: FrameDecodeResult,
        requested: Int,
        windowEndMs: Long,
        durationMs: Long,
        fps: Double,
    ) {
        if (requested > 0 && result.delivered == requested) return
        val lastPtsUs = result.lastFramePtsUs
        val samplePeriodUs = kotlin.math.ceil(1_000_000.0 / fps).toLong()
        val endsAtVideoTail = windowEndMs == durationMs
        // Container duration can include a short audio tail. Accept one
        // missing sample only after EOS, with recent decoded video evidence.
        if (endsAtVideoTail && result.reachedEos && !result.missingBeforeEos &&
            result.delivered > 0 && requested - result.delivered == 1 &&
            lastPtsUs != null && durationMs * 1000L - lastPtsUs <= 2 * samplePeriodUs
        ) return
        throw VideoDecodeException("视频解码不完整：${result.delivered}/$requested 帧")
    }

    fun retryOnCpu(error: Exception, provider: String, cancelled: Boolean): Boolean =
        provider == "qnn" && !cancelled && error !is InterruptedException && error !is VideoDecodeException

    /** Inference callbacks run inside the decoder loop. Preserve their errors
     * so a provider failure remains distinguishable from a codec failure. */
    fun <T> decode(block: (invokeCallback: (() -> Unit) -> Unit) -> T): T {
        var callbackFailure: Exception? = null
        return try {
            block { callback ->
                try {
                    callback()
                } catch (error: Exception) {
                    callbackFailure = error
                    throw error
                }
            }
        } catch (error: Exception) {
            callbackFailure?.let { throw it }
            if (error is InterruptedException || error is VideoDecodeException) throw error
            throw VideoDecodeException("视频解码失败", error)
        }
    }
}
