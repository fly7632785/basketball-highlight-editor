package com.bhe.bhe_mobile.diagnostics

import org.junit.Assert.*
import org.junit.Test

class NativeDiagnosticEventTest {
    @Test fun onlySafeStructuredFieldsAndThirtyCodeFramesAreRecorded() {
        val error = IllegalArgumentException("open /storage/emulated/0/private/video.mp4 failed")
        error.stackTrace = (1..60).map { StackTraceElement("com.bhe.Test", "run", "/private/source/Test.kt", it) }.toTypedArray()
        val text = NativeDiagnosticEvent.format("export.audio.skipped", mapOf(
            "mime" to "audio/apac", "track" to 1, "videoPath" to "/sdcard/personal/video.mp4", "projectName" to "alice"), error)
        assertTrue(text.contains("audio/apac")); assertTrue(text.contains("IllegalArgumentException"))
        assertFalse(text.contains("/storage")); assertFalse(text.contains("/private")); assertFalse(text.contains("alice"))
        assertEquals(30, text.lineSequence().count { it.contains(" at ") })
        assertTrue(text.contains("Test.kt:30")); assertFalse(text.contains("Test.kt:31"))
    }
    @Test fun rimCheckFrameLayoutRecordsBothCallbacksWithoutFileInfo() {
        val text = NativeDiagnosticEvent.format("analysis.rim_check.frame_layout", mapOf(
            "width" to 2160, "height" to 3840, "rotation_degrees" to 90,
            "yuv_frames" to 120, "yuv_size" to "3840x2160",
            "bitmap_frames" to 1, "bitmap_size" to "540x960",
            "retriever_attempts" to 1, "videoPath" to "/private/game.mp4",
        ))
        assertEquals(
            "analysis.rim_check.frame_layout width=2160 height=3840 rotation_degrees=90 " +
                "yuv_frames=120 yuv_size=3840x2160 bitmap_frames=1 bitmap_size=540x960 retriever_attempts=1",
            text,
        )
    }

    @Test fun endOfSourceClipFailureKeepsOnlySafeDiagnosticFields() {
        val text = NativeDiagnosticEvent.format("export.failed", mapOf(
            "operation" to "exportPortraitClip", "stage" to "portraitRendering",
            "clip_index" to 9, "clip_requested_start_us" to 205_000_000L,
            "clip_end_us" to 208_500_000L, "event_ms" to 208_000, "duration_ms" to 208_300,
            "code" to "EXPORT_FAILED", "media3_error_code" to 5001,
            "media3_error_name" to "ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED",
            "error_message" to "Video frame processing error",
            "inputPath" to "/private/basketball.mp4",
        ), IllegalStateException("private basketball.mp4"))
        assertTrue(text.contains("clip_index=9"))
        assertTrue(text.contains("clip_end_us=208500000"))
        assertTrue(text.contains("event_ms=208000 duration_ms=208300"))
        assertTrue(text.contains("media3_error_code=5001 media3_error_name=ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED"))
        assertTrue(text.contains("error_message=Video frame processing error"))
        assertFalse(text.contains("basketball.mp4"))
        val unsafe = NativeDiagnosticEvent.format("export.failed", mapOf("error_message" to "private-basketball.mp4"))
        assertEquals("export.failed", unsafe)
    }

    @Test fun nativeUncaughtHandlerDelegatesEvenWhenItsLoggerFails() {
        var original = 0; val failure = IllegalStateException("test")
        val handler = LoggingUncaughtHandler({ throw IllegalStateException("logger unavailable") },
            Thread.UncaughtExceptionHandler { _, error -> assertSame(failure, error); original++ })
        handler.uncaughtException(Thread.currentThread(), failure); assertEquals(1, original)
    }

    @Test fun mergeWriteFailureRetainsSampleDetailsWithoutPathsOrLabels() {
        val fields = linkedMapOf(
            "batch_group" to 2, "interval" to 1, "clip_requested_start_us" to 33_000L,
            "clip_start_us" to 29_000L, "clip_end_us" to 40_000L, "output_base_us" to 0L,
            "source_track" to 2, "mux_track" to 1, "is_video" to false,
            "sample_pts_us" to 28_000L, "output_pts_us" to 0L, "prev_output_pts_us" to 0L,
            "flags" to 0, "sample_bytes" to 128, "wrote_samples" to true,
            "video_samples" to 1L, "was_transcoded" to false,
        )
        val text = NativeDiagnosticEvent.format("export.merge.write_failed", fields + mapOf(
            "inputPath" to "/storage/private/video.mp4",
            "label" to "private_label",
        ))
        assertEquals(
            fields.entries.joinToString(" ", prefix = "export.merge.write_failed ") { (key, value) -> "$key=$value" },
            text,
        )
    }
}
