package com.bhe.bhe_mobile

import org.junit.Assert.*
import org.junit.Test

class ExportTrackPolicyTest {
    private val video = ExportSourceTrack(0, "video/hevc")
    private val spatial = ExportSourceTrack(1, "audio/apac")
    private val aac = ExportSourceTrack(2, "audio/mp4a-latm")

    @Test fun rejectedAudioPreservesVideoAndOriginalTrackMapping() {
        val selection = ExportTrackPolicy.select(listOf(video, spatial, aac), addTrack = { index ->
            if (index == 1) throw IllegalArgumentException("unsupported audio")
            if (index == 0) 4 else 7
        })
        assertEquals(mapOf(0 to 4, 2 to 7), selection.trackMap)
        assertEquals(listOf(spatial), selection.skippedAudio)
    }
    @Test fun rejectedVideoFailsInsteadOfReportingSuccess() {
        assertThrows(IllegalStateException::class.java) {
            ExportTrackPolicy.select(listOf(video, aac), addTrack = { throw IllegalArgumentException("unsupported") })
        }
    }
    @Test fun audioOnlyInputCannotBecomeASuccessfulVideoExport() {
        assertThrows(IllegalStateException::class.java) {
            ExportTrackPolicy.select(listOf(aac), addTrack = { 0 })
        }
    }
    @Test fun acceptedAudioHasNoWarningAndMetadataIsNotSelected() {
        val selection = ExportTrackPolicy.select(listOf(video, aac, ExportSourceTrack(3, "application/meta")), addTrack = { it })
        assertEquals(mapOf(0 to 0, 2 to 2), selection.trackMap)
        assertTrue(selection.skippedAudio.isEmpty())
    }

    // 杜比视界手机视频：Android 报 video/dolby-vision + video/hevc 两条视频轨，
    // 加上 aac 和两条 acse（时间元数据）。只能选 hevc + aac。
    @Test fun dolbyVisionPicksBaseHevcTrackAndSkipsTheVisionTrack() {
        val tracks = listOf(
            ExportSourceTrack(0, "video/dolby-vision"),
            ExportSourceTrack(1, "video/hevc"),
            ExportSourceTrack(2, "audio/mp4a-latm"),
            ExportSourceTrack(3, "application/acse1"),
            ExportSourceTrack(4, "application/acse2"),
        )
        val skippedVideo = mutableListOf<ExportSourceTrack>()
        val selection = ExportTrackPolicy.select(
            tracks,
            addTrack = { it },
            onSkippedVideo = { track, _ -> skippedVideo.add(track) },
        )
        assertEquals(mapOf(1 to 1, 2 to 2), selection.trackMap)
        assertEquals(listOf(ExportSourceTrack(0, "video/dolby-vision")), selection.skippedVideo)
        assertEquals(listOf(ExportSourceTrack(0, "video/dolby-vision")), skippedVideo)
        assertTrue(selection.skippedAudio.isEmpty())
    }

    @Test fun dolbyVisionOnlyTrackIsStillExported() {
        val tracks = listOf(
            ExportSourceTrack(0, "video/dolby-vision"),
            ExportSourceTrack(1, "audio/mp4a-latm"),
        )
        val selection = ExportTrackPolicy.select(tracks, addTrack = { it })
        assertEquals(mapOf(0 to 0, 1 to 1), selection.trackMap)
        assertTrue(selection.skippedVideo.isEmpty())
    }

    @Test fun twoAvcTracksKeepOnlyTheFirstVideoTrack() {
        val tracks = listOf(
            ExportSourceTrack(0, "video/avc"),
            ExportSourceTrack(1, "video/avc"),
            ExportSourceTrack(2, "audio/mp4a-latm"),
        )
        val selection = ExportTrackPolicy.select(tracks, addTrack = { it })
        assertEquals(mapOf(0 to 0, 2 to 2), selection.trackMap)
        assertEquals(listOf(ExportSourceTrack(1, "video/avc")), selection.skippedVideo)
    }

    @Test fun hevcWinsOverAvcWhenBothArePresent() {
        val tracks = listOf(
            ExportSourceTrack(0, "video/avc"),
            ExportSourceTrack(1, "video/hevc"),
        )
        val selection = ExportTrackPolicy.select(tracks, addTrack = { it })
        assertEquals(mapOf(1 to 1), selection.trackMap)
    }

    @Test fun orientationPreservesAllQuarterTurnsAndNormalizesNegativeAngles() {
        for (degrees in listOf(0, 90, 180, 270)) assertEquals(degrees, ExportTrackPolicy.orientation(degrees))
        assertEquals(270, ExportTrackPolicy.orientation(-90))
        assertEquals(0, ExportTrackPolicy.orientation(360))
        assertThrows(IllegalArgumentException::class.java) { ExportTrackPolicy.orientation(45) }
    }
}
