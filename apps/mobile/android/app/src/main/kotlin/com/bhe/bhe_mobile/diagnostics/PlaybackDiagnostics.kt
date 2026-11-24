package com.bhe.bhe_mobile.diagnostics

import androidx.media3.common.PlaybackException
import androidx.media3.common.util.Log
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlaybackException
import androidx.media3.exoplayer.mediacodec.MediaCodecDecoderException
import androidx.media3.exoplayer.mediacodec.MediaCodecRenderer.DecoderInitializationException

@UnstableApi
internal class PlaybackDiagnostics(
    private val record: (String, Map<String, Any?>) -> Unit,
    private val logcat: Log.Logger = Log.Logger.DEFAULT,
) : Log.Logger by logcat {
    override fun e(tag: String, message: String, throwable: Throwable?) {
        logcat.e(tag, message, throwable)
        // Media3 logs the original Throwable before video_player flattens it for Flutter.
        if (tag != "ExoPlayerImplInternal" || throwable !is ExoPlaybackException ||
            throwable.type != ExoPlaybackException.TYPE_RENDERER ||
            throwable.rendererName != "MediaCodecVideoRenderer"
        ) return

        recordVideoRendererFailure(
            throwable.errorCode, throwable.rendererFormat?.sampleMimeType, throwable.cause,
        )
    }

    internal fun recordVideoRendererFailure(errorCode: Int, mimeType: String?, cause: Throwable?) {
        val causes = generateSequence(cause) { it.cause }.take(8).toList()
        val init = causes.filterIsInstance<DecoderInitializationException>().firstOrNull()
        val runtime = causes.filterIsInstance<MediaCodecDecoderException>().firstOrNull()
        val codec = init?.codecInfo ?: runtime?.codecInfo
        val stage = when (errorCode) {
            PlaybackException.ERROR_CODE_DECODER_INIT_FAILED -> "decoder_init"
            PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED -> "decoder_query"
            PlaybackException.ERROR_CODE_DECODING_FAILED,
            PlaybackException.ERROR_CODE_DECODING_RESOURCES_RECLAIMED -> "decoding"
            else -> "renderer"
        }
        record(
            "playback.video_renderer.failed",
            mapOf(
                "stage" to stage,
                "code" to PlaybackException.getErrorCodeName(errorCode),
                "mime" to (mimeType ?: init?.mimeType ?: codec?.mimeType),
                "codec" to codec?.name,
                "hardware_accelerated" to codec?.hardwareAccelerated,
                "codec_diagnostic" to (init?.diagnosticInfo ?: runtime?.diagnosticInfo),
                // Exception messages and Format.toString() can contain the source URI.
                "cause" to causes.joinToString(":") { it.javaClass.name }.take(300),
            ),
        )
    }
}
