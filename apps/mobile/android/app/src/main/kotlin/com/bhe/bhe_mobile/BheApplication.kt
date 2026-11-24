package com.bhe.bhe_mobile

import android.app.Application
import androidx.media3.common.util.Log
import androidx.media3.common.util.UnstableApi
import com.bhe.bhe_mobile.diagnostics.AppDiagnostics
import com.bhe.bhe_mobile.diagnostics.LoggingUncaughtHandler
import com.bhe.bhe_mobile.diagnostics.PlaybackDiagnostics

class BheApplication : Application() {
    @UnstableApi
    override fun onCreate() {
        super.onCreate()
        VideoInput.configure(this)
        AppDiagnostics.configure(this)
        Log.setLogger(PlaybackDiagnostics({ event, fields -> AppDiagnostics.event(event, fields) }))
        Thread.getDefaultUncaughtExceptionHandler()?.let { previous ->
            Thread.setDefaultUncaughtExceptionHandler(LoggingUncaughtHandler(
                { error -> AppDiagnostics.event("app.error.native", error = error) }, previous,
            ))
        }
    }
}
