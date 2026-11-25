package com.bhe.bhe_mobile

import android.provider.MediaStore
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer

internal fun putGallerySaveDates(savedAtMs: Long, put: (String, Long) -> Unit) {
    val savedAtSeconds = savedAtMs / 1000L
    put(MediaStore.Video.Media.DATE_TAKEN, savedAtMs)
    put(MediaStore.Video.Media.DATE_ADDED, savedAtSeconds)
    put(MediaStore.Video.Media.DATE_MODIFIED, savedAtSeconds)
}

// Publishing a pending MediaStore item re-reads the date from the file.
// Change only the movie creation time in the gallery copy, without remuxing.
internal fun copyVideoForGallery(source: File, output: FileOutputStream, savedAtMs: Long) {
    val (dateOffset, dateLength) = RandomAccessFile(source, "r").use { file ->
        val movie = file.requireBox(0x6d6f6f76, 0, file.length()) // moov
        val header = file.requireBox(0x6d766864, movie.body, movie.end) // mvhd
        file.seek(header.body)
        val length = when (file.readUnsignedByte()) {
            0 -> 4
            1 -> 8
            else -> throw IOException("Unsupported MP4 movie header version")
        }
        val offset = header.body + 4
        if (header.end - offset < length) throw IOException("Truncated MP4 creation time")
        offset to length
    }
    val mp4Seconds = savedAtMs / 1000L + 2_082_844_800L // ISO BMFF epoch, 1904-01-01 UTC.
    val date = ByteBuffer.allocate(dateLength)
    if (dateLength == 4) {
        if (mp4Seconds !in 0..0xffff_ffffL) throw IOException("MP4 creation time out of range")
        date.putInt(mp4Seconds.toInt())
    } else {
        date.putLong(mp4Seconds)
    }

    FileInputStream(source).use { it.copyTo(output) }
    output.channel.position(dateOffset)
    output.write(date.array())
}

private data class Mp4Box(val body: Long, val end: Long)

private fun RandomAccessFile.requireBox(type: Int, from: Long, until: Long): Mp4Box {
    var start = from
    while (start < until) {
        if (until - start < 8) throw IOException("Truncated MP4 box")
        seek(start)
        val shortSize = readInt().toLong() and 0xffff_ffffL
        val boxType = readInt()
        val size = when (shortSize) {
            0L -> until - start
            1L -> {
                if (until - start < 16) throw IOException("Truncated MP4 box size")
                readLong()
            }
            else -> shortSize
        }
        val body = filePointer
        if (size < body - start || size > until - start) throw IOException("Invalid MP4 box size")
        val end = start + size
        if (boxType == type) return Mp4Box(body, end)
        start = end
    }
    throw IOException("MP4 movie header is missing")
}
