package com.bhe.bhe_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MergeSampleStatsTest {
    private fun facts(readable: Long, tracks: List<MergeTrackFacts> = emptyList()) =
        MergeMediaFacts(videoTracks = 1, durationMs = 2000, readableVideoSamples = readable, tracks = tracks)

    @Test fun samplePtsRetainsClampAndClipBaseWithoutForcingMonotonicity() {
        val clipStartUs = -1_000L
        val outputBaseUs = 20_000L
        val sourcePts = listOf(-1_000L, -1_200L, 3_000L, 2_000L)
        assertEquals(
            listOf(20_000L, 20_000L, 24_000L, 23_000L),
            sourcePts.map { mergeSamplePtsUs(it, clipStartUs, outputBaseUs) },
        )
    }

    @Test fun seamKeepsTheLastVideoFrameDurationAndIncreasingPresentationTimes() {
        val first = MergeClipWindow(startUs = 18_000_000, endUs = 25_211_000, outputBaseUs = 0)
        val lastPts = mergeSamplePtsUs(25_200_000, first.startUs, first.outputBaseUs)
        assertTrue(first.includes(25_200_000, isVideo = true))
        assertFalse(first.includes(25_216_667, isVideo = true))
        val second = MergeClipWindow(73_000_000, 77_186_000, first.nextOutputBaseUs(25_216_667))
        val outputPts = listOf(
            lastPts,
            mergeSamplePtsUs(second.startUs, second.startUs, second.outputBaseUs),
            mergeSamplePtsUs(73_016_667, second.startUs, second.outputBaseUs),
        )
        assertEquals(listOf(16_667L, 16_667L), outputPts.zipWithNext { prev, next -> next - prev })
    }

    @Test fun audioUsesTheVideoAnchorWithoutClampingEarlierAudioOntoIt() {
        val window = MergeClipWindow(startUs = 73_000_000, endUs = 77_186_000, outputBaseUs = 7_216_667)
        assertFalse(window.includes(72_996_000, isVideo = false))
        assertTrue(window.includes(73_000_000, isVideo = false))
        assertTrue(window.includes(73_003_537, isVideo = false))
        assertFalse(window.includes(77_186_000, isVideo = false))
        val videoPts = mergeSamplePtsUs(window.startUs, window.startUs, window.outputBaseUs)
        val audioPts = mergeSamplePtsUs(73_003_537, window.startUs, window.outputBaseUs)
        assertEquals(window.outputBaseUs, videoPts)
        assertEquals(3_537L, audioPts - videoPts)
    }

    @Test fun aNonFinalClipMustHaveAKnownNextVideoFrame() {
        assertThrows(MergeRangeUnavailable::class.java) {
            MergeClipWindow(18_000_000, 25_211_000, 0).nextOutputBaseUs(null)
        }
    }

    @Test fun countsClampedNonMonotonicAndSyncSamples() {
        val stats = MergeVideoStats()
        val interval = stats.startInterval(clipStartUs = 1000)
        // 片段起点前被夹成 0 的两个样本（PTS 都是 0 → 第二个非单调）
        interval.record(sourcePtsUs = 500, outputPtsUs = 0, isSync = true)
        interval.record(sourcePtsUs = 800, outputPtsUs = 0, isSync = false)
        interval.record(sourcePtsUs = 1000, outputPtsUs = 0, isSync = false)
        interval.record(sourcePtsUs = 1400, outputPtsUs = 400, isSync = true)
        stats.finishInterval(interval)

        assertEquals(4, interval.samples)
        assertEquals(2, interval.clampedToZero)
        // 0,0,0,400：第二个和第三个都 <= 前一个
        assertEquals(2, interval.nonMonotonic)
        assertEquals(0, interval.firstPtsUs)
        assertEquals(400, interval.lastPtsUs)
        assertEquals(2, interval.syncSamples)
        assertEquals(4, stats.writtenVideoSamples)
    }

    @Test fun mismatchReportCarriesBothCountsAndPerIntervalNumbers() {
        val stats = MergeVideoStats()
        val interval = stats.startInterval(clipStartUs = 0)
        interval.record(sourcePtsUs = 0, outputPtsUs = 0, isSync = true)
        interval.record(sourcePtsUs = 33000, outputPtsUs = 33000, isSync = false)
        stats.finishInterval(interval)

        val events = MergeMismatchReport.events(stats, facts(readable = 1))
        val summary = events.first { it.first == "export.merge.mismatch" }.second
        assertEquals(2L, summary["written"])
        assertEquals(1L, summary["readable"])
        assertEquals(1, summary["clips"])

        val detail = events.first { it.first == "export.merge.interval" }.second
        assertEquals(2L, detail["samples"])
        assertEquals(0L, detail["clamped"])
        assertEquals(1L, detail["sync"])
        assertEquals(33000L, detail["pts_last"])
    }

    @Test fun perTrackFactsAreReportedOneEventPerTrack() {
        val stats = MergeVideoStats()
        val track = MergeTrackFacts(
            mime = "video/avc", width = 1920, height = 1080, frameRate = 30f,
            durationUs = 2_000_000, samples = 60, syncSamples = 1,
            firstPtsUs = 500_000, lastPtsUs = 1_500_000,
        )
        val events = MergeMismatchReport.events(stats, facts(readable = 60, tracks = listOf(track)))
        val event = events.first { it.first == "export.merge.track" }.second
        assertEquals("video/avc", event["mime"])
        assertEquals(1920, event["width"])
        assertEquals(2000L, event["track_duration_ms"])
        assertEquals(60L, event["readable"])
        assertEquals(500_000L, event["pts_first"])
        assertTrue(events.count { it.first == "export.merge.track" } == 1)
    }

    @Test fun everyReportedKeyIsAllowedByTheDiagnosticAllowlist() {
        val stats = MergeVideoStats()
        val interval = stats.startInterval(clipStartUs = 0)
        interval.record(sourcePtsUs = 0, outputPtsUs = 0, isSync = true)
        stats.finishInterval(interval)
        val track = MergeTrackFacts("video/hevc", 1080, 1920, 30f, 1, 1, 1, 0, 0)
        MergeMismatchReport.events(stats, facts(readable = 1, tracks = listOf(track))).forEach { (event, fields) ->
            val line = com.bhe.bhe_mobile.diagnostics.NativeDiagnosticEvent.format(event, fields)
            fields.keys.forEach { key ->
                assertTrue("$key 被诊断白名单丢掉：$line", key in line)
            }
        }
    }
}
