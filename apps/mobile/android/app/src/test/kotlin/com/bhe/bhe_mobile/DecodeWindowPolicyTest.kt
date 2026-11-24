package com.bhe.bhe_mobile

import org.junit.Assert.*
import org.junit.Test

class DecodeWindowPolicyTest {
    @Test fun acceptsReportedEighteenOfNineteenAtPhysicalTail() {
        DecodeWindowPolicy.requireUsable(
            FrameDecodeResult(18, true, 208_267_000, false),
            requested = 19, windowEndMs = 208_400, durationMs = 208_400, fps = 10.0,
        )
    }

    @Test fun earlyEosDoesNotQualifyAsPhysicalTail() {
        assertThrows(VideoDecodeException::class.java) {
            DecodeWindowPolicy.requireUsable(
                FrameDecodeResult(18, true, 207_800_000, false),
                requested = 19, windowEndMs = 208_400, durationMs = 208_400, fps = 10.0,
            )
        }
    }

    @Test fun middleWindowAndMissingInteriorFrameCannotBeSilentlyAccepted() {
        for (interiorGap in listOf(false, true)) {
            assertThrows(VideoDecodeException::class.java) {
                DecodeWindowPolicy.requireUsable(
                    FrameDecodeResult(18, true, 208_267_000, interiorGap),
                    requested = 19, windowEndMs = if (interiorGap) 208_400 else 208_300,
                    durationMs = 208_400, fps = 10.0,
                )
            }
        }
    }

    @Test fun emptyEosCannotOverwriteLastFrameButDataBearingEosCanRender() {
        assertFalse(DecodeWindowPolicy.isFrameOutput(true, false, 0))
        assertTrue(DecodeWindowPolicy.isFrameOutput(true, false, 1024))
        assertFalse(DecodeWindowPolicy.isFrameOutput(false, true, 1024))
    }

    @Test fun codecFailureDoesNotRestartProviderButInferenceFailureStillCan() {
        val codecError = IllegalStateException("codec failed")
        val decodeError = assertThrows(VideoDecodeException::class.java) {
            DecodeWindowPolicy.decode<Unit> { throw codecError }
        }
        assertSame(codecError, decodeError.cause)
        assertFalse(DecodeWindowPolicy.retryOnCpu(decodeError, "qnn", false))
        val inferenceError = IllegalStateException("inference failed")
        val callbackError = assertThrows(IllegalStateException::class.java) {
            DecodeWindowPolicy.decode { invoke -> invoke { throw inferenceError } }
        }
        assertSame(inferenceError, callbackError)
        assertTrue(DecodeWindowPolicy.retryOnCpu(callbackError, "qnn", false))
        assertFalse(DecodeWindowPolicy.retryOnCpu(InterruptedException(), "qnn", false))
    }
}
