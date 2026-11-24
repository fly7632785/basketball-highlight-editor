package com.bhe.bhe_mobile

/** Keep room for project metadata and avoid filling the volume while importing. */
internal object VideoImportSpace {
    const val RESERVE_BYTES = 128L * 1024 * 1024
    fun missingBytes(size: Long, available: Long): Long =
        (size.coerceAtLeast(0).coerceAtMost(Long.MAX_VALUE - RESERVE_BYTES) +
            RESERVE_BYTES - available.coerceAtLeast(0)).coerceAtLeast(0)
}
