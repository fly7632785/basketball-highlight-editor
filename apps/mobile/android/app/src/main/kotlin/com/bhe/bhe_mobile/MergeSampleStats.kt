package com.bhe.bhe_mobile

/**
 * 合并导出时按片段统计写入情况，只为了在「样本数对不上」时能区分
 * 「文件其实完好、两种数法口径不同」和「muxer 真的丢了样本」。
 *
 * 只收集数字和类型，不含路径/文件名。
 */
internal class MergeIntervalStats(val clipStartUs: Long) {
    var samples = 0L
    var firstPtsUs = -1L
    var lastPtsUs = -1L
    /** 源样本早于片段起点、时间戳被夹成 0 的条数。 */
    var clampedToZero = 0L
    /** 输出时间戳没有严格递增（后一个 <= 前一个）的次数。 */
    var nonMonotonic = 0L
    var syncSamples = 0L

    fun record(sourcePtsUs: Long, outputPtsUs: Long, isSync: Boolean) {
        samples++
        if (sourcePtsUs < clipStartUs) clampedToZero++
        if (firstPtsUs < 0L) firstPtsUs = outputPtsUs
        if (lastPtsUs >= 0L && outputPtsUs <= lastPtsUs) nonMonotonic++
        lastPtsUs = outputPtsUs
        if (isSync) syncSamples++
    }
}

internal class MergeVideoStats {
    val intervals = mutableListOf<MergeIntervalStats>()
    var writtenVideoSamples = 0L

    fun startInterval(clipStartUs: Long): MergeIntervalStats =
        MergeIntervalStats(clipStartUs).also { intervals.add(it) }

    fun finishInterval(stats: MergeIntervalStats) {
        writtenVideoSamples += stats.samples
    }
}

/**
 * 把统计整理成诊断事件。键名必须在 NativeDiagnosticEvent 的白名单里。
 * 每个片段、每条轨各一条事件，避免字段互相覆盖。
 */
internal object MergeMismatchReport {
    fun events(stats: MergeVideoStats, facts: MergeMediaFacts): List<Pair<String, Map<String, Any>>> {
        val events = mutableListOf<Pair<String, Map<String, Any>>>(
            "export.merge.mismatch" to linkedMapOf(
                "written" to stats.writtenVideoSamples,
                "readable" to facts.readableVideoSamples,
                "clips" to stats.intervals.size,
                "duration_ms" to facts.durationMs,
                "tracks" to facts.videoTracks,
            ),
        )
        stats.intervals.forEachIndexed { index, interval ->
            events.add(
                "export.merge.interval" to linkedMapOf(
                    "interval" to index,
                    "samples" to interval.samples,
                    "clamped" to interval.clampedToZero,
                    "nonmono" to interval.nonMonotonic,
                    "sync" to interval.syncSamples,
                    "pts_first" to interval.firstPtsUs,
                    "pts_last" to interval.lastPtsUs,
                    "clip_start_us" to interval.clipStartUs,
                ),
            )
        }
        facts.tracks.forEachIndexed { index, track ->
            events.add(
                "export.merge.track" to linkedMapOf(
                    "track" to index,
                    "mime" to track.mime,
                    "width" to track.width,
                    "height" to track.height,
                    "fps" to track.frameRate,
                    "track_duration_ms" to track.durationUs / 1000L,
                    "readable" to track.samples,
                    "sync" to track.syncSamples,
                    "pts_first" to track.firstPtsUs,
                    "pts_last" to track.lastPtsUs,
                ),
            )
        }
        return events
    }
}
