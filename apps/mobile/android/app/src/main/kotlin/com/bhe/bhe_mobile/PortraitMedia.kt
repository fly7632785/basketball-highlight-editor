package com.bhe.bhe_mobile

import android.content.Context
import android.graphics.Matrix
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.Size
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.MatrixTransformation
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

internal data class PortraitMediaRange(val path: String, val startMs: Long, val endMs: Long) {
    init {
        require(path.isNotBlank() && startMs >= 0 && endMs > startMs && endMs <= Long.MAX_VALUE / 1000) {
            "Invalid portrait media range"
        }
    }
}

internal data class PortraitSource(
    val width: Int,
    val height: Int,
    val durationMs: Long,
    val isHdr: Boolean,
    val hasAudio: Boolean,
) {
    companion object {
        fun read(path: String): PortraitSource {
            val extractor = MediaExtractor()
            try {
                VideoInput.open(extractor, path)
                val formats = (0 until extractor.trackCount).map(extractor::getTrackFormat)
                val video = formats.firstOrNull { it.getString(MediaFormat.KEY_MIME) == DolbyVisionPolicy.MIME }
                    ?: formats.firstOrNull { it.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
                    ?: throw IllegalArgumentException("No video track")
                val width = video.getInteger(MediaFormat.KEY_WIDTH)
                val height = video.getInteger(MediaFormat.KEY_HEIGHT)
                val rotated = video.getInteger(MediaFormat.KEY_ROTATION, 0) % 180 != 0
                return PortraitSource(
                    if (rotated) height else width,
                    if (rotated) width else height,
                    video.getLong(MediaFormat.KEY_DURATION) / 1000,
                    isPortraitHdr(video.getString(MediaFormat.KEY_MIME), video.getInteger(MediaFormat.KEY_COLOR_TRANSFER, -1)),
                    formats.any { it.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true },
                )
            } finally {
                extractor.release()
            }
        }
    }
}

@UnstableApi
internal class PortraitMedia(private val context: Context) {
    fun render(
        range: PortraitMediaRange,
        timeline: PortraitTimeline,
        output: File,
        cancelled: AtomicBoolean,
        progress: (Int) -> Unit,
    ) {
        val source = PortraitSource.read(range.path)
        val effect = object : MatrixTransformation {
            private var geometry: PortraitGeometry? = null

            override fun configure(inputWidth: Int, inputHeight: Int): Size {
                // Media3 applies the track's rotation before user effects.
                geometry = PortraitGeometry(inputWidth, inputHeight)
                return Size(PORTRAIT_WIDTH, PORTRAIT_HEIGHT)
            }

            override fun getMatrix(presentationTimeUs: Long): Matrix {
                val crop = checkNotNull(geometry)
                return Matrix().apply {
                    setScale(crop.scaleX.toFloat(), crop.scaleY.toFloat())
                    postTranslate(crop.translationX(timeline.centerAt(presentationTimeUs)).toFloat(), 0f)
                }
            }
        }
        val clip = EditedMediaItem.Builder(mediaItem(range))
            .setEffects(Effects(emptyList(), listOf(effect))).build()
        transform(composition(listOf(clip), source.hasAudio, source.isHdr), output, cancelled, progress)
        verifyOutput(output, source.hasAudio, portrait = true)
    }

    fun prepareSdrSample(
        range: PortraitMediaRange,
        source: PortraitSource,
        output: File,
        cancelled: AtomicBoolean,
        progress: (Int) -> Unit,
    ) {
        val scale = minOf(1.0, 960.0 / maxOf(source.width, source.height))
        val width = ((source.width * scale / 2).roundToInt() * 2).coerceAtLeast(2)
        val height = ((source.height * scale / 2).roundToInt() * 2).coerceAtLeast(2)
        val clip = EditedMediaItem.Builder(mediaItem(range))
            .setRemoveAudio(true)
            .setEffects(Effects(emptyList(), listOf(
                Presentation.createForWidthAndHeight(width, height, Presentation.LAYOUT_SCALE_TO_FIT),
            )))
            .build()
        transform(composition(listOf(clip), hasAudio = false, hdr = true), output, cancelled, progress)
        verifyOutput(output, hasAudio = false, portrait = false)
    }

    fun merge(
        clips: List<PortraitMediaRange>,
        output: File,
        cancelled: AtomicBoolean,
        progress: (Int) -> Unit,
    ) {
        val sources = clips.map { PortraitSource.read(it.path) }
        val hasAudio = sources.first().hasAudio
        check(sources.all { it.width == PORTRAIT_WIDTH && it.height == PORTRAIT_HEIGHT &&
            !it.isHdr && it.hasAudio == hasAudio }) { "Incompatible rendered portrait tracks" }
        // These items are complete, independently encoded outputs, not source
        // trims. The encoder may have rounded the planned length to its frame grid.
        val items = clips.map { EditedMediaItem.Builder(MediaItem.fromUri(VideoInput.uri(it.path))).build() }
        transform(composition(items, hasAudio, hdr = false, concatenate = true), output, cancelled, progress)
        verifyOutput(output, hasAudio, portrait = true)
    }

    private fun mediaItem(range: PortraitMediaRange): MediaItem = MediaItem.Builder()
        .setUri(VideoInput.uri(range.path))
        .setClippingConfiguration(MediaItem.ClippingConfiguration.Builder()
            .setStartPositionMs(range.startMs)
            .setEndPositionMs(range.endMs)
            .build())
        .build()

    private fun composition(
        clips: List<EditedMediaItem>,
        hasAudio: Boolean,
        hdr: Boolean,
        concatenate: Boolean = false,
    ): Composition {
        val trackTypes = if (hasAudio) setOf(C.TRACK_TYPE_VIDEO, C.TRACK_TYPE_AUDIO) else setOf(C.TRACK_TYPE_VIDEO)
        val sequence = EditedMediaItemSequence.Builder(trackTypes).addItems(clips).build()
        return Composition.Builder(sequence)
            .setHdrMode(if (hdr) Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL else Composition.HDR_MODE_KEEP_HDR)
            .setTransmuxVideo(concatenate)
            .setTransmuxAudio(concatenate && hasAudio)
            .build()
    }

    private fun verifyOutput(file: File, hasAudio: Boolean, portrait: Boolean) {
        val output = PortraitSource.read(file.absolutePath)
        check(output.durationMs > 0 && !output.isHdr) { "Portrait export did not produce a readable SDR video" }
        check(output.hasAudio == hasAudio) { "Portrait export did not preserve its audio track" }
        if (portrait) {
            check(output.width == PORTRAIT_WIDTH && output.height == PORTRAIT_HEIGHT) {
                "Unexpected portrait display size: ${output.width}x${output.height}"
            }
        }
    }

    // Run Transformer on its owning looper, using the same export worker
    // cancellation flag that the existing channel sets.
    private fun transform(
        composition: Composition,
        output: File,
        cancelled: AtomicBoolean,
        progress: (Int) -> Unit,
    ) {
        val handler = Handler(Looper.getMainLooper())
        val finished = CountDownLatch(1)
        var transformer: Transformer? = null
        var failure: Exception? = null
        val holder = ProgressHolder()
        var lastProgress = -1
        val poll = object : Runnable {
            override fun run() {
                if (finished.count == 0L) return
                val active = checkNotNull(transformer)
                try {
                    if (cancelled.get()) {
                        active.cancel()
                        finished.countDown()
                        return
                    }
                    if (active.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE &&
                        holder.progress / 10 > lastProgress) {
                        lastProgress = holder.progress / 10
                        progress(holder.progress)
                    }
                    handler.postDelayed(this, 100)
                } catch (error: Exception) {
                    failure = error
                    finished.countDown()
                }
            }
        }
        handler.post {
            try {
                requirePortraitActive(cancelled)
                val active = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setEncoderFactory(DefaultEncoderFactory.Builder(context).setEnableFallback(false).build())
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, result: ExportResult) {
                            finished.countDown()
                        }

                        override fun onError(composition: Composition, result: ExportResult, error: ExportException) {
                            failure = error
                            finished.countDown()
                        }
                    }).build()
                transformer = active
                active.start(composition, output.absolutePath)
                handler.post(poll)
            } catch (error: Exception) {
                failure = error
                finished.countDown()
            }
        }
        // The completion callback follows the final muxer close. A cancellation
        // stays active in the registry until Transformer has stopped.
        while (!finished.await(100, TimeUnit.MILLISECONDS)) {
            // Cancellation is observed on the Transformer looper.
        }
        requirePortraitActive(cancelled)
        failure?.let { throw it }
        progress(100)
    }
}

internal fun requirePortraitActive(cancelled: AtomicBoolean) {
    if (cancelled.get()) throw InterruptedException("导出已取消")
}
