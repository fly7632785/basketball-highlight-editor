package com.bhe.bhe_mobile

import android.provider.MediaStore
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class GalleryVideoDatesTest {
    @Test fun galleryDatesUseTheSaveClockWithTheCorrectUnits() {
        val oldRecordingMs = 1_795_004_270_000L
        val savedAtMs = 1_795_609_789_123L
        val values = mutableMapOf(MediaStore.Video.Media.DATE_TAKEN to oldRecordingMs)
        putGallerySaveDates(savedAtMs) { column, value -> values[column] = value }

        assertEquals(savedAtMs, values[MediaStore.Video.Media.DATE_TAKEN])
        assertEquals(1_795_609_789L, values[MediaStore.Video.Media.DATE_ADDED])
        assertEquals(1_795_609_789L, values[MediaStore.Video.Media.DATE_MODIFIED])
    }

    @Test fun galleryCopyOnlyChangesTheCreationDateInBothMp4HeaderVersions() {
        val source = File.createTempFile("gallery-original-", ".mp4")
        val gallery = File.createTempFile("gallery-saved-", ".mp4")
        try {
            for (version in 0..1) {
                val original = ByteBuffer.allocate(56)
                    .putInt(12).putInt(0x6d646174).putInt(0x12345678) // media stays byte-identical
                    .putInt(1).putInt(0x6d6f6f76).putLong(44) // 64-bit movie box size
                    .putInt(28).putInt(0x6d766864).putInt(version shl 24)
                    .putLong(0x7040404070404040).putLong(0x7282828272828282).array()
                source.writeBytes(original)
                FileOutputStream(gallery).use {
                    copyVideoForGallery(source, it, 1_795_609_789_123L)
                }
                val expected = original.copyOf()
                val date = ByteBuffer.wrap(expected)
                date.position(40)
                if (version == 0) date.putInt(3_878_454_589L.toInt())
                else date.putLong(3_878_454_589L)
                assertArrayEquals(original, source.readBytes())
                assertArrayEquals(expected, gallery.readBytes())
            }
        } finally {
            source.delete()
            gallery.delete()
        }
    }
}
