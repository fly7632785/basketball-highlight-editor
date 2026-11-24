package com.bhe.bhe_mobile

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.zip.ZipInputStream

internal object ProjectPackageInput {
    private const val MAX_METADATA_BYTES = 32 * 1024 * 1024

    class MetadataTooLarge : IOException("Project metadata exceeds 32 MiB")
    class MissingMetadata : IOException("Missing project.json")

    // Document providers can return pipes. Do not require a file path or seek.
    fun read(input: InputStream): ByteArray = BufferedInputStream(input).use { buffered ->
        buffered.mark(4)
        val zip = buffered.read() == 0x50 && buffered.read() == 0x4b &&
            buffered.read() == 0x03 && buffered.read() == 0x04
        buffered.reset()
        if (zip) readArchive(buffered) else readMetadata(buffered)
    }

    private fun readArchive(input: InputStream): ByteArray {
        ZipInputStream(input).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: throw MissingMetadata()
                if (!entry.isDirectory && entry.name == "project.json") {
                    if (entry.size > MAX_METADATA_BYTES) throw MetadataTooLarge()
                    return readMetadata(zip)
                }
                // A preceding entry is drained through the ZIP stream, never retained.
                zip.closeEntry()
            }
        }
    }

    private fun readMetadata(input: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer)
            if (count == -1) return output.toByteArray()
            if (count > MAX_METADATA_BYTES - output.size()) throw MetadataTooLarge()
            output.write(buffer, 0, count)
        }
    }
}
