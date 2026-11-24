package com.bhe.bhe_mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class VideoImportSpaceTest {
    @Test fun insufficientStorageReportsTheShortfallBeforeCopy() {
        val gib = 1024L * 1024 * 1024
        assertEquals(gib + VideoImportSpace.RESERVE_BYTES, VideoImportSpace.missingBytes(2 * gib, gib))
        assertEquals(0L, VideoImportSpace.missingBytes(gib, 2 * gib))
        assertEquals(VideoImportSpace.RESERVE_BYTES, VideoImportSpace.missingBytes(-1, 0))
    }
}
