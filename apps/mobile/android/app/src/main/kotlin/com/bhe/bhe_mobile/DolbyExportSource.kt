package com.bhe.bhe_mobile

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import com.bhe.bhe_mobile.diagnostics.AppDiagnostics
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

@UnstableApi
internal object DolbyExportSource {
    fun transcodeIfNeeded(context: Context, path: String, cancelled: AtomicBoolean): File? {
        val reader = MediaExtractor()
        val needsTranscode = try {
            VideoInput.open(reader, path)
            (0 until reader.trackCount).any { index ->
                val format = reader.getTrackFormat(index)
                format.getString(MediaFormat.KEY_MIME) == DolbyVisionPolicy.MIME &&
                    !DolbyVisionFormat.canUseHevcBase(format)
            }
        } finally {
            reader.release()
        }
        if (!needsTranscode) return null

        val temporary = File.createTempFile("bhe-dolby-", ".mp4", context.cacheDir)
        try {
            transcode(context, path, temporary, cancelled)
            return temporary
        } catch (error: Exception) {
            temporary.delete()
            if (error is InterruptedException) throw error
            throw IllegalStateException("杜比视界视频转码失败，无法导出画面。", error)
        }
    }

    private fun transcode(context: Context, path: String, output: File, cancelled: AtomicBoolean) {
        // Transformer is confined to the main looper; the existing export worker waits.
        val handler = Handler(Looper.getMainLooper())
        val finished = CountDownLatch(1)
        var failure: Exception? = null
        var transformer: Transformer? = null
        handler.post {
            try {
                if (cancelled.get()) {
                    finished.countDown()
                    return@post
                }
                val media = MediaItem.fromUri(VideoInput.uri(path))
                val sequence = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO, C.TRACK_TYPE_VIDEO))
                    .addItem(EditedMediaItem.Builder(media).build()).build()
                val composition = Composition.Builder(sequence)
                    .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL).build()
                transformer = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            if (exportResult.videoFrameCount <= 0) failure = IllegalStateException("No transcoded video frames")
                            finished.countDown()
                        }

                        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                            failure = exportException
                            finished.countDown()
                        }
                    }).build()
                transformer!!.start(composition, output.absolutePath)
                AppDiagnostics.event("export.dolby.transcode.started")
            } catch (error: Exception) {
                failure = error
                finished.countDown()
            }
        }
        while (!finished.await(100, TimeUnit.MILLISECONDS)) {
            if (!cancelled.get()) continue
            val stopped = CountDownLatch(1)
            handler.post {
                try { transformer?.cancel() } finally { stopped.countDown() }
            }
            stopped.await()
            throw InterruptedException("导出已取消")
        }
        if (cancelled.get()) throw InterruptedException("导出已取消")
        failure?.let { throw it }
        AppDiagnostics.event("export.dolby.transcode.completed")
    }
}
