package com.bhe.bhe_mobile

import java.io.File

/** Process-wide reservations; a running worker retains its path until cleanup. */
internal object ExportPathRegistry {
    private data class Entry(val path: String?, var started: Boolean = false)
    private val entries = mutableMapOf<String, Entry>()
    private val paths = mutableMapOf<String, String>()

    @Synchronized fun reserve(id: String, outputPath: String): Boolean {
        val path = File(outputPath).canonicalPath
        if (entries.containsKey(id) || paths.containsKey(path)) return false
        entries[id] = Entry(path)
        paths[path] = id
        return true
    }

    @Synchronized fun start(id: String, outputPath: String): Boolean {
        val entry = entries[id] ?: return false
        if (entry.started || entry.path != File(outputPath).canonicalPath) return false
        entry.started = true
        return true
    }

    @Synchronized fun startRead(id: String): Boolean {
        if (entries.containsKey(id)) return false
        entries[id] = Entry(null, started = true)
        return true
    }

    @Synchronized fun releaseIdle(id: String): Boolean {
        val entry = entries[id] ?: return false
        if (entry.started) return false
        finish(id)
        return true
    }

    @Synchronized fun contains(id: String): Boolean = entries.containsKey(id)

    @Synchronized fun finish(id: String) {
        val entry = entries.remove(id) ?: return
        entry.path?.let { paths.remove(it, id) }
    }
}
