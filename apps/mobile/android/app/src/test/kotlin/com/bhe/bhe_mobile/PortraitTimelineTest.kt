package com.bhe.bhe_mobile

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class PortraitTimelineTest {
    @Test fun relativeRenderTimeUsesTheOriginalClipClock() {
        val plan = PortraitTimeline(2300, 2700, listOf(
            PortraitKeyframe(2300, .30),
            PortraitKeyframe(2500, .60),
            PortraitKeyframe(2700, .70),
        ))
        assertEquals(.30, plan.centerAt(0), 1e-9)
        assertEquals(.45, plan.centerAt(100_000), 1e-9)
        assertEquals(.65, plan.centerAt(300_000), 1e-9)
        assertEquals(.70, plan.centerAt(1_000_000), 1e-9)
    }

    @Test fun landscapeCropsSidewaysAndAlreadyPortraitSourcesAreRejected() {
        val landscape = PortraitGeometry(1920, 1080)
        assertEquals(1920 / 607.5, landscape.scaleX, 1e-6)
        assertEquals(-landscape.translationX(0.0), landscape.translationX(1.0), 1e-6)
        assertEquals(1.0, landscape.scaleY, 1e-6)
        for ((width, height) in listOf(2160 to 3840, 900 to 1920)) {
            val error = assertThrows(IllegalArgumentException::class.java) {
                PortraitGeometry(width, height)
            }
            assertEquals("The source is already portrait. Follow-ball cropping is unnecessary.", error.message)
        }
        assertTrue(PortraitGeometry(2161, 3840).scaleX > 1)
    }

    @Test fun directYuvAndDisplayBitmapScaleToTheSameRotatedSource() {
        val detection = JSONObject("""{"x1":70,"y1":125,"x2":90,"y2":145,"confidence":0.8}""")
        val rotated = portraitDetection(detection, RimCheckFrameCoordinates(960, 540, 90, 2160.0, 3840.0))
        val bitmap = portraitDetection(detection, RimCheckFrameCoordinates(540, 960, 0, 2160.0, 3840.0))
        assertEquals(rotated, bitmap)
        assertEquals(mapOf("cx" to 320.0, "cy" to 540.0, "w" to 80.0, "h" to 80.0, "conf" to .8), rotated)
    }

    @Test fun hdrOnlyForHlgPqOrDolby() {
        assertTrue(isPortraitHdr("video/hevc", 7)) // HLG
        assertTrue(isPortraitHdr("video/hevc", 6)) // PQ
        assertTrue(isPortraitHdr("video/dolby-vision", 3))
        assertFalse(isPortraitHdr("video/hevc", 3)) // SDR
        assertFalse(isPortraitHdr("video/avc", -1))
    }

    @Test fun sampleGridIsTenHertzAndDoesNotDuplicateTheExclusiveEnd() {
        assertEquals(listOf(3130L, 3230L, 3330L), portraitSampleTimes(3130, 3430))
        assertEquals(listOf(3130L, 3230L, 3330L, 3430L), portraitSampleTimes(3130, 3431))
    }

    @Test fun malformedPlansFailWithoutSortingOrReusingLastGoodPlan() {
        assertThrows(IllegalArgumentException::class.java) {
            PortraitTimeline(100, 300, listOf(PortraitKeyframe(100, .5), PortraitKeyframe(100, .6)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            PortraitTimeline(100, 300, listOf(PortraitKeyframe(100, Double.NaN)))
        }
    }

    @Test fun mergeDurationUsesTrackTimeWithOneFrameOfTolerance() {
        assertTrue(portraitMergeDurationMatches(1_234_333, 1200))
        assertTrue(portraitMergeDurationMatches(1_165_667, 1200))
        assertFalse(portraitMergeDurationMatches(1_234_334, 1200))
        assertFalse(portraitMergeDurationMatches(1_165_666, 1200))
        assertFalse(portraitMergeDurationMatches(0, 1))
    }

    @Test fun nativeProgressCallsTheDartMediaContractWithinEachStage() {
        val events = mutableListOf<Pair<String, Any>>()
        for (stage in PortraitExportStage.entries) {
            stage.sendProgress({ method, payload -> events.add(method to payload) }, "portrait-job", 60, 200)
        }
        assertEquals(listOf("sampling", "encoding", "merging").map { stage ->
            "exportProgress" to mapOf("stage" to stage, "exportId" to "portrait-job", "progress" to .3)
        }, events)
    }

    @Test fun cancellationIsObservableByTheActiveExportRegistry() {
        val id = "portrait-sample-test"
        assertTrue(ExportPathRegistry.startRead(id))
        try {
            assertTrue(ExportPathRegistry.contains(id))
            assertFalse(ExportPathRegistry.startRead(id))
            assertFalse(ExportPathRegistry.releaseIdle(id))
        } finally {
            ExportPathRegistry.finish(id)
        }
        assertFalse(ExportPathRegistry.contains(id))
    }
}
