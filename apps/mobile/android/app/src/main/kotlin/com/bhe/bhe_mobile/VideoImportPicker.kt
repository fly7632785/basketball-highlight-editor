package com.bhe.bhe_mobile

import android.app.Activity
import android.content.Intent
import android.os.StatFs
import android.provider.OpenableColumns
import android.provider.DocumentsContract
import com.bhe.bhe_mobile.diagnostics.AppDiagnostics
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/** Read system documents without the stock picker’s automatic cache copy. */
internal class VideoImportPicker(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var projectSelection = false
    private val requestCode = 4561

    fun pruneGrants(referenced: Set<String>) {
        val resolver = activity.contentResolver
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        // This app persists document grants only for video. Leave recent
        // selections alone in case their project has not committed yet.
        for (permission in resolver.persistedUriPermissions) {
            if (!permission.isReadPermission || permission.isWritePermission ||
                permission.persistedTime >= cutoff || permission.uri.toString() in referenced) continue
            runCatching {
                resolver.releasePersistableUriPermission(permission.uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }
    }

    fun pick(result: MethodChannel.Result, project: Boolean = false) {
        if (pending != null) {
            result.error("already_active", "Document picker already active", null)
            return
        }
        pending = result
        projectSelection = project
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                type = if (project) "*/*" else "video/*"
                addCategory(Intent.CATEGORY_OPENABLE)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }, requestCode)
        } catch (error: Exception) {
            pending = null
            if (project) result.error("PROJECT_IMPORT_FAILED", null, null)
            else result.error("VIDEO_PICK_FAILED", "无法打开系统视频选择器", null)
        }
    }

    fun onResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != requestCode) return false
        val result = pending ?: return true
        // Keep the picker busy until the background copy also finishes.
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) {
            pending = null
            result.success(null)
            return true
        }
        if (projectSelection) {
            Thread {
                try {
                    val metadata = activity.contentResolver.openInputStream(uri)?.let(ProjectPackageInput::read)
                        ?: throw IOException("Cannot read selected project")
                    activity.runOnUiThread {
                        pending = null
                        result.success(metadata)
                    }
                } catch (error: Exception) {
                    AppDiagnostics.event("project.import.failed", mapOf("kind" to error.javaClass.simpleName))
                    val errorCode = when (error) {
                        is ProjectPackageInput.MetadataTooLarge -> "PROJECT_METADATA_TOO_LARGE"
                        is ProjectPackageInput.MissingMetadata -> "PROJECT_METADATA_MISSING"
                        is SecurityException -> "PROJECT_READ_PERMISSION"
                        else -> "PROJECT_IMPORT_FAILED"
                    }
                    activity.runOnUiThread {
                        pending = null
                        result.error(errorCode, null, null)
                    }
                }
            }.start()
            return true
        }
        Thread {
            var temporary: File? = null
            try {
                val resolver = activity.contentResolver
                var name = "video.mp4"
                var size = -1L
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
                    }
                }
                val alreadyGranted = resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }
                val directSize = runCatching {
                    resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    VideoInput.seekableSize(uri.toString())
                }.getOrNull()
                if (directSize != null) {
                    AppDiagnostics.event("video.import.document", mapOf("bytes" to directSize))
                    activity.runOnUiThread {
                        pending = null
                        result.success(mapOf("path" to uri.toString(), "name" to name, "size" to directSize))
                    }
                    return@Thread
                }
                if (!alreadyGranted) runCatching {
                    resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                fun requireSpace(bytes: Long) {
                    val available = StatFs(activity.cacheDir.absolutePath).availableBytes
                    val missing = VideoImportSpace.missingBytes(bytes, available)
                    if (missing > 0) throw ImportSpaceException(missing)
                }
                // Unknown provider sizes are checked incrementally as well.
                val modified = runCatching {
                    val column = DocumentsContract.Document.COLUMN_LAST_MODIFIED
                    resolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
                        val index = cursor.getColumnIndex(column)
                        if (index >= 0 && cursor.moveToFirst()) cursor.getLong(index) else 0L
                    } ?: 0L
                }.getOrDefault(0L)
                requireSpace(size)
                val directory = File(activity.cacheDir, "file_picker").also { it.mkdirs() }
                val extension = name.substringAfterLast('.', "mp4").lowercase()
                    .takeIf { it.matches(Regex("[a-z0-9]{1,10}")) } ?: "mp4"
                val output = File.createTempFile("bhe-import-", ".$extension", directory)
                temporary = output
                resolver.openInputStream(uri)?.use { input ->
                    output.outputStream().use { destination ->
                        val buffer = ByteArray(1024 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            requireSpace(count.toLong())
                            destination.write(buffer, 0, count)
                        }
                    }
                } ?: throw IOException("Cannot read selected video")
                check(size < 0 || output.length() == size) { "Incomplete video import" }
                if (modified > 0) output.setLastModified(modified)
                val importedSize = output.length()
                AppDiagnostics.event("video.import.copied", mapOf("bytes" to importedSize))
                activity.runOnUiThread {
                    pending = null
                    result.success(mapOf("path" to output.absolutePath, "name" to name, "size" to importedSize))
                }
            } catch (error: Exception) {
                temporary?.delete() // Only this attempt's incomplete copy.
                AppDiagnostics.event("video.import.failed", mapOf("kind" to error.javaClass.simpleName))
                activity.runOnUiThread {
                    pending = null
                    if (error is ImportSpaceException) {
                        result.error("VIDEO_STORAGE_INSUFFICIENT", "手机空间不足", mapOf("missingBytes" to error.missing))
                    } else if (generateSequence<Throwable>(error) { it.cause }.any {
                        it is android.system.ErrnoException && it.errno == android.system.OsConstants.ENOSPC ||
                            it.message?.contains("ENOSPC", ignoreCase = true) == true
                    }) {
                        result.error("VIDEO_STORAGE_INSUFFICIENT", "手机空间不足", null)
                    } else {
                        result.error("VIDEO_IMPORT_FAILED", "视频导入失败，请重新选择", null)
                    }
                }
            }
        }.start()
        return true
    }

    private class ImportSpaceException(val missing: Long) : IOException("Insufficient storage")
}
