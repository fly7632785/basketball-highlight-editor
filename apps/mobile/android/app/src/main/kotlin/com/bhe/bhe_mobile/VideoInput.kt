package com.bhe.bhe_mobile

import android.content.ContentResolver
import android.content.Context
import android.content.res.AssetFileDescriptor
import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.DocumentsContract
import android.system.Os
import android.system.OsConstants
import java.io.EOFException
import java.io.File
import java.io.FileNotFoundException
import java.security.MessageDigest

/** Source videos can be ordinary files or persisted Android documents. */
internal object VideoInput {
    private lateinit var resolver: ContentResolver

    fun configure(context: Context) {
        resolver = context.applicationContext.contentResolver
    }

    fun isDocument(path: String) = path.startsWith("content://")
    fun uri(path: String): Uri = if (isDocument(path)) Uri.parse(path) else Uri.fromFile(File(path))

    private fun <T> read(path: String, block: (AssetFileDescriptor) -> T): T =
        (resolver.openAssetFileDescriptor(uri(path), "r") ?: throw FileNotFoundException("Video document unavailable"))
            .use(block)

    fun seekableSize(path: String): Long = read(path) {
        Os.lseek(it.fileDescriptor, 0L, OsConstants.SEEK_CUR)
        val length = it.length
        require(length > 0) { "Document has no known readable length" }
        length
    }

    fun modified(path: String): Long = runCatching {
        val column = DocumentsContract.Document.COLUMN_LAST_MODIFIED
        resolver.query(uri(path), arrayOf(column), null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(column)
            if (index >= 0 && cursor.moveToFirst()) cursor.getLong(index) else 0L
        } ?: 0L
    }.getOrDefault(0L)

    fun open(extractor: MediaExtractor, path: String) {
        if (!isDocument(path)) {
            extractor.setDataSource(path)
            return
        }
        read(path) { extractor.setDataSource(it.fileDescriptor, it.startOffset, it.length) }
    }

    fun open(retriever: MediaMetadataRetriever, path: String) {
        if (!isDocument(path)) {
            retriever.setDataSource(path)
            return
        }
        read(path) { retriever.setDataSource(it.fileDescriptor, it.startOffset, it.length) }
    }

    /** Same first/last MiB and length hash as the Dart local-file importer. */
    fun fingerprint(path: String): String = read(path) { asset ->
        val length = asset.length
        require(length > 0) { "Document has no known readable length" }
        val digest = MessageDigest.getInstance("SHA-256")
        val sample = 1024 * 1024
        val buffer = ByteArray(sample)
        fun add(offset: Long, bytes: Int) {
            var count = 0
            while (count < bytes) {
                val read = Os.pread(asset.fileDescriptor, buffer, count, bytes - count, asset.startOffset + offset + count)
                if (read <= 0) throw EOFException("Incomplete video fingerprint")
                count += read
            }
            digest.update(buffer, 0, bytes)
        }
        add(0, minOf(length, sample.toLong()).toInt())
        if (length > sample) add(length - sample, sample)
        digest.update(length.toString().toByteArray(Charsets.UTF_8))
        digest.digest().joinToString("") { "%02x".format(it) }
    }
}
