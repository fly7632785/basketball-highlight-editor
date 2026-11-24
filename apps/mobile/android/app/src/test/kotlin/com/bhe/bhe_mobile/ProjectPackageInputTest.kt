package com.bhe.bhe_mobile

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.FilterInputStream
import java.io.InputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class ProjectPackageInputTest {
    @Test
    fun readsMetadataWithoutReadingFollowingVideoFromNonSeekableUri() {
        val metadata = """{"name":"篮球"}""".toByteArray()
        val archive = zip("project.json" to metadata, "video.mp4" to ByteArray(128 * 1024))
        var count = 0
        val stream = object : FilterInputStream(archive.inputStream()) {
            override fun markSupported() = false
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                super.read(buffer, offset, length).also { if (it > 0) count += it }
        }
        assertArrayEquals(metadata, ProjectPackageInput.read(stream))
        assertTrue(count < archive.size)
    }

    @Test
    fun readsMetadataAfterOtherEntries() {
        val metadata = """{"name":"project"}""".toByteArray()
        val archive = zip("clip.mp4" to ByteArray(100), "project.json" to metadata)
        assertArrayEquals(metadata, ProjectPackageInput.read(archive.inputStream()))
    }

    @Test
    fun readsRawJson() {
        val bytes = """{"name":"篮球"}""".toByteArray()
        assertArrayEquals(bytes, ProjectPackageInput.read(bytes.inputStream()))
    }

    @Test(expected = ProjectPackageInput.MissingMetadata::class)
    fun rejectsZipWithoutProjectJson() {
        ProjectPackageInput.read(zip("video.mp4" to byteArrayOf(1)).inputStream())
    }

    @Test(expected = ProjectPackageInput.MetadataTooLarge::class)
    fun boundsUnknownLengthJson() {
        val input = object : InputStream() {
            override fun read() = ' '.code
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                buffer.fill(' '.code.toByte(), offset, offset + length)
                return length
            }
        }
        ProjectPackageInput.read(input)
    }

    private fun zip(vararg entries: Pair<String, ByteArray>): ByteArray {
        val bytes = ByteArrayOutputStream()
        ZipOutputStream(bytes).use { zip ->
            zip.setLevel(0)
            for ((name, data) in entries) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(data)
                zip.closeEntry()
            }
        }
        return bytes.toByteArray()
    }
}
