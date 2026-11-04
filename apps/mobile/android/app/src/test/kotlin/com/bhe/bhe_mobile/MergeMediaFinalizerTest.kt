package com.bhe.bhe_mobile

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class MergeMediaFinalizerTest {
    private val valid = MergeMediaFacts(videoTracks = 1, durationMs = 2000, readableVideoSamples = 2)
    private fun replace(from: File, to: File) {
        Files.move(from.toPath(), to.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }

    @Test fun invalidOrUnreadableMediaNeverReplacesOldOutput() {
        for (kind in listOf("garbage", "no-samples", "truncated", "corrupt-track", "zero-duration", "stop", "release", "rename")) {
            val dir = Files.createTempDirectory("merge-media").toFile()
            try {
                val old = File(dir, "out.mp4").apply { writeText("previous") }
                val temp = File(dir, "temp.mp4").apply { writeText("nonempty-$kind") }
                var stopped = false
                var released = false
                val tx = MergeOutputTransaction(temp, old, AtomicBoolean(false)) { from, to ->
                    if (kind == "rename") throw IOException("rename failed")
                    replace(from, to)
                }
                try {
                    assertThrows(Exception::class.java) {
                        MergeMediaFinalizer.finish(
                            transaction = tx,
                            writtenVideoSamples = if (kind == "no-samples") 0 else 2,
                            stop = { stopped = true; if (kind == "stop") throw IOException("stop failed") },
                            release = { released = true; if (kind == "release") throw IOException("release failed") },
                            inspect = {
                                when (kind) {
                                    "garbage" -> throw IOException("container cannot be parsed")
                                    "truncated" -> valid.copy(readableVideoSamples = 1)
                                    "corrupt-track" -> valid.copy(videoTracks = 0)
                                    "zero-duration" -> valid.copy(durationMs = 0)
                                    else -> valid
                                }
                            },
                        )
                    }
                } finally { tx.cleanup() }
                assertTrue("stop called: $kind", stopped)
                assertTrue("release attempted: $kind", released)
                assertEquals("previous", old.readText())
                assertFalse(temp.exists())
            } finally { dir.deleteRecursively() }
        }
    }

    @Test fun temporaryCreationFailureDoesNotTouchPreviousFile() {
        val dir = Files.createTempDirectory("merge-create").toFile()
        try {
            val old = File(dir, "out.mp4").apply { writeText("previous") }
            assertThrows(IOException::class.java) {
                MergeOutputFiles.create(old) { throw IOException("permission denied") }
            }
            assertEquals("previous", old.readText())
            assertEquals(listOf("out.mp4"), dir.list()!!.toList())
        } finally { dir.deleteRecursively() }
    }

    @Test fun validMediaPublishesOnlyAfterStopReleaseAndInspection() {
        val dir = Files.createTempDirectory("merge-valid").toFile()
        try {
            val old = File(dir, "out.mp4").apply { writeText("previous") }
            val temp = File(dir, "temp.mp4").apply { writeText("new") }
            val steps = mutableListOf<String>()
            val tx = MergeOutputTransaction(temp, old, AtomicBoolean(false)) { from, to -> steps.add("rename"); replace(from, to) }
            try {
                MergeMediaFinalizer.finish(tx, 2, { steps.add("stop") }, { steps.add("release") }, { steps.add("inspect"); valid })
            } finally { tx.cleanup() }
            assertEquals(listOf("stop", "release", "inspect", "rename"), steps)
            assertEquals("new", old.readText())
        } finally { dir.deleteRecursively() }
    }

    @Test fun cancellationBeforeOrDuringFinalizationPreservesOldOutput() {
        for (stage in listOf("before-stop", "during-stop", "after-stop", "during-inspection")) {
            val dir = Files.createTempDirectory("merge-cancel").toFile()
            try {
                val old = File(dir, "out.mp4").apply { writeText("previous") }
                val temp = File(dir, "temp.mp4").apply { writeText("new") }
                val tx = MergeOutputTransaction(temp, old, AtomicBoolean(false), ::replace)
                if (stage == "before-stop") tx.cancel()
                try {
                    assertThrows(InterruptedException::class.java) {
                        MergeMediaFinalizer.finish(tx, 2,
                            stop = { if (stage == "during-stop") tx.cancel() },
                            release = { if (stage == "after-stop") tx.cancel() },
                            inspect = { if (stage == "during-inspection") tx.cancel(); valid },
                        )
                    }
                } finally { tx.cleanup() }
                assertEquals("previous", old.readText())
                assertFalse(temp.exists())
            } finally { dir.deleteRecursively() }
        }
    }
    @Test fun unlocatableOrVideolessIntervalIsDistinguished() {
        assertThrows(MergeRangeUnavailable::class.java) {
            MergeMediaFinalizer.requireLocation(NO_SAMPLE_TIME, -1)
        }
        assertThrows(MergeRangeUnavailable::class.java) { MergeMediaFinalizer.requireVideoSamples(0) }
        MergeMediaFinalizer.requireLocation(0, 0)
        MergeMediaFinalizer.requireVideoSamples(1)
    }

    @Test fun negativeStartPtsIsAValidLocation() {
        // 手机录制常见：首个样本 PTS 是负数（如 -1,000,000µs），不是「没有样本」。
        MergeMediaFinalizer.requireLocation(-1_000_000L, 0)
        MergeMediaFinalizer.requireLocation(-33_333L, 3)
    }

}
