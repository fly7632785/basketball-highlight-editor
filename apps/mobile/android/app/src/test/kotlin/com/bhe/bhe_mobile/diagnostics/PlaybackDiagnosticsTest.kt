package com.bhe.bhe_mobile.diagnostics

import androidx.media3.common.PlaybackException
import androidx.media3.common.util.Log
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.mediacodec.MediaCodecDecoderException
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

@UnstableApi
class PlaybackDiagnosticsTest {
    private val events = mutableListOf<String>()
    private val logcatErrors = mutableListOf<Throwable?>()
    private val logcat = object : Log.Logger by Log.Logger.DEFAULT {
        override fun e(tag: String, message: String, throwable: Throwable?) {
            logcatErrors.add(throwable)
        }
    }
    private val logger = PlaybackDiagnostics(
        { event, fields -> events.add(NativeDiagnosticEvent.format(event, fields)) },
        logcat,
    )

    @Test fun recordsInitializationFailureWithoutMediaPath() {
        val cause = IllegalStateException(
            "content://provider/private.mp4", IOException("/storage/private.mp4"),
        )
        logger.recordVideoRendererFailure(PlaybackException.ERROR_CODE_DECODER_INIT_FAILED, "video/hevc", cause)
        assertEquals(
            "playback.video_renderer.failed stage=decoder_init code=ERROR_CODE_DECODER_INIT_FAILED mime=video/hevc " +
                "cause=java.lang.IllegalStateException:java.io.IOException",
            events.single(),
        )
    }

    @Test fun runtimeFailureIsDistinctAndCauseIsBounded() {
        val cause = (1..10).fold<Int, Throwable>(IOException("private.mp4")) { nested, _ ->
            UnsupportedOperationException("private.mp4", nested)
        }
        val codec = MediaCodecInfo.newInstance(
            "c2.vendor.avc.decoder", "video/avc", "video/avc", null,
            /* hardwareAccelerated= */ true, /* softwareOnly= */ false,
            /* vendor= */ true, /* forceDisableAdaptive= */ false, /* forceSecure= */ false,
        )
        val failure = MediaCodecDecoderException(cause, codec)
        logger.recordVideoRendererFailure(PlaybackException.ERROR_CODE_DECODING_FAILED, null, failure)
        val event = events.single()
        assertTrue(event.contains("stage=decoding code=ERROR_CODE_DECODING_FAILED"))
        assertTrue(event.contains("mime=video/avc codec=c2.vendor.avc.decoder hardware_accelerated=true"))
        assertEquals(300, event.substringAfter("cause=").length)
        assertFalse(event.contains("private.mp4"))
    }

    @Test fun unrelatedErrorsStayInLogcatOnly() {
        val error = IOException("unrelated")
        Log.setLogger(logger)
        try {
            Log.e("ExoPlayerImplInternal", "Playback error", error)
        } finally {
            Log.setLogger(Log.Logger.DEFAULT)
        }
        assertTrue(events.isEmpty())
        assertEquals(listOf(error), logcatErrors)
    }
}
