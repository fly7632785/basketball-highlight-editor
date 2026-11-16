package com.bhe.bhe_mobile

import com.bhe.bhe_mobile.diagnostics.RotatingLogStore
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class RimCheckSessionTest {
    private fun config(provider: String = "qnn") = JSONObject()
        .put("model_path", "qnn-context.onnx")
        .put("execution_provider", provider)
        .put("execution_provider_backend", "libQnnHtp.so")
        .put("optimized_model_path", "main-cache.onnx")
        .put("model_size", 640)
        .put("detection_only", true)
        .put("analysis_roi", JSONObject().put("left", 0.25))

    @Test fun successfulPrimarySessionIsReturnedWithoutRetry() {
        var calls = 0
        assertEquals(42L, RimCheckSession.create(config(), "source.onnx", {
            calls++; 42L
        }, { error("must not query errors on success") }, { error("must not log failure") }))
        assertEquals(1, calls)
    }

    @Test fun acceleratorFailureRetriesPortableCpuModelAndRetainsRimSettings() {
        val original = config()
        val attempts = mutableListOf<JSONObject>()
        val logs = mutableListOf<String>()
        val session = RimCheckSession.create(original, "source.onnx", {
            attempts.add(JSONObject(it))
            if (attempts.size == 1) 0L else 73L
        }, { "QNN context unavailable" }, { logs.add(it) })
        assertEquals(73L, session)
        assertEquals(2, attempts.size)
        val cpu = attempts[1]
        assertEquals("cpu", cpu.getString("execution_provider"))
        assertEquals("source.onnx", cpu.getString("model_path"))
        assertEquals(InferenceTuner.CPU_THREADS, cpu.getInt("intra_threads"))
        assertFalse(cpu.has("optimized_model_path"))
        assertFalse(cpu.has("execution_provider_backend"))
        assertEquals(640, cpu.getInt("model_size"))
        assertTrue(cpu.getBoolean("detection_only"))
        assertEquals(0.25, cpu.getJSONObject("analysis_roi").getDouble("left"), 0.0)
        assertEquals("qnn", original.getString("execution_provider"))
        assertTrue(original.has("optimized_model_path"))
        assertTrue(logs.first().contains("QNN context unavailable"))
        assertTrue(logs.last().contains("fallback succeeded"))
    }

    @Test fun cpuPrimaryFailureAlsoRetriesWithoutPossiblyInvalidCache() {
        var calls = 0
        assertEquals(9L, RimCheckSession.create(config("cpu"), "source.onnx", {
            calls++
            if (calls == 1) 0L else {
                assertFalse(JSONObject(it).has("optimized_model_path"))
                9L
            }
        }, { "invalid cached graph" }, {}))
        assertEquals(2, calls)
    }

    @Test fun bothFailuresExposeBothCausesAndNeverRetryAgain() {
        var calls = 0
        val logs = mutableListOf<String>()
        val error = assertThrows(IllegalStateException::class.java) {
            RimCheckSession.create(config(), "source.onnx", { calls++; 0L }, {
                if (calls == 1) "QNN context error" else "source model missing"
            }, { logs.add(it) })
        }
        assertEquals(2, calls)
        assertTrue(error.message!!.contains("qnn: QNN context error"))
        assertTrue(error.message!!.contains("CPU: source model missing"))
        assertEquals(error.message, logs.last())
    }

    @Test fun missingNativeCauseHasExplicitFallbackText() {
        val error = assertThrows(IllegalStateException::class.java) {
            RimCheckSession.create(config(), "source.onnx", { 0L }, { "" }, {})
        }
        assertTrue(error.message!!.contains("native session creation returned 0"))
    }

    @Test fun fallbackSuccessReasonsReachDiagnosticsTailWithBasenamesOnly() {
        val directory = Files.createTempDirectory("bhe-rim-diagnostics").toFile()
        try {
            val store = RotatingLogStore(directory)
            val logcat = mutableListOf<String>()
            val qnnPath = "/data/user/0/private user/models/qnn-context.onnx"
            val cachePath = "/data/user/0/private user/cache/main-cache.onnx"
            val original = config().put("model_path", qnnPath).put("optimized_model_path", cachePath)
            var calls = 0
            assertEquals(8L, RimCheckSession.create(original, "/data/user/0/private user/models/source.onnx", {
                calls++; if (calls == 1) 0L else 8L
            }, { "Load $qnnPath failed; cache '$cachePath' incompatible\nQNN error 42" }, { message ->
                logcat.add(message)
                store.record("analysis.rim_check.session $message")
            }))
            val tail = store.tail()
            assertEquals(2, logcat.size)
            assertEquals(2, tail.size)
            assertTrue(tail.first().contains("provider=qnn"))
            assertTrue(tail.first().contains("qnn-context.onnx"))
            assertTrue(tail.first().contains("main-cache.onnx"))
            assertTrue(tail.first().contains("QNN error 42"))
            assertTrue(tail.last().contains("CPU fallback succeeded"))
            assertTrue(tail.last().contains("QNN error 42"))
            assertFalse(tail.joinToString().contains("private user"))
            assertFalse(logcat.any { '/' in it || '\\' in it || '\n' in it })
        } finally { directory.deleteRecursively() }
    }

    @Test fun fallbackFailureReasonsReachDiagnosticsTailWithoutNativeSourcePaths() {
        val directory = Files.createTempDirectory("bhe-rim-diagnostics").toFile()
        try {
            val store = RotatingLogStore(directory)
            var calls = 0
            val source = "C:\\private user\\models\\source.onnx"
            val error = assertThrows(IllegalStateException::class.java) {
                RimCheckSession.create(config(), source, { calls++; 0L }, {
                    if (calls == 1) "QNN failed at /build/private/onnxruntime/core/session.cc:42"
                    else "Load model from $source failed: missing file; backend '/private user/backend/libQnnHtp.so' unavailable"
                }, { store.record("analysis.rim_check.session $it") })
            }
            val tail = store.tail()
            assertEquals(2, tail.size)
            assertTrue(tail.first().contains("provider=qnn"))
            assertTrue(tail.first().contains("session.cc:42"))
            assertTrue(tail.last().contains("CPU: Load model from source.onnx failed: missing file"))
            assertTrue(tail.last().contains("backend 'libQnnHtp.so' unavailable"))
            assertFalse(tail.joinToString().contains("private"))
            assertFalse(tail.any { '/' in it || '\\' in it })
            assertFalse(error.message!!.contains(source))
        } finally { directory.deleteRecursively() }
    }
}
